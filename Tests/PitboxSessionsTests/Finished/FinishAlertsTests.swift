import Foundation
import Testing
@testable import PitboxSessions
import PitboxKit

/// Finish alerts with fake closures (no real sound or voice): the three steps of speaking, the generic
/// phrase, coalescing, the 30 s between phrases, skipped while busy, locked or away, and the "looking at it" rule.
@MainActor
@Suite("Finish alerts", .serialized)
struct FinishAlertsTests {
    let folder = SeamFolder("alerts")
    let clock = ManualClock(readyNow)

    init() { CodeTileLog.enabled = false }

    func id(_ n: Int) -> String { "local_0aaaaaaa-1111-4111-8111-\(String(format: "%012d", n))" }

    struct Rig {
        let alerts: CodeFinishAlerts
        let presence: ReadyPresence
        let scheduler: ReadyScheduler
        let speech: ReadySpeech
        let memory: CodeMemoryStore
    }

    func rig(chime: Bool = true, sayIt: Bool = true, sayHeadlines: Bool = false) -> Rig {
        var settings = CodeSettings()
        settings.chime = chime
        settings.sayIt = sayIt
        settings.sayHeadlines = sayHeadlines
        let presence = ReadyPresence(), scheduler = ReadyScheduler(), speech = ReadySpeech()
        let memory = readyStore(folder, clock: clock)
        let alerts = CodeFinishAlerts(environment: presence.environment(scheduler, speech: speech), memory: memory, settings: settings)
        return Rig(alerts: alerts, presence: presence, scheduler: scheduler, speech: speech, memory: memory)
    }

    func finished(_ n: Int, _ headline: String = "Toy Cube · checkout", silent: Bool = false, item: Bool = true,
                  popout: Bool = true) -> CodeSessionSnapshot {
        readySession(id(n), headline, index: n, popout: popout,
                     finished: CodeFinishedMark(replyUUID: "r\(n)", at: readyNow, ranSeconds: 600, hasItem: item, silent: silent))
    }

    func followed(_ sessions: [CodeSessionSnapshot], parked: Bool = true, recent: [CodeRecentSession] = []) -> CodeFollowedSet {
        let ids = Set(sessions.filter { $0.popout != nil }.map(\.id))
        return CodeFollowedSet(monitors: sessions, statuses: [:], parked: parked ? ids : [], recent: recent, recentHours: 6,
                               now: readyNow)
    }

    @Test func aLiveFinishChimesAndSaysTheGenericPhraseInThreeSteps() async {
        let r = rig()
        var pulses: [String] = []
        r.alerts.onFinishPulse = { pulses.append($0) }
        let session = finished(1)
        r.alerts.observe([session], followed: followed([session]))
        #expect(r.presence.chimes == 0 && r.scheduler.delays == [CodeFinishAlerts.alertGather] && pulses == [id(1)])
        r.scheduler.runAll()
        await settle()
        #expect(r.presence.chimes == 1 && r.speech.calls == ["begin", "speak"] && r.speech.spoken == ["A Code session is done"])
        #expect(r.scheduler.delays.last == CodeTuning.speechResumeDelay)
        r.scheduler.runAll()
        #expect(r.speech.calls == ["begin", "speak", "end"], "the listener resumes 0.5 s after the phrase")
        // The same finish never alerts twice.
        r.alerts.observe([session], followed: followed([session]))
        #expect(r.scheduler.pending == 0)
    }

    @Test func aListenerThatDoesNotPauseMeansNothingIsSaid() async {
        let r = rig()
        r.speech.listenerPauses = false
        r.alerts.observe([finished(1)], followed: followed([finished(1)]))
        r.scheduler.runAll()
        await settle()
        // begin had asked for the pause: end undoes it at once, or the host's listener would stay paused.
        #expect(r.speech.calls == ["begin", "end"] && r.speech.spoken.isEmpty && r.scheduler.pending == 0)
    }

    @Test func headlinesOnlyWithSayHeadlinesAndSeveralFinishesAreOnePhrase() async {
        let headlines = rig(sayHeadlines: true)
        headlines.alerts.observe([finished(1, "Chess clock · timer bug")], followed: followed([finished(1, "Chess clock · timer bug")]))
        headlines.scheduler.runAll()
        await settle()
        #expect(headlines.speech.spoken == ["Chess clock · timer bug is done"])

        let several = rig()
        let three = [finished(1), finished(2), finished(3)]
        several.alerts.observe(three, followed: followed(three))
        several.scheduler.runAll()
        await settle()
        #expect(several.presence.chimes == 1 && several.speech.spoken == ["3 Code sessions are done"])
    }

