import AppKit
import PitboxKit

/// One bucket's header, 28 pt on the block's glass. Left to right: the 14 pt
/// colour square, the name (13 pt semibold, cut at 180 pt), "4 · 2 running" (12 pt grey), the badges (12 pt pills, each
/// only above 0, each with a word or a sign), space, fold (▾ / ▸) and delete (✕, not on Unsorted). The bucket's colour
/// shows only on the square and as the 2 pt line along the bottom, never on monitors.
///
/// Delete turns the header into "Delete “Toy Cube”? 3 monitors move to Unsorted. No window is closed. [Keep]
/// [Delete]". A double-click on the name asks for the rename field (the block lays it over `nameFrame`). Clicks act on
/// mouse-up inside the same part; never first responder. VoiceOver: one group, "Bucket Toy Cube, 4 sessions, 2 running,
/// 1 needs you", with a button per part.
final class CodeBucketHeaderView: NSView, NSViewToolTipOwner {
    enum Part: Equatable { case color, name, fold, delete, keep, confirmDelete }

    /// A badge as drawn.
    struct Badge: Equatable {
        var text: String
        var fill: UInt32
        var ink: UInt32
        var rect: CGRect
    }

    /// Where everything goes, in the view's flipped coordinates.
    struct Layout: Equatable {
        var swatch: CGRect
        var name: CGRect
        var meta: CGRect
        var badges: [Badge]
        var fold: CGRect
        var delete: CGRect?
        /// Delete's question and its buttons (only while asking).
        var question: CGRect?
        var keep: CGRect?
        var confirm: CGRect?
    }

    private(set) var section: CodeBucketSection
    private(set) var confirmingDelete = false
    /// The rename field covers the name: nothing is drawn there.
    private(set) var renaming = false
    private(set) var layoutInfo: Layout
    var onPart: ((CodeBucketHeaderView, Part) -> Void)?
    /// A double-click on the name (not Unsorted's).
    var onRename: ((CodeBucketHeaderView) -> Void)?
    private var pressedPart: Part?
    private var hoveredPart: Part?
    /// Tests: every string drawn.
    var drawnTexts: [String]?

    static let height = CodeBucketLayout.headerHeight
    /// The colour line along the bottom.
    static let lineThickness: CGFloat = 2
    static let swatchSide: CGFloat = 14
    /// The name is cut at this width.
    static let nameMax: CGFloat = 180
    static let buttonSide: CGFloat = 22
    static let badgeHeight: CGFloat = 18
    static let nameFont = CodeMonitorFonts.rowHeadline
    static let metaFont = CodeMonitorFonts.headerDetail
    static let badgeFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let glyphFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    /// ▾ and ▸ are small glyphs: drawn larger to match ✕.
    static let foldFont = NSFont.systemFont(ofSize: 18, weight: .regular)
    /// The square's distance from the bucket's left edge (clear of the drop outline).
    static let swatchInset: CGFloat = 4
    /// Delete's red button (the original design's danger button: red with dark words, 5.7:1).
    static let dangerFill: UInt32 = 0xEF5B5B, dangerInk: UInt32 = 0x1A0606

