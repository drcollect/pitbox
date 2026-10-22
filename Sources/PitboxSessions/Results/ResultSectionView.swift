import AppKit
import PitboxKit

/// A session's results as one self-contained view: the rows of `CodeResultPeekRows` ("Results" with
/// every button of the work, an SSH session's previews with Copy link, "2 other links in the reply (open them from the
/// session)", other paths of the reply as plain text, "Earlier artifacts"), its buttons armed. For a surface
/// that hosts views, the way the block hosts its accessories (`accessoryHeight(forWidth:)`, the shape of
/// `CodeTileAccessory`): a Ready card's details, the desk peek. The monitor's peek draws the same rows with its own
/// elements instead. Presses come out of `onPress`, already armed.
final class CodeResultsSectionView: NSView {
    static let labelFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let textFont = NSFont.systemFont(ofSize: 12)
    static let rowGap: CGFloat = 6

    private(set) var results: [CodeResult]
    private(set) var otherLinkCount: Int
    private(set) var alias: String?
    private(set) var textHidden: Bool
    var palette: CodeResultPalette { didSet { placed.forEach { if case .buttons(let view) = $0.kind { view.palette = palette } } } }
    var onPress: ((CodeResultButton) -> Void)?
    /// Earlier artifacts' times, in this Mac's zone and the system's 12- or 24-hour form.
    var timeText: (Date) -> String = CodeResultPeekRows.defaultTime { didSet { relayout() } }

    private struct Placed {
        enum Kind { case label(String), text(String, dim: Bool), buttons(CodeResultButtonsView) }
        var kind: Kind
        var frame: CGRect
    }

    private var placed: [Placed] = []

    init(results: [CodeResult], otherLinkCount: Int, alias: String?, hidden: Bool,
         palette: CodeResultPalette = CodeResultPalette(dark: true), width: CGFloat) {
        self.results = results
        self.otherLinkCount = otherLinkCount
        self.alias = alias
        self.textHidden = hidden
        self.palette = palette
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: 0))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Results")
        relayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    /// The height the section takes at its width (0: nothing to show).
    var height: CGFloat { placed.last.map { $0.frame.maxY } ?? 0 }

    /// The height at `width` (the shape of the block's `CodeTileAccessory`).
    func accessoryHeight(forWidth width: CGFloat) -> CGFloat {
        if abs(width - frame.width) > 0.5 { setFrameSize(CGSize(width: width, height: frame.height)) }
        return height
    }

    func update(results: [CodeResult], otherLinkCount: Int, alias: String?, hidden: Bool) {
        guard results != self.results || otherLinkCount != self.otherLinkCount || alias != self.alias || hidden != self.textHidden else {
            return
        }
        self.results = results
        self.otherLinkCount = otherLinkCount
        self.alias = alias
        self.textHidden = hidden
        relayout()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize.width != frame.width
        super.setFrameSize(newSize)
        if changed { relayout() }
    }

    private func relayout() {
        for item in placed { if case .buttons(let view) = item.kind { view.removeFromSuperview() } }
        placed = []
        let width = max(60, bounds.width)
        var y: CGFloat = 0
        let rows = CodeResultPeekRows.rows(results: results, otherLinkCount: otherLinkCount, alias: alias, hidden: textHidden,
                                           time: timeText)
        for row in rows {
            switch row {
            case .label(let words):
                let height = ceil(Self.labelFont.ascender - Self.labelFont.descender + Self.labelFont.leading)
                placed.append(Placed(kind: .label(words), frame: CGRect(x: 0, y: y, width: width, height: height)))
                y += height + Self.rowGap
            case .text(let words, let dim):
                let lineHeight = ceil(Self.textFont.ascender - Self.textFont.descender + Self.textFont.leading)
                let lines = max(1, min(3, Int(ceil((words as NSString).size(withAttributes: [.font: Self.textFont]).width / width))))
                let frame = CGRect(x: 0, y: y, width: width, height: CGFloat(lines) * lineHeight)
                placed.append(Placed(kind: .text(words, dim: dim), frame: frame))
                y += frame.height + Self.rowGap
            case .buttons(let buttons):
                let view = CodeResultButtonsView(buttons: buttons, palette: palette, width: width)
                view.onPress = { [weak self] button in self?.onPress?(button) }
                view.frame = CGRect(x: 0, y: y, width: width, height: CodeResultButtonsView.height(of: buttons, note: nil, width: width))
                addSubview(view)
                placed.append(Placed(kind: .buttons(view), frame: view.frame))
                y += view.frame.height + Self.rowGap
            }
        }
        if !placed.isEmpty { y -= Self.rowGap }
        super.setFrameSize(CGSize(width: frame.width, height: max(0, y)))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        for item in placed {
            let text: String, font: NSFont, color: UInt32
            switch item.kind {
            case .label(let words): text = words.uppercased(); font = Self.labelFont; color = palette.dim
            case .text(let words, let dim): text = words; font = Self.textFont; color = dim ? palette.dim : palette.plain
            case .buttons: continue
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingMiddle
            (text as NSString).draw(with: item.frame, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                    attributes: [.font: font, .foregroundColor: CodeResultPalette.color(color), .paragraphStyle: paragraph])
        }
    }
}
