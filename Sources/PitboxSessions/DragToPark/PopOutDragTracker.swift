import CoreGraphics
import Foundation

/// What the tracker asks its host to do, in order.
enum DragToParkEffect: Equatable {
    /// Ends a claim: parked (the block minimized it) or not (the guard corrects it at once).
    case releaseClaim(pid: pid_t, windowNumber: UInt32, parked: Bool)
    /// The left button went up while armed: dates the claims' mouse-up before anything else.
    case noteMouseUp
    /// "Drop to park in <bucket>" next to the pointer (Quartz point), shown or moved.
    case showLabel(text: String, at: CGPoint)
    /// The park failed: the reason next to where the window was dropped (Quartz), for 3 s.
    case showFailure(text: String, at: CGPoint)
    /// Hides the armed label (never a failure line shown for another drop).
    case hideLabel
    /// The dashed slot in the bucket under the pointer, or none.
    case showSlot(CodeDropSlot)
    case hideSlot
    /// Parks through the window side with the frame from before the drag.
    case park(sessionID: String, windowNumber: UInt32, restoreFrame: CGRect)
    /// Parked: the session goes to the drop's bucket.
    case moveToBucket(sessionID: String, target: CodeDropTarget)
    /// Reads the window's bounds again shortly (the guard may slide it back): its frame at rest.
    case observeSoon(windowNumber: UInt32)
    /// A `[code]` log line: labels and numbers only.
    case log(String)
}

/// One poll of the 30 Hz timer, read by the host: Quartz points and rectangles, monotonic seconds.
struct DragToParkTick: Equatable {
    var now: TimeInterval
    /// `NSEvent.mouseLocation`, in Quartz coordinates.
    var pointer: CGPoint
    /// `CGEventSource.buttonState(.combinedSessionState, .left)`.
    var buttonDown: Bool
    /// The block's published regions (each equal to its frame).
    var strips: [CGRect]
    /// `CodeDragToParkConditions.allowsArming`.
    var allowsArming: Bool
    /// The pressed or dragged window's window-server bounds now (nil: gone or not on screen).
    var windowBounds: CGRect?
    /// The bucket of the visible block under the pointer, if any.
    var bucketUnderPointer: CodeDropTarget?
}

/// The drag-to-park state machine, pure: the host feeds it events and the time, and applies its effects.
///
/// - **A pop-out drag** starts at a move notification for a matched desk pop-out while the button is down, or, without
///   notifications, at a press in the top 52 pt of a matched pop-out (the frontmost window there) whose bounds then
///   move with the pointer at the same size (a resize from an edge is no drag).
/// - **The pre-drag frame** is the window's bounds at the last observation with the button up (the 1 Hz pass,
///   notifications, after a release); a press read while the pointer had not moved yet is such an observation too.
/// - **Armed** once the pointer has been inside the block's region for `armDelay` with the button down, drag-to-park
///   allowed, the window still following the pointer, and the claim granted (a refused claim never arms: the guard
///   would slide the window back while the block minimized it). Leaving the region, or the conditions failing, disarms
///   at once.
/// - **Released while armed:** the claims learn the mouse-up, and the park starts `parkDelay` later; parked, the claim is
///   released as parked and the session goes to the target bucket; failed, the claim is released unparked at once and
///   the label shows the reason for 3 s. **Released unarmed:** nothing new (the guard slides the window back).
/// - A lost mouse-up ends a drag through the poll (`buttonDown` false), as the guard's own poll does.
struct PopOutDragTracker {
    /// The title-bar band a fallback drag starts in.
    static let titleBand: CGFloat = 52
    static let armDelay = CodeTuning.dropArmDelay
    /// From the mouse-up to the park call.
    static let parkDelay: TimeInterval = 0.05
    /// The window moved this far: a press became a drag (or something else).
    static let moveThreshold: CGFloat = 2
    /// At the press, the window must follow the pointer within this (the two reads are a few milliseconds apart).
    static let followAtPress: CGFloat = 12
    /// When arming, the pointer must still hold the window where it grabbed it, within this (an app-driven drag lags).
    static let followAtArm: CGFloat = 32
    /// The pointer moved this far while the window stayed: the press was no window drag.
    static let pressGiveUp: CGFloat = 40

