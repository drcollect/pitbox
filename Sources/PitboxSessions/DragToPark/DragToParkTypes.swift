import CoreGraphics
import Foundation
import PitboxKit

// Drag-to-park's shared words: which pop-outs can be dropped, where a drop goes, what the block shows, and what the
// window side must offer. The app's own words and numbers only; no session text.

/// A Claude pop-out on the desk that a drop can park: matched by the window join, on screen, with no operation in
/// flight, in a running readable copy.
public struct CodeDropPopout: Equatable, Sendable {
    /// `local_<id>`. Never logged.
    public var sessionID: String
    /// The session's local index (`session=#3` in logs).
    public var index: Int
    public var pid: pid_t
    /// The window server's number (claims and bounds go by it).
    public var windowNumber: UInt32

    /// A pop-out by its session, process and window number.
    public init(sessionID: String, index: Int, pid: pid_t, windowNumber: UInt32) {
        self.sessionID = sessionID; self.index = index; self.pid = pid; self.windowNumber = windowNumber
    }

    /// The desk pop-outs from the window join (`CodeWindowParking.deskWindows`: session id → pid and window number),
    /// with each session's local index from the data side's snapshots for log lines. A session the data side no longer
    /// lists is left out (it is going away).
    static func desk(_ windows: [String: CodeDeskWindow], sessions: [CodeSessionSnapshot]) -> [CodeDropPopout] {
        let index = Dictionary(sessions.map { ($0.id, $0.index) }, uniquingKeysWith: { first, _ in first })
        return windows.compactMap { id, window in
            index[id].map { CodeDropPopout(sessionID: id, index: $0, pid: window.pid, windowNumber: window.windowNumber) }
        }.sorted { $0.windowNumber < $1.windowNumber }
    }
}

/// Where a drop parks a session: a bucket of the Code monitors block.
public struct CodeDropTarget: Equatable, Sendable {
    /// `unsorted` or `b-` and 6 characters.
    public var bucketID: String
    /// The user's own name for it (1-32 characters, checked by the bucket store); shown in the label.
    public var bucketName: String

    public init(bucketID: String, bucketName: String) {
        self.bucketID = bucketID; self.bucketName = bucketName
    }

    /// The label's words: "Drop to park in <bucket>", or "Drop to park" when no bucket is known.
    static func labelText(_ target: CodeDropTarget?) -> String {
        guard let target, let name = CodePlainText.line(target.bucketName, limit: CodeTuning.bucketNameMax) else {
            return CodeDropWords.dropToPark
        }
        return "\(CodeDropWords.dropToPark) in \(name)"
    }
}

/// The dashed "Drop to park" slot the block shows while a drop is armed over one of its buckets: in that bucket, at
/// the session's stable place, with the bucket's outline.
public struct CodeDropSlot: Equatable, Sendable {
    public var sessionID: String
    public var target: CodeDropTarget

    public init(sessionID: String, target: CodeDropTarget) {
        self.sessionID = sessionID; self.target = target
    }
}

/// How a drop's park ended.
public enum CodeDropParkResult: Equatable, Sendable {
    /// Minimized and confirmed off screen; the record holds the frame from before the drag.
    case parked
    /// The reason in the app's words ("couldn't park (Claude didn't answer)").
    case failed(reason: String)
}

/// When a drop may arm: drag-to-park on and the block shown (not hidden, not folded to the rail). While the
/// block is folded to its rail, drags are still watched (never armed): a pop-out held over the rail unfolds the block
/// for the drop (spring-loaded).
public struct CodeDragToParkConditions: Equatable, Sendable {
    /// The settings file's `dragToPark` ("Drag windows into the block to pit them").
    public var dragToPark: Bool
    public var stripShown: Bool
    /// The block is on screen folded to its rail (its published region is the rail's).
    public var railShown: Bool

    public init(dragToPark: Bool = true, stripShown: Bool = false, railShown: Bool = false) {
        self.dragToPark = dragToPark; self.stripShown = stripShown; self.railShown = railShown
    }

    /// Both hold.
    public var allowsArming: Bool { dragToPark && stripShown }
    /// Drags are noticed and followed: arming is allowed, or the rail shows (to spring-load it, nothing more).
    public var watchesDrags: Bool { dragToPark && (stripShown || railShown) }
    /// A drag over the region drives the rail's spring-loaded unfold.
    var watchesRail: Bool { dragToPark && railShown && !stripShown }
}

/// The park drag-to-park needs from the window side (`Windows/`, `CodeWindowParker`). Which pop-outs are on the desk
/// comes from `CodeWindowParking.deskWindows`. Main thread.
@MainActor
public protocol CodeDropParking: AnyObject {
    /// Parks the session's window as a click does (the record first, `AXMinimized = true`, confirmed off screen
    /// within 1.5 s, one retry), but records `restoreFrame` (Quartz, the window's bounds before the drag) instead of
    /// the frame it has now, so a restore brings it back where it was, not into the block. `done` runs on the main
    /// thread, once.
    func parkDropped(sessionID: String, restoreFrame: CGRect, done: @escaping @MainActor (CodeDropParkResult) -> Void)
}

/// The claims registry as drag-to-park uses it (`WindowDropClaims` in Core; a fake in tests).
protocol CodeDropClaiming: AnyObject, Sendable {
    func setClaimablePIDs(_ pids: Set<pid_t>)
    func claim(pid: pid_t, windowNumber: UInt32) -> Bool
    func noteMouseUp()
    func release(pid: pid_t, windowNumber: UInt32, parked: Bool)
}

extension WindowDropClaims: CodeDropClaiming {}

/// Drag-to-park's words (the app's own).
enum CodeDropWords {
    static let dropToPark = "Drop to pit"
    static let parkFailure = "couldn't pit (Claude didn't answer)"
}
