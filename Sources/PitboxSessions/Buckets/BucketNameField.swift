import AppKit
import PitboxKit

/// The field a bucket's name is typed into, laid over the name in its header: right after "+ New bucket" (its text
/// selected) or on a double-click on the name. B1 characters, tabs and line breaks are dropped while typing, and the
/// text stops at 32 characters. Return keeps the name; Escape cancels (a bucket just made goes again, an old name
/// stays); a click elsewhere or the block losing the keyboard keeps what was typed. The block asks for the keyboard
/// when the field opens and hands it back when it closes.
///
/// This is the block's only text field, and it only ever holds the user's own words for their bucket: no sheet, tag,
/// peek, card or label has one, so a text field anywhere else is an imitation (docs/THREAT_MODEL.md).
final class CodeBucketNameField: NSTextField, NSTextFieldDelegate {
    /// Return (`true`), Escape (`false`), or the field's editing ending otherwise (`true`). Called once.
    var onFinish: ((Bool) -> Void)?
    private var finished = false

    init(name: String, dark: Bool) {
        super.init(frame: .zero)
        stringValue = CodeBucketName.typed(name)
        font = CodeMonitorFonts.rowHeadline
        isBordered = false
        isBezeled = false
        drawsBackground = true
        backgroundColor = dark ? CodeMonitorPalette.color(0x1B1E25) : CodeMonitorPalette.color(0xFFFFFF)
        textColor = dark ? CodeMonitorPalette.color(CodeMonitorPalette.headerTitleDark)
            : CodeMonitorPalette.color(CodeMonitorPalette.headerTitleLight)
        focusRingType = .exterior
        usesSingleLineMode = true
        maximumNumberOfLines = 1
        lineBreakMode = .byClipping
        cell?.isScrollable = true
        cell?.wraps = false
        isEditable = true
        isSelectable = true
        delegate = self
        wantsLayer = true
        layer?.cornerRadius = 5
        setAccessibilityLabel("Bucket name")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Ends the field once (the block also calls it for a click elsewhere, the keyboard leaving, or the block hiding).
    func finish(commit: Bool) {
        guard !finished else { return }
        finished = true
        onFinish?(commit)
    }

    /// What typing keeps: the text with dropped characters removed and cut at 32 characters.
    func controlTextDidChange(_ obj: Notification) {
        let kept = CodeBucketName.typed(stringValue)
        guard kept != stringValue else { return }
        stringValue = kept
        currentEditor()?.selectedRange = NSRange(location: (kept as NSString).length, length: 0)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            finish(commit: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            finish(commit: false)
            return true
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            finish(commit: true)
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        finish(commit: true)
    }
}
