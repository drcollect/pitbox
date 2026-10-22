import AppKit
import SwiftTerm

/// SwiftTerm's `TerminalView` with what a docked, non-activating terminal needs:
///
/// - **Shortcuts** (`performKeyEquivalent`, which AppKit offers before `keyDown`): new/close/rotate tabs, Cmd-1...9,
///   Cmd-Escape to hand the keyboard back. Everything else, including Cmd-C / Cmd-V / Cmd-A, is left to the hidden Edit
///   menu the Shell installs, which finds the `copy:`, `paste:`, `selectAll:` and `pasteAsPlainText:` actions here.
/// - **Paste** that removes control characters (paste injection) and honors bracketed paste.
/// - **Drag and drop**: dropped files type their escaped paths, dropped text and URLs are pasted.
/// - A click always takes first responder, even in a window that was not key a moment ago.
///
/// `keyDown`, `becomeFirstResponder` and `scrollWheel` are not `open` in SwiftTerm, so they are not overridden; focus is
/// observed from outside (see `ConsoleView`).
final class ConsoleTerminalView: TerminalView {
    /// Shortcut sink. Return true when the shortcut was handled.
    var shortcutHandler: ((TerminalShortcut) -> Bool)?
    /// A drag entered (true) or left (false) the view.
    var onDropTargetChange: ((Bool) -> Void)?
    /// Extra items for the context menu (Restart, ...), asked each time it opens.
    var contextMenuExtras: (() -> [NSMenuItem])?
    /// Where paste reads from. Tests use a private pasteboard.
    var pasteboard: NSPasteboard = .general
    /// The program rang the bell (also when the style is visual or none).
    var onBell: (() -> Void)?

    init(frame: NSRect, font: NSFont, options: TerminalOptions) {
        super.init(frame: frame, font: font, options: options)
        registerForDraggedTypes([.fileURL, .URL, .string])
        // SwiftTerm 1.20 gives macOS accessibility nothing: without this VoiceOver finds only a bare scroller where the
        // terminal is. The terminal is a text area named after its tab (the console sets "Terminal, <title>"). Its text is
        // not exposed: any app with the Accessibility permission could read it then (a decision for the user).
        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
        setAccessibilityRoleDescription("terminal")
        setAccessibilityLabel("Terminal")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Accessibility

    /// SwiftTerm's scroller is not a control VoiceOver can use here (the text is not exposed), so it is left out of the
    /// children and a hit on it answers with the terminal; the find bar (Cmd-F) stays reachable.
    override func accessibilityChildren() -> [Any]? {
        super.accessibilityChildren()?.filter { !($0 is NSScroller) }
    }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        let hit = super.accessibilityHitTest(point)
        return hit is NSScroller ? self : hit
    }

    // MARK: Size

    /// Cell size in points, derived from SwiftTerm's own optimal-frame computation.
    var cellSize: CGSize {
        let cols = max(1, terminal.cols), rows = max(1, terminal.rows)
        let optimal = getOptimalFrameSize()
        let scroller = subviews.first { $0 is NSScroller }
        let scrollerWidth = (scroller?.isHidden ?? true) ? 0 : NSScroller.scrollerWidth(for: .regular, scrollerStyle: scrollerStyle)
        return CGSize(width: max(1, (optimal.width - scrollerWidth) / CGFloat(cols)), height: max(1, optimal.height / CGFloat(rows)))
    }

    /// The size the child process is told: cells and pixels (for programs that draw images).
    var terminalSize: TerminalSize {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let cell = cellSize
        return TerminalSize(cols: terminal.cols, rows: terminal.rows,
                            pixelWidth: Int(cell.width * CGFloat(terminal.cols) * scale),
                            pixelHeight: Int(cell.height * CGFloat(terminal.rows) * scale))
    }

    // MARK: Appearance

    /// Applies colors, font and behavior settings.
    func configure(palette: TerminalPalette, settings: TerminalSettings) {
        apply(palette: palette)
        optionAsMetaKey = settings.optionAsMeta
        bellStyle = settings.bell.swiftTerm
        allowMouseReporting = true
        linkReporting = .implicit
        linkHighlightMode = .hoverWithModifier
        useBrightColors = true
        scrollerStyle = .overlay
    }

    /// Colors only (the appearance changed).
    func apply(palette: TerminalPalette) {
        installColors(palette.ansi.map { Color(nsColor: $0) })
        nativeForegroundColor = palette.foreground
        // The console paints the tint; the terminal's default background is transparent so the glass shows through.
        nativeBackgroundColor = palette.background.withAlphaComponent(0)
        caretColor = palette.foreground
        caretTextColor = palette.background
        selectedTextBackgroundColor = palette.selectionBackground
        selectedTextForegroundColor = palette.selectionForeground
    }

    override func bell(source: Terminal) {
        onBell?()
        super.bell(source: source)
    }

