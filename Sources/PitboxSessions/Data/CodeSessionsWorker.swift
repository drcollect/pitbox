import Foundation
import PitboxKit

/// The data side's work, all on one serial background queue: discovery, the session index, the pop-out files, careful
/// reads of session files and transcript tails, the state rules and the offers. File events mark sessions dirty; while
/// the block is visible a dirty session is parsed at most once per `parseInterval` (newer changes join the pending
/// parse), and a one-shot timer re-evaluates time-based states (the 10 s summary grace, the 30 s tool wait, the 30 min
/// quiet, the 24 h offer limit, the sparkline's minute). While the block is hidden nothing runs on a timer: events only
/// mark sessions dirty. Results go to `publish`, only when they changed.
final class CodeSessionsWorker: @unchecked Sendable {
    /// What the engine shows.
    struct Publication: Equatable, Sendable {
        var sessions: [CodeSessionSnapshot]
        var profiles: [CodeProfile]
        var processes: [ClaudeProcessInfo]
        var banner: String?
        /// Sessions active within `CodeTuning.readyRecentHoursMax`, by id.
        var recent: [CodeRecentSession] = []
    }

    let environment: CodeSessionsEnvironment
    let checker: CodeOfferFreshnessChecker
    private let publish: @Sendable (Publication, Set<CommandOffer.ID>) -> Void
    private let queue = DispatchQueue(label: "pitbox.code.sessions", qos: .utility)
    /// Marks `queue`, so the memory store's change callback can tell this engine's own writes apart.
    private let queueKey = DispatchSpecificKey<UInt8>()

    // Everything below is used on `queue` only.
    private var running = false
    private var visible = false
    private var settings = CodeSettings()
    private var processes: [ClaudeProcessInfo] = []
    private var indices: [String: SessionIndex] = [:]
    private var indicesBuiltAt = -TimeInterval.infinity
    private var popouts: [String: [ClaudePopouts.Entry]] = [:]
    private var popoutIdentity: [String: FileIdentity] = [:]
    private var popoutFailureLogged: [String: String] = [:]
    private var watched: Set<String> = []
    private var records: [String: SessionRecord] = [:]
    private var order: [String] = []
    private var indexByID: [String: Int] = [:]
    private var firstSeenByID: [String: Int] = [:]
    private var nextIndex = 1
    private var nextSeen = 0
    private var sshFacts = SSHConfigFacts()
    private var sshFactsReadAt = -TimeInterval.infinity
    private var hostNames: [String: String?] = [:]
    private var programsCache: (at: TimeInterval, value: Set<String>?)?
    private var dirty: Set<String> = []
    private var dirtyPopouts: Set<String> = []
    private var scheduledParses: [String: DispatchWorkItem] = [:]
    private var scheduledPopouts: [String: DispatchWorkItem] = [:]
    private var lastParseAt: [String: TimeInterval] = [:]
    private var lastPopoutsAt: [String: TimeInterval] = [:]
    private var publishItem: DispatchWorkItem?
    private var evaluationTimer: DispatchSourceTimer?
    private var nextDeadline: Date?
    private var folderWatcher: CodeFolderWatcher?
    private var watchedFolders: [String] = []
    private var popoutWatchers: [String: CodeFileWatcher] = [:]
    /// "<folder>/<file>.jsonl" → session id, for transcript events.
    private var transcriptKeys: [String: String] = [:]
    private var lastPublication: Publication?
    private var publishedOfferIDs: Set<CommandOffer.ID> = []
    private var bannerLogged = false
    private var capLogged = false

    // Derivers and recent sessions, also on `queue` only.
    private let deriveRunner = CodeDeriveRunner()
    private var memory: CodeMemoryStore?
    private var memoryObserver: UUID?
    private var memoryVersions: [String: Int] = [:]
    private var settingsVersion = 0
    private var recentScanner = RecentSessionScanner()
    private var recent: [CodeRecentSession] = []
    /// Session files named by file events since the last scan, and whether only a full scan is reliable now.
    private var recentChanged: Set<String> = []
    private var recentNeedsFullScan = false
    private var lastArchived: Set<String> = []
    private var scheduledRecentScan: DispatchWorkItem?
    private var lastRecentScanAt = -TimeInterval.infinity