    struct Press: Equatable {
        var popout: CodeDropPopout
        /// The pointer and the bounds read together when the press was handled.
        var pointer: CGPoint
        var bounds: CGRect
        var preDragFrame: CGRect
    }

    /// The label as last shown.
    struct Label: Equatable {
        var text: String
        var at: CGPoint
    }

    struct Drag: Equatable {
        var popout: CodeDropPopout
        var preDragFrame: CGRect
        /// Pointer minus window origin when the drag was seen to start, and the window's size then.
        var grab: CGPoint
        var size: CGSize
        var insideSince: TimeInterval?
        var armed = false
        var target: CodeDropTarget?
        var slot: CodeDropTarget?
        var label: Label?
        var refusalLogged = false
        var lastPointer: CGPoint
    }

    struct Park: Equatable {
        var popout: CodeDropPopout
        var restoreFrame: CGRect
        var target: CodeDropTarget?
        var dropPoint: CGPoint
        var parkAt: TimeInterval
        var requested = false
    }

    private(set) var popouts: [UInt32: CodeDropPopout] = [:]
    private(set) var claimable: Set<pid_t> = []
    /// Window bounds at the last observation with the button up, by window number.
    private(set) var restFrames: [UInt32: CGRect] = [:]
    private(set) var press: Press?
    private(set) var drag: Drag?
    private(set) var parks: [Park] = []

    /// The window the poll must read: the pressed or dragged one.
    var watchedWindow: UInt32? { drag?.popout.windowNumber ?? press?.popout.windowNumber }
    /// The 30 Hz poll runs while a press or a drag is in progress, or a park waits for its delay.
    var needsPolling: Bool { press != nil || drag != nil || parks.contains { !$0.requested } }
    /// Whether `windowNumber` is a matched desk pop-out of a claimable copy.
    func isCandidate(_ windowNumber: UInt32) -> Bool {
        popouts[windowNumber].map { claimable.contains($0.pid) } ?? false
    }

    /// A park of this window is waiting for its delay or for the parker's answer: it cannot be grabbed again until then,
    /// or the first park's answer would release the new drag's claim.
    func parkInFlight(_ windowNumber: UInt32) -> Bool {
        parks.contains { $0.popout.windowNumber == windowNumber }
    }

    // MARK: Inputs

    /// The matched desk pop-outs and the claimable processes (the 1 Hz pass). A dragged or pressed window that is no
    /// longer one of them ends its drag (disarming it).
    mutating func update(popouts list: [CodeDropPopout], claimable pids: Set<pid_t>) -> [DragToParkEffect] {
        popouts = Dictionary(list.map { ($0.windowNumber, $0) }, uniquingKeysWith: { first, _ in first })
        claimable = pids
        restFrames = restFrames.filter { popouts[$0.key] != nil }
        if let number = press?.popout.windowNumber, !isCandidate(number) { press = nil }
        if let number = drag?.popout.windowNumber, !isCandidate(number) { return endDrag() }
        return []
    }

    /// The window's bounds seen with the button up and no drag of it running: its frame at rest.
    mutating func observe(windowNumber: UInt32, bounds: CGRect, buttonDown: Bool) {
        guard !buttonDown, popouts[windowNumber] != nil, watchedWindow != windowNumber else { return }
        restFrames[windowNumber] = bounds
    }

    /// A move notification for a window (the observer). With the button down, a matched pop-out starts a drag.
    mutating func moved(windowNumber: UInt32, bounds: CGRect, buttonDown: Bool, pointer: CGPoint, now: TimeInterval) {
        guard buttonDown else {
            observe(windowNumber: windowNumber, bounds: bounds, buttonDown: false)
            return
        }
        guard drag == nil, isCandidate(windowNumber), !parkInFlight(windowNumber), let popout = popouts[windowNumber] else {
            return
        }
        let pressed = press.flatMap { $0.popout.windowNumber == windowNumber ? $0 : nil }
        let frame = pressed?.preDragFrame ?? restFrames[windowNumber] ?? bounds
        press = nil
        startDrag(popout, preDragFrame: frame, bounds: bounds, pointer: pointer)
    }

