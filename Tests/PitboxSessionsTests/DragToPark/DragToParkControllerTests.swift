import AppKit
import CoreGraphics
import Foundation
import PitboxKit
import Testing
@testable import PitboxSessions

// Drag-to-park's controller over fakes: the system calls, the window side, the claims registry and the label are fakes;
// one test uses the real `WindowDropClaims` with a fake button and clock. No real window, event monitor or timer.

@MainActor
@Suite("Drag-to-park controller")
struct DragToParkControllerTests {
    init() { CodeTileLog.enabled = false }

    @Test func idleCostsNothingAndMonitorsRunOnlyWithPopOutsOnTheDesk() {
        let rig = DragRig(conditions: CodeDragToParkConditions(dragToPark: true, stripShown: false))
        #expect(rig.system.repeatingTimers.isEmpty, "block hidden: no pass, no poll")
        #expect(!rig.system.monitorsInstalled)
        rig.controller.setStripVisible(true)
        #expect(rig.system.repeatingTimers == [1], "the 1 Hz pass")
        #expect(rig.system.monitorsInstalled, "a pop-out is on the desk")
        rig.parker.deskPopouts = []
        rig.controller.refresh()
        #expect(!rig.system.monitorsInstalled, "no pop-out on the desk: no monitors")
        rig.parker.deskPopouts = [DropFixture.popout]
        rig.system.advance(1)
        #expect(rig.system.monitorsInstalled, "the pass found it again")
        for idle in ["off", "hidden"] {
            switch idle {
            case "off":
                var settings = CodeSettings()
                settings.dragToPark = false
                rig.controller.update(settings: settings)
            default: rig.controller.setStripVisible(false)
            }
            #expect(rig.system.repeatingTimers.isEmpty, "\(idle): nothing runs")
            #expect(!rig.system.monitorsInstalled, "\(idle)")
            rig.controller.update(settings: CodeSettings())
            rig.controller.setStripVisible(true)
            #expect(rig.system.repeatingTimers == [1])
        }
    }

    /// The whole drop: claimable copies set, the claim on arming, the label, the mouse-up to the claims, the park 0.05 s
    /// later with the frame from before the drag, released as parked, the session into its bucket.
    @Test func aDropParksThroughTheWindowSideWithTheFrameFromBeforeTheDrag() throws {
        let rig = DragRig()
        rig.dragIntoStrip()
        #expect(rig.claims.log == ["claimable [4242]", "claim 4242 77"], "the unreadable copy is never claimable")
        let shown = try #require(rig.label.shown)
        #expect(shown.text == "Drop to pit in Unsorted")
        #expect(!shown.failure)
        #expect(shown.at == rig.system.appKitPoint(fromQuartz: rig.system.pointerAt), "next to the pointer")
        rig.system.release()
        #expect(rig.claims.log.last == "mouseUp")
        #expect(rig.label.shown == nil)
        #expect(rig.parker.parks.isEmpty, "the park waits 0.05 s")
        rig.system.advance(0.07)
        let park = try #require(rig.parker.parks.first)
        #expect(park.sessionID == "local_4c1d2e")
        #expect(park.frame == DropFixture.desk, "the frame from before the drag, for the restore")
        rig.parker.answer(0, .parked)
        #expect(rig.claims.log.last == "release 4242 77 parked=true")
        #expect(rig.slots.parked.count == 1)
        #expect(rig.slots.parked.first?.0 == "local_4c1d2e")
        #expect(rig.slots.parked.first?.1 == DropFixture.unsorted)
        #expect(rig.system.repeatingTimers == [1], "the 30 Hz poll stopped")
    }

    @Test func aFailedParkReleasesUnparkedAndShowsTheReasonForThreeSeconds() throws {
        let rig = DragRig()
        rig.dragIntoStrip()
        rig.system.release()
        rig.system.advance(0.07)
        rig.parker.answer(0, .failed(reason: "couldn't pit (Claude didn't answer)"))
        #expect(rig.claims.log.last == "release 4242 77 parked=false", "at once: the guard slides it back now")
        let shown = try #require(rig.label.shown)
        #expect(shown.failure)
        #expect(shown.text == "couldn't pit (Claude didn't answer)")
        rig.system.advance(2.9)
        #expect(rig.label.shown != nil)
        rig.system.advance(0.2)
        #expect(rig.label.shown == nil)
        #expect(rig.slots.parked.isEmpty)
    }

