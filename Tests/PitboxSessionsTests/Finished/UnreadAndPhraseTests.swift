import Foundation
import Testing
@testable import PitboxSessions
import PitboxKit

/// The unread dot by event times against `seenAt`, none on first sight, cleared by looking; only on
/// parked monitors.
@Suite("Unread dot", .serialized)
struct UnreadTests {
    let folder = SeamFolder("unread")
    let clock = ManualClock(readyNow)

    func derive(_ sessions: [CodeSessionSnapshot], memory: CodeMemoryStore, now: Date = readyNow,
                digest: CodeTurnDigest = .empty) -> [String: CodeDerivedFields] {
        var fields: [String: CodeDerivedFields] = [:]
        let inputs = sessions.map { CodeCrossSessionInput(snapshot: $0, digest: digest, digestVersion: 1) }
        UnreadDeriver().derive(inputs, context: CodeCrossDeriveContext(now: now, memory: memory, settings: CodeSettings(),
                                                                       owner: getuid()), into: &fields)
        return fields
    }

    @Test func firstSightIsReadThenNewEventsAreUnreadUntilSeen() {
        let memory = readyStore(folder, clock: clock)
        let quiet = readySession(sessionA)
        #expect(derive([quiet], memory: memory)[sessionA]?.unread == false, "first sight: seenAt is now")
        let seen: CodeSeenRecord? = memory.read(.seen, session: sessionA)
        #expect(seen?.at == readyNow)

        let later = readyNow.addingTimeInterval(60)
        let offer = readyOffer("echo 1", reply: "r1", replyTime: later)
        #expect(derive([readySession(sessionA, offers: [offer])], memory: memory, now: later)[sessionA]?.unread == true)
        let warned = readySession(sessionA, warnings: [CodeWarning(kind: .silence, since: later)])
        #expect(derive([warned], memory: memory, now: later)[sessionA]?.unread == true)
        let result = readySession(sessionA, results: [CodeResult(kind: .artifact, origin: .artifactTool, label: "a", at: later)])
        #expect(derive([result], memory: memory, now: later)[sessionA]?.unread == true)
        let finishedTurn = digestOf([Line.user("Go", uuid: "u1", at: readyNow), Line.text("Done.", uuid: "a1", at: later)])
        #expect(derive([quiet], memory: memory, now: later, digest: finishedTurn)[sessionA]?.unread == true, "a finished turn of any length")

        CodeUnreadMarks.markSeen(sessionA, memory: memory, now: later.addingTimeInterval(1))
        #expect(derive([readySession(sessionA, offers: [offer])], memory: memory, now: later)[sessionA]?.unread == false)
    }

    @Test func anSSHServerClockAFewSecondsAheadRaisesNoDot() {
        let memory = readyStore(folder, clock: clock)
        let ssh = readySession(sessionA), local = readySession(sessionB, place: .local, sshHost: nil)
        _ = derive([ssh, local], memory: memory)
        let soon = readyNow.addingTimeInterval(3)
        let offer = { (session: String) in readyOffer("echo 1", session: session, reply: "r1", replyTime: soon) }
        let fields = derive([readySession(sessionA, offers: [offer(sessionA)]),
                             readySession(sessionB, place: .local, sshHost: nil, offers: [offer(sessionB)])], memory: memory, now: soon)
        #expect(fields[sessionA]?.unread == false, "SSH: within the slack")
        #expect(fields[sessionB]?.unread == true, "this Mac's clock: counted")
        let later = readyNow.addingTimeInterval(UnreadDeriver.sshClockSlack + 1)
        let past = derive([readySession(sessionA, offers: [readyOffer("echo 2", reply: "r2", replyTime: later)])],
                          memory: memory, now: later)
        #expect(past[sessionA]?.unread == true)
    }

    @Test func theDotShowsOnParkedMonitorsOnly() {
        var unread = readySession(sessionA)
        unread.unread = true
        #expect(CodeUnreadMarks.showsDot(unread, status: CodeWindowStatus(place: .parked(since: readyNow)), parked: []))
        #expect(CodeUnreadMarks.showsDot(unread, status: CodeWindowStatus(place: .closed), parked: []))
        #expect(CodeUnreadMarks.showsDot(unread, status: nil, parked: [sessionA]))
        #expect(!CodeUnreadMarks.showsDot(unread, status: CodeWindowStatus(place: .onDesk), parked: []))
        #expect(!CodeUnreadMarks.showsDot(readySession(sessionA), status: CodeWindowStatus(place: .parked(since: readyNow)), parked: []))
        #expect(!CodeUnreadMarks.dotLabel.isEmpty)
    }
}