    /// A left press (the mouse-down monitors): `point` where it happened, `front` the frontmost window there, `pointer`
    /// and `front.bounds` read when it was handled (all Quartz).
    mutating func pressed(at point: CGPoint, front: (windowNumber: UInt32, bounds: CGRect)?, pointer: CGPoint) {
        press = nil
        guard drag == nil, let front, isCandidate(front.windowNumber), !parkInFlight(front.windowNumber),
              let popout = popouts[front.windowNumber] else { return }
        let band = CGRect(x: front.bounds.minX, y: front.bounds.minY, width: front.bounds.width,
                          height: min(Self.titleBand, front.bounds.height))
        guard band.contains(point) else { return }
        // Until the pointer moves, nothing has moved the window: the bounds read now are from before the drag.
        let unmoved = abs(pointer.x - point.x) <= 1 && abs(pointer.y - point.y) <= 1
        let frame = unmoved ? front.bounds : (restFrames[front.windowNumber] ?? front.bounds)
        press = Press(popout: popout, pointer: pointer, bounds: front.bounds, preDragFrame: frame)
    }

    /// The left button went up (the mouse-up monitors; the poll finds a lost one).
    mutating func released(now: TimeInterval, pointer: CGPoint) -> [DragToParkEffect] {
        press = nil
        guard let drag else { return [] }
        self.drag = nil
        guard drag.armed else { return [.observeSoon(windowNumber: drag.popout.windowNumber)] }
        parks.append(Park(popout: drag.popout, restoreFrame: drag.preDragFrame, target: drag.target, dropPoint: pointer,
                          parkAt: now + Self.parkDelay))
        return [.noteMouseUp, .hideLabel, .hideSlot, .log("drop released session=#\(drag.popout.index)")]
    }

    /// One poll: parks due after their delay, a lost mouse-up, a press turning into a drag, arming and disarming.
    mutating func tick(_ input: DragToParkTick, claim: (pid_t, UInt32) -> Bool,
                       ownBucket: (String) -> CodeDropTarget?) -> [DragToParkEffect] {
        var effects: [DragToParkEffect] = []
        for index in parks.indices where !parks[index].requested && input.now >= parks[index].parkAt {
            parks[index].requested = true
            effects.append(.park(sessionID: parks[index].popout.sessionID, windowNumber: parks[index].popout.windowNumber,
                                 restoreFrame: parks[index].restoreFrame))
        }
        guard input.buttonDown else { return effects + released(now: input.now, pointer: input.pointer) }
        if let press, drag == nil { advance(press, input) }
        if drag != nil { effects += follow(input, claim: claim, ownBucket: ownBucket) }
        return effects
    }

    /// The window side answered a park.
    mutating func parkFinished(windowNumber: UInt32, result: CodeDropParkResult) -> [DragToParkEffect] {
        guard let index = parks.firstIndex(where: { $0.popout.windowNumber == windowNumber && $0.requested }) else {
            return []
        }
        let park = parks.remove(at: index)
        let popout = park.popout
        // Never release a claim a new armed drag of the same window holds (belt and braces).
        let regrabbed = drag?.armed == true && drag?.popout.windowNumber == windowNumber
        switch result {
        case .parked:
            var effects: [DragToParkEffect] = regrabbed ? []
                : [.releaseClaim(pid: popout.pid, windowNumber: popout.windowNumber, parked: true)]
            if let target = park.target { effects.append(.moveToBucket(sessionID: popout.sessionID, target: target)) }
            effects.append(.log("drop parked session=#\(popout.index)"))
            return effects
        case .failed(let reason):
            let release: [DragToParkEffect] = regrabbed ? []
                : [.releaseClaim(pid: popout.pid, windowNumber: popout.windowNumber, parked: false)]
            return release + [.showFailure(text: reason, at: park.dropPoint),
                              .log("drop park failed session=#\(popout.index)"),
                              .observeSoon(windowNumber: popout.windowNumber)]
        }
    }

    /// Ends everything at once (quit): a drag is disarmed; parks in flight keep their claims until they answer.
    mutating func cancelDrag() -> [DragToParkEffect] {
        press = nil
        return endDrag()
    }

    // MARK: Steps

    private mutating func startDrag(_ popout: CodeDropPopout, preDragFrame: CGRect, bounds: CGRect, pointer: CGPoint) {
        drag = Drag(popout: popout, preDragFrame: preDragFrame,
                    grab: CGPoint(x: pointer.x - bounds.minX, y: pointer.y - bounds.minY), size: bounds.size,
                    lastPointer: pointer)
    }

