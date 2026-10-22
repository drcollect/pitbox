import AppKit
import PitboxKit

/// A monitor's warning: an orange line on large and medium monitors ("⚠ Looks stuck: 4 commands failed in a row", "+1"
/// for another), "⚠ stuck" or "⚠ same file" on small ones, and an orange screen outline on every size. No glow, no
/// chime, no change of the state word. Shaped like the block's monitor parts: a value the monitor item carries, laid
/// out and drawn by the monitor view; the outline is drawn where the monitor draws Needs you's amber border (Needs you
/// wins).
struct CodeMonitorWarningLine: Equatable {
    /// Large and medium: the first warning's line, "  +1" for each more.
    var text: String
    /// Small: "⚠ stuck", "⚠ same file".
    var short: String
    /// VoiceOver's words: "Looks stuck", "Same file in two sessions".
    var label: String

    /// The line for `session` (nil without an active warning). With Hide text the reason stays (it is the app's own
    /// words) but the other session's path reads "hidden"; the other headline stays, as on cards.
    static func make(_ session: CodeSessionSnapshot, now: Date, textHidden: Bool) -> CodeMonitorWarningLine? {
        guard let first = session.warnings.first else { return nil }
        return CodeMonitorWarningLine(text: CodeWarningLineView.text(session.warnings, now: now, hidden: textHidden),
                                      short: CodeWarningWords.short(first),
                                      label: String(CodeWarningWords.cardTitle(first).dropFirst(2)))
    }

    static let font = NSFont.systemFont(ofSize: 12, weight: .medium)

    /// The line's height (one line of 12 pt).
    static var lineHeight: CGFloat { ceil(font.ascender - font.descender + font.leading) }

    /// Draws `small ? short : text` in orange, one line, cut at the end.
    static func draw(_ line: CodeMonitorWarningLine, in rect: CGRect, small: Bool) {
        guard rect.width > 2 else { return }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let target = CGRect(x: rect.minX, y: (rect.midY - lineHeight / 2).rounded(), width: rect.width, height: lineHeight)
        ((small ? line.short : line.text) as NSString).draw(with: target, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                                           attributes: [.font: font, .paragraphStyle: style,
                                                                        .foregroundColor: CodeWarningPalette.color(CodeWarningPalette.orange)])
    }

    /// The orange screen outline (1.5 pt, inside the screen's rounded rect), as Needs you's amber border is drawn.
    static func strokeOutline(screen: CGRect, radius: CGFloat) {
        let border = NSBezierPath(roundedRect: screen.insetBy(dx: 0.75, dy: 0.75), xRadius: radius, yRadius: radius)
        border.lineWidth = 1.5
        CodeWarningPalette.color(CodeWarningPalette.outline).setStroke()
        border.stroke()
    }
}
