import Darwin
import Dispatch
import Foundation
import PitboxKit

/// Runs Fetch file: one file from the session's server into `~/Downloads`, with
/// Pitbox's own scp invocation, never replacing anything, after the user's click on the sheet.
///
/// `plan` finds out without running anything that could act: it reads the SSH config files itself, runs `ssh -G` (which
/// never connects) only when no file has a `Match` block, applies the name rules and checks Downloads, the staging
/// folder and the free space. `start` checks the config is unchanged, then runs the size-limited scp into a private
/// staging folder, quarantines the result and moves it into Downloads with an exclusive rename (see `FetchJob`).
///
/// Logs carry labels and numbers only (docs/THREAT_MODEL.md): never an alias, user, path, file name or scp output.
final class FetchRunner: FetchRunning, @unchecked Sendable {
    let environment: FetchEnvironment
    private let log: @Sendable (String) -> Void
    private let registry = FetchRegistry()
    private let planQueue = DispatchQueue(label: "pitbox.console.fetch.plan")
    private let counter = NSLock()
    private var nextRun = 1

    /// - Parameter log: where the `fetch …` lines go; the terminal's log (`[terminal]`) in the app.
    init(environment: FetchEnvironment = .live, log: @escaping @Sendable (String) -> Void = { TerminalLog.info($0) }) {
        self.environment = environment
        self.log = log
    }

    /// How many fetches are running now.
    var runningCount: Int { registry.count }

    // MARK: Plan

    func plan(for request: FetchFileRequest, loginUser: String?) async -> Result<FetchPlan, FetchPlanRefusal> {
        let started = ContinuousClock.now
        let result = await makePlan(request, loginUser: loginUser)
        let seconds = Self.seconds(since: started)
        switch result {
        case .success(let plan):
            let choice = plan.replyUser != nil && plan.replyUser != plan.configUser ? 1 : 0
            let asReplyUser = plan.loginUser != plan.configUser ? 1 : 0
            let renamed = plan.previewName != plan.fileName ? 1 : 0
            log("fetch plan ready proxy=\(plan.proxyNote == nil ? 0 : 1) userChoice=\(choice) asReplyUser=\(asReplyUser) "
                + "renamed=\(renamed) seconds=\(seconds)")
            return .success(plan)
        case .failure(let refusal):
            log("fetch plan refused reason=\(refusal.reason) check=\(refusal.check) seconds=\(seconds)")
            return .failure(refusal.reason)
        }
    }

    /// A refusal and the check that gave it (a log label only).
    private struct Refusal: Error {
        var reason: FetchPlanRefusal
        var check: String
    }

    private func makePlan(_ request: FetchFileRequest, loginUser: String?) async -> Result<FetchPlan, Refusal> {
        let limits = environment.limits
        guard FetchNames.isValidAlias(request.alias) else {
            return .failure(Refusal(reason: .aliasNotInConfig, check: "aliasGrammar"))
        }
        guard FetchNames.isAcceptableRemotePath(request.remotePath) else {
            return .failure(Refusal(reason: .deceptiveName, check: "remotePath"))
        }
        guard let fileName = request.destinationName ?? FetchNames.baseName(ofRemotePath: request.remotePath),
              FetchNames.isAcceptableFileName(fileName) else {
            return .failure(Refusal(reason: .deceptiveName, check: "fileName"))
        }

        // The config, read by Pitbox itself: nothing runs to find out.
        let reader = configReader
        let reading = await onPlanQueue { reader.read() }
        if let problem = reading.problem {
            return .failure(Refusal(reason: .configNeedsRunning, check: "config-\(problem.rawValue)"))
        }
        guard reading.hostTokens.contains(request.alias) else {
            return .failure(Refusal(reason: .aliasNotInConfig, check: "hostToken"))
        }
        if reading.hasMatch { return .failure(Refusal(reason: .configNeedsRunning, check: "match")) }

        guard let resolution = await resolve(request.alias) else {
            return .failure(Refusal(reason: .configNeedsRunning, check: "sshG"))
        }
        // ssh -G read the files after Pitbox did: they must not have changed in between.
        let reread = await onPlanQueue { reader.read() }
        guard reread.problem == nil, !reread.hasMatch, reread.fingerprint == reading.fingerprint else {
            return .failure(Refusal(reason: .configNeedsRunning, check: "changedDuringLookup"))
        }

        // The login user: the config's by default, the reply's only as the visible choice.
        let configUser = resolution.user.flatMap { FetchNames.isUsableConfigUser($0) ? $0 : nil }
        let replyUser = request.replyUser.flatMap { FetchNames.isValidReplyUser($0) ? $0 : nil }
        let chosen: String
        if let wanted = loginUser {
            guard wanted == configUser || wanted == replyUser else {
                return .failure(Refusal(reason: .configNeedsRunning, check: "userNotOffered"))
            }
            chosen = wanted
        } else {
            guard let user = configUser else { return .failure(Refusal(reason: .configNeedsRunning, check: "configUser")) }
            chosen = user
        }

        let environment = environment
        let folders = await onPlanQueue { Self.checkFolders(environment, fileName: fileName) }
        let previewName: String
        switch folders {
        case .failure(let refusal): return .failure(refusal)
        case .success(let name): previewName = name
        }

        let arguments = FetchCommand.arguments(user: chosen, alias: request.alias, remotePath: request.remotePath,
                                               stagingFolder: FetchCommand.stagingPlaceholder, fileName: fileName,
                                               connectTimeout: limits.connectTimeoutSeconds,
                                               extraOptions: environment.extraSCPOptions)
        return .success(FetchPlan(alias: request.alias, loginUser: chosen, configUser: configUser, replyUser: replyUser,
                                  proxyNote: resolution.proxyNote, remotePath: request.remotePath, fileName: fileName,
                                  previewName: previewName, arguments: arguments,
                                  configFingerprint: reading.fingerprint))
    }

