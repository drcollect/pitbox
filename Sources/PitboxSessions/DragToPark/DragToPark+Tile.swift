import AppKit

/// Drag-to-park on the Code monitors block, through the drop targets the block offers: the bucket under the pointer
/// (`CodeMonitorsTileView.bucket(atWindowPoint:)`), its 2 pt outline while a drop is armed over it
/// (`externalDropTarget`), the session's own bucket (`CodeMonitorsModel.bucketID(of:)`) and the move after the park
/// (`moveSession(_:toBucket:)`). Uses those only; nothing of Tile/ or Buckets/ is changed.
extension CodeDragToPark {
    /// Makes a root view this drop's target (`PitboxBlock.makeView()`; the latest view wins, held weakly):
    /// - over a bucket of the visible block, that bucket is the target and gets the drop outline;
    /// - elsewhere in the block the target is the session's own bucket, without an outline;
    /// - with Unsorted alone (the block's plain look, no bucket headers) the label says "Drop to park" alone and
    ///   nothing is outlined or moved;
    /// - parked, the session moves to the target bucket at its first-seen place.
    func attach(tile view: CodeMonitorsTileView) {
        bucketUnderPointer = { [weak view] point in view.flatMap { CodeDropTile.target(in: $0, atScreenPoint: point) } }
        ownBucket = { [weak view] sessionID in view.flatMap { CodeDropTile.ownTarget(in: $0, of: sessionID) } }
        onSlotChange = { [weak view] slot in view?.externalDropTarget = slot?.target.bucketID }
        // A session already in that bucket stays where it is (`moveSession` answers false).
        onParked = { [weak view] sessionID, target in view?.model.moveSession(sessionID, toBucket: target.bucketID) }
    }
}

/// The block's buckets as drop targets.
@MainActor
enum CodeDropTile {
    /// The bucket of the visible block under an AppKit screen point, by id and name; nil when the block is not visible,
    /// shows no buckets (Unsorted alone), or the point is not on a bucket's header or body (gaps, the Ready list,
    /// outside the visible part).
    static func target(in view: CodeMonitorsTileView, atScreenPoint point: CGPoint) -> CodeDropTarget? {
        guard view.reportedVisible, view.model.snapshot.bucketMode, let window = view.window,
              let id = view.bucket(atWindowPoint: window.convertPoint(fromScreen: point)) else { return nil }
        return named(id, in: view)
    }

    /// The bucket the session sits in (Unsorted for one seen first now); nil with Unsorted alone.
    static func ownTarget(in view: CodeMonitorsTileView, of sessionID: String) -> CodeDropTarget? {
        guard view.model.snapshot.bucketMode else { return nil }
        return named(view.model.bucketID(of: sessionID), in: view)
    }

    private static func named(_ id: String, in view: CodeMonitorsTileView) -> CodeDropTarget? {
        view.model.buckets.bucket(id).map { CodeDropTarget(bucketID: $0.id, bucketName: $0.name) }
    }
}
