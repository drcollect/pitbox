import AppKit
import PitboxKit

/// What the command area shows, built from the exact text that runs.
///
/// Every character of the text is shown, in order, wrapped, never cut: tabs as `→`, trailing spaces as `·`, runs of
/// 4 or more spaces with a faint `·` per space (text pushed far right still shows), hidden characters (B1) escaped in
/// place (`⟨U+202E⟩`), every other non-ASCII character on an amber background followed by its code point, the exact
/// characters of each red line underlined in red, the shell's comments dimmed (full-line and trailing, as the scanner
/// reads them), here-doc bodies on a faint panel labelled "text given to <program>". Output lines of prompt-style
/// blocks are greyed and labelled "shown in the reply, not run"; they are not part of the text. No other colouring.
///
/// The offer's display lines are used only when their command lines put together are exactly the offer's text;
/// otherwise the text alone is shown. What is shown as running is always exactly what runs.
struct CommandAreaContent {
    /// `label` is the host's own line above a here-doc body ("text given to cat"); it is not part of the text.
    enum Role: Equatable { case run, output, comment, label }

    struct Paragraph: Equatable {
        /// The line number of a run line (1-based, as the red lines count), nil for output and comment lines.
        var number: Int?
        var role: Role
    }

    let attributed: NSAttributedString
    let paragraphs: [Paragraph]
    /// The display ranges of the red lines' characters (for tests).
    let underlined: [NSRange]
    /// What VoiceOver reads: the run lines with their numbers.
    let accessibilityText: String
    /// For each UTF-16 offset of the text (and its end), where it starts in `attributed`.
    let displayLocation: [Int]
    /// The here-doc panels: each label line with the body lines under it, in `attributed`.
    let panels: [NSRange]

    static func build(text: String, displayLines: [CommandOffer.DisplayLine], flags: [CommandFlag],
                      palette: CommandSheetPalette, marks: CommandScriptMarks? = nil) -> CommandAreaContent {
        let marks = marks ?? CommandScriptMarks(text: text)
        let commandLines = displayLines.filter { $0.role == .command }.map(\.text)
        let useDisplay = !displayLines.isEmpty && commandLines.joined(separator: "\n") == text
        let items: [(role: Role, text: String)] = useDisplay
            ? displayLines.map { line in (line.role == .command ? .run : (line.role == .output ? .output : .comment), line.text) }
            : text.split(separator: "\n", omittingEmptySubsequences: false).map { (.run, String($0)) }

        let out = NSMutableAttributedString()
        var paragraphs: [Paragraph] = []
        var spans: [(utf16: Range<Int>, display: NSRange)] = []
        var runNumber = 0
        var textOffset = 0   // UTF-16 offset in `text` of the current run line
        var previousRole: Role?
        var spoken: [String] = []
        var panels: [NSRange] = []
        var openPanel: (start: Int, document: CommandScriptMarks.HereDocument)?
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        paragraph.lineSpacing = 2
        let base: [NSAttributedString.Key: Any] = [.font: CommandSheetFonts.mono, .foregroundColor: palette.screenFG,
                                                   .paragraphStyle: paragraph]

        for (index, item) in items.enumerated() {
            if item.role == .run, index > 0, openPanel == nil,
               let document = marks.hereDocuments.first(where: { $0.body.lowerBound == textOffset }) {
                // The body starts on this line: the label line goes above it, and the panel opens there.
                out.append(NSAttributedString(string: "\n", attributes: base))
                let start = out.length
                out.append(hereDocumentLabel(document.program, palette: palette, paragraph: paragraph))
                paragraphs.append(Paragraph(number: nil, role: .label))
                spoken.append("text given to \(document.program):")
                openPanel = (start, document)
            }
            if index > 0 {
                let newlineAt = out.length
                out.append(NSAttributedString(string: "\n", attributes: base))
                if item.role == .run, runNumber > 0 {
                    // The newline that joins two run lines is the character before this line in the text.
                    spans.append((textOffset - 1..<textOffset, NSRange(location: newlineAt, length: 1)))
                }
            }
            switch item.role {
            case .run:
                runNumber += 1
                paragraphs.append(Paragraph(number: runNumber, role: .run))
                spoken.append("\(runNumber): \(item.text)")
                appendRunLine(item.text, startingAt: textOffset, into: out, spans: &spans, base: base, palette: palette,
                              marks: marks)
                textOffset += item.text.utf16.count + 1
                if let panel = openPanel, textOffset >= panel.document.body.upperBound {
                    panels.append(NSRange(location: panel.start, length: out.length - panel.start))
                    openPanel = nil
                }
            case .output, .comment, .label:
                paragraphs.append(Paragraph(number: nil, role: item.role))
                let grey: [NSAttributedString.Key: Any] = base.merging([.foregroundColor: palette.faint]) { $1 }
                out.append(NSAttributedString(string: escaped(item.text), attributes: grey))
                if previousRole != item.role {
                    let label = item.role == .output ? "   shown in the reply, not run" : "   a comment in the reply, not run"
                    out.append(NSAttributedString(string: label, attributes: [
                        .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: palette.faint, .paragraphStyle: paragraph]))
                }
            }
            previousRole = item.role
        }
        if let panel = openPanel { panels.append(NSRange(location: panel.start, length: out.length - panel.start)) }

        // Underline the exact characters of each red line and block reason.
        var underlined: [NSRange] = []
        for flag in flags where !flag.utf16Range.isEmpty {
            var lower = Int.max
            var upper = Int.min
            for span in spans where span.utf16.overlaps(flag.utf16Range) {
                lower = min(lower, span.display.location)
                upper = max(upper, span.display.location + span.display.length)
            }
            guard lower < upper else { continue }
            let range = NSRange(location: lower, length: upper - lower)
            out.addAttributes([.underlineStyle: NSUnderlineStyle.thick.rawValue, .underlineColor: palette.red], range: range)
            underlined.append(range)
        }
        var locations = [Int](repeating: out.length, count: text.utf16.count + 1)
        for span in spans {
            for offset in span.utf16 where offset >= 0 && offset < locations.count { locations[offset] = span.display.location }
        }
        return CommandAreaContent(attributed: out, paragraphs: paragraphs, underlined: underlined,
                                  accessibilityText: spoken.joined(separator: "\n"), displayLocation: locations, panels: panels)
    }