    @Test func laterFinishesJoinWithin20sAndPhrasesComeAtMostEvery30s() async {
        let r = rig()
        r.alerts.observe([finished(1)], followed: followed([finished(1)]))
        r.scheduler.runAll()
        await settle()
        r.scheduler.runAll()
        r.presence.now = readyNow.addingTimeInterval(10)
        r.alerts.observe([finished(1), finished(2)], followed: followed([finished(1), finished(2)]))
        r.scheduler.runAll()
        await settle()
        #expect(r.presence.chimes == 1 && r.speech.spoken.count == 1, "joined the alert of 10 s ago")
        r.presence.now = readyNow.addingTimeInterval(25)
        r.alerts.observe([finished(3)], followed: followed([finished(3)]))
        r.scheduler.runAll()
        await settle()
        #expect(r.presence.chimes == 2 && r.speech.spoken.count == 1, "a chime, but no phrase within 30 s")
    }

    @Test func noSoundWhileBusyLockedOrAway() async {
        let setUps: [@MainActor (ReadyPresence) -> Void] = [{ $0.canSpeak = false }, { $0.locked = true }, { $0.idle = 15 * 60 }]
        for setUp in setUps {
            let r = rig()
            setUp(r.presence)
            r.alerts.observe([finished(1)], followed: followed([finished(1)]))
            r.scheduler.runAll()
            await settle()
            #expect(r.presence.chimes == 0 && r.speech.calls.isEmpty)
        }
        // Off by default: nothing at all.
        let off = rig(chime: false, sayIt: false)
        off.alerts.observe([finished(1)], followed: followed([finished(1)]))
        off.scheduler.runAll()
        await settle()
        #expect(off.presence.chimes == 0 && off.speech.calls.isEmpty)
    }

    @Test func underTheUsersEyesAPopOutGetsNoItemAndAMainWindowSessionNoSound() async throws {
        let r = rig()
        r.presence.idle = 10
        // A desk pop-out whose window is key in the frontmost app: its record is closed, nothing sounds.
        r.memory.write(.finished, session: id(1), value: [CodeFinishedRecord(reply: "r1", at: readyNow, ranSeconds: 600, open: true,
                                                                             expired: false, item: true, silent: false, etaWas: nil)])
        r.presence.keyWindows = [id(1)]
        let desk = finished(1)
        r.alerts.observe([desk], followed: followed([desk], parked: false))
        let records: [CodeFinishedRecord] = try #require(r.memory.read(.finished, session: id(1)))
        #expect(records.first?.open == false && r.scheduler.pending == 0)
        // A main-window session while Claude is in front: the card stays, no sound.
        r.presence.claudeInFront = true
        let recent = finished(2, popout: false)
        r.alerts.observe([recent], followed: followed([recent], recent: [CodeRecentSession(id: id(2), profile: .a,
                                                                                            lastFocusedAt: readyNow)]))
        #expect(r.scheduler.pending == 0)
        // Without recent input both would alert.
        r.presence.idle = 120
        let another = finished(3)
        r.alerts.observe([another], followed: followed([another], parked: false))
        #expect(r.scheduler.pending == 1)
    }

    @Test func silentMarksAndMarksWithoutAnItemNeverAlert() {
        let r = rig()
        r.alerts.observe([finished(1, silent: true), finished(2, item: false)], followed: followed([finished(1), finished(2)]))
        #expect(r.scheduler.pending == 0)
    }

    @Test func theRecapReadOutUsesTheSameVoiceAndRules() async {
        let r = rig()
        let recap = CodeAwayRecap.Recap(from: readyNow, until: readyNow, sections: [
            CodeAwayRecap.Section(kind: .finished, count: 2, lines: [], more: 0),
            CodeAwayRecap.Section(kind: .waiting, count: 3, lines: [], more: 0)], shownAt: readyNow)
        r.alerts.sayRecap(recap)
        await settle()
        #expect(r.speech.spoken == ["While you were away, 2 finished and 3 are waiting for you."])
        let quiet = rig()
        quiet.presence.locked = true
        quiet.alerts.sayRecap(recap)
        await settle()
        #expect(quiet.speech.calls.isEmpty)
    }
}