    /// A drop armed while a failure line still shows takes the label over; the failure's timer then leaves it alone.
    @Test func aDropArmedDuringTheFailureLineKeepsItsLabel() throws {
        let rig = DragRig()
        rig.dragIntoStrip()
        rig.system.release()
        rig.system.advance(0.07)
        rig.parker.answer(0, .failed(reason: "couldn't pit (Claude didn't answer)"))
        // The guard slid it back; the user tries again at once.
        rig.system.windows[0].bounds = DropFixture.desk
        rig.system.advance(0.6)
        rig.dragIntoStrip(hold: 2.5)
        #expect(rig.label.shown?.text == "Drop to pit in Unsorted")
        rig.system.advance(1)
        let shown = try #require(rig.label.shown, "the old failure timer did not hide the armed label")
        #expect(!shown.failure)
    }

    /// Two drops close together: the first one's failure line shows while the second is armed, and the second one
    /// disarming does not take that line away before its 3 s.
    @Test func aDisarmLeavesAnotherDropsFailureLine() throws {
        let rig = DragRig()
        let second = CGRect(x: 500, y: 900, width: 800, height: 400)
        rig.system.windows.append(CodeDragWindow(number: 78, pid: 4242, bounds: second, layer: 0, alpha: 1))
        rig.parker.deskPopouts = [DropFixture.popout, DropFixture.other]
        rig.controller.refresh()
        rig.dragIntoStrip()
        rig.system.release()
        rig.system.advance(0.07)
        #expect(rig.parker.parks.count == 1)
        rig.system.press(at: CGPoint(x: 600, y: 915))
        for _ in 0..<12 {
            rig.system.move(78, dx: (3900 - 600) / 12)
            rig.system.advance(1.0 / 30)
        }
        rig.system.advance(0.4)
        #expect(rig.claims.log.last == "claim 4242 78")
        rig.parker.answer(0, .failed(reason: "couldn't pit (Claude didn't answer)"))
        #expect(rig.label.shown?.failure == true)
        rig.system.move(78, dx: -300)   // the second drop leaves the strip: disarmed
        rig.system.advance(1.0 / 30)
        #expect(rig.claims.log.last == "release 4242 78 parked=false")
        let shown = try #require(rig.label.shown, "the first drop's failure line stays")
        #expect(shown.failure)
        rig.system.advance(3)
        #expect(rig.label.shown == nil)
        rig.system.release()
    }

    @Test func theStripHidingMidDragDisarmsAtOnce() {
        let rig = DragRig()
        rig.dragIntoStrip()
        rig.controller.setStripVisible(false)
        #expect(rig.claims.log.last == "release 4242 77 parked=false")
        #expect(rig.label.shown == nil)
        #expect(rig.system.monitorsInstalled, "the drag still runs: its release is still seen")
        rig.system.release()
        rig.system.advance(1)
        #expect(rig.parker.parks.isEmpty, "released unarmed: nothing new")
        #expect(!rig.system.monitorsInstalled)
        #expect(rig.system.repeatingTimers.isEmpty)
    }

    /// Over a bucket of the visible block: the slot shows there and the drop parks into that bucket.
    @Test func theSlotShowsInTheBucketUnderThePointer() {
        let rig = DragRig()
        let box = BucketProbe()
        rig.controller.bucketUnderPointer = { point in box.under(point) }
        box.bucket = DropFixture.toyCube
        rig.dragIntoStrip()
        #expect(rig.label.shown?.text == "Drop to pit in Toy Cube")
        #expect(rig.slots.changes.last == CodeDropSlot(sessionID: "local_4c1d2e", target: DropFixture.toyCube))
        #expect(box.points.last == rig.system.appKitPoint(fromQuartz: rig.system.pointerAt), "asked with AppKit points")
        box.bucket = nil
        rig.system.move(77, dx: 30)
        rig.system.advance(1.0 / 30)
        #expect(rig.slots.changes.last == .some(nil))
        #expect(rig.label.shown?.text == "Drop to pit in Unsorted")
        box.bucket = DropFixture.toyCube
        rig.system.move(77, dx: 10)
        rig.system.advance(1.0 / 30)
        rig.system.release()
        #expect(rig.slots.changes.last == .some(nil), "the slot goes at the release")
        rig.system.advance(0.07)
        rig.parker.answer(0, .parked)
        #expect(rig.slots.parked.first?.1 == DropFixture.toyCube)
    }

    /// A release the monitors missed: the poll reads the button up and the drop parks all the same.
    @Test func aLostMouseUpStillEndsTheDragThroughThePoll() {
        let rig = DragRig()
        rig.dragIntoStrip()
        rig.system.release(reported: false)
        rig.system.advance(1.0 / 30 + 0.07)
        #expect(rig.claims.log.contains("mouseUp"))
        #expect(rig.parker.parks.count == 1)
    }