    init(section: CodeBucketSection, frame: CGRect) {
        self.section = section
        layoutInfo = Self.layout(section, width: frame.width, confirming: false)
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        updateAccessibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(section: CodeBucketSection, confirmingDelete: Bool, renaming: Bool) {
        guard section != self.section || confirmingDelete != self.confirmingDelete || renaming != self.renaming else { return }
        self.section = section
        self.confirmingDelete = confirmingDelete && !section.bucket.isUnsorted
        self.renaming = renaming
        relayout()
        updateAccessibility()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { relayout() }
    }

    private func relayout() {
        layoutInfo = Self.layout(section, width: bounds.width, confirming: confirmingDelete)
        updateTrackingAreas()
        removeAllToolTips()
        for (_, rect) in parts() { addToolTip(rect, owner: self, userData: nil) }
        needsDisplay = true
    }

    /// Where the rename field goes: over the name, as wide as a 32-character name needs (at most the free room).
    var nameFrame: CGRect {
        let l = layoutInfo
        let right = (l.badges.first?.rect.minX ?? l.fold.minX) - 6
        let width = max(l.name.width, min(220, max(120, right - l.name.minX)))
        return CGRect(x: l.name.minX - 3, y: 3, width: width + 6, height: Self.height - Self.lineThickness - 6)
    }

    // MARK: Words (the app's own text)

    /// "4 · 2 running" (monitors shown, then those running when any run).
    static func meta(_ counts: CodeBucketCounts) -> String {
        counts.running > 0 ? "\(counts.monitors) · \(counts.running) running" : "\(counts.monitors)"
    }

    /// "2 need you", "▶ 3", "⤓ 1", "✓ 2 new", "⚠ 1": each only above 0.
    static func badges(_ counts: CodeBucketCounts) -> [(text: String, fill: UInt32, ink: UInt32)] {
        var out: [(String, UInt32, UInt32)] = []
        func add(_ number: Int, _ text: String, _ colors: (fill: UInt32, ink: UInt32)) {
            if number > 0 { out.append((text, colors.fill, colors.ink)) }
        }
        add(counts.needYou, "\(counts.needYou) need\(counts.needYou == 1 ? "s" : "") you", CodeBucketBadgeColors.needYou)
        add(counts.commands, "▶ \(counts.commands)", CodeBucketBadgeColors.commands)
        add(counts.files, "⤓ \(counts.files)", CodeBucketBadgeColors.files)
        add(counts.finishedNew, "✓ \(counts.finishedNew) new", CodeBucketBadgeColors.finished)
        add(counts.warnings, "⚠ \(counts.warnings)", CodeBucketBadgeColors.warnings)
        return out
    }

    /// "Delete “Toy Cube”? 3 monitors move to Unsorted. No window is closed." (one monitor "moves"; none: no middle).
    static func deleteQuestion(name: String, monitors: Int) -> String {
        let shown = CodePlainText.line(name, limit: 40) ?? "bucket"
        let middle: String
        switch monitors {
        case 0: middle = ""
        case 1: middle = " 1 monitor moves to Unsorted."
        default: middle = " \(monitors) monitors move to Unsorted."
        }
        return "Delete “\(shown)”?\(middle) No window is closed."
    }

    /// "Bucket Toy Cube, 4 sessions, 2 running, 1 needs you, 3 commands, 1 file, 2 new, 1 warning".
    static func accessibilityLabel(_ section: CodeBucketSection) -> String {
        let c = section.counts
        var parts = ["Bucket \(name(section))", c.monitors == 1 ? "1 session" : "\(c.monitors) sessions"]
        if c.running > 0 { parts.append("\(c.running) running") }
        if c.needYou > 0 { parts.append("\(c.needYou) need\(c.needYou == 1 ? "s" : "") you") }
        if c.commands > 0 { parts.append(c.commands == 1 ? "1 command" : "\(c.commands) commands") }
        if c.files > 0 { parts.append(c.files == 1 ? "1 file" : "\(c.files) files") }
        if c.finishedNew > 0 { parts.append("\(c.finishedNew) new") }
        if c.warnings > 0 { parts.append(c.warnings == 1 ? "1 warning" : "\(c.warnings) warnings") }
        if section.bucket.folded { parts.append("folded") }
        return parts.joined(separator: ", ")
    }

    // MARK: Layout (pure)

    static func layout(_ section: CodeBucketSection, width: CGFloat, confirming: Bool) -> Layout {
        let band = CGRect(x: 0, y: 0, width: width, height: height - lineThickness)
        let mid = band.midY
        let swatch = CGRect(x: swatchInset, y: (mid - swatchSide / 2).rounded(), width: swatchSide, height: swatchSide)
        var right = width
        var delete: CGRect?
        if !section.bucket.isUnsorted {
            delete = CGRect(x: right - buttonSide, y: (mid - buttonSide / 2).rounded(), width: buttonSide, height: buttonSide)
            right -= buttonSide + 2
        }
        let fold = CGRect(x: right - buttonSide, y: (mid - buttonSide / 2).rounded(), width: buttonSide, height: buttonSide)
        right = fold.minX - 8
        let nameText = name(section)
        let nameLine = CodeMonitorFonts.lineHeight(nameFont)
        let nameWidth = min(nameMax, ceil((nameText as NSString).size(withAttributes: [.font: nameFont]).width))
        let metaText = meta(section.counts)
        let metaLine = CodeMonitorFonts.lineHeight(metaFont)
        let metaWidth = ceil((metaText as NSString).size(withAttributes: [.font: metaFont]).width)
        // The name gives way (down to 60 pt) before the count does.
        let nameRoom = max(60, right - (swatch.maxX + 8) - 8 - metaWidth)
        let name = CGRect(x: swatch.maxX + 8, y: (mid - nameLine / 2).rounded(), width: min(nameWidth, nameRoom), height: nameLine)
        let meta = CGRect(x: name.maxX + 8, y: (mid - metaLine / 2).rounded(), width: min(metaWidth, max(0, right - name.maxX - 8)),
                          height: metaLine)
        var x = meta.maxX + 10
        var placed: [Badge] = []
        for badge in badges(section.counts) {
            let textWidth = ceil((badge.text as NSString).size(withAttributes: [.font: badgeFont]).width)
            let rect = CGRect(x: x, y: (mid - badgeHeight / 2).rounded(), width: textWidth + 14, height: badgeHeight)
            guard rect.maxX <= right else { break }
            placed.append(Badge(text: badge.text, fill: badge.fill, ink: badge.ink, rect: rect))
            x = rect.maxX + 5
        }
        var out = Layout(swatch: swatch, name: name, meta: meta, badges: placed, fold: fold, delete: delete, question: nil,
                         keep: nil, confirm: nil)
        guard confirming, !section.bucket.isUnsorted else { return out }
        let buttonHeight: CGFloat = 20
        let deleteWidth = ceil(("Delete" as NSString).size(withAttributes: [.font: CodeMonitorFonts.button]).width) + 20
        let keepWidth = ceil(("Keep" as NSString).size(withAttributes: [.font: CodeMonitorFonts.button]).width) + 20
        let confirm = CGRect(x: width - deleteWidth, y: (mid - buttonHeight / 2).rounded(), width: deleteWidth, height: buttonHeight)
        let keep = CGRect(x: confirm.minX - 6 - keepWidth, y: confirm.minY, width: keepWidth, height: buttonHeight)
        out.question = CGRect(x: swatch.maxX + 8, y: (mid - metaLine / 2).rounded(), width: max(0, keep.minX - 8 - swatch.maxX - 8),
                              height: metaLine)
        out.keep = keep
        out.confirm = confirm
        out.badges = []
        out.delete = nil
        return out
    }

    /// The name as drawn (the user's words, through the plain-text renderer anyway).
    static func name(_ section: CodeBucketSection) -> String {
        CodePlainText.line(section.bucket.name, limit: CodeBucketName.maxCharacters + 1) ?? CodeBucketName.unsorted
    }

    /// The clickable parts and their areas.
    func parts() -> [(Part, CGRect)] {
        let l = layoutInfo
        if confirmingDelete, let keep = l.keep, let confirm = l.confirm { return [(.keep, keep), (.confirmDelete, confirm)] }
        var out: [(Part, CGRect)] = [(.color, l.swatch.insetBy(dx: -3, dy: -3))]
        if !section.bucket.isUnsorted, !renaming { out.append((.name, l.name)) }
        out.append((.fold, l.fold))
        if let delete = l.delete { out.append((.delete, delete)) }
        return out
    }

    func part(at point: CGPoint) -> Part? { parts().first { $0.1.contains(point) }?.0 }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let dark = ThemeColor.isDark(effectiveAppearance)
        let palette = CodeMonitorPalette(dark: dark)
        let l = layoutInfo
        let color = section.bucket.color.color(dark: dark)
        // The colour line along the bottom.
        color.withAlphaComponent(0.9).setFill()
        CGRect(x: 0, y: bounds.height - Self.lineThickness, width: bounds.width, height: Self.lineThickness).fill()
        // The colour square.
        if hoveredPart == .color || pressedPart == .color {
            palette.buttonHover.setFill()
            NSBezierPath(roundedRect: l.swatch.insetBy(dx: -3, dy: -3), xRadius: 6, yRadius: 6).fill()
        }
        color.setFill()
        NSBezierPath(roundedRect: l.swatch, xRadius: 4, yRadius: 4).fill()
        if confirmingDelete, let question = l.question, let keep = l.keep, let confirm = l.confirm {
            text(Self.deleteQuestion(name: section.bucket.name, monitors: section.counts.monitors), in: question,
                 font: Self.metaFont, color: palette.headerTitle)
            button("Keep", in: keep, fill: pressedPart == .keep ? palette.buttonHover.withAlphaComponent(0.5)
                   : (hoveredPart == .keep ? palette.buttonHover : palette.buttonFill), ink: palette.buttonText)
            let danger = CodeMonitorPalette.color(Self.dangerFill, pressedPart == .confirmDelete ? 0.8 : (hoveredPart == .confirmDelete ? 0.92 : 1))
            button("Delete", in: confirm, fill: danger, ink: CodeMonitorPalette.color(Self.dangerInk))
            return
        }
        if !renaming { text(Self.name(section), in: l.name, font: Self.nameFont, color: palette.headerTitle) }
        text(Self.meta(section.counts), in: l.meta, font: Self.metaFont, color: palette.headerFaint)
        for badge in l.badges {
            CodeMonitorPalette.color(badge.fill).setFill()
            NSBezierPath(roundedRect: badge.rect, xRadius: badge.rect.height / 2, yRadius: badge.rect.height / 2).fill()
            text(badge.text, in: badge.rect, font: Self.badgeFont, color: CodeMonitorPalette.color(badge.ink), alignment: .center)
        }
        glyph(section.bucket.folded ? "▸" : "▾", in: l.fold, part: .fold, font: Self.foldFont, palette: palette)
        if let delete = l.delete { glyph("✕", in: delete, part: .delete, font: Self.glyphFont, palette: palette) }
    }