/// The generic phrase by default; with `sayHeadlines`, the letters-only wake-word check on the raw headline, then the
/// cleaner without the assistant-name replacement, cut at 60 characters.
@Suite("Spoken phrase")
struct SpokenPhraseTests {
    @Test func withoutSayHeadlinesItIsAlwaysTheGenericPhrase() {
        #expect(CodeSpokenPhrase.finished(headlines: ["Toy Cube · checkout"], sayHeadlines: false) == "A Code session is done")
        #expect(CodeSpokenPhrase.finished(headlines: ["a", "b", "c"], sayHeadlines: true) == "3 Code sessions are done")
        #expect(CodeSpokenPhrase.finished(headlines: [], sayHeadlines: true) == "A Code session is done")
    }

    /// An invented wake word, as `neverSay` (or a dock host's `wakeWords`) would list it.
    static let neverSay = ["Nova"]

    @Test func headlinesThatHoldANeverSayWordGiveTheGenericPhrase() {
        for headline in ["N.O.V.A. build", "N.O.V.A", "N O V A", "NOVA", "no-va", "hey nova tests",
                         "Ν.Ο.V.A.", "Nóva", "ｎｏｖａ"] {
            #expect(CodeSpokenPhrase.headlinePhrase(headline, neverSay: Self.neverSay) == CodeSpokenPhrase.generic, "\(headline)")
            #expect(CodeSpokenPhrase.finished(headlines: [headline], sayHeadlines: true, neverSay: Self.neverSay)
                    == CodeSpokenPhrase.generic, "\(headline)")
        }
        // Nothing listed (the default): every word may be said.
        #expect(CodeSpokenPhrase.headlinePhrase("hey nova tests") == "hey nova tests is done")
        // A listed word without letters never matches anything.
        #expect(CodeSpokenPhrase.headlinePhrase("release 1.2", neverSay: ["1.2", "  "]) == "release 1.2 is done")
    }

    @Test func theCleanerAndTheCut() {
        #expect(CodeSpokenPhrase.headlinePhrase("build → deploy") == "build deploy is done")
        let long = "Move the photo archive to the new folder layout and check every album twice before Friday"
        let phrase = CodeSpokenPhrase.headlinePhrase(long)
        #expect(phrase.hasSuffix(" is done"))
        let spoken = String(phrase.dropLast(" is done".count))
        #expect(spoken.count <= 60 && long.hasPrefix(spoken) && !spoken.hasSuffix(" ") && long.dropFirst(spoken.count).first == " ")
        // No letters, a hidden character: the generic phrase.
        #expect(CodeSpokenPhrase.headlinePhrase("1234 · 56") == CodeSpokenPhrase.generic)
        #expect(CodeSpokenPhrase.headlinePhrase("Fix\u{202E} build") == CodeSpokenPhrase.generic)
        // The cleaner never produces a never-say word.
        for headline in ["Ab → NOVA", "No → va", "N.O → V.A", "Casa nova build", "Supernova"] {
            let letters = CodeSpokenPhrase.headlinePhrase(headline, neverSay: Self.neverSay).lowercased().filter(\.isLetter)
            #expect(!letters.contains("nova"), "\(headline)")
        }
    }

    @Test func theRecapReadOutSaysCountsOnly() {
        #expect(CodeSpokenPhrase.recap(finished: 2, waiting: 3, running: 1)
                == "While you were away, 2 finished, 3 are waiting for you and 1 is still running.")
        #expect(CodeSpokenPhrase.recap(finished: 1, waiting: 0, running: 2) == "While you were away, 1 finished and 2 are still running.")
        #expect(CodeSpokenPhrase.recap(finished: 0, waiting: 1, running: 0) == "While you were away, 1 is waiting for you.")
        #expect(CodeSpokenPhrase.recap(finished: 0, waiting: 0, running: 0) == nil)
    }
}
