import CoreGraphics
import Foundation
import Testing
@testable import PitboxSessions

// Drag-to-park's tracker as a pure state machine: made-up windows, points and times only. No window, event, timer or
// claim registry is real here.

enum DropFixture {
    /// The right-hand strip of a 5120 × 1440 display (Quartz).
    static let strip = CGRect(x: 3840, y: 30, width: 1280, height: 1312)
    static let popout = CodeDropPopout(sessionID: "local_4c1d2e", index: 3, pid: 4242, windowNumber: 77)
    static let other = CodeDropPopout(sessionID: "local_9f8e7d", index: 5, pid: 4242, windowNumber: 78)
    /// The pop-out on the desk, before any drag.
    static let desk = CGRect(x: 1000, y: 200, width: 900, height: 700)
    /// A press in its title bar.
    static let grab = CGPoint(x: 1200, y: 215)
    static let unsorted = CodeDropTarget(bucketID: "unsorted", bucketName: "Unsorted")
    static let toyCube = CodeDropTarget(bucketID: "b-k3x9q2", bucketName: "Toy Cube")
}

/// The tracker with a hand-moved pointer, window and clock; claim calls and effects are recorded in one ordered list.
struct TrackerRig {
    var tracker = PopOutDragTracker()
    var now: TimeInterval = 100
    var pointer = DropFixture.grab
    var window: CGRect? = DropFixture.desk
    var buttonDown = false
    var allowed = true
    var strips = [DropFixture.strip]
    var bucket: CodeDropTarget?
    var own: CodeDropTarget? = DropFixture.unsorted
    var grants = true
    /// "claim 4242 77" for claim calls; every effect as it came.
    var log: [String] = []
    var effects: [DragToParkEffect] = []
    var claimCalls = 0

    init(popouts: [CodeDropPopout] = [DropFixture.popout]) {
        _ = tracker.update(popouts: popouts, claimable: [DropFixture.popout.pid])
        tracker.observe(windowNumber: DropFixture.popout.windowNumber, bounds: DropFixture.desk, buttonDown: false)
    }

    @discardableResult
    mutating func tick() -> [DragToParkEffect] {
        let input = DragToParkTick(now: now, pointer: pointer, buttonDown: buttonDown, strips: strips,
                                   allowsArming: allowed, windowBounds: window, bucketUnderPointer: bucket)
        var calls: [String] = []
        let grants = self.grants
        let own = self.own
        let out = tracker.tick(input, claim: { pid, number in
            calls.append("claim \(pid) \(number)")
            return grants
        }, ownBucket: { _ in own })
        claimCalls += calls.count
        record(out, calls: calls)
        return out
    }

    mutating func record(_ out: [DragToParkEffect], calls: [String] = []) {
        log += calls
        log += out.map { "\($0)" }
        effects += out
    }

    /// Moves the pointer by (dx, dy), the window with it (a title-bar drag), and polls `steps` times 1/30 s apart.
    @discardableResult
    mutating func drag(dx: CGFloat, dy: CGFloat = 0, steps: Int = 1) -> [DragToParkEffect] {
        var out: [DragToParkEffect] = []
        for _ in 0..<steps {
            pointer.x += dx / CGFloat(steps)
            pointer.y += dy / CGFloat(steps)
            window = window?.offsetBy(dx: dx / CGFloat(steps), dy: dy / CGFloat(steps))
            now += 1.0 / 30
            out += tick()
        }
        return out
    }

    /// Holds still for `seconds`, polling at 30 Hz.
    @discardableResult
    mutating func hold(_ seconds: TimeInterval) -> [DragToParkEffect] {
        var out: [DragToParkEffect] = []
        var left = seconds
        while left > 1e-9 {
            let step = min(1.0 / 30, left)
            now += step
            left -= step
            out += tick()
        }
        return out
    }

    /// Button down on the title bar, the first move notification after the window started moving.
    mutating func startByNotification() {
        buttonDown = true
        drag(dx: 30)
        tracker.moved(windowNumber: DropFixture.popout.windowNumber, bounds: window ?? .zero, buttonDown: true,
                      pointer: pointer, now: now)
    }