    @Test func aQuickReleaseNeverArms() {
        let rig = DragRig()
        rig.dragIntoStrip(hold: 0.15)
        rig.system.release()
        rig.system.advance(1)
        #expect(rig.claims.log == ["claimable [4242]"])
        #expect(rig.parker.parks.isEmpty)
        #expect(rig.label.history.isEmpty)
    }

    /// Without notifications the press decides: one on another window in front of the pop-out's title bar, or on the
    /// label itself, is no press of the pop-out.
    @Test func aPressOnAWindowInFrontOfThePopOutIsNoPress() {
        let rig = DragRig()
        rig.system.windows.insert(CodeDragWindow(number: 12, pid: 600, bounds: CGRect(x: 1100, y: 150, width: 300, height: 200),
                                                 layer: 0, alpha: 1), at: 0)
        rig.dragIntoStrip()
        #expect(rig.claims.log == ["claimable [4242]"], "the press went to the other window")
        rig.system.release()
        let label = CodeDragWindow(number: 900, pid: getpid(), bounds: CGRect(x: 1100, y: 150, width: 300, height: 200),
                                   layer: 25, alpha: 1)
        rig.system.windows[0] = label
        rig.system.windows[1].bounds = DropFixture.desk
        rig.dragIntoStrip()
        #expect(rig.claims.log.last == "claim 4242 77", "the label is skipped: the press is the pop-out's")
    }

    /// With notifications: the window observer (over its own fakes) watches the desk pop-out for this drop; a move read
    /// with the button down starts the drag (no mouse-down event at all here), and the frame stored is the one at rest.
    @Test func theWindowObserversMovesStartADrag() {
        let rig = DragRig()
        let timeline = TagTimeline()
        let ax = FakeTagAX()
        let server = FakeTagServer()
        let button = FakeTagButton()
        let observer = CodeWindowObserver(queue: FakeTagQueue(timeline), ax: ax, server: server, button: button,
                                          uptime: { timeline.now }, deliverToMain: { work in work() })
        let key = CodeWindowKey(pid: 4242, number: 77)
        server.windows[77] = DeskTagServerWindow(number: 77, pid: 4242, bounds: DropFixture.desk)
        rig.controller.attach(observer: observer)
        timeline.drain()
        #expect(ax.watchCalls == [key], "the desk pop-out is watched while drag-to-park is active")
        rig.system.buttonDown = true
        button.down = true
        rig.system.pointerAt = DropFixture.grab
        func step(_ dx: CGFloat) {
            rig.system.move(77, dx: dx)
            server.windows[77]?.bounds = rig.system.windows[0].bounds
            ax.post(.moved, pid: 4242)
            timeline.advance(by: 1.0 / 30)
            rig.system.advance(1.0 / 30)
        }
        step(40)
        for _ in 0..<10 { step((3900 - 1240) / 10) }
        rig.system.advance(0.3)
        #expect(rig.claims.log.last == "claim 4242 77")
        button.down = false
        rig.system.release()
        rig.system.advance(0.07)
        #expect(rig.parker.parks.first?.frame == DropFixture.desk, "the frame at rest, not the first moved one")
        // Idle again: the observer is asked for nothing more.
        rig.controller.setStripVisible(false)
        timeline.drain()
        #expect(ax.unwatchCalls == [key])
        rig.controller.stop()
    }

    /// The observer's moves of another app's window, or of a window that is no desk pop-out, start nothing.
    @Test func movesOfOtherWindowsStartNothing() {
        let rig = DragRig()
        rig.system.buttonDown = true
        rig.controller.moved(pid: 600, windowNumber: 77, bounds: DropFixture.desk, buttonDown: true)
        rig.controller.moved(pid: 4242, windowNumber: 12, bounds: DropFixture.desk, buttonDown: true)
        rig.system.advance(1)
        #expect(rig.system.repeatingTimers == [1], "no drag: no 30 Hz poll")
    }

