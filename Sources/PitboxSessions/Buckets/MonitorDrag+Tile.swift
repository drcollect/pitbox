import AppKit
import PitboxKit

/// The block's side of a monitor drag (`CodeMonitorDrag`): the dimmed monitor, the card under the
/// pointer, the drop outline, Escape, scrolling at the area's edges, and the drop itself.
extension CodeMonitorsTileView {
    /// Escape's key code.
    static let escapeKey: UInt16 = 53
    /// The pointer this close to the visible part's top or bottom edge scrolls it during a drag.
    static let dragEdge: CGFloat = 28
    static let dragScrollStep: CGFloat = 14

    func monitorDragged(_ view: CodeMonitorView, _ phase: CodeMonitorView.DragPhase, _ event: NSEvent) {
        switch phase {
        case .began: beginDrag(view, event)
        case .moved: moveDrag(event)
        case .ended: endDrag(event)
        }
    }

    private func beginDrag(_ view: CodeMonitorView, _ event: NSEvent) {
        guard snapshot.bucketMode, drag == nil else {
            view.cancelPress()
            return
        }
        closePeek()
        finishRename(commit: true)
        confirmingDelete = nil
        let id = view.item.id
        var next = CodeMonitorDrag(sessionID: id, fromBucket: model.bucketID(of: id))
        view.dimmed = true
        let card = CodeMonitorDragCard(headline: view.item.headline)
        card.isHidden = true
        addSubview(card, positioned: .above, relativeTo: nil)
        dragCard = card
        // Escape cancels. The block takes the keyboard for the drag, so the key never reaches the app behind it
        // (Escape in a Claude session would interrupt it); it is handed back at the end.
        if let requester = model.keyboardRequester {
            requester(true)
            next.tookKeyboard = true
        }
        dragKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let key = event.keyCode
            let used = MainActor.assumeIsolated { self?.escapeDuringDrag(keyCode: key) ?? false }
            return used ? nil : event
        }
        drag = next
        CodeTileLog.info("monitor drag started session=#\(view.item.index)")
        moveDrag(event)
    }

    private func moveDrag(_ event: NSEvent) {
        guard var current = drag else { return }
        current.outsideStrip = Self.isOutsideStrip(event, window: window)
        let inContent = content.convert(event.locationInWindow, from: nil)
        current.over = current.outsideStrip ? nil : bucket(atContentPoint: inContent)
        drag = current
        let point = convert(event.locationInWindow, from: nil)
        if let card = dragCard {
            card.isHidden = !bounds.contains(point)
            let size = CodeMonitorDragCard.size
            card.frame = CGRect(x: min(point.x + 12, bounds.maxX - size.width), y: min(point.y + 10, bounds.maxY - size.height),
                                width: size.width, height: size.height)
        }
        // At the visible part's edges the area scrolls a step per move.
        if !current.outsideStrip, inContent.x >= 0, inContent.x <= content.bounds.width {
            if inContent.y < Self.dragEdge, scrollOffset > 0 {
                scrollDuringDrag(to: scrollOffset - Self.dragScrollStep)
            } else if inContent.y > content.bounds.height - Self.dragEdge, scrollOffset < maxScrollOffset {
                scrollDuringDrag(to: scrollOffset + Self.dragScrollStep)
            }
        }
        placeDropOutline()
    }

    private func scrollDuringDrag(to offset: CGFloat) {
        scroll(to: offset)
        if var current = drag, !current.outsideStrip, let window {
            let pointer = window.mouseLocationOutsideOfEventStream
            current.over = bucket(atContentPoint: content.convert(pointer, from: nil))
            drag = current
        }
    }

    private func endDrag(_ event: NSEvent) {
        moveDrag(event)
        guard let finished = drag else { return }
        cleanUpDrag()
        let index = snapshot.monitors.first { $0.id == finished.sessionID }?.index ?? 0
        switch finished.drop {
        case .move(let bucket):
            CodeTileLog.info("monitor drag dropped session=#\(index) on=bucket")
            if model.moveSession(finished.sessionID, toBucket: bucket) { reveal(sessionID: finished.sessionID) }
        case .click:
            CodeTileLog.info("monitor drag dropped session=#\(index) on=outside")
            model.clickScreen(finished.sessionID)
        case .nothing:
            CodeTileLog.info("monitor drag dropped session=#\(index) on=nothing")
        }
    }

    /// A key during a drag (what the local monitor does with it): Escape cancels the drag and is used up (nil); other
    /// keys go on.
    func dragKeyDown(_ event: NSEvent) -> NSEvent? {
        escapeDuringDrag(keyCode: event.keyCode) ? nil : event
    }

    /// Escape during a drag cancels it; true when the key was used.
    func escapeDuringDrag(keyCode: UInt16) -> Bool {
        guard drag != nil, keyCode == Self.escapeKey else { return false }
        cancelDrag()
        return true
    }

    /// Ends a drag as a cancel (Escape, the block hiding or folding, the session going away): nothing
    /// moves, nothing is clicked.
    func cancelDrag() {
        guard let current = drag else { return }
        monitorView(current.sessionID)?.cancelPress()
        cleanUpDrag()
        CodeTileLog.info("monitor drag cancelled")
    }

    private func cleanUpDrag() {
        let finished = drag
        drag = nil
        if let monitor = dragKeyMonitor { NSEvent.removeMonitor(monitor) }
        dragKeyMonitor = nil
        dragCard?.removeFromSuperview()
        dragCard = nil
        for view in allMonitorViews where view.dimmed { view.dimmed = false }
        if finished?.tookKeyboard == true { model.keyboardRequester?(false) }
        placeDropOutline()
    }

    /// The pointer left the block: outside the window's content (the block panel's frame in production).
    static func isOutsideStrip(_ event: NSEvent, window: NSWindow?) -> Bool {
        guard let window, let root = window.contentView else { return true }
        return !root.bounds.contains(root.convert(event.locationInWindow, from: nil))
    }
}