    /// From the desk into the strip (pointer at x 3900), then held until armed.
    mutating func armInStrip() {
        startByNotification()
        drag(dx: 3900 - pointer.x, steps: 6)
        hold(0.3)
    }
}

@Suite("Drag-to-park tracker")
struct PopOutDragTrackerTests {
    @Test func armsAfterAQuarterSecondInsideTheStripAndNotBefore() throws {
        var rig = TrackerRig()
        rig.startByNotification()
        #expect(rig.tracker.drag != nil)
        rig.drag(dx: 3860 - rig.pointer.x, steps: 5)   // the last step lands inside the strip
        let entered = rig.now
        #expect(rig.tracker.drag?.insideSince == entered)
        rig.hold(0.2)
        #expect(rig.claimCalls == 0, "0.2 s inside: not armed")
        #expect(rig.tracker.drag?.armed == false)
        rig.hold(0.06)
        #expect(rig.claimCalls == 1)
        let drag = try #require(rig.tracker.drag)
        #expect(drag.armed)
        #expect(rig.effects.contains(.showLabel(text: "Drop to pit in Unsorted", at: rig.pointer)))
        #expect(rig.effects.contains(.log("drop armed session=#3")))
        #expect(!rig.effects.contains { if case .showSlot = $0 { return true } else { return false } },
                "no bucket under the pointer: no slot")
    }

    @Test func leavingTheStripDisarmsAtOnceAndReenteringWaitsAgain() {
        var rig = TrackerRig()
        rig.armInStrip()
        rig.effects.removeAll()
        rig.drag(dx: -200)   // out of the strip
        #expect(rig.effects == [.releaseClaim(pid: 4242, windowNumber: 77, parked: false), .hideLabel, .hideSlot,
                                .log("drop disarmed session=#3")])
        #expect(rig.tracker.drag?.armed == false)
        rig.drag(dx: 200)
        rig.hold(0.2)
        #expect(rig.claimCalls == 1, "back inside for 0.2 s: not armed again yet")
        rig.hold(0.1)
        #expect(rig.claimCalls == 2)
        #expect(rig.tracker.drag?.armed == true)
    }

    /// The claim calls in order: claim on arming, the mouse-up at the release, the park 0.05 s later with the frame
    /// from before the drag, the claim released as parked, the session into the target bucket.
    @Test func anArmedReleaseParksWithThePreDragFrameAfterFiftyMilliseconds() {
        var rig = TrackerRig()
        rig.armInStrip()
        rig.buttonDown = false
        rig.record(rig.tracker.released(now: rig.now, pointer: rig.pointer))
        rig.now += 0.04
        rig.tick()
        #expect(!rig.effects.contains { if case .park = $0 { return true } else { return false } }, "not before 0.05 s")
        rig.now += 0.011
        rig.tick()
        rig.record(rig.tracker.parkFinished(windowNumber: 77, result: .parked))
        let order = rig.log.filter { $0.hasPrefix("claim") || $0 == "noteMouseUp" || $0.hasPrefix("park(")
            || $0.hasPrefix("releaseClaim") || $0.hasPrefix("moveToBucket") }
        #expect(order == [
            "claim 4242 77", "noteMouseUp",
            "\(DragToParkEffect.park(sessionID: "local_4c1d2e", windowNumber: 77, restoreFrame: DropFixture.desk))",
            "\(DragToParkEffect.releaseClaim(pid: 4242, windowNumber: 77, parked: true))",
            "\(DragToParkEffect.moveToBucket(sessionID: "local_4c1d2e", target: DropFixture.unsorted))",
        ])
        #expect(rig.effects.contains(.log("drop parked session=#3")))
        #expect(rig.tracker.parks.isEmpty)
        #expect(!rig.tracker.needsPolling)
    }

    /// While a dropped pop-out's park is in flight it cannot be grabbed and claimed again (the first park's answer
    /// would otherwise release the new drag's claim); once the park answered, it can.
    @Test func aPopOutWhoseParkIsInFlightCannotBeGrabbedAgainUntilItAnswers() {
        var rig = TrackerRig()
        rig.armInStrip()
        rig.buttonDown = false
        rig.record(rig.tracker.released(now: rig.now, pointer: rig.pointer))
        #expect(rig.tracker.parkInFlight(77))
        let claimsBefore = rig.claimCalls
        // Grabbed again at once: neither a press nor a move notification starts a drag.
        rig.buttonDown = true
        rig.tracker.pressed(at: DropFixture.grab, front: (windowNumber: 77, bounds: DropFixture.desk), pointer: DropFixture.grab)
        rig.tracker.moved(windowNumber: 77, bounds: DropFixture.desk, buttonDown: true, pointer: DropFixture.grab, now: rig.now)
        #expect(rig.tracker.press == nil && rig.tracker.drag == nil)
        rig.hold(0.4)
        #expect(rig.claimCalls == claimsBefore, "no second claim while the park is in flight")
        // The park answers; the next grab works again.
        rig.buttonDown = false
        rig.tick()
        rig.record(rig.tracker.parkFinished(windowNumber: 77, result: .failed(reason: "couldn't pit (Claude didn't answer)")))
        #expect(!rig.tracker.parkInFlight(77))
        rig.buttonDown = true
        rig.tracker.moved(windowNumber: 77, bounds: DropFixture.desk, buttonDown: true, pointer: DropFixture.grab, now: rig.now)
        #expect(rig.tracker.drag != nil)
    }

    @Test func anUnarmedReleaseCallsNothing() {
        var rig = TrackerRig()
        rig.startByNotification()
        rig.drag(dx: 3900 - rig.pointer.x, steps: 6)
        rig.hold(0.15)
        rig.buttonDown = false
        rig.tick()
        rig.hold(1)
        #expect(rig.claimCalls == 0)
        #expect(rig.effects == [.observeSoon(windowNumber: 77)], "only a later look at its frame at rest")
        #expect(rig.tracker.drag == nil)
        #expect(rig.tracker.parks.isEmpty)
    }

    /// The release event was lost: the 30 Hz poll reads the button up and ends the drag the same way.
    @Test func aLostMouseUpEndsTheDragThroughThePoll() {
        var rig = TrackerRig()
        rig.armInStrip()
        rig.effects.removeAll()
        rig.buttonDown = false   // no released() call
        rig.tick()
        #expect(rig.effects == [.noteMouseUp, .hideLabel, .hideSlot, .log("drop released session=#3")])
        #expect(rig.tracker.parks.count == 1)
        rig.hold(0.06)
        #expect(rig.effects.contains(.park(sessionID: "local_4c1d2e", windowNumber: 77, restoreFrame: DropFixture.desk)))
    }

    @Test func aFailedParkReleasesUnparkedAtOnceAndShowsWhy() {
        var rig = TrackerRig()
        rig.armInStrip()
        let dropPoint = rig.pointer
        rig.buttonDown = false
        rig.tick()
        rig.hold(0.06)
        rig.effects.removeAll()
        rig.record(rig.tracker.parkFinished(windowNumber: 77, result: .failed(reason: "couldn't pit (Claude didn't answer)")))
        #expect(rig.effects == [.releaseClaim(pid: 4242, windowNumber: 77, parked: false),
                                .showFailure(text: "couldn't pit (Claude didn't answer)", at: dropPoint),
                                .log("drop park failed session=#3"), .observeSoon(windowNumber: 77)])
        #expect(rig.tracker.parkFinished(windowNumber: 77, result: .parked).isEmpty, "answered once")
    }

    /// Over a bucket the target is that bucket and the slot shows there; elsewhere in the strip it is the session's own
    /// bucket, without a slot.
    @Test func theBucketUnderThePointerIsTheTargetAndGetsTheSlot() {
        var rig = TrackerRig()
        rig.bucket = DropFixture.toyCube
        rig.armInStrip()
        let slot = CodeDropSlot(sessionID: "local_4c1d2e", target: DropFixture.toyCube)
        #expect(rig.effects.contains(.showLabel(text: "Drop to pit in Toy Cube", at: rig.pointer)))
        #expect(rig.effects.contains(.showSlot(slot)))
        rig.effects.removeAll()
        rig.bucket = nil
        rig.drag(dx: 40)
        #expect(rig.effects == [.showLabel(text: "Drop to pit in Unsorted", at: rig.pointer), .hideSlot])
        rig.effects.removeAll()
        rig.bucket = DropFixture.toyCube
        rig.drag(dx: 10)
        #expect(rig.effects == [.showLabel(text: "Drop to pit in Toy Cube", at: rig.pointer), .showSlot(slot)])
        rig.buttonDown = false
        rig.tick()
        rig.hold(0.06)
        rig.effects.removeAll()
        rig.record(rig.tracker.parkFinished(windowNumber: 77, result: .parked))
        #expect(rig.effects.contains(.moveToBucket(sessionID: "local_4c1d2e", target: DropFixture.toyCube)))
    }

    @Test func neverArmsWithDragToParkOffOrTheBlockHidden() {
        for blocked in ["setting off", "block hidden"] {
            var rig = TrackerRig()
            if blocked == "setting off" { rig.allowed = false } else { rig.strips = [] }
            rig.armInStrip()
            rig.hold(1)
            #expect(rig.claimCalls == 0, "\(blocked)")
            #expect(rig.tracker.drag?.armed == false)
        }
        // Drag-to-park turned off or the block hidden while armed (either makes allowsArming false): disarmed at once.
        var rig = TrackerRig()
        rig.armInStrip()
        rig.effects.removeAll()
        rig.allowed = false
        rig.hold(1.0 / 30)
        #expect(rig.effects.first == .releaseClaim(pid: 4242, windowNumber: 77, parked: false))
        #expect(rig.tracker.drag?.armed == false)
        rig.hold(1)
        #expect(rig.claimCalls == 1)
    }

    /// A refused claim (two windows claimed already, a copy not claimable, the button seen up) never arms: the guard
    /// would slide the window back while the block minimized it. Retried each poll, logged once.
    @Test func aRefusedClaimNeverArmsAndIsLoggedOnce() {
        var rig = TrackerRig()
        rig.grants = false
        rig.armInStrip()
        rig.hold(0.5)
        #expect(rig.tracker.drag?.armed == false)
        #expect(rig.claimCalls > 5, "asked again at every poll")
        #expect(rig.effects.filter { $0 == .log("drop claim refused session=#3") }.count == 1)
        #expect(!rig.effects.contains { if case .showLabel = $0 { return true } else { return false } })
        rig.grants = true
        rig.hold(1.0 / 30)
        #expect(rig.tracker.drag?.armed == true)
    }

    // MARK: Detection without notifications (the title-bar fallback)

    @Test func aTitleBarPressWhoseWindowMovesWithThePointerStartsADrag() throws {
        var rig = TrackerRig()
        rig.buttonDown = true
        rig.tracker.pressed(at: DropFixture.grab, front: (77, DropFixture.desk), pointer: DropFixture.grab)
        #expect(rig.tracker.press != nil)
        #expect(rig.tracker.needsPolling)
        rig.drag(dx: 1)
        #expect(rig.tracker.drag == nil, "1 pt is not a move yet")
        rig.drag(dx: 5, dy: 3)
        let drag = try #require(rig.tracker.drag)
        #expect(drag.preDragFrame == DropFixture.desk)
        #expect(drag.grab == CGPoint(x: 200, y: 15))
        rig.drag(dx: 3900 - rig.pointer.x, steps: 6)
        rig.hold(0.3)
        #expect(rig.tracker.drag?.armed == true)
    }

    @Test func aPressBelowTheTitleBandOrOnAnotherWindowStartsNothing() {
        var rig = TrackerRig()
        rig.buttonDown = true
        rig.tracker.pressed(at: CGPoint(x: 1200, y: 200 + 53), front: (77, DropFixture.desk), pointer: CGPoint(x: 1200, y: 253))
        #expect(rig.tracker.press == nil, "53 pt down: inside the window, below the title band")
        rig.tracker.pressed(at: DropFixture.grab, front: (99, DropFixture.desk), pointer: DropFixture.grab)
        #expect(rig.tracker.press == nil, "another window is in front there")
        rig.tracker.pressed(at: DropFixture.grab, front: nil, pointer: DropFixture.grab)
        #expect(rig.tracker.press == nil)
        _ = rig.tracker.update(popouts: [DropFixture.popout], claimable: [])
        rig.tracker.pressed(at: DropFixture.grab, front: (77, DropFixture.desk), pointer: DropFixture.grab)
        #expect(rig.tracker.press == nil, "a copy that is not claimable")
    }

    /// The top edge belongs to the title band, but resizing from it changes the window's size: no drag.
    @Test func aResizeFromTheTopEdgeIsNoDrag() {
        var rig = TrackerRig()
        rig.buttonDown = true
        let edge = CGPoint(x: 1200, y: 201)
        rig.pointer = edge
        rig.tracker.pressed(at: edge, front: (77, DropFixture.desk), pointer: edge)
        rig.pointer.y -= 40
        rig.window = CGRect(x: 1000, y: 160, width: 900, height: 740)
        rig.now += 1.0 / 30
        rig.tick()
        #expect(rig.tracker.press == nil)
        #expect(rig.tracker.drag == nil)
    }

    @Test func aPressWhoseWindowStaysIsDroppedOnceThePointerGoesFar() {
        var rig = TrackerRig()
        rig.buttonDown = true
        rig.tracker.pressed(at: DropFixture.grab, front: (77, DropFixture.desk), pointer: DropFixture.grab)
        rig.pointer.x += 30
        rig.tick()
        #expect(rig.tracker.press != nil, "30 pt: the window may lag a moment")
        rig.pointer.x += 20
        rig.tick()
        #expect(rig.tracker.press == nil)
        #expect(!rig.tracker.needsPolling)
    }

    // MARK: The frame from before the drag

    /// A notification comes once the window has moved: the frame stored for the restore is the one seen at rest.
    @Test func thePreDragFrameIsTheFrameAtRestNotTheFirstMovedOne() {
        var rig = TrackerRig()
        rig.startByNotification()
        #expect(rig.tracker.drag?.preDragFrame == DropFixture.desk)
        // While the button is down, observations never move the frame at rest.
        rig.tracker.observe(windowNumber: 77, bounds: CGRect(x: 2000, y: 200, width: 900, height: 700), buttonDown: true)
        #expect(rig.tracker.restFrames[77] == DropFixture.desk)
    }

    /// A press handled after the pointer moved may see the window moved already: the frame at rest is used instead.
    @Test func aPressReadLateUsesTheFrameAtRest() {
        var rig = TrackerRig()
        let moved = DropFixture.desk.offsetBy(dx: 8, dy: 0)
        rig.tracker.pressed(at: DropFixture.grab, front: (77, moved), pointer: CGPoint(x: 1208, y: 215))
        #expect(rig.tracker.press?.preDragFrame == DropFixture.desk)
        // Read before the pointer moved, the press's own bounds win (Claude may have moved it since the last pass).
        var fresh = TrackerRig()
        let newer = DropFixture.desk.offsetBy(dx: 0, dy: 40)
        let point = CGPoint(x: 1200, y: 255)
        fresh.tracker.pressed(at: point, front: (77, newer), pointer: point)
        #expect(fresh.tracker.press?.preDragFrame == newer)
    }

    /// Arming needs the window still held where the pointer grabbed it, at its size: a window its app moved, or one
    /// being resized, never arms.
    @Test func theWindowMustStillFollowThePointerToArm() {
        var rig = TrackerRig()
        rig.startByNotification()
        rig.drag(dx: 3900 - rig.pointer.x, steps: 6)
        rig.window = rig.window?.offsetBy(dx: -300, dy: 0)   // the window stops following
        rig.hold(0.5)
        #expect(rig.claimCalls == 0)
        rig.window = rig.window?.offsetBy(dx: 300, dy: 0)
        rig.hold(1.0 / 30)
        #expect(rig.claimCalls == 1)
        #expect(rig.tracker.drag?.armed == true)
    }

    // MARK: The window or its copy going away

    @Test func aPopOutThatLeavesTheDeskMidDragIsDisarmed() {
        var rig = TrackerRig()
        rig.armInStrip()
        rig.effects.removeAll()
        rig.record(rig.tracker.update(popouts: [], claimable: [4242]))
        #expect(rig.effects == [.releaseClaim(pid: 4242, windowNumber: 77, parked: false), .hideLabel, .hideSlot,
                                .log("drop disarmed session=#3")])
        #expect(rig.tracker.drag == nil)
    }

    @Test func aCopyNoLongerClaimableEndsTheDrag() {
        var rig = TrackerRig()
        rig.armInStrip()
        rig.effects.removeAll()
        rig.record(rig.tracker.update(popouts: [DropFixture.popout], claimable: []))
        #expect(rig.effects.first == .releaseClaim(pid: 4242, windowNumber: 77, parked: false))
        #expect(rig.tracker.drag == nil)
        #expect(!rig.tracker.isCandidate(77))
    }

    @Test func cancellingDisarmsAndKeepsParksInFlight() {
        var rig = TrackerRig(popouts: [DropFixture.popout, DropFixture.other])
        rig.armInStrip()
        rig.buttonDown = false
        rig.tick()
        rig.hold(0.06)
        #expect(rig.tracker.parks.count == 1)
        rig.effects.removeAll()
        #expect(rig.tracker.cancelDrag().isEmpty, "no drag running")
        #expect(rig.tracker.parks.count == 1, "the park keeps its claim until it answers")
    }

    /// Two drops in a row: each park is answered once, by its own window.
    @Test func twoDropsInFlightAreAnsweredSeparately() {
        var rig = TrackerRig(popouts: [DropFixture.popout, DropFixture.other])
        rig.armInStrip()
        rig.buttonDown = false
        rig.tick()
        rig.hold(0.06)
        // The second pop-out, dragged in by notification.
        rig.pointer = CGPoint(x: 600, y: 915)
        rig.window = CGRect(x: 500, y: 900, width: 800, height: 400)
        rig.tracker.observe(windowNumber: 78, bounds: rig.window ?? .zero, buttonDown: false)
        rig.buttonDown = true
        rig.drag(dx: 30)
        rig.tracker.moved(windowNumber: 78, bounds: rig.window ?? .zero, buttonDown: true, pointer: rig.pointer, now: rig.now)
        rig.drag(dx: 3900 - rig.pointer.x, steps: 6)
        rig.hold(0.3)
        rig.buttonDown = false
        rig.tick()
        rig.hold(0.06)
        #expect(rig.tracker.parks.map(\.popout.windowNumber) == [77, 78])
        rig.effects.removeAll()
        rig.record(rig.tracker.parkFinished(windowNumber: 78, result: .parked))
        #expect(rig.effects.first == .releaseClaim(pid: 4242, windowNumber: 78, parked: true))
        #expect(rig.tracker.parks.map(\.popout.windowNumber) == [77])
    }

    @Test func pollingRunsOnlyForAPressADragOrAParkDelay() {
        var rig = TrackerRig()
        #expect(!rig.tracker.needsPolling)
        rig.armInStrip()
        #expect(rig.tracker.needsPolling)
        rig.buttonDown = false
        rig.tick()
        #expect(rig.tracker.needsPolling, "the 0.05 s before the park")
        rig.hold(0.06)
        #expect(!rig.tracker.needsPolling, "the park is the window side's now")
    }

    @Test func theLabelsWords() {
        #expect(CodeDropTarget.labelText(nil) == "Drop to pit")
        #expect(CodeDropTarget.labelText(DropFixture.toyCube) == "Drop to pit in Toy Cube")
        let hidden = CodeDropTarget(bucketID: "b-aaaaaa", bucketName: "Toy\u{202E}Cube")
        #expect(CodeDropTarget.labelText(hidden) == "Drop to pit in Toy⟨U+202E⟩Cube", "shown, escaped, never interpreted")
        let long = CodeDropTarget(bucketID: "b-bbbbbb", bucketName: String(repeating: "x", count: 50))
        #expect(CodeDropTarget.labelText(long).count <= "Drop to pit in ".count + 32)
    }
}
