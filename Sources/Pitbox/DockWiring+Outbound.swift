import AppKit
import PitboxDock
import PitboxKit
import PitboxShell

/// What the app tells the host (the area, the counts, the mirrored drop claims, the speech pause), the docked area the
/// app's overlays keep out of, and the menu's words.
extension DockWiring {
    // MARK: Area

    /// The panel's area changed (its `onAreaChanged`: after a placement, a fold or unfold, a show or hide): sent while
    /// the block is docked beside the host, never while the user shows it alone at the screen edge.
    func panelAreaChanged() { sendArea() }

    /// The user's "show it alone while the host hides its strip" started or ended: when it ends, the area goes out once
    /// (the block is beside the host again, or hidden with it).
    func aloneOverrideChanged(_ on: Bool) {
        if !on { sendArea() }
    }

    /// The panel's frame, rail and visibility to the host, answering `seq` (default: the latest `place`). The guest
    /// sends the same report for the same `place` once.
    func sendArea(seq: Int? = nil) {
        guard !awaitingFirstShow, let guest, let panel, guest.state.isDocked, panel.isDockedNow, panel.blockLayout.docked,
              panel.frame.width > 0 else { return }
        guest.sendArea(frame: panel.frame, folded: panel.fit.isRail, visible: panel.isVisible, seq: seq)
    }

    // MARK: Attention

    /// The block's counts (the rail's dots): to the host at most once a second (feature `attention`), the newest win.
    func attentionChanged(needsYou: Int, finished: Int, running: Int) {
        attention = (needsYou, finished, running)
        pushAttention()
    }

    func pushAttention() {
        guard let guest, let counts = attention else { return }
        guest.sendAttention(needsYou: counts.needsYou, finished: counts.finished, running: counts.running)
    }

    // MARK: Drop claims (feature guard.claims)

    /// Mirrors every claim, mouse-up and release of `claims` to the host while docked (the guest sends them only when
    /// both sides use `guard.claims`). The registry reports on any thread; the link is told on the main thread, in
    /// order.
    func mirror(_ claims: WindowDropClaims) {
        claims.onChange = { [weak self] change in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.claimsChanged(change) } }
        }
    }

    /// One change of the app's drop-claims registry, on the main thread.
    func claimsChanged(_ change: WindowDropClaims.Change) {
        guard let guest, guest.state.isDocked else { return }
        switch change {
        case let .claimed(pid, windowNumber): guest.claim(pid: pid, windowNumber: windowNumber)
        case .mouseUp: guest.mouseUp()
        case let .released(pid, windowNumber, parked): guest.release(pid: pid, windowNumber: windowNumber, parked: parked)
        }
    }

    // MARK: Speech (feature speech)

    /// May the spoken line speak now? Docking off: yes (nothing of a host listens). Otherwise the guest decides: alone
    /// (no listed host app runs) yes; docked with the speech pause, only once the host paused its listener (`speech.ok`;
    /// `no` or no answer within 2 s: silent, the chime still plays); docked without it, or a listed host app running
    /// undocked: silent.
    func beginSpeech() async -> Bool {
        guard let guest else { return true }
        return await guest.requestSpeech() == .ok
    }

    /// The phrase ended: `speech.end` after an `ok` (the host resumes listening); nothing otherwise.
    func endSpeech() { guest?.endSpeech() }

    /// The spoken line's gate over this link.
    var speechGate: SpeechGate {
        SpeechGate(begin: { [weak self] in await self?.beginSpeech() ?? true }, end: { [weak self] in self?.endSpeech() })
    }

    // MARK: The docked area

    /// The host's strip as a region (Quartz coordinates, the host's edge) while the block is docked beside it and both
    /// are on screen: restored windows and desk tags keep out of the whole docked area. Nil otherwise.
    var hostRegion: ReservedRegion? {
        guard let place = shownPlace else { return nil }
        return BlockGeometry.region(forPanelFrame: place.host, displayID: place.displayID, edge: place.edge,
                                    primaryHeight: primaryHeight())
    }

    /// The docked area (the host's strip and the block, AppKit coordinates) while docked and on screen: what sheets and
    /// previews sit beside. Nil otherwise.
    var dockedAreaFrame: CGRect? {
        guard let place = shownPlace, let panel else { return nil }
        return place.host.union(panel.frame)
    }

    private var shownPlace: HostPlace? {
        guard let panel, panel.isDockedNow, panel.isVisible, let place = guest?.state.place, place.visible else { return nil }
        return place
    }

    // MARK: Menu

    /// The host's name from its `hello` (one clean line), when known.
    var hostName: String? { guest?.hostName }

    /// The line under "Dock with <host>" (docs/DOCK_PROTOCOL.md §9).
    var menuLine: String {
        Self.menuLine(enabled: settings.enabled, hosts: settings.hosts, state: guest?.state, warning: guest?.warning,
                      hostName: guest?.hostName, connected: guest?.isConnected ?? false)
    }

    /// The menu's dock line for a state (pure). The host's name comes from its `hello`; "the host app" before one.
    static func menuLine(enabled: Bool, hosts: [String], state: DockGuestState?, warning: DockWarning?, hostName: String?,
                         connected: Bool) -> String {
        guard enabled else { return "Off: \(AppIdentity.displayName) stays alone at the screen edge" }
        let host = hostName ?? "the host app"
        let subject = hostName ?? "The host app"   // at the start of a line
        if warning == .socketUnavailable { return "Dock unavailable: the socket could not be opened" }
        switch state ?? .alone {
        case .docked: return "Docked with \(host)"
        case .hostNotResponding: return "\(subject) not responding"
        case .waitingForHost: return "Waiting for \(host)…"
        case .refused(let refusal): return refusal.menuLine(hostName: hostName)
        case .alone:
            if warning == .hostWithoutDockSupport {
                return "\(subject) is running without dock support: two apps may park the same windows. Update or quit one"
            }
            if connected { return "Connected to \(host)" }
            if hosts.isEmpty { return "No host app listed (dock.hosts in the settings file)" }
            return "No host app connected"
        }
    }
}

/// Whether the spoken line may speak now, and the call after it spoke (`CodeOwnSpeech`'s two ends).
struct SpeechGate {
    /// True: speak now (then `end` after the phrase). False: say nothing (the chime still plays).
    var begin: @MainActor () async -> Bool
    /// The phrase ended (or `begin` said no).
    var end: @MainActor () -> Void

    /// Nothing of a host listens: speak at once.
    static var alone: SpeechGate { SpeechGate(begin: { true }, end: {}) }
}
