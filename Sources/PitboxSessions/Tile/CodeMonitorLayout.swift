import AppKit

/// The parts of one monitor (the original design's look): bezel, screen, LED, stand
/// and foot, and where each line goes, in the monitor's own flipped coordinates. Pure (fonts measure without a window),
/// so tests check every size.
///
/// - Large (219 pt): headline; nickname and the window chip; the TL;DR, whose last line becomes "Now:" while working;
///   the Ask line, which takes TL;DR lines from the bottom; the offer or result line; the bottom bar. TL;DR lines give
///   way first when the screen is short.
/// - Medium (150 pt): headline; one line ("Now:" while working, else the TL;DR); the offer or result line; the bottom
///   bar. No nickname, Ask line or chip: the glow and the state word say it, the peek has the rest.
/// - Small (104 pt): headline on up to two lines; one line (a run's result, "▶ 2", "⤓ 1", else the state word); an
///   18 pt offer badge on the corner.
/// - Medium and small draw a 3 pt progress bar while working with todos; every size shows a spinner while a park or
///   restore is in flight.
struct CodeMonitorLayout: Equatable {
    var bezel: CGRect
    var screen: CGRect
    /// The screen minus its padding: where text goes.
    var content: CGRect
    var led: CGRect
    var neck: CGRect
    var base: CGRect
    /// "A · Claude" beside the foot of a large monitor, only with profile marks.
    var profileLabel: CGRect?
    var bezelRadius: CGFloat
    var screenRadius: CGFloat

    var headline: CGRect
    var headlineLines: Int
    var nickname: CGRect?
    /// The window chip ("in the pit 12 min") of a large monitor; on medium and small only a failure, at the bottom bar.
    var chip: CGRect?
    /// Where the spinner of an operation in flight goes.
    var spinner: CGRect
    var tldr: CGRect?
    var tldrLines: Int
    var now: CGRect?
    var ask: CGRect?
    var askLines: Int
    /// The offer line's pill (large, medium).
    var offer: CGRect?
    /// A small monitor's 18 pt offer badge.
    var pip: CGRect?
    /// A small monitor's one line.
    var compact: CGRect?
    /// The 3 pt progress bar (medium, small).
    var progress: CGRect?
    /// The run line (large: under "Now:"; medium: the line under the headline) and a large monitor's bar.
    var run: CGRect? = nil
    var runBar: CGRect? = nil
    /// The bottom bar (large, medium); a slim row's words on the right.
    var status: CGRect?
    /// A slim row's 3 pt profile stripe (only with profile marks).
    var stripe: CGRect?
    /// Where each of the item's marks goes, in `item.marks`' order (`.zero` for one that does not fit).
    var marks: [CGRect] = []
    /// The orange warning line (large: under the nickname line; medium: in place of the one body line).
    var warning: CGRect?

    struct Metrics {
        var footHeight: CGFloat
        var bezelPad: CGFloat
        var bezelBottom: CGFloat
        var bezelRadius: CGFloat
        var screenRadius: CGFloat
        var padX: CGFloat
        var padTop: CGFloat
        var padBottom: CGFloat
        var led: CGFloat
        var neck: CGSize
        var base: CGSize
        var offerHeight: CGFloat
    }

    static func metrics(_ size: CodeMonitorSize) -> Metrics {
        switch size {
        case .large:
            return Metrics(footHeight: 22, bezelPad: 6, bezelBottom: 14, bezelRadius: 10, screenRadius: 5, padX: 10, padTop: 8,
                           padBottom: 6, led: 7, neck: CGSize(width: 30, height: 8), base: CGSize(width: 62, height: 4), offerHeight: 19)
        case .medium:
            return Metrics(footHeight: 16, bezelPad: 5, bezelBottom: 11, bezelRadius: 8, screenRadius: 4, padX: 8, padTop: 6,
                           padBottom: 5, led: 6, neck: CGSize(width: 24, height: 7), base: CGSize(width: 48, height: 3), offerHeight: 18)
        case .small:
            return Metrics(footHeight: 10, bezelPad: 4, bezelBottom: 9, bezelRadius: 7, screenRadius: 3, padX: 7, padTop: 5,
                           padBottom: 5, led: 5, neck: CGSize(width: 14, height: 4), base: CGSize(width: 28, height: 3), offerHeight: 0)
        }
    }