    /// Downloads (a real folder, not a link), the staging parent on the same volume, the free space for the limit plus
    /// the reserve, and the free name Downloads has now.
    private static func checkFolders(_ environment: FetchEnvironment, fileName: String) -> Result<String, Refusal> {
        let downloads = FetchFolders.openFolder(environment.downloads)
        guard downloads >= 0 else { return .failure(Refusal(reason: .downloadsUnavailable, check: "downloads")) }
        defer { close(downloads) }
        let parent = FetchFolders.openStagingParent(environment.stagingParent)
        guard parent >= 0 else { return .failure(Refusal(reason: .downloadsUnavailable, check: "stagingParent")) }
        defer { close(parent) }
        guard let downloadsID = FetchFolders.identity(of: downloads), let parentID = FetchFolders.identity(of: parent),
              downloadsID.device == parentID.device else {
            return .failure(Refusal(reason: .otherVolume, check: "device"))
        }
        let limits = environment.limits
        guard let free = environment.freeSpace(downloads), free >= limits.freeSpaceReserve + limits.maxFileBytes else {
            return .failure(Refusal(reason: .notEnoughSpace, check: "freeSpace"))
        }
        // With all 99 names taken the preview stays the plain name; the run then fails with "already has 99 files".
        let preview = FetchFolders.firstFreeName(in: downloads, candidates: FetchNames.candidates(for: fileName)) ?? fileName
        return .success(preview)
    }

    var configReader: SSHConfigReader {
        SSHConfigReader(userConfig: URL(fileURLWithPath: environment.userConfig),
                        systemConfig: environment.systemConfig.map { URL(fileURLWithPath: $0) }, home: environment.home)
    }

    private func resolve(_ alias: String) async -> SSHResolution? {
        if let resolver = environment.resolver { return await resolver(alias) }
        return await SSHLookup.resolve(alias: alias, sshPath: environment.sshPath, options: environment.resolveOptions,
                                       environment: environment.processEnvironment,
                                       timeout: environment.limits.resolveTimeout)
    }

    /// Runs blocking file work (small files, a few system calls) on the plan queue, off the cooperative pool.
    private func onPlanQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            planQueue.async { continuation.resume(returning: work()) }
        }
    }

    // MARK: Start

    func start(_ plan: FetchPlan, progress: @escaping @MainActor (Int64) -> Void,
               completion: @escaping @MainActor (FetchFileOutcome) -> Void) -> FetchHandle {
        let id = counter.withLock { () -> Int in defer { nextRun += 1 }; return nextRun }
        // One fetch per session: the plan does not name the session yet, so the alias
        // stands in for it, which is stricter (two sessions on one server share the slot).
        let session = "alias:" + plan.alias
        if let busy = registry.reserve(id: id, session: session, limits: environment.limits) {
            log("fetch refused run=#\(id) reason=\(busy.rawValue) running=\(registry.count)")
            let words = busy.words(alias: plan.alias, user: plan.loginUser, fileName: plan.fileName,
                                   limits: environment.limits)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(.failed(reason: words)) } }
            return InertFetchHandle()
        }
        let registry = registry
        let job = FetchJob(id: id, plan: plan, environment: environment, reader: configReader, log: log,
                           progress: progress, completion: completion, release: { registry.release(id: id) })
        log("fetch started run=#\(id) running=\(registry.count)")
        job.begin()
        return job
    }

    static func seconds(since start: ContinuousClock.Instant) -> String {
        let elapsed = start.duration(to: .now).components
        let value = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        return String(format: "%.1f", value)
    }
}

/// The fetches running now, for the limits: two overall, one per session. Thread-safe.
final class FetchRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var running: [Int: String] = [:]

    var count: Int { lock.withLock { running.count } }

    /// Takes a slot for `id`; returns why not when a limit is reached.
    func reserve(id: Int, session: String, limits: FetchLimits) -> FetchFailure? {
        lock.withLock {
            if running.values.filter({ $0 == session }).count >= limits.maxPerSession { return .busySession }
            if running.count >= limits.maxRunning { return .busyOverall }
            running[id] = session
            return nil
        }
    }

    func release(id: Int) { lock.withLock { _ = running.removeValue(forKey: id) } }
}

/// The handle of a fetch that never started (a limit was reached): there is nothing to cancel.
final class InertFetchHandle: FetchHandle {
    func cancel() {}
}
