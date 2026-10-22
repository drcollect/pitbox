import AppKit
import PitboxKit

/// The result line of large and medium monitors: the first result's button ("↗ Open preview ·
/// localhost:5173", "▤ Open notes.md") and "+2 more", in the offer line's place when the monitor has no offer line (the
/// original design's order there: an offer, a run's result, then results). Shaped like the block's `CodeOfferLine` and
/// `CodeMonitorMark`: a value the monitor item carries, which the monitor view lays out and draws, its click armed like
/// an opening mark (counted 0.8 s after it appeared or moved, never the press under the pointer when it appeared).
/// Small monitors and slim rows show none (the peek has the results).
struct CodeMonitorResultLine: Equatable {
    /// The button a click acts on (`CodeResultActions.perform`).
    var button: CodeResultButton
    /// "+2 more" when the work has more results with buttons.
    var more: String?
    /// VoiceOver's words: "Open the preview", "Preview the page", "Fetch the file" (host words).
    var label: String

    /// The key the monitor's arming notes the line under (a monitor has one).
    static let armingKey = "result-line"

    /// The line for `session`, nil without a result button or with text hidden (Hide text shows headline and state
    /// only).
    static func make(_ session: CodeSessionSnapshot, textHidden: Bool) -> CodeMonitorResultLine? {
        guard !textHidden, let first = CodeResultWords.firstLine(session.results) else { return nil }
        return CodeMonitorResultLine(button: first.button, more: first.more, label: label(for: first.button))
    }

    static func label(for button: CodeResultButton) -> String {
        switch button.action {
        case .open: return button.tone == .result && button.title.hasPrefix("↗") ? "Open the link" : "Open the file"
        case .preview: return "Preview the page"
        case .showInFinder: return "Show the file in Finder"
        case .copyLink: return "Copy the link"
        case .fetch: return "Fetch the file"
        }
    }

    /// The result link colour of the line.
    static let tone = CodeResultPalette.resultLink

    /// Draws the line in `rect` (the offer line's place) like the monitor's offer line: a pill of the result link
    /// colour, the button's words in it, "+2 more" after them in the dim colour when there is room. `large` also gets the
    /// note on medium monitors only when it fits.
    static func draw(_ line: CodeMonitorResultLine, in rect: CGRect, hovered: Bool, pressed: Bool) {
        let pill = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        CodeResultPalette.color(tone, pressed ? 0.26 : (hovered ? 0.18 : 0.13)).setFill()
        pill.fill()
        CodeResultPalette.color(tone, 0.38).setStroke()
        let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4.5, yRadius: 4.5)
        edge.lineWidth = 1
        edge.stroke()
        let inner = rect.insetBy(dx: 6, dy: 0)
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let labelWidth = min(inner.width, ceil((line.button.title as NSString).size(withAttributes: [.font: font]).width))
        drawText(line.button.title, in: CGRect(x: inner.minX, y: inner.minY, width: labelWidth, height: inner.height), font: font,
                 color: CodeResultPalette.color(tone), truncation: .byTruncatingMiddle)
        if let more = line.more {
            let small = NSFont.systemFont(ofSize: 12)
            let width = ceil((more as NSString).size(withAttributes: [.font: small]).width)
            if inner.width - labelWidth >= width + 8 {
                drawText(more, in: CGRect(x: inner.minX + labelWidth + 8, y: inner.minY, width: width, height: inner.height), font: small,
                         color: CodeResultPalette.color(CodeResultPalette.dimDark), truncation: .byClipping)
            }
        }
    }

    private static func drawText(_ text: String, in rect: CGRect, font: NSFont, color: NSColor, truncation: NSLineBreakMode) {
        guard rect.width > 2 else { return }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = truncation
        let height = ceil(font.ascender - font.descender + font.leading)
        let target = CGRect(x: rect.minX, y: (rect.midY - height / 2).rounded(), width: rect.width, height: height)
        (text as NSString).draw(with: target, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }
}
