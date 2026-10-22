import Foundation

/// What the user does with buckets, through the block model: each changes `code-buckets.json` and rebuilds the
/// snapshot. None touches a window, a session or a file other than the buckets file
/// (no parker call: a monitor's window stays where it is). Log lines carry counts and session numbers only, never a
/// bucket name.
extension CodeMonitorsModel {
    /// "+ New bucket": "New bucket" at the end; nil at 20 buckets. The block opens its name for typing at once.
    @discardableResult
    func createBucket() -> String? {
        guard let bucket = buckets.create() else { return nil }
        CodeTileLog.info("bucket created buckets=\(buckets.buckets.count)")
        rebuild()
        return bucket.id
    }

    /// Escape on a bucket just made: no name, no bucket.
    func discardNewBucket(_ id: String) {
        guard buckets.delete(id) != nil else { return }
        CodeTileLog.info("bucket discarded buckets=\(buckets.buckets.count)")
        rebuild()
    }

    /// A new name; false (the old name stays) when it is empty after trimming, or for Unsorted.
    @discardableResult
    func renameBucket(_ id: String, to text: String) -> Bool {
        let before = buckets.bucket(id)?.name
        guard buckets.rename(id, to: text) else { return false }
        if buckets.bucket(id)?.name != before { CodeTileLog.info("bucket renamed") }
        rebuild()
        return true
    }

    func setBucketColor(_ id: String, _ color: CodeBucketColor) {
        guard let bucket = buckets.bucket(id), bucket.color != color else { return }
        buckets.setColor(id, color)
        CodeTileLog.info("bucket colour changed color=\(color.rawValue)")
        rebuild()
    }

    /// ▾ / ▸: folds a bucket to its header (the badges stay), or opens it. Remembered.
    func toggleFolded(_ id: String) {
        guard let bucket = buckets.bucket(id) else { return }
        buckets.setFolded(id, !bucket.folded)
        CodeTileLog.info("bucket \(bucket.folded ? "opened" : "folded")")
        rebuild()
    }

    /// Delete (after "Delete “…”? … [Keep] [Delete]"): its sessions move to Unsorted and the bucket goes. Unsorted
    /// cannot be deleted.
    func deleteBucket(_ id: String) {
        guard let moved = buckets.delete(id) else { return }
        pages[id] = nil
        CodeTileLog.info("bucket deleted moved=\(moved) buckets=\(buckets.buckets.count)")
        rebuild()
    }

    /// Moves a session to another bucket, where its first-seen time gives its place: a drop on a bucket
    /// (and drag-to-park over one). False when it already sits there or the bucket is unknown.
    @discardableResult
    func moveSession(_ sessionID: String, toBucket bucketID: String) -> Bool {
        guard buckets.move(sessionID, to: bucketID, now: now()) else { return false }
        let index = source.sessions.first { $0.id == sessionID }?.index
        CodeTileLog.info("monitor moved to another bucket session=#\(index.map(String.init) ?? "?")")
        rebuild()
        return true
    }

    /// The bucket a session sits in (Unsorted when unknown).
    func bucketID(of sessionID: String) -> String { buckets.bucketID(of: sessionID) }

    // MARK: Pages

    /// The page shown in a bucket (views clamp it to the pages there are).
    func page(of bucketID: String) -> Int { pages[bucketID] ?? 0 }

    /// Remembers a bucket's page while the app runs (not stored). No rebuild: the view that turned it shows it.
    func setPage(_ page: Int, of bucketID: String) {
        pages[bucketID] = max(0, page)
    }

    /// "Show monitor" (in the Ready list): unfolds the session's bucket, and every view turns to its page and
    /// scrolls it into view.
    func revealMonitor(_ sessionID: String) {
        let bucket = buckets.bucketID(of: sessionID)
        if buckets.bucket(bucket)?.folded == true { buckets.setFolded(bucket, false) }
        revealRequest = (sessionID, (revealRequest?.serial ?? 0) + 1)
        rebuild()
        notify()
    }
}