    /// The desk pop-outs come from the window join's `deskWindows` and the data side's indexes.
    @Test func deskPopOutsComeFromTheJoinsDeskWindows() {
        let windows = ["local_a": CodeDeskWindow(pid: 4242, windowNumber: 78), "local_b": CodeDeskWindow(pid: 4242, windowNumber: 77),
                       "local_gone": CodeDeskWindow(pid: 4242, windowNumber: 90)]
        let sessions = [tileSession("local_a", "a", index: 4), tileSession("local_b", "b", index: 9)]
        #expect(CodeDropPopout.desk(windows, sessions: sessions) == [
            CodeDropPopout(sessionID: "local_b", index: 9, pid: 4242, windowNumber: 77),
            CodeDropPopout(sessionID: "local_a", index: 4, pid: 4242, windowNumber: 78),
        ], "a session the data side no longer lists is left out")
        #expect(CodeDropPopout.desk([:], sessions: sessions).isEmpty)
        // The production drop reads them through the parker and the source it was given, weakly.
        let parker = DeskWindowsParker()
        let source = TileTestSource()
        parker.deskWindows = ["local_b": CodeDeskWindow(pid: 4242, windowNumber: 77)]
        source.sessions = sessions
        let read = CodeDragToPark.deskPopouts(parker: parker, source: source)
        #expect(read() == [CodeDropPopout(sessionID: "local_b", index: 9, pid: 4242, windowNumber: 77)])
        parker.deskWindows = [:]
        #expect(read().isEmpty, "read anew each time")
    }

    @Test func stopDisarmsAndRemovesEverything() {
        let rig = DragRig()
        rig.dragIntoStrip()
        rig.controller.stop()
        #expect(rig.claims.log.last == "release 4242 77 parked=false")
        #expect(rig.label.shown == nil)
        #expect(rig.system.repeatingTimers.isEmpty)
        #expect(rig.system.pendingCalls == 0)
        #expect(!rig.system.monitorsInstalled)
        rig.controller.setStripVisible(true)
        rig.controller.refresh()
        #expect(rig.system.repeatingTimers.isEmpty, "stopped for good")
    }

    /// The real registry: the claim holds while armed, the mouse-up dates it, the park's release ends it. The guard is
    /// not involved here (its own tests cover the other side).
    @Test func withTheRealRegistryTheClaimHoldsUntilTheParkAnswers() throws {
        final class Clock: @unchecked Sendable {
            var now: TimeInterval = 50
            var down = false
        }
        let clock = Clock()
        let registry = WindowDropClaims(isLeftButtonDown: { clock.down }, now: { clock.now })
        let system = FakeDragSystem()
        let parker = FakeDropParker()
        let controller = CodeDragToPark(claims: registry, parker: parker, desk: { parker.deskPopouts },
                                        processes: { [ClaudeProcessInfo(pid: 4242, profile: .a)] },
                                        stripRegions: { [DragRig.strip] },
                                        conditions: CodeDragToParkConditions(dragToPark: true, stripShown: true),
                                        system: system, label: FakeDropLabel())
        system.windows = [CodeDragWindow(number: 77, pid: 4242, bounds: DropFixture.desk, layer: 0, alpha: 1)]
        parker.deskPopouts = [DropFixture.popout]
        controller.refresh()
        clock.down = true
        system.press(at: DropFixture.grab)
        for _ in 0..<12 {
            system.move(77, dx: 225)
            system.advance(1.0 / 30)
        }
        system.advance(0.4)
        clock.now = system.now
        let held = try #require(registry.holdRemaining(pid: 4242, windowNumber: 77))
        #expect(held > 29, "held while the button is down")
        clock.down = false
        system.release()
        let left = try #require(registry.holdRemaining(pid: 4242, windowNumber: 77))
        #expect(left <= 3, "the release dated it")
        system.advance(0.07)
        parker.answer(0, .parked)
        #expect(registry.holdRemaining(pid: 4242, windowNumber: 77) == nil)
        #expect(registry.count == 0)
    }

    @Test func logLinesHoldLabelsAndNumbersOnly() {
        CodeTileLog.startRecording()
        let rig = DragRig()
        let box = BucketProbe()
        box.bucket = DropFixture.toyCube
        rig.controller.bucketUnderPointer = { box.under($0) }
        rig.dragIntoStrip()
        rig.system.move(77, dx: -300)
        rig.system.advance(1.0 / 30)
        rig.system.move(77, dx: 300)
        rig.system.advance(0.4)
        rig.system.release()
        rig.system.advance(0.07)
        rig.parker.answer(0, .failed(reason: "couldn't pit (Claude didn't answer)"))
        let lines = CodeTileLog.recorded.filter { $0.hasPrefix("drop ") }
        #expect(lines.contains("drop armed session=#3"))
        #expect(lines.contains("drop disarmed session=#3"))
        #expect(lines.contains("drop park failed session=#3"))
        for line in CodeTileLog.recorded {
            #expect(!line.contains("local_4c1d2e"), "no session id: \(line)")
            #expect(!line.contains("Toy Cube"), "no bucket name: \(line)")
        }
    }
}

/// The block's bucket hit test, as a probe.
@MainActor
final class BucketProbe {
    var bucket: CodeDropTarget?
    var points: [CGPoint] = []
    func under(_ point: CGPoint) -> CodeDropTarget? {
        points.append(point)
        return bucket
    }
}
