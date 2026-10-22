import AppKit
import Foundation
import PitboxKit
import Testing
@testable import PitboxSessions

/// Renders the Ready list and the recap card as PNGs over a stand-in for the block's glass, when `PITBOX_TEST_OUT` is
/// set: `PITBOX_TEST_OUT=<dir> scripts/test.sh --filter renderReadyPictures`. Invented sessions only.
@MainActor
@Suite("Ready pictures", .serialized)
struct ReadyPictureTests {
    let folder = SeamFolder("ready-pictures")
    let clock = ManualClock(readyNow)

    init() { CodeTileLog.enabled = false }

    func id(_ n: Int) -> String { "local_0aaaaaaa-1111-4111-8111-\(String(format: "%012d", n))" }

    struct Scene {
        var name: String
        var width: CGFloat = 992
        var dark = true
        var hideText = false
        var tall = false
        var prepare: (ReadyPictureTests, CodeReadyForYou, inout [CodeSessionSnapshot], inout [CodeRecentSession]) -> Void
        var after: (ReadyPictureTests, CodeReadyForYou) -> Void = { _, _ in }
    }

    func warning() -> CodeSessionSnapshot {
        readySession(id(1), "Toy Cube · checkout tests", index: 1,
                     warnings: [CodeWarning(kind: .failedInARow, since: readyNow.addingTimeInterval(-120), failures: 4, lastExitCode: 1)])
    }

    func earlierCommand() -> CodeSessionSnapshot {
        var offer = readyOffer("rm -rf ~/Library/Caches/com.toycube.slicer && ./scripts/release.sh --channel beta", session: id(2),
                               index: 2, reply: "r2", replyTime: readyNow.addingTimeInterval(-2100), commandClass: .risky)
        offer.offer.supersession = CommandOffer.Supersession(newerReplies: 1, latestAt: readyNow.addingTimeInterval(-600),
                                                             sessionIsWorking: false)
        return readySession(id(2), "Toy Cube · print settings", index: 2, earlierOffers: [offer])
    }

    func fileOffer() -> CodeSessionSnapshot {
        let fetch = readyOffer("scp 'someone@buildbox:/home/someone/drafts/recipe-import-notes.md' ~/Downloads/",
                               session: id(3), index: 3, reply: "r3", replyTime: readyNow.addingTimeInterval(-300), commandClass: .fetchFile,
                               fetch: FetchFileRequest(alias: "buildbox", replyUser: "someone",
                                                       remotePath: "/home/someone/drafts/recipe-import-notes.md", destinationName: nil))
        return readySession(id(3), "Recipe box · import", index: 3, offers: [fetch])
    }

    func finished() -> CodeSessionSnapshot {
        readySession(id(4), "Weather app · forecast refactor", index: 4, tldr: "Workflow finished: K1-K4 done, 214 tests green.",
                     finished: CodeFinishedMark(replyUUID: "f4", at: readyNow.addingTimeInterval(-240), ranSeconds: 1260,
                                                etaWas: readyNow.addingTimeInterval(-420)),
                     results: [CodeResult(kind: .preview, origin: .replyLink, url: URL(string: "http://localhost:5173/"),
                                          label: "localhost:5173")],
                     dashboard: CodeDashboard(handle: "polar-shore", site: .test, firstSeen: readyNow))
    }

    func laterCommand() -> CodeSessionSnapshot {
        readySession(id(5), "Plant log · token setup", index: 5,
                     offers: [readyOffer("security add-generic-password -U -a \"$USER\" -s PLANTLOG_TOKEN -w", session: id(5),
                                         index: 5, reply: "r5", replyTime: readyNow.addingTimeInterval(-900))])
    }

