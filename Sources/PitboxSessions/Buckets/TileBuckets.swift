import AppKit
import PitboxKit

/// The block's buckets: one header and one body per bucket in the scrolling area, the colour menu, Delete's question,
/// the name field, "Show monitor", and the drop targets drag-to-park uses.
extension CodeMonitorsTileView {
    // MARK: Bodies and headers

    /// A bucket's body (made the first time a bucket shows).
    func folderView(for id: String) -> CodeMonitorFolderView {
        if id == CodeBucket.unsortedID { return folder }
        if let body = otherFolders[id] { return body }
        let body = CodeMonitorFolderView(frame: .zero)
        body.reduceMotion = folder.reduceMotion
        wire(body, bucketID: id)
        content.addSubview(body, positioned: .below, relativeTo: dropOutline)
        otherFolders[id] = body
        return body
    }

    /// Places every bucket's header and body where `placedBuckets` says (scrolled), and drops the views of buckets that
    /// went. With Unsorted alone (`flat`) its body stands alone and monitors are not dragged.
    func layoutBuckets(_ sections: [CodeBucketSection], flat: Bool, column: CGFloat) {
        var live: Set<String> = []
        for (section, placed) in zip(sections, placedBuckets) {
            live.insert(section.id)
            let body = folderView(for: section.id)
            if flat, body.onMonitorDrag != nil { body.onMonitorDrag = nil }
            if !flat, body.onMonitorDrag == nil {
                body.onMonitorDrag = { [weak self] view, phase, event in self?.monitorDragged(view, phase, event) }
            }
            if let rect = placed.body {
                body.isHidden = false
                body.frame = scrolledStackFrame(rect)
                let page = model.page(of: section.id)
                body.update(items: section.monitors, showsProfiles: snapshot.showsProfiles, stripColumn: column, look: snapshot.look,
                            emptyHint: !flat, page: page)
                if body.page != page { model.setPage(body.page, of: section.id) }
            } else {
                body.isHidden = true
                body.update(items: [], showsProfiles: snapshot.showsProfiles, stripColumn: column, look: snapshot.look)
            }
            if let rect = placed.header {
                let header = bucketHeaders[section.id] ?? makeHeader(section)
                header.frame = scrolledStackFrame(rect)
                header.update(section: section, confirmingDelete: confirmingDelete == section.id,
                              renaming: renaming?.bucketID == section.id)
                if let renaming, renaming.bucketID == section.id { renaming.field.frame = header.nameFrame }
            } else if let header = bucketHeaders.removeValue(forKey: section.id) {
                header.removeFromSuperview()
            }
        }
        for (id, body) in otherFolders where !live.contains(id) {
            body.removeFromSuperview()
            otherFolders[id] = nil
        }
        for (id, header) in bucketHeaders where !live.contains(id) {
            header.removeFromSuperview()
            bucketHeaders[id] = nil
        }
    }

    private func makeHeader(_ section: CodeBucketSection) -> CodeBucketHeaderView {
        let header = CodeBucketHeaderView(section: section, frame: CGRect(x: 0, y: 0, width: content.bounds.width,
                                                                         height: CodeBucketHeaderView.height))
        header.onPart = { [weak self] header, part in self?.headerPart(header.section.id, part, header: header) }
        header.onRename = { [weak self] header in self?.beginRename(header.section.id, isNew: false) }
        content.addSubview(header, positioned: .below, relativeTo: dropOutline)
        bucketHeaders[section.id] = header
        return header
    }

    /// The outline around the bucket a drop would move to: the drag's, or one drag-to-park names
    /// (`externalDropTarget`).
    func placeDropOutline() {
        guard let target = drag?.highlighted ?? externalDropTarget,
              let placed = placedBuckets.first(where: { $0.id == target }) else {
            dropOutline.isHidden = true
            return
        }
        dropOutline.frame = scrolledStackFrame(placed.area).insetBy(dx: 0, dy: -4)
        dropOutline.isHidden = false
        dropOutline.needsDisplay = true
    }

    // MARK: Drop targets (a monitor drag, and drag-to-park's window drop over a bucket)

    /// The bucket whose header or body is under `point` (the scrolling area's coordinates), nil elsewhere (the gaps
    /// between buckets, the Ready list, outside the visible part).
    func bucket(atContentPoint point: CGPoint) -> String? {
        guard content.bounds.contains(point), !content.isHidden else { return nil }
        let inStack = CGPoint(x: point.x, y: point.y + scrollOffset)
        return placedBuckets.first { $0.area.contains(inStack) }?.id
    }

    /// The bucket under a point in the window's coordinates (drag-to-park: "Drop to park in <bucket>").
    func bucket(atWindowPoint point: CGPoint) -> String? { bucket(atContentPoint: content.convert(point, from: nil)) }

    // MARK: Header parts

    func headerPart(_ id: String, _ part: CodeBucketHeaderView.Part, header: CodeBucketHeaderView) {
        switch part {
        case .color:
            showColorMenu(for: id, from: header)
        case .name:
            beginRename(id, isNew: false)
        case .fold:
            model.toggleFolded(id)
        case .delete:
            if renaming?.bucketID == id { finishRename(commit: true) }
            confirmingDelete = id
            layoutContent()
        case .keep:
            confirmingDelete = nil
            layoutContent()
        case .confirmDelete:
            confirmingDelete = nil
            if renaming?.bucketID == id { finishRename(commit: false) }
            model.deleteBucket(id)
        }
    }