    /// "text given to cat": host words, with the program as written in the command (monospaced).
    private static func hereDocumentLabel(_ program: String, palette: CommandSheetPalette,
                                          paragraph: NSParagraphStyle) -> NSAttributedString {
        let label = NSMutableAttributedString(string: "text given to ", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: palette.dim, .paragraphStyle: paragraph])
        label.append(NSAttributedString(string: program, attributes: [
            .font: CommandSheetFonts.gutter, .foregroundColor: palette.dim, .paragraphStyle: paragraph]))
        return label
    }

    /// One run line, character by character, recording where each character of the text went.
    private static func appendRunLine(_ line: String, startingAt offset: Int, into out: NSMutableAttributedString,
                                      spans: inout [(utf16: Range<Int>, display: NSRange)],
                                      base: [NSAttributedString.Key: Any], palette: CommandSheetPalette,
                                      marks: CommandScriptMarks) {
        let scalars = Array(line.unicodeScalars)
        let lastVisible = scalars.lastIndex { $0 != " " } ?? -1
        var inLongRun = [Bool](repeating: false, count: scalars.count)
        var runStart: Int?
        for index in 0...scalars.count {
            let isSpace = index < scalars.count && scalars[index] == " "
            if isSpace, runStart == nil { runStart = index }
            if !isSpace, let start = runStart {
                if index - start >= 4 { for marked in start..<index { inLongRun[marked] = true } }
                runStart = nil
            }
        }
        var utf16 = offset
        for (index, scalar) in scalars.enumerated() {
            let start = out.length
            let ink = marks.isComment(at: utf16) ? palette.dim : palette.screenFG
            if scalar == "\t" {
                out.append(NSAttributedString(string: "→", attributes: base.merging([.foregroundColor: palette.gutter]) { $1 }))
            } else if scalar == " ", index > lastVisible {
                out.append(NSAttributedString(string: "·", attributes: base.merging([.foregroundColor: palette.gutter]) { $1 }))
            } else if scalar == " ", inLongRun[index] {
                out.append(NSAttributedString(string: "·", attributes: base.merging([.foregroundColor: palette.gutter.withAlphaComponent(0.55)]) { $1 }))
            } else if CommandHiddenCharacters.isHidden(scalar) {
                out.append(NSAttributedString(string: CommandHiddenCharacters.escaped(scalar), attributes: base.merging([
                    .foregroundColor: palette.red, .backgroundColor: palette.redFill]) { $1 }))
            } else if scalar.value > 0x7E {
                out.append(NSAttributedString(string: String(scalar), attributes: base.merging([
                    .foregroundColor: ink, .backgroundColor: palette.amberFill]) { $1 }))
                out.append(NSAttributedString(string: "\u{2009}" + CommandHiddenCharacters.codePoint(scalar) + "\u{2009}", attributes: [
                    .font: CommandSheetFonts.codePoint, .foregroundColor: palette.amber, .backgroundColor: palette.amberFill,
                    .baselineOffset: 1, .paragraphStyle: base[.paragraphStyle] as Any]))
            } else {
                out.append(NSAttributedString(string: String(scalar), attributes: base.merging([.foregroundColor: ink]) { $1 }))
            }
            let width = scalar.utf16.count
            spans.append((utf16..<utf16 + width, NSRange(location: start, length: out.length - start)))
            utf16 += width
        }
    }

    /// Output lines are session text too: hidden characters escaped, controls never drawn.
    private static func escaped(_ line: String) -> String {
        var out = ""
        for scalar in line.unicodeScalars {
            if scalar == "\t" { out += "→" } else if CommandHiddenCharacters.isHidden(scalar) { out += CommandHiddenCharacters.escaped(scalar) }
            else { out.unicodeScalars.append(scalar) }
        }
        return out
    }
}