    var scenes: [Scene] {
        let everything: (ReadyPictureTests, CodeReadyForYou, inout [CodeSessionSnapshot], inout [CodeRecentSession]) -> Void = { t, ready, sessions, _ in
            sessions = [t.warning(), t.earlierCommand(), t.fileOffer(), t.finished(), t.laterCommand()]
            _ = ready
        }
        let foldLater: (ReadyPictureTests, CodeReadyForYou) -> Void = { t, ready in
            if let key = ready.list.snapshot.entries.first(where: { $0.item.sessionID == t.id(5) })?.item.id
                ?? ready.list.allItems.first(where: { $0.sessionID == t.id(5) })?.id {
                ready.list.press(.later(key))
            }
        }
        return [
            Scene(name: "ready-cards-dark", prepare: everything, after: foldLater),
            Scene(name: "ready-cards-light", dark: false, prepare: everything, after: foldLater),
            Scene(name: "ready-tall-expanded-dark", tall: true, prepare: everything, after: foldLater),
            Scene(name: "ready-hide-text-dark", hideText: true, tall: true, prepare: everything),
            Scene(name: "ready-narrow-480-dark", width: 480, tall: true, prepare: everything),
            Scene(name: "ready-narrow-360-light", width: 360, dark: false, tall: true, prepare: { t, _, sessions, _ in
                sessions = [t.finished(), t.earlierCommand()]
            }),
            Scene(name: "ready-results-undo-dark", prepare: { t, ready, sessions, _ in
                sessions = [t.laterCommand(), t.fileOffer(), t.earlierCommand()]
                _ = ready
            }, after: { t, ready in
                let entries = ready.list.allItems
                if let run = entries.first(where: { $0.sessionID == t.id(5) }), let offerID = run.offerID {
                    let offer = t.laterCommand().offers[0].offer
                    _ = offerID
                    let runID = UUID()
                    ready.record(.started(runID: runID), offer: offer, sessionID: t.id(5))
                    ready.record(.finished(runID: runID, exitStatus: 0, seconds: 3), offer: offer, sessionID: t.id(5))
                }
                let fetch = t.fileOffer().offers[0].offer
                ready.record(.fetched(.saved(fileName: "recipe-import-notes.md", bytes: 42_100)), offer: fetch, sessionID: t.id(3))
                if let key = ready.list.allItems.first(where: { $0.sessionID == t.id(2) })?.id { ready.list.press(.dismiss(key)) }
            }),
            Scene(name: "ready-recap-dark", prepare: { t, ready, sessions, _ in
                sessions = [t.finished(), t.fileOffer()]
                ready.list.recap = CodeAwayRecap.Recap(
                    from: readyNow.addingTimeInterval(-1860), until: readyNow, sections: [
                        CodeAwayRecap.Section(kind: .finished, count: 2, lines: [
                            .init(headline: "“Weather app · forecast refactor”", detail: "at 14:33 · Workflow finished: K1-K4 done."),
                            .init(headline: "“Chess clock · timer bug”", detail: "at 14:12 · Matched 214 of 220 photos.")], more: 0),
                        CodeAwayRecap.Section(kind: .waiting, count: 3, lines: [
                            .init(headline: "“Recipe box · import”", detail: "file ready: recipe-import-notes.md"),
                            .init(headline: "“Toy Cube · checkout tests”", detail: "Looks stuck"),
                            .init(headline: "“Docs site · link checker”", detail: "needs you")], more: 0),
                        CodeAwayRecap.Section(kind: .running, count: 1, lines: [
                            .init(headline: "“Photo sorter · dedupe”", detail: "ETA 15:10")], more: 0)],
                    shownAt: readyNow)
            }),
            Scene(name: "ready-recap-light", dark: false, prepare: { t, ready, sessions, _ in
                sessions = [t.finished()]
                ready.list.recap = CodeAwayRecap.Recap(
                    from: readyNow.addingTimeInterval(-1860), until: readyNow, sections: [
                        CodeAwayRecap.Section(kind: .finished, count: 11, lines: (1...8).map {
                            .init(headline: "“Session \($0)”", detail: "at 14:\(10 + $0) · Report written.")
                        }, more: 3)],
                    shownAt: readyNow)
            }),
            Scene(name: "ready-recent-sessions-dark", prepare: { t, _, sessions, recent in
                var used = t.laterCommand()
                used.popout = nil
                var own = t.finished()
                own.popout = nil
                sessions = [used, own]
                recent = [CodeRecentSession(id: t.id(5), profile: .a, lastFocusedAt: readyNow.addingTimeInterval(-5 * 3600)),
                          CodeRecentSession(id: t.id(4), profile: .a, ownLastActivity: readyNow.addingTimeInterval(-600))]
            }),
        ]
    }

    @Test func renderReadyPictures() throws {
        let out = ProcessInfo.processInfo.environment["PITBOX_TEST_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        for scene in scenes {
            let presence = ReadyPresence(), scheduler = ReadyScheduler()
            let ready = CodeReadyForYou(memory: readyStore(SeamFolder("ready-picture"), clock: clock), settings: CodeSettings(),
                                        environment: presence.environment(scheduler))
            ready.list.clock = utcClock
            var sessions: [CodeSessionSnapshot] = []
            var recent: [CodeRecentSession] = []
            scene.prepare(self, ready, &sessions, &recent)
            var statuses: [String: CodeWindowStatus] = [:]
            for (n, session) in sessions.enumerated() where session.popout != nil {
                statuses[session.id] = CodeWindowStatus(place: n % 2 == 0 ? .onDesk : .parked(since: readyNow))
            }
            let parked = Set(statuses.filter { $0.value.isParked }.map(\.key))
            let followed = ready.follow(monitors: sessions.filter { $0.popout != nil }, statuses: statuses, parked: parked,
                                        recent: recent)
            ready.update(CodeReadyInput(sessions: sessions, followed: followed, statuses: statuses,
                                        bucketName: { _ in "Toy Cube" }, hideText: scene.hideText, tallTile: scene.tall,
                                        now: readyNow))
            scene.after(self, ready)
            let view = ready.makeView()
            view.testsRenderUnredacted = true
            view.now = { readyNow.addingTimeInterval(5) }
            view.pointerProbe = { nil }
            let height = max(40, view.accessoryHeight(forWidth: scene.width))
            view.frame = CGRect(x: 0, y: 0, width: scene.width, height: height)
            view.refresh()
            // Drawn a second after the layout: the open buttons have armed (0.8 s).
            view.now = { readyNow.addingTimeInterval(6) }
            let size = CGSize(width: scene.width, height: height)
            let png = try #require(PictureTests.picture(of: view, size: size, dark: scene.dark), "\(scene.name)")
            #expect(png.count > 2000, "\(scene.name)")
            if let out {
                try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                try png.write(to: out.appendingPathComponent("\(scene.name).png"))
            }
        }
    }
}
