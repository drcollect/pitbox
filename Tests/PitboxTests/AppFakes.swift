import AppKit
import Foundation
@testable import Pitbox
import PitboxKit
import PitboxSessions

// Fakes for the composition root's tests: a session source that records what the engine would read when the block
// reloads it, a window side and a sheet that do nothing, and scratch folders. Invented data only.

/// A scratch folder, resolved (so `/var` and `/private/var` cannot differ), removed when released.
final class ScratchFolder {
    let url: URL

    init(_ name: String) {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("pitbox-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        url = raw.resolvingSymlinksInPath()
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    /// Writes `text` as `name`, 0600, in place.
    func write(_ text: String, to name: String) throws {
        let target = file(name)
        try Data(text.utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }
}

/// The engine as the block drives it: `reloadSettings()` records what its environment's settings closure returns at
/// that moment (the engine's worker reads it exactly then).
@MainActor
final class EngineProbe: CodeSessionsSource, CodeSettingsReloading {
    var sessions: [CodeSessionSnapshot] = []
    var runningProfiles: [CodeProfile] = [.a]
    var runningProcesses: [ClaudeProcessInfo] = []
    var banner: String?
    var onChange: (() -> Void)?
    let settingsClosure: @Sendable () -> CodeSettings
    private(set) var seen: [CodeSettings] = []

    init(settings: @escaping @Sendable () -> CodeSettings) { settingsClosure = settings }

    func setWatched(_ sessionIDs: Set<String>) {}
    func setStripVisible(_ visible: Bool) {}
    func start() {}
    func stop() {}
    func recentSessions(within hours: Double) -> [CodeRecentSession] { [] }
    func reloadSettings() { seen.append(settingsClosure()) }
}

@MainActor
final class IdleParker: CodeWindowParking {
    var statuses: [String: CodeWindowStatus] = [:]
    var parkedSessionIDs: Set<String> = []
    var deskWindows: [String: CodeDeskWindow] = [:]
    var onChange: (() -> Void)?
    func start() {}
    func stop() {}
    func update(sessions: [CodeSessionSnapshot], processes: [ClaudeProcessInfo]) {}
    func setActive(_ active: Bool) {}
    func perform(_ click: CodeWindowClick, sessionID: String) {}
    func parkAllDone(_ sessionIDs: [String]) async -> CodeParkAllResult { CodeParkAllResult() }
    func parkFrontmostPopout() async -> CodeParkFrontmostResult { .notAPopout }
}

/// A sheet that records what reached it.
@MainActor
final class RecordingSheet: CommandOfferPresenting {
    private(set) var calls: [String] = []
    private(set) var events: [@MainActor (CommandOfferEvent) -> Void] = []

    func present(_ offer: CommandOffer, anchor: CGRect, freshness: CommandOfferFreshnessChecking,
                 events: @escaping @MainActor (CommandOfferEvent) -> Void) {
        calls.append("present")
        self.events.append(events)
    }

    func presentFetch(_ request: FetchFileRequest, source: CommandOffer.Source, sessionIndex: Int, anchor: CGRect,
                      freshness: CommandOfferFreshnessChecking, events: @escaping @MainActor (CommandOfferEvent) -> Void) {
        calls.append("fetch")
        self.events.append(events)
    }

    func offerWentStale(_ offer: CommandOffer.ID) { calls.append("stale") }
    func offerWasSuperseded(_ offer: CommandOffer.ID, supersession: CommandOffer.Supersession) { calls.append("superseded") }
    func dismissSheet() { calls.append("dismiss") }
    func revealRun(_ runID: UUID) { calls.append("reveal") }
}

final class FreshFreshness: CommandOfferFreshnessChecking {
    func freshness(of offer: CommandOffer.ID) async -> CommandOfferFreshness { .fresh }
}

enum AppFixture {
    static func offer() -> CommandOffer {
        let facts = CommandSessionFacts(place: .local, homeDirectory: "/Users/alex", userName: "alex", turnOrigin: .human)
        return CommandOffer(id: CommandOffer.ID(sessionIndex: 1, replyUUID: "reply-1", number: 1), text: "ls -la", total: 1,
                            blockKind: .tagged("zsh"), displayLines: [CommandOffer.DisplayLine(role: .command, text: "ls -la")],
                            caption: nil,
                            source: CommandOffer.Source(sessionID: "local_s1", headline: "h",
                                                        replyTime: Date(timeIntervalSince1970: 0)),
                            replyReadCompletely: true, folder: CommandOffer.Folder(path: "/Users/alex", isHomeFallback: false),
                            context: CommandContext(facts: facts), replyText: "reply")
    }
}

/// Waits (suspending, never parking a thread) until `condition` holds or `seconds` pass.
@MainActor
func eventually(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
    let deadline = MonotonicClock.now() + seconds
    while !condition() {
        if MonotonicClock.now() > deadline { return false }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return true
}