    private func glyph(_ text: String, in rect: CGRect, part: Part, font: NSFont, palette: CodeMonitorPalette) {
        if hoveredPart == part || pressedPart == part {
            (pressedPart == part ? palette.buttonHover.withAlphaComponent(0.5) : palette.buttonHover).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        }
        self.text(text, in: rect, font: font, color: palette.headerText, alignment: .center)
    }

    private func button(_ title: String, in rect: CGRect, fill: NSColor, ink: NSColor) {
        fill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        text(title, in: rect, font: CodeMonitorFonts.button, color: ink, alignment: .center)
    }

    /// One line, vertically centred in `rect`, cut at its end.
    private func text(_ string: String, in rect: CGRect, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left) {
        guard rect.width > 2, !string.isEmpty else { return }
        drawnTexts?.append(string)
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byTruncatingTail
        let height = CodeMonitorFonts.lineHeight(font)
        let target = CGRect(x: rect.minX, y: (rect.midY - height / 2).rounded(), width: rect.width, height: height)
        (string as NSString).draw(with: target, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                  attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        for (index, (_, rect)) in parts().enumerated() {
            addTrackingArea(NSTrackingArea(rect: rect, options: [.mouseEnteredAndExited, .activeAlways], owner: self,
                                           userInfo: ["part": index]))
        }
    }

    override func mouseEntered(with event: NSEvent) {
        guard let index = event.trackingArea?.userInfo?["part"] as? Int, parts().indices.contains(index) else { return }
        hoveredPart = parts()[index].0
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoveredPart = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        pressedPart = part(at: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let pressed = pressedPart
        pressedPart = nil
        needsDisplay = true
        guard let pressed, part(at: convert(event.locationInWindow, from: nil)) == pressed else { return }
        if pressed == .name {
            if event.clickCount >= 2 { onRename?(self) }
            return
        }
        onPart?(self, pressed)
    }

    // MARK: Tooltips and accessibility

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        switch part(at: point) {
        case .color?: return "Colour"
        case .name?: return "Double-click to rename"
        case .fold?: return section.bucket.folded ? "Open" : "Fold"
        case .delete?: return "Delete bucket"
        default: return ""
        }
    }

    private func updateAccessibility() {
        setAccessibilityLabel(Self.accessibilityLabel(section))
    }

    override func accessibilityChildren() -> [Any]? {
        let name = Self.name(section)
        return parts().map { part, rect in
            let label: String
            switch part {
            case .color: label = "Change the colour of \(name)"
            case .name: label = "Rename \(name)"
            case .fold: label = section.bucket.folded ? "Open \(name)" : "Fold \(name)"
            case .delete: label = "Delete \(name)"
            case .keep: label = "Keep \(name)"
            case .confirmDelete: label = "Delete \(name) now"
            }
            let element = CodeAccessibilityButton(label: label) { [weak self] in
                guard let self else { return }
                if part == .name { self.onRename?(self) } else { self.onPart?(self, part) }
            }
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(rect)
            return element
        }
    }
}
