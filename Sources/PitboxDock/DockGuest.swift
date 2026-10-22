import CoreGraphics
import Foundation
import PitboxKit

/// The guest side of the dock link, as the app uses it (docs/DOCK_PROTOCOL.md). Main actor.
///
/// The link can only move, size, colour, hide, fold and quiet the guest: every callback carries plain values (a frame,
/// protocol words, counts, the host's focus key and wake words, and the host's private folders for the command
/// sandbox). Nothing here reaches anything that runs, types, opens, parks, restores or reads back (the link invariant,
/// pinned by `LinkInvariantTests`).
///
/// ```swift
/// let listener = DockListener()                     // right after the single-instance lock, before any window
/// try? listener.bind()
/// let dock = DockGuest(listener: listener, configuration: .init(enabled: settings.dock.enabled,
///                                                                hosts: settings.dock.hosts, build: version))
/// dock.onPlace = { place in panel.setPlacement(place.map { .docked(DockPlace(…)) } ?? .alone) … }
/// dock.start()                                      // the first onPlace (a place, or nil = alone) comes within 1 s
/// ```
@MainActor
public final class DockGuest {
    /// What the guest needs from the settings and the build.
    public struct Configuration: Equatable, Sendable {
        /// The menu's "Dock with the host app" tick (`dock.enabled`).
        public var enabled: Bool
        /// Bundle ids allowed to dock (`dock.hosts`, file only).
        public var hosts: [String]
        /// This build's version, sent in `hello.build`.
        public var build: String
        /// The features offered (default: all of them).
        public var features: Set<DockFeature>

        public init(enabled: Bool = true, hosts: [String] = [], build: String = "0", features: Set<DockFeature> = DockFeature.all) {
            self.enabled = enabled
            self.hosts = hosts
            self.build = build
            self.features = features
        }
    }

    /// How long to wait for a running host's first `place` before showing alone.
    public static let startWait: TimeInterval = 1
    /// A listed host app that runs this long without connecting gets the "without dock support" warning.
    public static let noConnectionWait: TimeInterval = 5
    /// How long to wait for `speech.ok` or `speech.no`.
    public static let speechAnswerWait: TimeInterval = 2
    /// `speech.end` goes out at the latest this long after an `ok`, whether or not the app ended the phrase.
    public static let speechEndBackstop: TimeInterval = 60

    // MARK: State

    /// Where the guest stands.
    public private(set) var state: DockGuestState = .alone
    /// A warning for the menu, beside the state.
    public private(set) var warning: DockWarning?
    /// The connected host's name (one clean line, at most 40 characters), when connected or last refused.
    public private(set) var hostName: String?
    /// The current settings.
    public private(set) var configuration: Configuration

    /// The features both sides use (empty unless connected).
    public var features: Set<DockFeature> { handshake?.features ?? [] }

    /// True once the handshake with a verified host is done (docked or about to be).
    public var isConnected: Bool { handshake != nil }

    /// The menu's line under "Dock with …"; nil while docking is off.
    public var statusLine: String? {
        guard configuration.enabled else { return nil }
        let host = hostName ?? "the host app"
        if warning == .socketUnavailable { return "Dock unavailable: the socket could not be opened" }
        switch state {
        case .docked: return "Docked with \(host)"
        case .hostNotResponding: return "\(host) not responding"
        case .waitingForHost: return "Waiting for \(host)…"
        case .refused(let refusal): return refusal.menuLine(hostName: hostName)
        case .alone:
            if warning == .hostWithoutDockSupport {
                return "The host app is running without dock support: two apps may park the same windows. "
                    + "Update or quit one"
            }
            return isConnected ? "Connected to \(host)" : "No host app connected"
        }
    }

    // MARK: Callbacks (main actor; plain values only)

    /// The state, warning or host name changed (refresh the menu).
    public var onStateChanged: ((DockGuestState) -> Void)?
    /// Where to put the panel: the host's place, or nil to go alone at the screen edge. The first call comes once
    /// after `start()` (at once, or within `startWait` while a host app runs); then on every change.
    public var onPlace: ((HostPlace?) -> Void)?
    /// The host's look; `.system` when the host leaves.
    public var onAppearance: ((DockAppearance) -> Void)?
    /// The host's focus key; `.all` when the host leaves.
    public var onFocus: ((DockFocus) -> Void)?
    /// The host's menu folded (true) or unfolded (false) the guest.
    public var onFold: ((Bool) -> Void)?
    /// Words the spoken line must never say (the host's wake words); empty when the host leaves.
    public var onHostWakeWords: (([String]) -> Void)?
    /// The private folders a verified host announced, for the command sandbox's append-only memory: capped at
    /// `maxRememberedFolders` distinct entries per kind for this guest. Called after the handshake with a host that
    /// passed every check, and only when something is left to remember.
    public var onHostPrivateFolders: ((HostPrivateFolders) -> Void)?
    /// The same verified host's whole announcement, uncapped (the wire keeps at most 16 per kind per `hello`, each
    /// passed by the folder rule): the sandbox denies it for this process even when the memory's cap is reached. Called
    /// right before `onHostPrivateFolders`, when the host announced something.
    public var onHostAnnouncement: ((HostPrivateFolders) -> Void)?

