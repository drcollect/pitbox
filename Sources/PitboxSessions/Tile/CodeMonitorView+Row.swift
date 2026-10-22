import AppKit
import PitboxKit

/// Drawing of a slim row and of the marks other features add (`CodeMonitorMark`). A row is a dark object like a
/// monitor, in both appearances: the original design's panel colour with a hairline; Needs you and Problem draw the
/// glow's colour as its outline. Strings are already plain text.
extension CodeMonitorView {
    static let rowFill: UInt32 = 0x1B1E25
    static let rowHover: UInt32 = 0x232731
    static let rowPressed: UInt32 = 0x16191F
    static let rowLine: UInt32 = 0x2E333F

    func drawRow() {
        let l = layoutInfo
        let row = l.bezel.insetBy(dx: 0.75, dy: 0.75)
        let path = NSBezierPath(roundedRect: row, xRadius: l.bezelRadius, yRadius: l.bezelRadius)
        if let glow = item.glow, !suppressGlow {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = P.color(glow, 0.6)
            shadow.shadowBlurRadius = 6
            shadow.shadowOffset = .zero
            shadow.set()
            P.color(Self.rowFill).setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        P.color(isPressedScreen ? Self.rowPressed : (hovered ? Self.rowHover : Self.rowFill)).setFill()
        path.fill()
        path.lineWidth = item.glow != nil && !suppressGlow ? 1.5 : 1
        (item.glow.map { suppressGlow ? P.color(Self.rowLine) : P.color($0, 0.85) } ?? P.color(Self.rowLine)).setStroke()
        path.stroke()

        let context = NSGraphicsContext.current?.cgContext
        if item.quiet {
            context?.saveGState()
            context?.setAlpha(0.5)
            context?.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        if let stripe = l.stripe {
            P.profileColor(letter: item.profileLetter, colour: item.profileColour).setFill()
            NSBezierPath(roundedRect: stripe, xRadius: 1.5, yRadius: 1.5).fill()
        }
        if !(item.led.pulses && !reduceMotion()) { Self.drawLED(item.led, in: l.led) }
        draw(item.headline, in: l.headline, font: CodeMonitorFonts.rowHeadline, color: P.color(P.headline), verticallyCentered: true)
        if let rect = l.offer, let action = item.rowAction {
            let pill = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
            P.color(P.cyan, isPressedOffer ? 0.3 : (hovered ? 0.2 : 0.14)).setFill()
            pill.fill()
            P.color(P.cyan, 0.45).setStroke()
            pill.lineWidth = 1
            pill.stroke()
            draw(action, in: rect, font: CodeMonitorFonts.bodyStrong, color: P.color(P.cyan), alignment: .center,
                 verticallyCentered: true)
        }
        if let rect = l.status {
            draw(CodeMonitorLayout.rowStatus(item), in: rect, font: CodeMonitorFonts.status,
                 color: P.color(item.runLine?.isLate == true ? CodeRunLineDrawing.late : P.dim), alignment: .right,
                 verticallyCentered: true)
        }
        if item.quiet {
            context?.endTransparencyLayer()
            context?.restoreGState()
        }
    }

    /// The marks: a corner dot (white, ringed with near-black so it reads on any bezel) and pills with their words.
    func drawMarks() {
        for (index, mark) in item.marks.enumerated() where layoutInfo.marks.indices.contains(index) {
            let rect = layoutInfo.marks[index]
            guard rect != .zero else { continue }
            switch mark.place {
            case .cornerDot:
                P.color(0x0F1115).setFill()
                NSBezierPath(ovalIn: rect).fill()
                P.color(mark.fill).setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
            case .footPill:
                P.color(mark.fill).setFill()
                NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
                let words = isRow || size == .large ? mark.text : mark.short
                draw(words, in: rect, font: size == .small && !isRow ? CodeMonitorFonts.markSmall : CodeMonitorFonts.mark,
                     color: P.color(mark.ink), alignment: .center, verticallyCentered: true, truncation: .byClipping)
            }
        }
    }
}