    init(environment: CodeSessionsEnvironment, checker: CodeOfferFreshnessChecker,
         publish: @escaping @Sendable (Publication, Set<CommandOffer.ID>) -> Void) {
        self.environment = environment
        self.checker = checker
        self.publish = publish
        queue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        if let memoryObserver { memory?.removeObserver(memoryObserver) }
    }

    // MARK: Requests (any thread)

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            settings = environment.settings()
            discover()
            rebuildIndices()
            readSSHFacts(force: true)
            for profile in readableRunning { readPopouts(profile) }
            syncSessions()
            for id in order { readSession(id) }
            dirty = []
            scanRecent(publishing: false)
            updateWatchers()
            publishNow()
            scheduleEvaluation()
            CodeLog.info("started processes=\(processes.count) sessions=\(order.count) followed=\(watched.count) "
                + "recent=\(recent.count) derivers=\(deriveRunner.count)")
        }
    }

    func stop() {
        queue.async { [self] in
            guard running else { return }
            running = false
            cancelScheduled()
            stopWatchers()
            checker.unregisterAll()
            for id in records.keys { leave(id) }
            recentScanner.reset()
            recent = []
            records = [:]
            order = []
            popouts = [:]
            popoutIdentity = [:]
            dirty = []
            dirtyPopouts = []
            transcriptKeys = [:]
            let stale = publishedOfferIDs
            publishedOfferIDs = []
            let empty = Publication(sessions: [], profiles: [], processes: [], banner: nil)
            lastPublication = empty
            publish(empty, stale)
            CodeLog.info("stopped")
        }
    }

    func setVisible(_ value: Bool) {
        queue.async { [self] in
            guard visible != value else { return }
            visible = value
            guard running else { return }
            if value {
                reloadSettings()
                let processesMoved = discover()
                readSSHFacts(force: false)
                for profile in readableRunning { dirtyPopouts.insert(profile.folderName) }
                var changed = false
                for profile in readableRunning where dirtyPopouts.contains(profile.folderName) {
                    if readPopouts(profile) { changed = true }
                }
                if changed { applySessionSetChange() }
                for id in dirty.sorted() { scheduleParse(id) }
                if recentNeedsFullScan || processesMoved || !recentChanged.isEmpty {
                    scanRecent(publishing: false, full: recentNeedsFullScan || processesMoved)
                }
                publishNow()
                scheduleEvaluation()
            } else {
                cancelScheduled()
            }
        }
    }

    func setWatched(_ ids: Set<String>) {
        queue.async { [self] in
            let valid = Set(ids.filter(CodeIDs.isSessionID))
            guard valid != watched else { return }
            watched = valid
            guard running else { return }
            applySessionSetChange()
        }
    }

    /// Reads everything again now (settings, processes, the index, the SSH config, pop-outs, every shown session).
    func refresh() {
        queue.async { [self] in
            guard running else { return }
            reloadSettings()
            discover()
            rebuildIndices()
            readSSHFacts(force: true)
            programsCache = nil
            for id in order { records[id]?.replies = [] }
            deriveRunner.forgetCaches()
            for profile in readableRunning { readPopouts(profile) }
            syncSessions()
            for id in order { readSession(id) }
            dirty = []
            scanRecent(publishing: false)
            updateWatchers()
            publishNow()
            scheduleEvaluation()
        }
    }

    /// Claude may have launched or quit.
    func processesChanged() {
        queue.async { [self] in
            guard running, discover() else { return }
            followProcessChange()
        }
    }

    /// Who runs (or which copies are known) changed: the pop-outs and recent sessions of the readable copies are read
    /// now while visible, else marked for the next show.
    private func followProcessChange() {
        if visible {
            for profile in readableRunning { readPopouts(profile) }
            scanRecent(publishing: false)
        } else {
            for profile in readableRunning { dirtyPopouts.insert(profile.folderName) }
            recentNeedsFullScan = true
        }
        applySessionSetChange()
    }

    /// The derivers to run after each parse and the store they keep their records in (replacing earlier ones).
    func setDerivers(_ set: CodeDeriverSet, memory store: CodeMemoryStore) {
        queue.async { [self] in
            deriveRunner.replace(with: set, leaving: Array(records.keys))
            if memory !== store {
                if let memoryObserver { memory?.removeObserver(memoryObserver) }
                memory = store
                memoryObserver = store.addObserver { [weak self] id in
                    // This engine's own derivers write from its queue while deriving: those writes are already seen.
                    guard let self, DispatchQueue.getSpecific(key: self.queueKey) == nil else { return }
                    self.queue.async { self.memoryChanged(id) }
                }
            }
            pruneMemory()
            if running { schedulePublish() }
        }
    }

    /// The settings file may have changed (a hand edit or the menu): read it and derive again.
    func settingsChanged() {
        queue.async { [self] in
            guard running else { return }
            if reloadSettings(), discover() { followProcessChange() }
            schedulePublish()
        }
    }

    /// Runs `done` on the queue after the work queued so far, a pending publication included.
    func flush(then done: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            if publishItem != nil {
                publishNow()
                scheduleEvaluation()
            }
            done()
        }
    }

    /// Tests: what the worker holds.
    var debugState: (sessions: [String], fullyRead: Int, dirty: Int, watchedFolders: [String], timerArmed: Bool) {
        queue.sync {
            (order, records.values.filter(\.fullyRead).count, dirty.count, watchedFolders, evaluationTimer != nil)
        }
    }

    // MARK: Processes, settings, SSH config

    @discardableResult
    private func discover() -> Bool {
        let found = ClaudeProcessDiscovery.resolve(environment.processes(), applicationSupport: environment.applicationSupport,
                                                   profiles: knownProfiles)
        guard found != processes else { return false }
        processes = found
        let letters = runningProfiles.map(\.letter).joined()
        CodeLog.info("processes=\(found.count) profiles=\(letters.isEmpty ? "none" : letters)")
        return true
    }

    private var runningProfiles: [CodeProfile] {
        var seen = Set<CodeProfile>()
        return processes.map(\.profile).filter { seen.insert($0).inserted }
    }

    private var readableRunning: [CodeProfile] { runningProfiles.filter(\.isReadable) }

    /// The copies the settings file lists, with the default one.
    private var knownProfiles: CodeProfiles { CodeProfiles(settings) }

    /// Reads the settings again; true when the list of copies (`profiles`) changed. Then the indexes and the folders
    /// watched follow at once; the callers find out who is who again (`discover`).
    @discardableResult
    private func reloadSettings() -> Bool {
        let fresh = environment.settings()
        guard fresh != settings else { return false }
        let profilesChanged = fresh.profiles != settings.profiles
        settings = fresh
        if profilesChanged {
            rebuildIndices()
            updateWatchers()
        }
        settingsVersion &+= 1
        programsCache = nil
        for id in order { records[id]?.replies = [] }
        return profilesChanged
    }

    private func readSSHFacts(force: Bool) {
        let now = MonotonicClock.now()
        guard force || now - sshFactsReadAt > 30 else { return }
        sshFactsReadAt = now
        let facts = SSHConfigReader.read(configPath: environment.sshConfig.path,
                                         sshFolder: environment.sshConfig.deletingLastPathComponent().path,
                                         home: environment.homeDirectory, owner: environment.userID)
        guard facts != sshFacts else { return }
        if facts.fingerprint != sshFacts.fingerprint {
            hostNames = [:]
            for id in order { records[id]?.replies = [] }
        }
        sshFacts = facts
        CodeLog.info("ssh config files=\(facts.filesRead) refused=\(facts.filesRefused) skipped=\(facts.filesSkipped) hosts=\(facts.exactHosts.count) match=\(facts.hasMatch ? "yes" : "no")")
    }

    /// `ssh -G` only when every file was read without a problem and none has `Match` (`allowsHostLookup`).
    private func hostName(_ alias: String) -> String? {
        guard sshFacts.allowsHostLookup, sshFacts.isExactHost(alias) else { return nil }
        if let cached = hostNames[alias] { return cached }
        let value = environment.hostName(alias)
        hostNames[alias] = .some(value)
        return value
    }

    private func cleanPathPrograms() -> Set<String>? {
        let now = MonotonicClock.now()
        if let cache = programsCache, now - cache.at < 60 { return cache.value }
        let value = environment.programsOnCleanPath(settings.usableExtraPath())
        programsCache = (now, value)
        return value
    }

    // MARK: Index and pop-outs

    private func profileFolder(_ profile: CodeProfile) -> CarefulPath? {
        CarefulPath(root: environment.applicationSupport.path, components: [profile.folderName])
    }

    private func rebuildIndices() {
        // A copy that left `profiles` keeps no index (the names and places of its session files) in memory.
        let keep = Set(knownProfiles.known.map(\.folderName))
        indices = indices.filter { keep.contains($0.key) }
        for profile in knownProfiles.known {
            guard let folder = profileFolder(profile) else { continue }
            indices[profile.folderName] = SessionIndex.build(profileFolder: folder, owner: environment.userID)
        }
        indicesBuiltAt = MonotonicClock.now()
        pruneMemory()
    }

    private func knownProfile(of id: String) -> CodeProfile? {
        knownProfiles.known.first { indices[$0.folderName]?.locations[id] != nil }
    }

    /// Reads a copy's `session-popouts.json` when it changed. A missing file means no pop-out is open; a
    /// file that fails its checks keeps what was read before. True when the list changed.
    @discardableResult
    private func readPopouts(_ profile: CodeProfile) -> Bool {
        let key = profile.folderName
        lastPopoutsAt[key] = MonotonicClock.now()
        dirtyPopouts.remove(key)
        guard let path = profileFolder(profile)?.appending(ClaudePopouts.fileName) else { return false }
        let entries: [ClaudePopouts.Entry]
        switch CarefulFiles.readIfChanged(path, owner: environment.userID, maxBytes: ClaudePopouts.maxBytes,
                                          known: popoutIdentity[key]) {
        case .failure(.missing):
            entries = []
            popoutIdentity[key] = nil
            popoutFailureLogged[key] = nil
        case .failure(let failure):
            logPopoutFailure(profile, failure.label)
            return false
        case .success(let (data, identity)):
            guard let data else { return false }
            switch ClaudePopouts.parse(data) {
            case .failure(let failure):
                logPopoutFailure(profile, failure.label)
                return false
            case .success(let parsed):
                popoutIdentity[key] = identity
                popoutFailureLogged[key] = nil
                entries = parsed.entries
                if parsed.rejected > 0 { CodeLog.warn("popouts profile=\(profile.letter) rejected=\(parsed.rejected)") }
            }
        }
        guard popouts[key] != entries else { return false }
        popouts[key] = entries
        CodeLog.info("popouts profile=\(profile.letter) count=\(entries.count)")
        return true
    }

    private func logPopoutFailure(_ profile: CodeProfile, _ label: String) {
        guard popoutFailureLogged[profile.folderName] != label else { return }
        popoutFailureLogged[profile.folderName] = label
        CodeLog.warn("popouts profile=\(profile.letter) failed=\(label)")
    }

    // MARK: The set of sessions

    /// The sessions to show: pop-outs of the running readable copies, then the followed ones found in any known copy's
    /// index. Order: copy, then first seen. The first `maxWatchedSessions` (followed ones first) are read fully.
    /// Returns the sessions that need a read now.
    @discardableResult
    private func syncSessions() -> [String] {
        var wanted: [(id: String, profile: CodeProfile, popout: ClaudePopouts.Entry?)] = []
        var seen = Set<String>()
        for profile in readableRunning {
            for entry in popouts[profile.folderName] ?? [] where seen.insert(entry.sessionID).inserted {
                wanted.append((entry.sessionID, profile, entry))
            }
        }
        func addFollowed() -> Bool {
            var missing = false
            for id in watched.sorted() where !seen.contains(id) {
                guard let profile = knownProfile(of: id) else {
                    missing = true
                    continue
                }
                seen.insert(id)
                wanted.append((id, profile, nil))
            }
            return missing
        }
        if addFollowed(), MonotonicClock.now() - indicesBuiltAt > 10 {
            rebuildIndices()
            _ = addFollowed()
        }
        var needsRead: [String] = []
        for item in wanted {
            if var record = records[item.id] {
                record.popout = item.popout
                record.profile = item.profile
                records[item.id] = record
                continue
            }
            let index = indexByID[item.id] ?? nextIndex
            if indexByID[item.id] == nil {
                indexByID[item.id] = index
                nextIndex += 1
            }
            let firstSeen = firstSeenByID[item.id] ?? nextSeen
            if firstSeenByID[item.id] == nil {
                firstSeenByID[item.id] = firstSeen
                nextSeen += 1
            }
            records[item.id] = SessionRecord(id: item.id, index: index, firstSeen: firstSeen, profile: item.profile, popout: item.popout)
            needsRead.append(item.id)
        }
        for id in Array(records.keys) where !seen.contains(id) { removeRecord(id) }
        order = records.values.sorted {
            (ClaudeProcessDiscovery.order($0.profile), $0.firstSeen) < (ClaudeProcessDiscovery.order($1.profile), $1.firstSeen)
        }.map(\.id)
        let priority = order.filter { watched.contains($0) } + order.filter { !watched.contains($0) }
        let full = Set(priority.prefix(environment.maxWatchedSessions))
        for id in order {
            guard var record = records[id] else { continue }
            let isFull = full.contains(id)
            guard record.fullyRead != isFull else { continue }
            record.fullyRead = isFull
            if !isFull {
                record.clearTranscript()
                leave(id)
            }
            records[id] = record
            if isFull, !needsRead.contains(id) { needsRead.append(id) }
        }
        if order.count > environment.maxWatchedSessions, !capLogged {
            capLogged = true
            CodeLog.warn("sessions=\(order.count) watched=\(environment.maxWatchedSessions) over=\(order.count - environment.maxWatchedSessions)")
        } else if order.count <= environment.maxWatchedSessions {
            capLogged = false
        }
        return needsRead
    }

    private func removeRecord(_ id: String) {
        guard let record = records[id] else { return }
        checker.unregister(sessionIndex: record.index)
        scheduledParses[id]?.cancel()
        scheduledParses[id] = nil
        dirty.remove(id)
        transcriptKeys = transcriptKeys.filter { $0.value != id }
        records[id] = nil
        leave(id)
    }

    /// After the set of sessions may have changed: read the new ones, watch what is shown, publish.
    private func applySessionSetChange() {
        for id in syncSessions() { readSession(id) }
        updateWatchers()
        schedulePublish()
    }

    // MARK: Reading one session

    private func readSession(_ id: String) {
        guard var record = records[id] else { return }
        let now = environment.clock()
        let owner = environment.userID
        let path = profileFolder(record.profile).flatMap { indices[record.profile.folderName]?.path(of: id, profileFolder: $0) }
        record.refreshFile(path: path, owner: owner)
        if case .read(.missing)? = record.fileFailure, MonotonicClock.now() - indicesBuiltAt > 10 {
            rebuildIndices()
            let found = profileFolder(record.profile).flatMap { indices[record.profile.folderName]?.path(of: id, profileFolder: $0) }
            if found != nil { record.refreshFile(path: found, owner: owner) }
        }
        let dropped = record.refreshTranscript(projects: CarefulPath(root: environment.claudeProjects.path), owner: owner, now: now)
        if let dropped { CodeLog.info("session=#\(record.index) transcript=\(dropped.rawValue) offers=dropped") }
        if let transcript = record.transcript, transcript.components.count >= 2 {
            transcriptKeys[transcript.components.suffix(2).joined(separator: "/")] = id
        }
        logFailure(&record)
        records[id] = record
    }

    /// One line when a session's reading problem changes: labels only.
    private func logFailure(_ record: inout SessionRecord) {
        var parts: [String] = []
        if let failure = record.fileFailure { parts.append("file=\(failure.label)") }
        if let failure = record.transcriptFailure { parts.append("transcript=\(failure.label)") }
        let line = parts.joined(separator: " ")
        guard line != (record.loggedFailure ?? "") else { return }
        record.loggedFailure = line
        if line.isEmpty {
            CodeLog.info("session=#\(record.index) readable")
        } else {
            CodeLog.warn("session=#\(record.index) profile=\(record.profile.letter) \(line)")
        }
    }

    // MARK: Events and scheduling

    private func filesChanged(_ paths: [String], mustRescan: Bool) {
        guard running else { return }
        if mustRescan {
            indicesBuiltAt = -TimeInterval.infinity
            for id in order { markDirty(id) }
            recentNeedsFullScan = true
            scheduleRecentScan()
            return
        }
        var syncNeeded = false
        for path in paths {
            let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard let name = parts.last else { continue }
            if name.hasSuffix(".jsonl"), parts.count >= 2 {
                if let id = transcriptKeys[parts[parts.count - 2] + "/" + name] { markDirty(id) }
                continue
            }
            guard name.hasSuffix(".json"), parts.count >= 5, parts[parts.count - 4] == SessionIndex.folderName else { continue }
            let id = String(name.dropLast(5))
            guard CodeIDs.isSessionID(id) else { continue }
            indices[parts[parts.count - 5]]?.note(id: id, account: parts[parts.count - 3], org: parts[parts.count - 2])
            // Any session file may make a session recent (or archive one): its file is looked at again.
            recentChanged.insert(id)
            scheduleRecentScan()
            if records[id] != nil {
                markDirty(id)
            } else if watched.contains(id) {
                syncNeeded = true
            }
        }
        if syncNeeded {
            for id in syncSessions() { markDirty(id) }
            updateWatchers()
            schedulePublish()
        }
    }

    private func popoutsEvent(_ key: String) {
        guard running else { return }
        dirtyPopouts.insert(key)
        guard visible, scheduledPopouts[key] == nil else { return }
        let delay = max(0, environment.parseInterval - (MonotonicClock.now() - (lastPopoutsAt[key] ?? -TimeInterval.infinity)))
        let work = DispatchWorkItem { [weak self] in self?.runPopouts(key) }
        scheduledPopouts[key] = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func runPopouts(_ key: String) {
        scheduledPopouts[key] = nil
        guard running, visible, dirtyPopouts.contains(key),
              let profile = readableRunning.first(where: { $0.folderName == key }) else { return }
        if readPopouts(profile) { applySessionSetChange() }
    }

    private func markDirty(_ id: String) {
        guard records[id] != nil else { return }
        dirty.insert(id)
        if visible { scheduleParse(id) }
    }

    /// At most one parse per session per `parseInterval`; a change during the wait joins the pending parse.
    private func scheduleParse(_ id: String) {
        guard scheduledParses[id] == nil else { return }
        let delay = max(0, environment.parseInterval - (MonotonicClock.now() - (lastParseAt[id] ?? -TimeInterval.infinity)))
        let work = DispatchWorkItem { [weak self] in self?.runParse(id) }
        scheduledParses[id] = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func runParse(_ id: String) {
        scheduledParses[id] = nil
        guard running, visible, dirty.remove(id) != nil, records[id] != nil else { return }
        lastParseAt[id] = MonotonicClock.now()
        let before = records[id]?.transcript
        readSession(id)
        if records[id]?.transcript != before { updateWatchers() }
        schedulePublish()
    }

    private func cancelScheduled() {
        for work in scheduledParses.values { work.cancel() }
        scheduledParses = [:]
        for work in scheduledPopouts.values { work.cancel() }
        scheduledPopouts = [:]
        scheduledRecentScan?.cancel()
        scheduledRecentScan = nil
        publishItem?.cancel()
        publishItem = nil
        evaluationTimer?.cancel()
        evaluationTimer = nil
    }

    // MARK: Watching

    private func updateWatchers() {
        guard environment.watchesFiles, running else {
            stopWatchers()
            return
        }
        var folders = Set<String>()
        for profile in knownProfiles.known {
            if let path = profileFolder(profile)?.appending(SessionIndex.folderName), CarefulFiles.isExistingFolder(path.absolutePath) {
                folders.insert(path.absolutePath)
            }
        }
        for record in records.values where record.fullyRead {
            if let folder = record.transcript?.parent { folders.insert(folder.absolutePath) }
        }
        let sorted = folders.sorted()
        if sorted != watchedFolders {
            let replacing = folderWatcher != nil
            folderWatcher?.stop()
            folderWatcher = CodeFolderWatcher(folders: sorted, latency: environment.watchLatency, queue: queue) { [weak self] paths, rescan in
                self?.filesChanged(paths, mustRescan: rescan)
            }
            // Without a stream (no folder exists yet) the next call tries again.
            watchedFolders = folderWatcher == nil ? [] : sorted
            // Changes between the old stream and the new one would be missed: look at everything once more.
            if replacing { for id in order { markDirty(id) } }
        }
        let wanted = Set(readableRunning.map(\.folderName))
        for (key, watcher) in popoutWatchers where !wanted.contains(key) {
            watcher.stop()
            popoutWatchers[key] = nil
        }
        for profile in readableRunning where popoutWatchers[profile.folderName] == nil {
            guard let file = profileFolder(profile)?.appending(ClaudePopouts.fileName) else { continue }
            let key = profile.folderName
            popoutWatchers[key] = CodeFileWatcher(file: file.absolutePath, queue: queue) { [weak self] in self?.popoutsEvent(key) }
        }
    }

    private func stopWatchers() {
        folderWatcher?.stop()
        folderWatcher = nil
        watchedFolders = []
        for watcher in popoutWatchers.values { watcher.stop() }
        popoutWatchers = [:]
    }

    // MARK: Publishing

    private func schedulePublish() {
        guard running else { return }
        guard visible else {
            publishNow()
            return
        }
        guard publishItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.publishItem = nil
            self.publishNow()
            self.scheduleEvaluation()
        }
        publishItem = work
        queue.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func publishNow() {
        publishItem?.cancel()
        publishItem = nil
        guard running else { return }
        readSSHFacts(force: false)
        let now = environment.clock()
        let context = SnapshotContext(now: now, sshFacts: sshFacts, settings: settings,
                                      homeDirectory: environment.homeDirectory, userName: environment.userName,
                                      multipleProfiles: runningProfiles.count > 1,
                                      programs: { [unowned self] in self.cleanPathPrograms() },
                                      hostName: { [unowned self] alias in self.hostName(alias) })
        var deadlines: [Date] = []
        // Every session's snapshot first; then the derivers over the sessions whose digests were read.
        let deriveMemory = deriveRunner.isEmpty ? nil : memory
        let copied = deriveMemory == nil ? [:] : deriveRunner.sharedToolUseIDs(order.compactMap { records[$0] })
        var built: [CodeDeriveRunner.Session] = []
        var fields: [String: CodeDerivedFields] = [:]
        for id in order {
            guard var record = records[id] else { continue }
            let output = SessionSnapshotBuilder.build(&record, context: context)
            logOffers(&record, output.latest)
            records[id] = record
            deadlines.append(contentsOf: output.deadlines)
            var digest: CodeTurnDigest?
            if let store = deriveMemory, record.fullyRead, let read = deriveRunner.digest(of: record, copied: copied[id] ?? []) {
                digest = read
                fields[id] = deriveRunner.derive(record, snapshot: output.snapshot, digest: read, copied: copied[id] ?? [],
                                                 memoryVersion: memoryVersions[id] ?? 0, settingsVersion: settingsVersion,
                                                 memory: store, settings: settings, owner: environment.userID, now: now)
            }
            built.append(CodeDeriveRunner.Session(id: id, snapshot: output.snapshot, digest: digest,
                                                  digestVersion: record.digestVersion))
        }
        if let store = deriveMemory {
            deriveRunner.crossDerive(built, fields: &fields, context: CodeCrossDeriveContext(
                now: now, memory: store, settings: settings, owner: environment.userID))
        }
        var sessions: [CodeSessionSnapshot] = []
        var offerIDs = Set<CommandOffer.ID>()
        for item in built {
            guard let record = records[item.id] else { continue }
            var snapshot = item.snapshot
            var registrations = record.replies.filter { !$0.entries.isEmpty }.map(\.registration)
            if let derivedFields = fields[item.id] {
                snapshot = derivedFields.applied(to: snapshot)
                deadlines.append(contentsOf: derivedFields.deadlines)
                // Earlier replies first: the checker keeps the newest 3, oldest first.
                registrations = derivedFields.earlierRegistrations.filter { $0.sessionIndex == record.index } + registrations
            }
            checker.register(registrations, sessionIndex: record.index)
            sessions.append(snapshot)
            offerIDs.formUnion(snapshot.offers.map(\.id))
            // A superseded offer moved to `earlierOffers` has not gone stale: its sheet is told by the block.
            offerIDs.formUnion(snapshot.earlierOffers.map(\.id))
        }
        nextDeadline = deadlines.filter { $0 > now }.min()
        let publication = Publication(sessions: sessions, profiles: runningProfiles, processes: processes, banner: banner(),
                                      recent: recent)
        let stale = publishedOfferIDs.subtracting(offerIDs)
        publishedOfferIDs = offerIDs
        guard publication != lastPublication || !stale.isEmpty else { return }
        lastPublication = publication
        publish(publication, stale)
    }

    /// One line when a session's offers change: count, classes, flags; never the text.
    private func logOffers(_ record: inout SessionRecord, _ latest: ReplyOffers?) {
        guard let latest, !latest.entries.isEmpty else {
            if record.loggedOffers != nil {
                record.loggedOffers = nil
                CodeLog.info("offers session=#\(record.index) profile=\(record.profile.letter) count=0")
            }
            return
        }
        let classes = latest.entries.map { SessionSnapshotBuilder.label($0.assessment.commandClass) }.joined(separator: ",")
        let flags = latest.entries.reduce(0) { $0 + $1.assessment.flags.count }
        let line = "offers session=#\(record.index) profile=\(record.profile.letter) count=\(latest.entries.count) "
            + "classes=\(classes) flags=\(flags) more=\(latest.notShown) complete=\(latest.readCompletely ? "yes" : "no")"
        guard line != record.loggedOffers else { return }
        record.loggedOffers = line
        CodeLog.info(line)
    }

    /// "Claude's session files changed" when more than half of at least two read session files fail their checks.
    /// Missing files do not count.
    private func banner() -> String? {
        var read = 0
        var failed = 0
        for record in records.values {
            if record.file != nil {
                read += 1
            } else if record.fileFailure?.isContentFailure == true {
                read += 1
                failed += 1
            }
        }
        let on = read >= 2 && failed * 2 > read
        if on != bannerLogged {
            bannerLogged = on
            CodeLog.warn("banner=\(on ? "on" : "off") failed=\(failed) read=\(read)")
        }
        guard on else { return nil }
        let version = processes.compactMap(\.version).first.map { " (Claude \($0))" } ?? ""
        return "Claude's session files changed\(version). Showing titles only."
    }

    // MARK: Derivers, recent sessions, memory

    /// The session is no longer read: its derived fields go and every deriver drops what it keeps for it.
    private func leave(_ id: String) { deriveRunner.leave(id) }

    /// The memory store changed a session's records from outside this queue (the block, a deriver's own queue).
    private func memoryChanged(_ id: String) {
        memoryVersions[id, default: 0] &+= 1
        guard running, records[id] != nil else { return }
        schedulePublish()
    }

    /// Reads the session files again for `recentSessions(within:)`: all of them (`full`), or the ones file
    /// events named since the last scan.
    private func scanRecent(publishing: Bool, full: Bool = true) {
        scheduledRecentScan?.cancel()
        scheduledRecentScan = nil
        lastRecentScanAt = MonotonicClock.now()
        let now = environment.clock()
        let root = environment.applicationSupport.path
        if full || recentNeedsFullScan {
            recentScanner.scanAll(profiles: readableRunning, indices: indices, applicationSupport: root,
                                  owner: environment.userID, now: now)
        } else if !recentChanged.isEmpty {
            recentScanner.update(recentChanged, profiles: readableRunning, indices: indices, applicationSupport: root,
                                 owner: environment.userID, now: now)
        }
        recentNeedsFullScan = false
        recentChanged = []
        let archived = recentScanner.archivedIDs
        if archived != lastArchived {
            lastArchived = archived
            pruneMemory()
        }
        let fresh = recentScanner.recent(now: now)
        guard fresh != recent else { return }
        recent = fresh
        if publishing { schedulePublish() }
    }

    /// While visible: one scan per `parseInterval` at most; hidden: the changes wait until the block is visible.
    private func scheduleRecentScan() {
        guard running, visible, scheduledRecentScan == nil else { return }
        let delay = max(0, environment.parseInterval - (MonotonicClock.now() - lastRecentScanAt))
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            self.scanRecent(publishing: true, full: false)
        }
        scheduledRecentScan = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Drops the memory of sessions gone from every copy's index or archived, only after complete listings.
    private func pruneMemory() {
        guard let memory else { return }
        var existing = Set<String>()
        for profile in knownProfiles.known {
            guard let index = indices[profile.folderName] else { continue }
            if index.incomplete { return }
            if let failure = index.failure, failure != .missing { return }
            existing.formUnion(index.locations.keys)
        }
        guard !existing.isEmpty else { return }
        var archived = recentScanner.archivedIDs
        for record in records.values where record.file?.isArchived == true { archived.insert(record.id) }
        memory.pruneSessions(existing: existing, archived: archived)
    }

    private func scheduleEvaluation() {
        evaluationTimer?.cancel()
        evaluationTimer = nil
        guard running, visible, let next = nextDeadline else { return }
        let delay = max(0.05, next.timeIntervalSince(environment.clock()) + 0.01)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.evaluationTimer?.cancel()
            self.evaluationTimer = nil
            self.publishNow()
            self.scheduleEvaluation()
        }
        timer.resume()
        evaluationTimer = timer
    }
}
