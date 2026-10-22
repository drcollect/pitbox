import AppKit

/// A slim row (`look: "rows"`): the block's width × 36 pt. Left to right: a 3 pt profile stripe (only with more than
/// one copy), the LED, the headline (13 pt semibold, cut), the "▶ Run…" or "⤓ Fetch…" button when there is an offer,
/// the marks' pills (the dashboard's "▦"), and on the right the short run text or "state · age" (12 pt grey). A corner
/// dot (the unread dot) sits on the top-left corner. Pure, like the monitor sizes.
extension CodeMonitorLayout {
    static let rowPadX: CGFloat = 10
    static let rowRadius: CGFloat = 8
    static let rowLED: CGFloat = 8
    static let rowButtonHeight: CGFloat = 22

    /// The words on a row's right.
    static func rowStatus(_ item: CodeMonitorItem) -> String { item.runText ?? item.statusShort }

    static func computeRow(_ item: CodeMonitorItem, bounds: CGRect, showsProfile: Bool) -> CodeMonitorLayout {
        let row = bounds.finiteOrZero.integral
        let mid = row.midY
        var x = row.minX + rowPadX
        var stripe: CGRect?
        if showsProfile {
            stripe = CGRect(x: row.minX + 5, y: mid - 10, width: 3, height: 20)
            x += 4
        }
        let led = CGRect(x: x, y: (mid - rowLED / 2).rounded(), width: rowLED, height: rowLED)
        x = led.maxX + 8
        var right = row.maxX - rowPadX
        // The right-hand words, at most 40 % of the row.
        let statusText = rowStatus(item)
        let statusFont = CodeMonitorFonts.status
        let statusLine = CodeMonitorFonts.lineHeight(statusFont)
        let statusWidth = min(row.width * 0.4, ceil((statusText as NSString).size(withAttributes: [.font: statusFont]).width))
        let status = CGRect(x: right - statusWidth, y: (mid - statusLine / 2).rounded(), width: statusWidth, height: statusLine)
        right = status.minX - 8
        let spinner = CGRect(x: right - 12, y: mid - 6, width: 12, height: 12)
        if item.busy { right = spinner.minX - 6 }
        // Mark pills, right to left before the words; the corner dot on the row's top-left corner.
        var marks = Array(repeating: CGRect.zero, count: item.marks.count)
        for (index, mark) in item.marks.enumerated().reversed() {
            switch mark.place {
            case .cornerDot:
                marks[index] = CGRect(x: row.minX - 1, y: row.minY - 1, width: cornerDot, height: cornerDot)
            case .footPill:
                let width = max(20, ceil((mark.text as NSString).size(withAttributes: [.font: CodeMonitorFonts.mark]).width) + 12)
                guard right - width >= x + 60 else { continue }
                marks[index] = CGRect(x: right - width, y: mid - 9, width: width, height: 18)
                right -= width + 6
            }
        }
        // The offer button.
        var offer: CGRect?
        if let action = item.rowAction, item.offer != nil {
            let width = ceil((action as NSString).size(withAttributes: [.font: CodeMonitorFonts.bodyStrong]).width) + 16
            if right - width >= x + 60 {
                offer = CGRect(x: right - width, y: (mid - rowButtonHeight / 2).rounded(), width: width, height: rowButtonHeight)
                right -= width + 8
            }
        }
        let headLine = CodeMonitorFonts.lineHeight(CodeMonitorFonts.rowHeadline)
        let headline = CGRect(x: x, y: (mid - headLine / 2).rounded(), width: max(0, right - x), height: headLine)
        var layout = CodeMonitorLayout(bezel: row, screen: row, content: row.finiteInset(dx: rowPadX, dy: 0), led: led, neck: .zero,
                                       base: .zero, profileLabel: nil, bezelRadius: rowRadius, screenRadius: rowRadius,
                                       headline: headline, headlineLines: 1, nickname: nil, chip: nil, spinner: spinner,
                                       tldr: nil, tldrLines: 0, now: nil, ask: nil, askLines: 0, offer: offer, pip: nil,
                                       compact: nil, progress: nil, status: status, stripe: stripe)
        layout.marks = marks
        return layout
    }
}
