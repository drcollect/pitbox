import AppKit
import Foundation
import Testing
@testable import PitboxSessions
import PitboxKit

/// The list view's buttons: open buttons arm 0.8 s after they appear or move and never under a pointer that was already
/// there (docs/THREAT_MODEL.md); Later and OK act at once.
@MainActor
@Suite("Ready list view", .serialized)
struct ReadyViewTests {
    let folder = SeamFolder("ready-view")
    let clock = ManualClock(readyNow)

    init() { CodeTileLog.enabled = false }

    func id(_ n: Int) -> String { "local_0aaaaaaa-1111-4111-8111-\(String(format: "%012d", n))" }

    final class Box {
        var time = readyNow
        var pointer: CGPoint?
        var actions: [CodeReadyAction] = []
    }

    func make() -> (CodeReadyList, CodeReadyListView, Box) {
        let list = CodeReadyList(memory: readyStore(folder, clock: clock))
        let scheduler = ReadyScheduler()
        list.schedule = scheduler.schedule
        list.clock = utcClock
        list.now = { readyNow }
        let box = Box()
        list.onAction = { action, _ in box.actions.append(action) }
        let view = CodeReadyListView(list: list)
        view.now = { box.time }
        view.pointerProbe = { box.pointer }
        view.screenFrame = { rect, _ in rect }
        list.onChange = { view.refresh() }
        view.frame = CGRect(x: 0, y: 0, width: 992, height: 400)
        return (list, view, box)
    }

    func finishedSession(_ n: Int) -> CodeSessionSnapshot {
        readySession(id(n), index: n,
                     finished: CodeFinishedMark(replyUUID: "f\(n)", at: readyNow.addingTimeInterval(-60), ranSeconds: 600),
                     results: [CodeResult(kind: .artifact, origin: .artifactTool,
                                          url: URL(string: "https://claude.ai/artifact/abcdefgh12"), label: "artifact")])
    }

    func input(_ sessions: [CodeSessionSnapshot]) -> CodeReadyInput {
        var statuses: [String: CodeWindowStatus] = [:]
        for session in sessions { statuses[session.id] = CodeWindowStatus(place: .onDesk) }
        return CodeReadyInput(sessions: sessions,
                              followed: CodeFollowedSet(monitors: sessions, statuses: statuses, parked: [], recent: [],
                                                        recentHours: 6, now: readyNow),
                              statuses: statuses, now: readyNow)
    }

    func button(_ view: CodeReadyListView, _ prefix: String) -> CodeReadyLayout.Button? {
        view.layout.buttons.first { $0.title.hasPrefix(prefix) }
    }

    func click(_ view: CodeReadyListView, _ point: CGPoint) {
        view.pressDown(at: point)
        view.pressUp(at: point)
    }

    @Test func aCardThatAppearsUnderThePointerSwallowsThePress() throws {
        let (list, view, box) = make()
        // The pointer rests where the artifact button will appear.
        list.update(input([finishedSession(1)]))
        let artifact = try #require(button(view, "↗ Open artifact"))
        let spot = CGPoint(x: artifact.rect.midX, y: artifact.rect.midY)
        let (fresh, freshView, freshBox) = make()
        freshBox.pointer = spot
        fresh.update(input([finishedSession(1)]))
        freshBox.time = readyNow.addingTimeInterval(2)
        click(freshView, spot)
        #expect(freshBox.actions.isEmpty, "the pointer was already there when the button appeared")
        // It leaves and comes back: now a press counts.
        freshView.pointerMoved(to: CGPoint(x: 1, y: 1))
        freshView.pointerMoved(to: spot)
        click(freshView, spot)
        #expect(freshBox.actions.count == 1)
        if case .openResult(let session, let result)? = freshBox.actions.first {
            #expect(session == id(1) && result.kind == .artifact)
        } else {
            Issue.record("expected openResult")
        }
        _ = box
    }

    @Test func aPressSoonAfterAMoveIsIgnoredAndALaterOneCounts() throws {
        let (list, view, box) = make()
        list.update(input([finishedSession(2)]))
        box.time = readyNow.addingTimeInterval(5)
        // A warning arrives above it: the card moves, its open buttons arm again.
        list.update(input([readySession(id(1), index: 1, warnings: [CodeWarning(kind: .silence, since: readyNow)]), finishedSession(2)]))
        let moved = try #require(button(view, "↗ Open artifact"))
        let spot = CGPoint(x: moved.rect.midX, y: moved.rect.midY)
        box.time = readyNow.addingTimeInterval(5.5)
        click(view, spot)
        #expect(box.actions.isEmpty, "0.5 s after the move")
        box.time = readyNow.addingTimeInterval(5.9)
        click(view, spot)
        #expect(box.actions.count == 1, "0.9 s after the move")
    }