    // MARK: Internals (used by the extension in DockGuest+Send.swift)

    let listener: DockListener
    let hostApps: DockHostApps
    let clock: DockClock
    var session: DockSession?
    var handshake: DockHandshake?
    var place: HostPlace?
    var settled = false
    var started = false
    var stopped = false
    var listedHostWasRunning = false
    var startTimer: DockTimer?
    var noConnectionTimer: DockTimer?
    var attentionTimer: DockTimer?
    var speechAnswerTimer: DockTimer?
    var speechEndTimer: DockTimer?
    var attentionLatest: AttentionCounts?
    var attentionSent: AttentionCounts?
    var attentionSentAt: TimeInterval?
    var lastArea: AreaReport?
    var nextSpeechID = 1
    var pendingSpeech: (id: Int, continuation: CheckedContinuation<SpeechAnswer, Never>)?
    var activeSpeechID: Int?
    var abandonedSpeech: Set<Int> = []
    /// Why the last session ended (for the tests and the log).
    var lastEndReason: DockEndReason?
    /// Distinct announced folders this guest passed on to be remembered, per kind (capped at `maxRememberedFolders`; a
    /// new guest, after docking off and on or a bind retry, starts again).
    var passedFolders: Set<String> = []
    var passedSocketFolders: Set<String> = []
    /// Announced folders refused by the cap.
    var cappedFolders = 0
    /// Distinct announced folders per kind the guest passes on in all (the console's sandbox memory has the same cap).
    static let maxRememberedFolders = 64
    private var lastNotified: Notified?

    struct AttentionCounts: Equatable {
        var needsYou: Int
        var finished: Int
        var running: Int
    }

    struct AreaReport: Equatable {
        var seq: Int
        var frame: CGRect
        var folded: Bool
        var visible: Bool
    }

    private struct Notified: Equatable {
        var state: DockGuestState
        var warning: DockWarning?
        var hostName: String?
        var enabled: Bool
        var connected: Bool
    }

    /// A guest on a bound listener (`DockListener.bind()` at launch), with the app's dock settings.
    public convenience init(listener: DockListener, configuration: Configuration) {
        self.init(listener: listener, configuration: configuration, hostApps: WorkspaceHostApps(),
                  clock: SystemDockClock.shared)
    }

    init(listener: DockListener, configuration: Configuration, hostApps: DockHostApps, clock: DockClock) {
        self.listener = listener
        self.configuration = configuration
        self.hostApps = hostApps
        self.clock = clock
    }

    // MARK: Lifecycle