    // MARK: Keyboard

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // AppKit offers a key event to the whole view hierarchy of the key window, not only to the first responder. The
        // shortcuts and the Option word motions must act only when THIS view is where the user is typing: otherwise Cmd-T,
        // Ctrl-Tab or Option-Left typed in another text field would land here (and a hidden tab would answer too).
        guard event.type == .keyDown, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let key = KeyInput(event)
        if !optionAsMetaKey, let sequence = TerminalShortcuts.optionEditingSequence(key) {
            send(sequence)
            return true
        }
        guard let handler = shortcutHandler, let shortcut = TerminalShortcuts.match(key) else {
            return super.performKeyEquivalent(with: event)
        }
        if shortcut == .deleteToLineStart {
            send([0x15])   // Ctrl-U, what Cmd-Backspace means in Terminal.app
            return true
        }
        return handler(shortcut)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Links

    /// The text an explicit (OSC 8) link to `target` shows on the screen now, as the user reads it: the screen's rows
    /// (soft wraps marked, the second halves of wide characters left out) read by `ShownLinkText`. SwiftTerm hands a
    /// click only the target, so `LinkPolicy` compares it with this.
    func shownTexts(ofLink target: String) -> [String] {
        var rows: [ShownLinkText.Row] = []
        for row in 0..<terminal.rows {
            guard let line = terminal.getLine(row: row) else {
                rows.append(ShownLinkText.Row(cells: [], isWrapped: false))
                continue
            }
            var cells: [ShownLinkText.Cell] = []
            for col in 0..<min(terminal.cols, line.count) {
                let cell = line[col]
                if cell.width == 0 { continue }
                let linked = (cell.getPayload() as? String).map { Self.linkTarget(ofPayload: $0) == target } ?? false
                cells.append(ShownLinkText.Cell(character: terminal.getCharacter(for: cell), linked: linked))
            }
            rows.append(ShownLinkText.Row(cells: cells, isWrapped: row > 0 && line.isWrapped))
        }
        return ShownLinkText.texts(rows: rows)
    }

    /// The target in an OSC 8 payload `params;URL`, split exactly as SwiftTerm splits it for `requestOpenLink`.
    static func linkTarget(ofPayload payload: String) -> String? {
        let parts = payload.split(separator: ";", maxSplits: Int.max, omittingEmptySubsequences: false)
        return parts.count > 1 ? String(parts[1]) : nil
    }

    override func mouseDown(with event: NSEvent) {
        // The block's panel becomes key on this click without activating the app; make sure typing goes here.
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        super.mouseDown(with: event)
    }

    // MARK: Text input

    /// The text-input system (macOS dictation, input methods, tools that insert text through it) may hand over an
    /// attributed string; SwiftTerm only accepts plain strings and would drop it.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        if let attributed = string as? NSAttributedString {
            super.insertText(attributed.string, replacementRange: replacementRange)
        } else {
            super.insertText(string, replacementRange: replacementRange)
        }
    }

    // MARK: Clipboard

    override func paste(_ sender: Any) { pasteFromPasteboard() }

    /// Edit > Copy: the selection goes to `pasteboard` (SwiftTerm's own version always uses the general one).
    override func copy(_ sender: Any) {
        let text = selection.getSelectedText()
        guard !text.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Edit > Paste and Match Style: the same as paste in a terminal.
    @objc func pasteAsPlainText(_ sender: Any?) { pasteFromPasteboard() }

    func pasteFromPasteboard() {
        guard let text = PasteSanitizer.text(from: pasteboard) else { return }
        sendPaste(text)
    }

    /// Types `text` as a paste: cleaned, and wrapped in the bracketed-paste markers when the program asked for them.
    func sendPaste(_ text: String) {
        let clean = PasteSanitizer.clean(text)
        guard !clean.isEmpty else { return }
        let bracketed = terminal.bracketedPasteMode
        if bracketed { send(data: EscapeSequences.bracketedPasteStart[0...]) }
        send(txt: clean)
        if bracketed { send(data: EscapeSequences.bracketedPasteEnd[0...]) }
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(pasteAsPlainText(_:)) { return true }
        if item.action == #selector(clearScrollbackAction(_:)) { return true }
        return super.validateUserInterfaceItem(item)
    }

    @objc func clearScrollbackAction(_ sender: Any?) { clearScrollback() }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(title: "Terminal")
        menu.autoenablesItems = true
        let copyItem = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        let pasteItem = NSMenuItem(title: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        let selectAllItem = NSMenuItem(title: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
        let clearItem = NSMenuItem(title: "Clear Scrollback", action: #selector(clearScrollbackAction(_:)), keyEquivalent: "")
        for item in [copyItem, pasteItem, selectAllItem, clearItem] { item.target = self }
        [copyItem, pasteItem, selectAllItem].forEach(menu.addItem)
        menu.addItem(.separator())
        menu.addItem(clearItem)
        let extras = contextMenuExtras?() ?? []
        if !extras.isEmpty {
            menu.addItem(.separator())
            extras.forEach(menu.addItem)
        }
        return menu
    }

    // MARK: Drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard PasteSanitizer.dropText(from: sender.draggingPasteboard) != nil else { return [] }
        onDropTargetChange?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func draggingExited(_ sender: NSDraggingInfo?) { onDropTargetChange?(false) }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDropTargetChange?(false)
        guard let text = PasteSanitizer.dropText(from: sender.draggingPasteboard) else { return false }
        sendPaste(text)
        return true
    }
}