    /// The menu of the 8 named colours, the current one ticked.
    func colorMenu(for bucket: CodeBucket) -> NSMenu {
        let dark = ThemeColor.isDark(effectiveAppearance)
        let menu = NSMenu(title: "Colour")
        menu.autoenablesItems = false
        for color in CodeBucketColor.allCases {
            let item = NSMenuItem(title: color.title, action: #selector(colorChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = CodeBucketColorChoice(bucketID: bucket.id, color: color)
            item.state = color == bucket.color ? .on : .off
            item.image = Self.swatch(color.color(dark: dark))
            menu.addItem(item)
        }
        return menu
    }

    func showColorMenu(for id: String, from header: CodeBucketHeaderView) {
        guard let bucket = snapshot.sections.first(where: { $0.id == id })?.bucket else { return }
        let square = header.layoutInfo.swatch
        menuPresenter(colorMenu(for: bucket), header, CGPoint(x: square.minX, y: square.maxY + 4))
    }

    @objc func colorChosen(_ item: NSMenuItem) {
        guard let choice = item.representedObject as? CodeBucketColorChoice else { return }
        model.setBucketColor(choice.bucketID, choice.color)
    }

    private static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: CGSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3).fill()
            return true
        }
    }

    // MARK: + New bucket and the name field

    /// "+ New bucket": the bucket appears at the end and its name opens for typing at once, its text selected.
    func startNewBucket() {
        endTransientBucketUI()
        guard let id = model.createBucket() else { return }
        beginRename(id, isNew: true)
    }

    /// Opens the name field over a bucket's name (never Unsorted's) and asks the block for the keyboard.
    func beginRename(_ id: String, isNew: Bool) {
        guard snapshot.bucketMode, let header = bucketHeaders[id],
              let section = snapshot.sections.first(where: { $0.id == id }), !section.bucket.isUnsorted else { return }
        if let renaming {
            if renaming.bucketID == id { return }
            finishRename(commit: true)
        }
        confirmingDelete = nil
        let field = CodeBucketNameField(name: section.bucket.name, dark: ThemeColor.isDark(effectiveAppearance))
        field.onFinish = { [weak self] commit in self?.finishRename(commit: commit) }
        renaming = (id, isNew, field)
        header.update(section: section, confirmingDelete: false, renaming: true)
        field.frame = header.nameFrame
        header.addSubview(field)
        if let placed = placedBuckets.first(where: { $0.id == id }) { scrollIntoView(placed.area) }
        model.keyboardRequester?(true)
        // The field starts editing with its text selected (`selectText(_:)` would end that editing session again).
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        // A click elsewhere keeps what was typed; so does the block losing the keyboard (a click in another app).
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.renameSawClick(event) }
            return event
        }) {
            renameCleanup.append { NSEvent.removeMonitor(monitor) }
        }
        if let window {
            let token = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window,
                                                               queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finishRename(commit: true) }
            }
            renameCleanup.append { NotificationCenter.default.removeObserver(token) }
        }
    }

    /// A mouse press while the field is open: anywhere but the field keeps the name and closes it.
    func renameSawClick(_ event: NSEvent) {
        guard let field = renaming?.field else { return }
        let sameWindow = event.window.map { $0 === field.window } ?? (event.windowNumber == field.window?.windowNumber)
        if sameWindow, field.bounds.contains(field.convert(event.locationInWindow, from: nil)) { return }
        finishRename(commit: true)
    }

    /// Closes the name field: `commit` keeps what was typed (trimmed; empty keeps the old name, and a new bucket stays
    /// "New bucket"); otherwise an old name stays and a bucket just made goes again. Hands the keyboard back.
    func finishRename(commit: Bool) {
        guard let state = renaming else { return }
        renaming = nil
        for undo in renameCleanup { undo() }
        renameCleanup = []
        let text = state.field.stringValue
        state.field.onFinish = nil
        if let editor = state.field.currentEditor(), window?.firstResponder === editor { window?.makeFirstResponder(nil) }
        state.field.removeFromSuperview()
        if commit {
            model.renameBucket(state.bucketID, to: text)
        } else if state.isNew {
            model.discardNewBucket(state.bucketID)
        }
        model.keyboardRequester?(false)
        layoutContent()
    }

    /// Ends what only lives while the user looks: a rename keeps its text, Delete's question goes, a drag is cancelled
    /// (block hidden or folded, a new bucket).
    func endTransientBucketUI() {
        finishRename(commit: true)
        confirmingDelete = nil
        cancelDrag()
    }

    // MARK: Show monitor

    /// Turns the session's bucket to its page and scrolls it into view.
    func reveal(sessionID: String) {
        guard let section = snapshot.sections.first(where: { $0.monitors.contains { $0.id == sessionID } }) else { return }
        let body = folderView(for: section.id)
        body.reveal(sessionID)
        guard let view = body.monitorView(sessionID) else { return }
        scrollIntoView(content.convert(view.bounds, from: view).offsetBy(dx: 0, dy: scrollOffset))
    }

    /// Scrolls the least that brings `rect` (the stack's coordinates) into the visible part.
    func scrollIntoView(_ rect: CGRect) {
        let visible = content.bounds.height
        if rect.minY < scrollOffset {
            scroll(to: rect.minY - 8)
        } else if rect.maxY > scrollOffset + visible {
            scroll(to: min(rect.minY - 8, rect.maxY - visible + 8))
        }
    }
}

/// What a colour menu item stands for.
struct CodeBucketColorChoice: Equatable {
    var bucketID: String
    var color: CodeBucketColor
}