    /// A press becomes a drag once the window moves with the pointer at its size; it ends when the window changes some
    /// other way, or the pointer goes far while the window stays.
    private mutating func advance(_ press: Press, _ input: DragToParkTick) {
        guard let bounds = input.windowBounds else {
            self.press = nil
            return
        }
        let window = CGPoint(x: bounds.minX - press.bounds.minX, y: bounds.minY - press.bounds.minY)
        let pointer = CGPoint(x: input.pointer.x - press.pointer.x, y: input.pointer.y - press.pointer.y)
        if max(abs(window.x), abs(window.y)) >= Self.moveThreshold {
            let follows = abs(window.x - pointer.x) <= Self.followAtPress && abs(window.y - pointer.y) <= Self.followAtPress
            let sameSize = abs(bounds.width - press.bounds.width) <= 1 && abs(bounds.height - press.bounds.height) <= 1
            self.press = nil
            if follows, sameSize {
                drag = Drag(popout: press.popout, preDragFrame: press.preDragFrame,
                            grab: CGPoint(x: press.pointer.x - press.bounds.minX, y: press.pointer.y - press.bounds.minY),
                            size: press.bounds.size, lastPointer: input.pointer)
            }
        } else if max(abs(pointer.x), abs(pointer.y)) > Self.pressGiveUp {
            self.press = nil
        }
    }

    private mutating func follow(_ input: DragToParkTick, claim: (pid_t, UInt32) -> Bool,
                                 ownBucket: (String) -> CodeDropTarget?) -> [DragToParkEffect] {
        guard var drag, isCandidate(drag.popout.windowNumber) else { return endDrag() }
        var effects: [DragToParkEffect] = []
        drag.lastPointer = input.pointer
        let inside = input.allowsArming && input.strips.contains { $0.contains(input.pointer) }
        if inside {
            let since = drag.insideSince ?? input.now
            drag.insideSince = since
            let target = input.bucketUnderPointer ?? ownBucket(drag.popout.sessionID)
            if !drag.armed, input.now - since >= Self.armDelay {
                if Self.holds(drag, input), claim(drag.popout.pid, drag.popout.windowNumber) {
                    drag.armed = true
                    effects.append(.log("drop armed session=#\(drag.popout.index)"))
                } else if !drag.refusalLogged, Self.holds(drag, input) {
                    drag.refusalLogged = true
                    effects.append(.log("drop claim refused session=#\(drag.popout.index)"))
                }
            }
            if drag.armed {
                drag.target = target
                let text = CodeDropTarget.labelText(target)
                let shown = Label(text: text, at: input.pointer)
                if drag.label != shown {
                    drag.label = shown
                    effects.append(.showLabel(text: text, at: input.pointer))
                }
                if drag.slot != input.bucketUnderPointer {
                    drag.slot = input.bucketUnderPointer
                    effects.append(drag.slot.map { .showSlot(CodeDropSlot(sessionID: drag.popout.sessionID, target: $0)) }
                                   ?? .hideSlot)
                }
            }
        } else {
            drag.insideSince = nil
            if drag.armed { effects += disarm(&drag) }
        }
        self.drag = drag
        return effects
    }

    /// The pointer still holds the window where it grabbed it, at its size (no resize, no window moved by its app).
    private static func holds(_ drag: Drag, _ input: DragToParkTick) -> Bool {
        guard let bounds = input.windowBounds else { return false }
        let grab = CGPoint(x: input.pointer.x - bounds.minX, y: input.pointer.y - bounds.minY)
        return abs(grab.x - drag.grab.x) <= followAtArm && abs(grab.y - drag.grab.y) <= followAtArm
            && abs(bounds.width - drag.size.width) <= 1 && abs(bounds.height - drag.size.height) <= 1
    }

    private func disarm(_ drag: inout Drag) -> [DragToParkEffect] {
        drag.armed = false
        drag.target = nil
        drag.slot = nil
        drag.label = nil
        return [.releaseClaim(pid: drag.popout.pid, windowNumber: drag.popout.windowNumber, parked: false), .hideLabel,
                .hideSlot, .log("drop disarmed session=#\(drag.popout.index)")]
    }

    private mutating func endDrag() -> [DragToParkEffect] {
        guard var drag else { return [] }
        self.drag = nil
        return drag.armed ? disarm(&drag) : []
    }
}