    /// Takes over the listener (and a host it accepted while the app was starting) and decides the start: alone at
    /// once (no listed host app runs and no host is connected, or docking is off), or wait up to `startWait` for the
    /// host's first `place`. Set the callbacks first: the first `onPlace` may come from inside this call.
    public func start() {
        guard !started else { return }
        started = true
        listener.update(configuration)
        hostApps.onChange = { [weak self] in self?.hostAppsChanged() }
        var waiting: DockSession?
        if listener.isBound {
            let earlier = listener.attachGuest(onSession: { [weak self] session in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return session.close(bye: .quit) }
                        self.attach(session)
                    }
                }
            }, onRefusal: { [weak self] refusal in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.peerRefused(refusal) } }
            })
            waiting = earlier.session
            if let session = earlier.session { attach(session) }
            if let refusal = earlier.refusal { peerRefused(refusal) }
        } else {
            warning = .socketUnavailable
            Log.warn("dock: socket unavailable, staying alone", "dock")
        }
        listedHostWasRunning = listedHostRunning()
        if configuration.enabled, listedHostWasRunning || waiting != nil, listener.isBound {
            setState(.waitingForHost)
            startTimer = clock.after(Self.startWait, on: .main) { [weak self] in
                MainActor.assumeIsolated { self?.startWaitEnded() }
            }
            armNoConnectionCheck()
        } else {
            settle()
        }
    }

    /// The dock tick (`dock.enabled`). Off: the host gets `bye` with `settings`, the guest goes alone and refuses
    /// every connection until it is on again (a host retries at its own pace).
    public func setEnabled(_ enabled: Bool) {
        guard enabled != configuration.enabled else { return }
        configuration.enabled = enabled
        listener.isEnabled = enabled
        if enabled {
            if case .refused = state { setState(.alone) }
            if listedHostRunning(), handshake == nil { armNoConnectionCheck() }
            notify()
            return
        }
        noConnectionTimer?.cancel()
        noConnectionTimer = nil
        if warning == .hostWithoutDockSupport { warning = nil }
        disconnect(bye: .settings)
        hostName = nil
        goAlone(refusal: nil)
    }

    /// The allow list (`dock.hosts`). A connected host that is no longer listed is closed (`bye` with `settings`).
    public func setHosts(_ hosts: [String]) {
        configuration.hosts = hosts
        listener.allowedHosts = hosts
        if let host = handshake?.host, !hosts.contains(host.bundleID) {
            disconnect(bye: .settings)
            goAlone(refusal: nil)
        }
        hostAppsChanged()
    }

    /// Closes the link normally: `bye` with `why`, then alone.
    public func bye(_ why: DockByeReason) {
        guard session != nil else { return }
        disconnect(bye: why)
        goAlone(refusal: nil)
    }

    /// At terminate: `bye` with `quit`, the listener stops and removes its socket, every timer stops.
    public func stop() {
        guard !stopped else { return }
        stopped = true
        bye(.quit)
        listener.stop()
        hostApps.onChange = nil
        for timer in [startTimer, noConnectionTimer, attentionTimer, speechAnswerTimer, speechEndTimer] { timer?.cancel() }
        startTimer = nil
        noConnectionTimer = nil
        attentionTimer = nil
        speechAnswerTimer = nil
        speechEndTimer = nil
    }

    // MARK: Sessions

    func attach(_ newSession: DockSession) {
        guard !stopped, configuration.enabled else { return newSession.close(bye: .settings) }
        // The listener's slot was freed before the old session's end reached the main queue: `busy`, as for any second
        // host.
        if let current = session, current !== newSession { return newSession.closeBusy() }
        session = newSession
        let id = newSession.id
        newSession.setEventHandler { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(event, from: id) } }
        }
    }

    func handle(_ event: DockSessionEvent, from id: Int) {
        guard let session, session.id == id else { return }
        switch event {
        case .handshake(let result): handshakeDone(result)
        case .message(let message): handle(message)
        case .responsive(let responsive): responsiveChanged(responsive)
        case .ended(let reason): sessionEnded(reason)
        }
    }

    private func handshakeDone(_ result: DockHandshake) {
        // The allow list may have changed between the accept and now.
        guard configuration.hosts.contains(result.host.bundleID) else {
            disconnect(bye: .settings)
            return goAlone(refusal: nil)
        }
        handshake = result
        hostName = Self.cleanHostName(result.hostName)
        noConnectionTimer?.cancel()
        noConnectionTimer = nil
        if warning == .hostWithoutDockSupport { warning = nil }
        if case .refused = state { setState(.alone) }
        if !result.privateFolders.isEmpty { onHostAnnouncement?(result.privateFolders) }
        let folders = capped(result.privateFolders)
        if !folders.isEmpty { onHostPrivateFolders?(folders) }
        onHostWakeWords?(result.wakeWords)
        attentionSent = nil
        attentionSentAt = nil
        lastArea = nil
        flushAttention()
        notify()
    }

    private func handle(_ message: HostMessage) {
        switch message {
        case .place(let newPlace): applyPlace(newPlace)
        case .appearance(let look): onAppearance?(look)
        case .focus(let focus): onFocus?(focus)
        case .fold(let folded): onFold?(folded)
        case .speechOK(let id): speechOK(id)
        case let .speechNo(id, why): speechNo(id, why: why)
        case .hello, .ping, .pong, .bye: break  // the session handles these
        }
    }

    private func applyPlace(_ newPlace: HostPlace) {
        place = newPlace
        startTimer?.cancel()
        startTimer = nil
        settled = true
        setState(.docked(newPlace, features))
        onPlace?(newPlace)
    }

    private func responsiveChanged(_ responsive: Bool) {
        guard let place else { return }
        setState(responsive ? .docked(place, features) : .hostNotResponding(place, features))
    }

    private func sessionEnded(_ reason: DockEndReason) {
        lastEndReason = reason
        session = nil
        handshake = nil
        if case let .version(ours, theirs, hostApp) = reason {
            // The host speaks the protocol (another version): no "without dock support" warning, and the menu line
            // names it.
            noConnectionTimer?.cancel()
            noConnectionTimer = nil
            if warning == .hostWithoutDockSupport { warning = nil }
            hostName = Self.cleanHostName(hostApp)
            goAlone(refusal: .version(ours: ours, theirs: theirs))
        } else {
            goAlone(refusal: nil)
        }
    }

    /// The announced folders this guest may still pass on to be remembered: at most `maxRememberedFolders` distinct
    /// entries per kind across all hosts and reconnects. Entries passed before are passed again; new ones beyond the
    /// cap are not remembered (counted and logged; `onHostAnnouncement` still had them); none is ever taken back.
    private func capped(_ announced: HostPrivateFolders) -> HostPrivateFolders {
        func admit(_ entries: [String], into known: inout Set<String>) -> [String] {
            var kept: [String] = []
            for entry in entries {
                if known.contains(entry) || known.count < Self.maxRememberedFolders {
                    known.insert(entry)
                    kept.append(entry)
                } else {
                    cappedFolders += 1
                }
            }
            return kept
        }
        let before = cappedFolders
        let result = HostPrivateFolders(folders: admit(announced.folders, into: &passedFolders),
                                        socketFolders: admit(announced.socketFolders, into: &passedSocketFolders))
        if cappedFolders > before {
            Log.warn("dock: private folders capped max=\(Self.maxRememberedFolders) refused=\(cappedFolders - before)", "dock")
        }
        return result
    }

    /// Closes the current session, if any (its `ended` event is ignored: the session is no longer ours).
    func disconnect(bye why: DockByeReason) {
        guard let current = session else { return }
        session = nil
        handshake = nil
        current.close(bye: why)
    }

    /// Back to alone: the panel goes to the screen edge, the host's look, focus and wake words are dropped, a waiting
    /// speech request is answered `no`.
    func goAlone(refusal: DockRefusal?) {
        let wasDocked = place != nil
        let hadHostState = wasDocked || lastNotified?.connected == true
        place = nil
        lastArea = nil
        startTimer?.cancel()
        startTimer = nil
        attentionTimer?.cancel()
        attentionTimer = nil
        speechEndTimer?.cancel()
        speechEndTimer = nil
        activeSpeechID = nil
        abandonedSpeech.removeAll()
        answerPendingSpeech(.no(.hostGone))
        setState(refusal.map(DockGuestState.refused) ?? .alone)
        if hadHostState {
            onAppearance?(.system)
            onFocus?(.all)
            onHostWakeWords?([])
        }
        if wasDocked || !settled {
            settled = true
            onPlace?(nil)
        }
    }

    // MARK: Start order and host apps

    private func settle() {
        guard !settled else { return }
        settled = true
        setState(state == .waitingForHost ? .alone : state)
        onPlace?(nil)
    }

    private func startWaitEnded() {
        startTimer = nil
        guard state == .waitingForHost else { return }
        Log.info("dock: no place within \(Self.startWait) s, showing alone", "dock")
        setState(.alone)
        settle()
    }

    func listedHostRunning() -> Bool {
        !hostApps.runningBundleIDs().isDisjoint(with: configuration.hosts)
    }

    private func armNoConnectionCheck() {
        noConnectionTimer?.cancel()
        noConnectionTimer = clock.after(Self.noConnectionWait, on: .main) { [weak self] in
            MainActor.assumeIsolated { self?.noConnectionCheck() }
        }
    }

    private func noConnectionCheck() {
        noConnectionTimer = nil
        guard configuration.enabled, handshake == nil, listedHostRunning(), warning == nil else { return }
        warning = .hostWithoutDockSupport
        Log.warn("dock: a listed host app runs without connecting", "dock")
        notify()
    }

    private func hostAppsChanged() {
        let running = listedHostRunning()
        defer { listedHostWasRunning = running }
        guard running else {
            noConnectionTimer?.cancel()
            noConnectionTimer = nil
            if warning == .hostWithoutDockSupport {
                warning = nil
                notify()
            }
            return
        }
        if !listedHostWasRunning, configuration.enabled, handshake == nil, !stopped { armNoConnectionCheck() }
    }

    private func peerRefused(_ refusal: DockRefusal) {
        guard place == nil, handshake == nil, configuration.enabled else { return }
        switch state {
        case .alone, .refused: setState(.refused(refusal))
        case .waitingForHost, .docked, .hostNotResponding: break
        }
    }

    // MARK: State and words

    func setState(_ new: DockGuestState) {
        state = new
        notify()
    }

    func notify() {
        let now = Notified(state: state, warning: warning, hostName: hostName, enabled: configuration.enabled,
                           connected: handshake != nil)
        guard now != lastNotified else { return }
        lastNotified = now
        onStateChanged?(state)
    }

    /// One line of at most 40 characters: control characters dropped, whitespace runs made one space; nil when empty.
    nonisolated static func cleanHostName(_ raw: String) -> String? {
        let kept = raw.unicodeScalars.filter { scalar in
            !(scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) || scalar.value == 0x2028
                || scalar.value == 0x2029 || (0x202A...0x202E).contains(scalar.value)
                || (0x2066...0x2069).contains(scalar.value))
        }
        let text = String(String.UnicodeScalarView(kept)).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty else { return nil }
        return text.count > 40 ? String(text.prefix(39)) + "…" : text
    }
}