    static func compute(_ item: CodeMonitorItem, size: CodeMonitorSize, bounds: CGRect, showsProfile: Bool) -> CodeMonitorLayout {
        // A first layout can come at zero or odd sizes (SwiftUI hosts the block before it has its frame): every rect
        // stays finite (LayoutGeometry.swift).
        let bounds = bounds.finiteOrZero
        let m = metrics(size)
        let bezel = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: max(20, bounds.height - m.footHeight)).integral
        let screen = CGRect(x: bezel.minX + m.bezelPad, y: bezel.minY + m.bezelPad, width: max(1, bezel.width - 2 * m.bezelPad),
                            height: max(1, bezel.height - m.bezelPad - m.bezelBottom))
        let content = screen.finiteInset(dx: m.padX, dy: 0)
            .divided(atDistance: m.padTop, from: .minYEdge).remainder
            .divided(atDistance: m.padBottom, from: .maxYEdge).remainder
        let led = CGRect(x: bezel.maxX - m.bezelPad - m.led - 3, y: screen.maxY + (m.bezelBottom - m.led) / 2, width: m.led, height: m.led)
        let neck = CGRect(x: (bezel.midX - m.neck.width / 2).rounded(), y: bezel.maxY, width: m.neck.width, height: m.neck.height)
        let base = CGRect(x: (bezel.midX - m.base.width / 2).rounded(), y: neck.maxY, width: m.base.width, height: m.base.height)
        var label: CGRect?
        if showsProfile, size == .large {
            let height = CodeMonitorFonts.lineHeight(CodeMonitorFonts.footLabel)
            let footMid = bezel.maxY + m.footHeight / 2
            label = CGRect(x: bezel.minX + 4, y: (footMid - height / 2).rounded(), width: max(0, base.minX - 10 - bezel.minX - 4), height: height)
        }
        var layout = CodeMonitorLayout(bezel: bezel, screen: screen, content: content, led: led, neck: neck, base: base,
                                       profileLabel: label, bezelRadius: m.bezelRadius, screenRadius: m.screenRadius,
                                       headline: .zero, headlineLines: 1, nickname: nil, chip: nil,
                                       spinner: CGRect(x: content.maxX - 12, y: content.minY + 1, width: 12, height: 12),
                                       tldr: nil, tldrLines: 0, now: nil, ask: nil, askLines: 0, offer: nil, pip: nil, compact: nil,
                                       progress: nil, status: nil, stripe: nil)
        switch size {
        case .large: layout.placeLarge(item, m)
        case .medium: layout.placeMedium(item, m)
        case .small: layout.placeSmall(item)
        }
        layout.placeMarks(item, size: size, m)
        return layout
    }

    // MARK: Marks (the slot other features fill: `CodeMonitorMark`)

    /// A corner dot on the bezel's top-left corner; pills on the bezel's bottom bar from the left, as many as fit left
    /// of the LED (large ones with their words, medium and small with the short form).
    private mutating func placeMarks(_ item: CodeMonitorItem, size: CodeMonitorSize, _ m: Metrics) {
        guard !item.marks.isEmpty else { return }
        let pillHeight: CGFloat = size == .small ? 14 : 16
        var x = bezel.minX + m.bezelPad + 1
        let y = (bezel.maxY - m.bezelBottom / 2 - pillHeight / 2).rounded()
        marks = item.marks.map { mark in
            switch mark.place {
            case .cornerDot:
                return CGRect(x: bezel.minX, y: bezel.minY, width: Self.cornerDot, height: Self.cornerDot)
            case .footPill:
                let words = size == .large ? mark.text : mark.short
                let font = size == .small ? CodeMonitorFonts.markSmall : CodeMonitorFonts.mark
                let width = max(pillHeight, ceil((words as NSString).size(withAttributes: [.font: font]).width) + 10)
                guard x + width <= led.minX - 6 else { return .zero }
                defer { x += width + 4 }
                return CGRect(x: x, y: y, width: width, height: pillHeight)
            }
        }
    }

    /// The unread-style corner dot's side (an 11 pt white dot).
    static let cornerDot: CGFloat = 11

    // MARK: Large

    private mutating func placeLarge(_ item: CodeMonitorItem, _ m: Metrics) {
        let headLine = CodeMonitorFonts.lineHeight(CodeMonitorFonts.headline(.large))
        let bodyLine = CodeMonitorFonts.lineHeight(CodeMonitorFonts.body)
        let statusLine = CodeMonitorFonts.lineHeight(CodeMonitorFonts.status)
        let width = content.width
        var y = content.minY
        headline = CGRect(x: content.minX, y: y, width: width, height: headLine)
        y = headline.maxY + 2
        let bar = CGRect(x: content.minX, y: content.maxY - statusLine, width: width, height: statusLine)
        status = bar

        // Nickname and chip on one line.
        let lineHeight = max(CodeMonitorFonts.lineHeight(CodeMonitorFonts.mono), 17)
        let chipText = item.chip as NSString
        let chipWidth = item.chip.isEmpty && !item.busy ? 0
            : min(width * 0.62, ceil(chipText.size(withAttributes: [.font: CodeMonitorFonts.chip]).width) + (item.busy ? 30 : 14))
        if chipWidth > 0 || (!item.textHidden && item.nickname != nil) {
            if chipWidth > 0 { chip = CGRect(x: content.maxX - chipWidth, y: y, width: chipWidth, height: lineHeight) }
            if !item.textHidden, item.nickname != nil {
                nickname = CGRect(x: content.minX, y: y, width: max(0, width - (chipWidth > 0 ? chipWidth + 8 : 0)), height: lineHeight)
            }
            spinner = CGRect(x: (chip?.minX ?? content.maxX - 24) + 6, y: y + (lineHeight - 12) / 2, width: 12, height: 12)
            y += lineHeight + 4
        }

        if item.warningLine != nil, !item.textHidden {
            let height = CodeMonitorWarningLine.lineHeight
            warning = CGRect(x: content.minX, y: y, width: width, height: height)
            y += height + 2
        }
        var bodyBottom = bar.minY - 3
        if item.offer != nil || item.resultLine != nil, !item.textHidden {
            offer = CGRect(x: content.minX - 3, y: bar.minY - 4 - m.offerHeight, width: width + 6, height: m.offerHeight)
            bodyBottom = (offer?.minY ?? bodyBottom) - 3
        }
        guard !item.textHidden else { return }
        // TL;DR up to 3 lines; "Now:" and the run line take the last ones while running; the Ask line (1-2) takes lines
        // from the bottom.
        let runBarRoom: CGFloat = item.runLine?.large != nil && item.runLine?.fraction != nil ? 5 : 0
        let available = max(0, min(3, LayoutCount.floor((bodyBottom - runBarRoom - y) / bodyLine)))
        guard available > 0 else { return }
        var remaining = available
        if let ask = item.ask {
            askLines = min(2, Self.lines(ask, CodeMonitorFonts.body, width: width), remaining)
            remaining -= askLines
        }
        let nowLines = item.now != nil && remaining > 0 ? 1 : 0
        remaining -= nowLines
        let runLines = item.runLine?.large != nil && remaining > 0 ? 1 : 0
        remaining -= runLines
        if let tldr = item.tldr, remaining > 0 { tldrLines = min(remaining, Self.lines(tldr, CodeMonitorFonts.body, width: width)) }
        if tldrLines > 0 {
            tldr = CGRect(x: content.minX, y: y, width: width, height: bodyLine * CGFloat(tldrLines))
            y += bodyLine * CGFloat(tldrLines)
        }
        if nowLines > 0 {
            now = CGRect(x: content.minX, y: y, width: width, height: bodyLine)
            y += bodyLine
        }
        if runLines > 0 {
            run = CGRect(x: content.minX, y: y, width: width, height: bodyLine)
            y += bodyLine
            if runBarRoom > 0 {
                runBar = CGRect(x: content.minX, y: y + 1, width: width, height: 3)
                y += runBarRoom
            }
        }
        if askLines > 0 { ask = CGRect(x: content.minX, y: y, width: width, height: bodyLine * CGFloat(askLines)) }
    }

    // MARK: Medium

    private mutating func placeMedium(_ item: CodeMonitorItem, _ m: Metrics) {
        let headLine = CodeMonitorFonts.lineHeight(CodeMonitorFonts.headline(.medium))
        let bodyLine = CodeMonitorFonts.lineHeight(CodeMonitorFonts.body)
        let statusLine = CodeMonitorFonts.lineHeight(CodeMonitorFonts.status)
        let width = content.width
        let busyRoom: CGFloat = item.busy ? 18 : 0
        headline = CGRect(x: content.minX, y: content.minY, width: width - busyRoom, height: headLine)
        spinner = CGRect(x: content.maxX - 12, y: content.minY + (headLine - 12) / 2, width: 12, height: 12)
        let bar = CGRect(x: content.minX, y: content.maxY - statusLine, width: width, height: statusLine)
        status = bar
        // A failure of the window side replaces the right part of the bottom bar for a while.
        if item.chipIsProblem {
            let chipWidth = min(width * 0.6, ceil((item.chip as NSString).size(withAttributes: [.font: CodeMonitorFonts.chip]).width))
            chip = CGRect(x: content.maxX - chipWidth, y: bar.minY, width: chipWidth, height: bar.height)
            status = CGRect(x: bar.minX, y: bar.minY, width: max(0, width - chipWidth - 8), height: bar.height)
        }
        var bottom = bar.minY - 3
        if item.offer != nil || item.resultLine != nil, !item.textHidden {
            offer = CGRect(x: content.minX - 3, y: bar.minY - 3 - m.offerHeight, width: width + 6, height: m.offerHeight)
            bottom = (offer?.minY ?? bottom) - 3
        }
        let lineY = headline.maxY + 2
        if let fraction = item.progress, fraction >= 0 {
            progress = CGRect(x: content.minX, y: min(bottom - 3, lineY + bodyLine + 3), width: width, height: 3)
        }
        guard !item.textHidden, lineY + bodyLine <= bottom + 1 else { return }
        // One body line: the warning first (trouble), then the run line, "Now:", the TL;DR.
        if item.warningLine != nil {
            warning = CGRect(x: content.minX, y: lineY, width: width, height: bodyLine)
        } else if item.runLine?.medium != nil {
            run = CGRect(x: content.minX, y: lineY, width: width, height: bodyLine)
        } else if item.now != nil {
            now = CGRect(x: content.minX, y: lineY, width: width, height: bodyLine)
        } else if item.tldr != nil {
            tldr = CGRect(x: content.minX, y: lineY, width: width, height: bodyLine)
            tldrLines = 1
        }
    }

    // MARK: Small

    private mutating func placeSmall(_ item: CodeMonitorItem) {
        let headFont = CodeMonitorFonts.headline(.small)
        let headLine = CodeMonitorFonts.lineHeight(headFont)
        let line = CodeMonitorFonts.lineHeight(CodeMonitorFonts.status)
        let width = content.width
        let pipSide: CGFloat = 18
        if item.pip != nil {
            pip = CGRect(x: screen.maxX - pipSide - 3, y: screen.minY + 3, width: pipSide, height: pipSide)
        }
        let corner: CGFloat = (item.pip != nil || item.busy) ? pipSide + 2 : 0
        spinner = CGRect(x: content.maxX - 12, y: content.minY + 1, width: 12, height: 12)
        let room = content.height - line - 4
        headlineLines = max(1, min(2, Self.lines(item.headline, headFont, width: width - corner), LayoutCount.floor(room / headLine)))
        headline = CGRect(x: content.minX, y: content.minY, width: width - corner, height: headLine * CGFloat(headlineLines))
        compact = CGRect(x: content.minX, y: content.maxY - line, width: width, height: line)
        if let fraction = item.progress, fraction >= 0 {
            progress = CGRect(x: content.minX, y: (compact?.minY ?? content.maxY) - 6, width: width, height: 3)
        }
    }

    /// How many lines `text` takes at `width` (word wrapping).
    static func lines(_ text: String, _ font: NSFont, width: CGFloat) -> Int {
        guard width > 4, !text.isEmpty else { return text.isEmpty ? 0 : 1 }
        let bounds = (text as NSString).boundingRect(with: CGSize(width: width, height: 10_000),
                                                     options: [.usesLineFragmentOrigin], attributes: [.font: font])
        // A quarter line of slack: the measured height is a hair over N lines when line fragments round up.
        return max(1, LayoutCount.ceil(bounds.height / CodeMonitorFonts.lineHeight(font) - 0.25))
    }
}
