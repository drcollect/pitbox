import Darwin
import Foundation
@testable import PitboxSessions
import PitboxKit

// Invented data only (never the user's sessions): fixtures for the Ready list and Finished tests.

/// A fixed "now" for these tests: 2026-10-01 14:37:00 UTC (the data fixtures' clock).
let readyNow = fixtureNow

/// A clock face in UTC, 24-hour, so the words of the tests do not depend on this Mac's zone or format.
let utcClock = CodeReadyClock(timeZone: TimeZone(identifier: "UTC") ?? .gmt, locale: Locale(identifier: "en_GB"))

/// A memory store in a fresh folder with a hand clock (writes coalesce for 0.05 s).
func readyStore(_ folder: SeamFolder, clock: ManualClock) -> CodeMemoryStore {
    CodeMemoryStore(url: folder.file("code-memory.json"), owner: getuid(), clock: { clock.now }, writeInterval: 0.05,
                    writeMax: CodeTuning.memoryWriteMax)
}

/// A transcript and a session file on disk (their identities are read by the earlier-offers deriver).
struct ReadyFiles {
    let folder: SeamFolder
    let cli = "0f3c2a9e-1111-2222-3333-444455556666"

    init(_ name: String = "ready-files") {
        folder = SeamFolder(name)
        try? FileManager.default.createDirectory(at: folder.url.appendingPathComponent("ssh-\(cli)"), withIntermediateDirectories: true)
        try? Data("{}\n".utf8).write(to: transcriptURL)
        try? Data("{}".utf8).write(to: folder.file("session.json"))
    }

    var transcriptURL: URL { folder.url.appendingPathComponent("ssh-\(cli)/\(cli).jsonl") }
    var transcript: CarefulPath? { CarefulPath(root: folder.url.path, components: ["ssh-\(cli)", "\(cli).jsonl"]) }
    var sessionFile: CarefulPath? { CarefulPath(root: folder.url.path, components: ["session.json"]) }

    /// Writes `lines` as the transcript (the deriver reads only its identity).
    func write(_ lines: [String]) {
        try? Data(lines.map { $0 + "\n" }.joined().utf8).write(to: transcriptURL)
    }

    /// Replaces the transcript with a new file (a new inode).
    func replace() {
        let copy = folder.file("copy.jsonl")
        try? FileManager.default.copyItem(at: transcriptURL, to: copy)
        _ = try? FileManager.default.replaceItemAt(transcriptURL, withItemAt: copy)
    }
}

/// The derive input a per-session deriver gets (the engine builds the same).
func deriveInput(_ snapshot: CodeSessionSnapshot, digest: CodeTurnDigest, now: Date = readyNow, memory: CodeMemoryStore,
                 settings: CodeSettings = CodeSettings(), files: ReadyFiles?, version: Int = 1) -> CodeDeriveInput {
    CodeDeriveInput(snapshot: snapshot, digest: digest, digestVersion: version, now: now, memory: memory, settings: settings,
                    transcript: files?.transcript, sessionFile: files?.sessionFile, owner: getuid())
}

/// A session snapshot with the Ready fields a test needs.
func readySession(_ id: String, _ headline: String = "Toy Cube · checkout", index: Int = 3, state: CodeSessionState = .done,
                  place: CommandSessionFacts.Place = .ssh, sshHost: String? = "buildbox", tldr: String? = "Checkout works.",
                  offers: [CodeOfferEntry] = [], earlierOffers: [CodeOfferEntry] = [], popout: Bool = true,
                  replyUUID: String? = nil, finished: CodeFinishedMark? = nil, warnings: [CodeWarning] = [],
                  results: [CodeResult] = [], dashboard: CodeDashboard? = nil, profile: CodeProfile = .a,
                  lastActivity: Date? = readyNow, progress: CodeProgress? = nil, eta: CodeETA? = nil,
                  workStartedAt: Date? = nil) -> CodeSessionSnapshot {
    CodeSessionSnapshot(id: id, index: index, profile: profile, headline: headline, nickname: "calm otter",
                        title: headline + " (calm otter)", place: place, sshHost: sshHost, cwd: "/home/someone/project",
                        state: state, lastActivity: lastActivity, tldr: tldr, offers: offers,
                        popout: popout ? CodePopoutHint(bounds: CGRect(x: 100, y: 100, width: 900, height: 700)) : nil,
                        turnFinishedAt: state == .working ? nil : lastActivity, workStartedAt: workStartedAt,
                        replyUUID: replyUUID, progress: progress, eta: eta, results: results, warnings: warnings,
                        dashboard: dashboard, earlierOffers: earlierOffers, finished: finished)
}

