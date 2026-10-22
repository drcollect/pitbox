import AppKit
import PitboxKit

/// A monitor's run line and bar, ready to draw, in every look at once (a block item is built before its bucket
/// decides its size): the words of each size, whether they are late (orange), and the
/// 3 pt bar's fill. On a large monitor it goes under "Now:" (the TL;DR gives its last lines to it while running), on a
/// medium one in place of the TL;DR's line, on a small one as the bar (and "≈ 9 min" when no offer, file or warning
/// comes first), on a slim row as the words at the right.
struct CodeRunLine: Equatable, Sendable {
    /// The looks of a monitor.
    enum Size: Equatable, Sendable { case large, medium, small, row }

    /// "Running 34 min · ETA 23:24 · 4 of 6 agents done", "Background · 4 of 6 agents done · ETA 23:24".
    var large: String?
    /// "ETA 23:24 · 4/6 agents", "≈ 9 min left" (medium monitors); nil without an ETA or a progress source, so a
    /// medium monitor keeps its "Now:" line then.
    var medium: String?
    /// "≈ 9 min" (small monitors).
    var small: String?
    /// A slim row's right-hand words: the medium words, else "Running 12 min".
    var row: String?
    /// A stated ETA passed while the session still runs: orange words and bar.
    var isLate: Bool
    /// done / total for the bar; nil: no bar (no source, no bar).
    var fraction: Double?

    /// The words a look shows.
    func text(for size: Size) -> String? {
        switch size {
        case .large: return large
        case .medium: return medium
        case .small: return small
        case .row: return row
        }
    }

    /// The run line of `snapshot`, or nil while the session is not running.
    static func make(_ snapshot: CodeSessionSnapshot, now: Date, clock: CodeClockFormat) -> CodeRunLine? {
        guard RunText.isRunning(snapshot) else { return nil }
        let short = RunText.medium(snapshot, now: now, clock: clock)
        let line = CodeRunLine(large: RunText.large(snapshot, now: now, clock: clock),
                               medium: snapshot.eta != nil || snapshot.progress != nil ? short : nil,
                               small: RunText.small(snapshot, now: now, clock: clock), row: short,
                               isLate: RunText.isLate(snapshot, now: now), fraction: RunText.fraction(snapshot))
        return line.large == nil && line.row == nil && line.fraction == nil ? nil : line
    }
}

/// Draws a `CodeRunLine` on a monitor's near-black screen (the colours hold in both appearances: a monitor is a dark
/// object, `CodeMonitorPalette`). Words 12 pt, never under it.
enum CodeRunLineDrawing {
    /// Words while on time (the run colour; 11:1 on the screen).
    static let text: UInt32 = 0xA9C8FF
    /// Late words and bar (the warning and late colour; 10.6:1 on the screen).
    static let late: UInt32 = 0xFFB36B
    /// The bar's fill and track.
    static let bar: UInt32 = 0x4C9BFF
    static let track: UInt32 = 0x22262F
    /// The bar's height.
    static let barHeight: CGFloat = 3
    static let font = NSFont.systemFont(ofSize: 12, weight: .medium)

    /// Draws the words of `size` in `textRect` (one line, cut at the end) and the bar in `barRect`; either may be nil.
    static func draw(_ line: CodeRunLine, size: CodeRunLine.Size, textRect: CGRect?, barRect: CGRect?) {
        if let rect = textRect, let words = line.text(for: size), rect.width > 2 {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: ThemeColor.srgb(line.isLate ? late : text), .paragraphStyle: style,
            ]
            let height = ceil(font.ascender - font.descender + font.leading)
            let target = CGRect(x: rect.minX, y: (rect.midY - height / 2).rounded(), width: rect.width, height: height)
            (words as NSString).draw(with: target, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                     attributes: attributes)
        }
        if let rect = barRect, let fraction = line.fraction {
            drawBar(fraction: fraction, late: line.isLate, in: rect)
        }
    }

    /// The 3 pt bar: a dark track and a blue (orange when late) fill of `fraction`.
    static func drawBar(fraction: Double, late isLate: Bool, in rect: CGRect) {
        let bar = CGRect(x: rect.minX, y: rect.midY - barHeight / 2, width: rect.width, height: barHeight)
        ThemeColor.srgb(track).setFill()
        NSBezierPath(roundedRect: bar, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
        let width = bar.width * CGFloat(min(max(fraction, 0), 1))
        guard width > 0.5 else { return }
        ThemeColor.srgb(isLate ? late : self.bar).setFill()
        NSBezierPath(roundedRect: CGRect(x: bar.minX, y: bar.minY, width: width, height: barHeight),
                     xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
    }
}