    /// The list follows the buckets: a bucket that grows moves it under a pointer that stayed still.
    @Test func aMoveInTheTileStackMovesAndRearmsTheOpenButtons() throws {
        let (list, view, box) = make()
        list.update(input([finishedSession(3)]))
        let artifact = try #require(button(view, "↗ Open artifact"))
        let spot = CGPoint(x: artifact.rect.midX, y: artifact.rect.midY)
        box.time = readyNow.addingTimeInterval(10)
        box.pointer = spot
        view.movedInStack()
        box.time = readyNow.addingTimeInterval(12)
        click(view, spot)
        #expect(box.actions.isEmpty, "moved under a pointer that was already there")
        view.pointerMoved(to: CGPoint(x: 1, y: 1))
        view.pointerMoved(to: spot)
        click(view, spot)
        #expect(box.actions.count == 1)
    }

    @Test func pressesThatOpenNothingActAtOnceAndAPressMustEndOnItsButton() throws {
        let (list, view, box) = make()
        let session = readySession(id(1), index: 1, offers: [readyOffer("echo 1", session: id(1), index: 1, reply: "r1")])
        list.update(input([session]))
        let later = try #require(button(view, "Later"))
        // Run is off by default (`commands` copyOnly): the card's sheet button says Review… (RunOffWordsTests has Run on).
        let run = try #require(button(view, "Review…"))
        // A press that began on Review and ended on Later does nothing.
        view.pressDown(at: CGPoint(x: run.rect.midX, y: run.rect.midY))
        view.pressUp(at: CGPoint(x: later.rect.midX, y: later.rect.midY))
        #expect(box.actions.isEmpty && list.snapshot.later.isEmpty)
        click(view, CGPoint(x: later.rect.midX, y: later.rect.midY))
        #expect(list.snapshot.later.count == 1, "Later acts at once")
        // The Later row's Review… opens the sheet at once too (the sheet has its own arming).
        let rowRun = try #require(button(view, "Review…"))
        click(view, CGPoint(x: rowRun.rect.midX, y: rowRun.rect.midY))
        #expect(box.actions == [.openSheet(session.offers[0].id, sessionID: id(1))])
        // A click on the row's text unfolds it.
        let area = try #require(view.layout.buttons.first { $0.style == .area })
        click(view, CGPoint(x: area.rect.minX + 20, y: area.rect.midY))
        #expect(list.snapshot.later.isEmpty && list.snapshot.entries.count == 1)
    }

    @Test func onANarrowCardLinksShortenThenGiveWayAndOKStays() throws {
        let (list, _, _) = make()
        var session = finishedSession(1)
        session.results = [CodeResult(kind: .preview, origin: .replyLink, url: URL(string: "http://localhost:5173/"),
                                      label: "localhost:5173")]
        session.dashboard = CodeDashboard(handle: "polar-shore", site: .test, firstSeen: readyNow)
        list.update(input([session]))
        let wide = CodeReadyLayout(list.snapshot, width: 992).buttons.map(\.title)
        #expect(wide == ["Back on track", "↗ Open preview · localhost:5173", "▦ Dashboard", "OK"])
        let medium = CodeReadyLayout(list.snapshot, width: 420).buttons.map(\.title)
        #expect(medium == ["Back on track", "↗ Open preview", "▦ Dashboard", "OK"])
        let narrow = CodeReadyLayout(list.snapshot, width: 300).buttons.map(\.title)
        #expect(narrow.first == "Back on track" && narrow.last == "OK" && narrow.count < 4)
    }

    @Test func theArmingRule() {
        var arming = CodeReadyArming()
        let rect = CGRect(x: 10, y: 10, width: 80, height: 18)
        arming.layout(["a": rect], pointer: nil, now: readyNow)
        #expect(!arming.counts("a", downAt: readyNow.addingTimeInterval(0.79)))
        #expect(arming.counts("a", downAt: readyNow.addingTimeInterval(0.801)))
        arming.layout(["a": rect], pointer: nil, now: readyNow.addingTimeInterval(3))
        #expect(arming.counts("a", downAt: readyNow.addingTimeInterval(3)), "unmoved: still armed")
        arming.layout(["a": rect.offsetBy(dx: 0, dy: 66)], pointer: CGPoint(x: 20, y: 80), now: readyNow.addingTimeInterval(4))
        #expect(!arming.counts("a", downAt: readyNow.addingTimeInterval(10)), "moved under the pointer")
        arming.pointerMoved(to: CGPoint(x: 500, y: 500))
        #expect(arming.counts("a", downAt: readyNow.addingTimeInterval(10)))
        #expect(arming.nextArming(after: readyNow.addingTimeInterval(4.1)) == readyNow.addingTimeInterval(4.8))
        #expect(!arming.counts("missing", downAt: readyNow.addingTimeInterval(10)))
    }

    @Test func theViewHasNoKeyboardAndAccessibilityLabelsHoldNoSessionText() throws {
        let (list, view, _) = make()
        list.update(input([readySession(id(1), "\(secretWord) headline", index: 1,
                                        offers: [readyOffer("echo \(secretWord)", session: id(1), index: 1, reply: "r1")])]))
        #expect(!view.acceptsFirstResponder)
        let labels = (view.accessibilityChildren() ?? []).compactMap { ($0 as? NSAccessibilityElement)?.accessibilityLabel() }
        #expect(labels.contains("Review command") && labels.contains("Later") && labels.contains("Dismiss"))
        #expect(!labels.contains { $0.contains(secretWord) })
    }
}