/// Session facts as the engine builds them for an SSH session on buildbox.
func readyFacts(origin: CommandTurnOrigin = .human) -> CommandSessionFacts {
    CommandSessionFacts(place: .ssh, sshAlias: "buildbox", resolvedHostName: "192.0.2.10", serverNames: ["box.example"],
                        knownSSHHosts: ["buildbox"], remoteCwd: "/home/someone/project", homeDirectory: "/Users/someone",
                        userName: "someone", turnOrigin: origin)
}

/// An offer as the engine would publish it.
func readyOffer(_ text: String, session: String = sessionA, index: Int = 3, reply: String, number: Int = 1, total: Int = 1,
                replyTime: Date = readyNow.addingTimeInterval(-600), commandClass: CommandAssessment.Class = .notFlagged,
                fetch: FetchFileRequest? = nil, replyText: String? = nil,
                programs: Set<String>? = ["ls", "git", "echo", "scp"]) -> CodeOfferEntry {
    let facts = readyFacts()
    let offer = CommandOffer(id: CommandOffer.ID(sessionIndex: index, replyUUID: reply, number: number), text: text,
                             total: total, blockKind: .tagged("bash"),
                             displayLines: [CommandOffer.DisplayLine(role: .command, text: text)], caption: nil,
                             source: CommandOffer.Source(sessionID: session, headline: "Toy Cube · checkout",
                                                         youAsked: "Make the checkout work", replyTime: replyTime),
                             replyReadCompletely: true, folder: CommandOffer.Folder(path: "/Users/someone", isHomeFallback: false),
                             context: CommandContext(facts: facts, programsOnCleanPath: programs, runFolder: "/Users/someone"),
                             replyText: replyText ?? "Run it:\n\n```bash\n\(text)\n```")
    let assessment = CommandAssessment(commandClass: commandClass, machine: .thisMac, machineReason: "reason", fetch: fetch,
                                       lineCount: 1, commandCount: 1)
    return CodeOfferEntry(offer: offer, assessment: assessment)
}

/// Runs scheduled work by hand and records the delays it was asked for.
@MainActor
final class ReadyScheduler {
    private(set) var delays: [TimeInterval] = []
    private var queue: [(delay: TimeInterval, work: @MainActor () -> Void)] = []

    /// Holds the scheduler strongly: tests keep only the object under test (a cycle in a test is harmless).
    var schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void {
        { delay, work in
            self.delays.append(delay)
            self.queue.append((delay, work))
        }
    }

    var pending: Int { queue.count }

    /// Runs what was scheduled so far (work it schedules waits for the next call).
    func runAll() {
        let now = queue
        queue = []
        for item in now { item.work() }
    }

    /// Runs only the work scheduled with `delay`.
    func run(delay: TimeInterval) {
        let matching = queue.filter { abs($0.delay - delay) < 0.001 }
        queue.removeAll { abs($0.delay - delay) < 0.001 }
        for item in matching { item.work() }
    }
}

/// On-device speech that only records (no real voice in tests).
@MainActor
final class ReadySpeech {
    var listenerPauses = true
    private(set) var calls: [String] = []
    private(set) var spoken: [String] = []

    var speech: CodeOwnSpeech {
        CodeOwnSpeech(beginOwnSpeech: {
            self.calls.append("begin")
            return self.listenerPauses
        }, speak: { phrase in
            self.calls.append("speak")
            self.spoken.append(phrase)
        }, endOwnSpeech: {
            self.calls.append("end")
        })
    }
}

/// Presence and window facts a test changes as it goes.
@MainActor
final class ReadyPresence {
    var now = readyNow
    var idle: TimeInterval? = 1
    var locked = false
    var canSpeak = true
    var keyWindows: Set<String> = []
    var claudeInFront = false
    private(set) var chimes = 0

    func environment(_ scheduler: ReadyScheduler, speech: ReadySpeech? = nil) -> CodeReadyEnvironment {
        CodeReadyEnvironment(clock: { self.now }, idleSeconds: { self.idle }, screenLocked: { self.locked },
                             canSpeakNow: { self.canSpeak }, isKeyWindow: { self.keyWindows.contains($0) },
                             claudeIsFrontmost: { self.claudeInFront }, chime: { self.chimes += 1 }, speech: speech?.speech,
                             schedule: scheduler.schedule)
    }
}

/// Waits until the main actor has run pending tasks (speech runs in a Task).
@MainActor
func settle(_ rounds: Int = 20) async {
    for _ in 0..<rounds { await Task.yield() }
}