/// Draws `CommandAreaContent`: a gutter with line numbers, a dim `↪` at the start of each continued row (never
/// horizontal scrolling, never an ellipsis), the text in SF Mono 13 pt on the screen colour. Scrolling belongs to the
/// sheet's body; the sheet notes when the bottom of this view has been on screen once.
@MainActor
final class CommandAreaView: NSView {
    static let padding: CGFloat = 10

    private(set) var content: CommandAreaContent
    var palette: CommandSheetPalette { didSet { if palette != oldValue { needsDisplay = true } } }
    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let container = NSTextContainer(size: CGSize(width: 400, height: 1_000_000))

    init(content: CommandAreaContent, palette: CommandSheetPalette) {
        self.content = content
        self.palette = palette
        super.init(frame: .zero)
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        storage.setAttributedString(content.attributed)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Command")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func accessibilityValue() -> Any? { content.accessibilityText }

    func setContent(_ new: CommandAreaContent) {
        content = new
        storage.setAttributedString(new.attributed)
        needsDisplay = true
    }

    private var gutterWidth: CGFloat {
        let digits = max(2, String(content.paragraphs.compactMap(\.number).max() ?? 1).count)
        return CGFloat(digits) * 7 + 18
    }

    /// The height the content needs at `width`.
    func height(for width: CGFloat) -> CGFloat {
        container.size = CGSize(width: max(40, width - gutterWidth - 2 * Self.padding), height: 1_000_000)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        return ceil(max(used.height, CommandSheetFonts.mono.ascender - CommandSheetFonts.mono.descender)) + 2 * Self.padding
    }

    override func layout() {
        super.layout()
        container.size = CGSize(width: max(40, bounds.width - gutterWidth - 2 * Self.padding), height: 1_000_000)
    }

    override func draw(_ dirtyRect: NSRect) {
        palette.screen.setFill()
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        box.fill()
        palette.line.setStroke()
        box.lineWidth = 1
        box.stroke()
        let origin = CGPoint(x: gutterWidth + Self.padding, y: Self.padding)
        let glyphs = layoutManager.glyphRange(for: container)
        drawPanels(origin: origin)
        layoutManager.drawBackground(forGlyphRange: glyphs, at: origin)
        layoutManager.drawGlyphs(forGlyphRange: glyphs, at: origin)
        drawGutter(origin: origin, glyphs: glyphs)
    }

    /// The here-doc panels: the full width of the text column, behind the label and the body lines.
    private func drawPanels(origin: CGPoint) {
        guard !content.panels.isEmpty else { return }
        palette.hereDocument.setFill()
        for panel in content.panels where NSMaxRange(panel) <= storage.length {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: panel, actualCharacterRange: nil)
            let used = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
            let rect = CGRect(x: origin.x - 6, y: origin.y + used.minY - 1, width: container.size.width + 10, height: used.height + 2)
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        }
    }

    /// Line numbers on the first row of each run line; `↪` on every continued row.
    private func drawGutter(origin: CGPoint, glyphs: NSRange) {
        let text = storage.string as NSString
        let numberAttributes: [NSAttributedString.Key: Any] = [.font: CommandSheetFonts.gutter, .foregroundColor: palette.gutter]
        let wrapAttributes: [NSAttributedString.Key: Any] = [.font: CommandSheetFonts.gutter, .foregroundColor: palette.gutter.withAlphaComponent(0.7)]
        var paragraphStarts: [Int] = [0]
        for index in 0..<text.length where text.character(at: index) == 0x0A { paragraphStarts.append(index + 1) }
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { [self] rect, _, _, glyphRange, _ in
            let characterIndex = layoutManager.characterIndexForGlyph(at: glyphRange.location)
            let y = origin.y + rect.minY + 1
            if let paragraphIndex = paragraphStarts.firstIndex(of: characterIndex) {
                guard paragraphIndex < content.paragraphs.count, let number = content.paragraphs[paragraphIndex].number else { return }
                let label = String(number) as NSString
                let size = label.size(withAttributes: numberAttributes)
                label.draw(at: CGPoint(x: gutterWidth - 8 - size.width, y: y + 1), withAttributes: numberAttributes)
            } else {
                ("↪" as NSString).draw(at: CGPoint(x: gutterWidth - 18, y: y), withAttributes: wrapAttributes)
            }
        }
        palette.line.setFill()
        CGRect(x: gutterWidth - 3, y: 6, width: 1, height: bounds.height - 12).fill()
    }
}
