import AppKit
import PitboxKit

/// Drawing of one monitor. Everything comes from `item` and `layoutInfo`; strings are already plain text.
extension CodeMonitorView {
    typealias P = CodeMonitorPalette

    func drawMonitor() {
        let l = layoutInfo
        drawStand(l)
        // Bezel glow for Needs you and Problem, under the bezel (not while the peek covers this monitor: it
        // would bleed out around the panel).
        if let glow = item.glow, !suppressGlow {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = P.color(glow, 0.75)
            shadow.shadowBlurRadius = size == .small ? 6 : 10
            shadow.shadowOffset = .zero
            shadow.set()
            P.color(P.bezel).setFill()
            NSBezierPath(roundedRect: l.bezel.insetBy(dx: 1, dy: 1), xRadius: l.bezelRadius, yRadius: l.bezelRadius).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        // Bezel: graphite with a soft top highlight; brighter under the pointer, darker while pressed.
        let bezelPath = NSBezierPath(roundedRect: l.bezel, xRadius: l.bezelRadius, yRadius: l.bezelRadius)
        let base = isPressedScreen ? P.color(0x33363D) : (hovered ? P.color(0x434751) : P.color(P.bezel))
        base.setFill()
        bezelPath.fill()
        NSGraphicsContext.saveGraphicsState()
        bezelPath.addClip()
        NSGradient(starting: P.color(P.bezelHighlight, 0.9), ending: P.color(P.bezelHighlight, 0))?
            .draw(in: CGRect(x: l.bezel.minX, y: l.bezel.minY, width: l.bezel.width, height: min(18, l.bezel.height / 3)), angle: 90)
        NSGraphicsContext.restoreGraphicsState()
        if let glow = item.glow, !suppressGlow {
            let ring = NSBezierPath(roundedRect: l.bezel.insetBy(dx: 0.75, dy: 0.75), xRadius: l.bezelRadius, yRadius: l.bezelRadius)
            ring.lineWidth = 1.5
            P.color(glow, 0.8).setStroke()
            ring.stroke()
        }

        // Screen.
        let screenPath = NSBezierPath(roundedRect: l.screen, xRadius: l.screenRadius, yRadius: l.screenRadius)
        P.color(P.screen).setFill()
        screenPath.fill()
        NSGraphicsContext.saveGraphicsState()
        screenPath.addClip()
        if !reduceMotion(), !increaseContrast() { drawScanlines(in: l.screen) }
        let context = NSGraphicsContext.current?.cgContext
        if item.quiet {
            context?.setAlpha(0.5)
            context?.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        drawScreenContent(l)
        if item.quiet { context?.endTransparencyLayer() }
        NSGraphicsContext.restoreGraphicsState()
        if item.state == .needsYou {
            let border = NSBezierPath(roundedRect: l.screen.insetBy(dx: 0.75, dy: 0.75), xRadius: l.screenRadius, yRadius: l.screenRadius)
            border.lineWidth = 1.5
            P.color(P.amber).setStroke()
            border.stroke()
        } else if item.warningLine != nil {
            // A warned monitor's orange screen outline; Needs you's amber wins.
            CodeMonitorWarningLine.strokeOutline(screen: l.screen, radius: l.screenRadius)
        }
        if !(item.led.pulses && !reduceMotion()) { Self.drawLED(item.led, in: l.led) }
    }

    private func drawScanlines(in rect: CGRect) {
        P.color(0xFFFFFF, 0.022).setFill()
        var y = rect.minY + 1
        while y < rect.maxY {
            CGRect(x: rect.minX, y: y, width: rect.width, height: 1).fill()
            y += 3
        }
    }

    private func drawStand(_ l: CodeMonitorLayout) {
        P.color(P.stand).setFill()
        l.neck.fill()
        let baseColor = showsProfile ? P.profileColor(letter: item.profileLetter, colour: item.profileColour) : P.color(P.stand)
        baseColor.setFill()
        NSBezierPath(roundedRect: l.base, xRadius: l.base.height / 2, yRadius: l.base.height / 2).fill()
        if let rect = l.profileLabel, let label = item.profileLabel {
            let dark = ThemeColor.isDark(effectiveAppearance)
            draw(label, in: rect, font: CodeMonitorFonts.footLabel, color: CodeMonitorPalette(dark: dark).footLabel, alignment: .right)
        }
    }

    private func drawScreenContent(_ l: CodeMonitorLayout) {
        let headFont = CodeMonitorFonts.headline(size)
        draw(item.headline, in: l.headline, font: headFont, color: P.color(P.headline), lines: l.headlineLines)
        if let rect = l.nickname, let nickname = item.nickname {
            draw(nickname, in: rect, font: CodeMonitorFonts.mono, color: P.color(P.dim), verticallyCentered: true)
        }
        if let rect = l.chip { drawChip(in: rect) }
        if let rect = l.tldr, let tldr = item.tldr {
            draw(tldr, in: rect, font: CodeMonitorFonts.body, color: P.color(P.text), lines: l.tldrLines)
        }
        if let rect = l.now, let now = item.now {
            draw(now, in: rect, font: CodeMonitorFonts.mono, color: P.color(P.nowText))
        }
        if let line = item.runLine, l.run != nil || l.runBar != nil {
            CodeRunLineDrawing.draw(line, size: size == .large ? .large : .medium, textRect: l.run, barRect: l.runBar)
        }
        if let rect = l.ask, let ask = item.ask {
            draw(ask, in: rect, font: CodeMonitorFonts.body, color: P.color(P.askText), lines: l.askLines)
        }
        if let rect = l.warning, let warning = item.warningLine {
            drawnTexts?.append(warning.text)
            CodeMonitorWarningLine.draw(warning, in: rect, small: false)
        }
        if let rect = l.offer, let offer = item.offer {
            drawOffer(offer, in: rect)
        } else if let rect = l.offer, let line = item.resultLine {
            drawnTexts?.append(line.button.title)
            CodeMonitorResultLine.draw(line, in: rect, hovered: hovered, pressed: isPressedResult)
        }
        if let rect = l.pip, let pip = item.pip, !item.busy { drawPip(pip, in: rect) }
        if let rect = l.progress, let fraction = item.progress {
            CodeRunLineDrawing.drawBar(fraction: fraction, late: item.runLine?.isLate == true, in: rect)
        }
        if let rect = l.compact, item.compactTone == nil, let warning = item.warningLine {
            // A warning: "⚠ stuck" / "⚠ same file" in place of the state word on a small monitor.
            drawnTexts?.append(warning.short)
            CodeMonitorWarningLine.draw(warning, in: rect, small: true)
        } else if let rect = l.compact {
            let color = item.compactTone.map { P.color(Self.toneColor($0)) } ?? P.color(P.dim)
            draw(item.compactLine, in: rect, font: item.compactTone == nil ? CodeMonitorFonts.status : CodeMonitorFonts.bodyStrong,
                 color: color, verticallyCentered: true)
        }
        if let rect = l.status {
            draw(size == .large ? item.status : item.statusCompact, in: rect, font: CodeMonitorFonts.status, color: P.color(P.dim),
                 verticallyCentered: true)
        }
    }

    private func drawProgress(_ fraction: Double, in rect: CGRect) {
        P.color(0x22262F).setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        let done = CGRect(x: rect.minX, y: rect.minY, width: rect.width * CGFloat(min(max(fraction, 0), 1)), height: rect.height)
        guard done.width > 0.5 else { return }
        P.color(P.working).setFill()
        NSBezierPath(roundedRect: done, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
    }

    private func drawChip(in rect: CGRect) {
        let problem = item.chipIsProblem
        if size == .large {
            let pill = rect.insetBy(dx: 0, dy: 1)
            P.color(problem ? P.red : 0xFFFFFF, problem ? 0.16 : 0.08).setFill()
            NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
            let textRect = rect.insetBy(dx: 7, dy: 0).offsetBy(dx: item.busy ? 13 : 0, dy: 0)
            draw(item.chip, in: CGRect(x: textRect.minX, y: rect.minY, width: max(0, rect.maxX - 7 - textRect.minX), height: rect.height),
                 font: CodeMonitorFonts.chip, color: problem ? P.color(0xFF9C9C) : P.color(0xB9BFCA), alignment: item.busy ? .left : .center,
                 verticallyCentered: true)
        } else {
            // Medium: only a failure shows here (the peek has the window's place).
            draw(item.chip, in: rect, font: CodeMonitorFonts.chip, color: problem ? P.color(0xFF9C9C) : P.color(0xB9BFCA),
                 alignment: .right, verticallyCentered: true)
        }
    }

    static func toneColor(_ tone: CodeOfferLine.Tone) -> UInt32 {
        switch tone {
        case .offer: return P.cyan
        case .running: return P.working
        case .ok: return P.green
        case .failed: return P.red
        case .neutral: return P.grey
        }
    }

    private func drawOffer(_ offer: CodeOfferLine, in rect: CGRect) {
        let tone = Self.toneColor(offer.tone)
        let pill = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        P.color(tone, isPressedOffer ? 0.26 : (hovered ? 0.18 : 0.13)).setFill()
        pill.fill()
        pill.lineWidth = 1
        P.color(tone, 0.38).setStroke()
        NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4.5, yRadius: 4.5).stroke()
        let inner = rect.insetBy(dx: 6, dy: 0)
        let label = NSAttributedString(string: offer.text, attributes: [.font: CodeMonitorFonts.bodyStrong])
        let labelWidth = min(inner.width, ceil(label.size().width))
        draw(offer.text, in: CGRect(x: inner.minX, y: inner.minY, width: labelWidth, height: inner.height),
             font: CodeMonitorFonts.bodyStrong, color: P.color(tone), verticallyCentered: true)
        if size == .large, let detail = offer.detail, inner.width - labelWidth > 40 {
            draw(detail, in: CGRect(x: inner.minX + labelWidth + 8, y: inner.minY, width: inner.width - labelWidth - 8, height: inner.height),
                 font: CodeMonitorFonts.mono, color: P.color(P.dim), verticallyCentered: true, truncation: .byTruncatingMiddle)
        }
    }

    /// The 18 pt badge of a small monitor: ▶ or ⤓ on the offer colour.
    private func drawPip(_ pip: CodeMonitorPip, in rect: CGRect) {
        P.color(P.cyan, isPressedOffer ? 0.8 : 1).setFill()
        NSBezierPath(ovalIn: rect).fill()
        draw(pip.symbol, in: rect, font: NSFont.systemFont(ofSize: 10, weight: .bold), color: P.color(0x06171B), alignment: .center,
             verticallyCentered: true)
    }

    /// A dot (filled), a white ring, or a hollow grey ring.
    static func drawLED(_ led: CodeMonitorLED, in rect: CGRect) {
        let color = P.color(led.color)
        switch led.form {
        case .filled:
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
        case .ring:
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.9, dy: 0.9))
            ring.lineWidth = 1.8
            color.setStroke()
            ring.stroke()
        case .hollow:
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.5
            color.withAlphaComponent(0.9).setStroke()
            ring.stroke()
        }
    }

    /// Draws `string` in `rect`: `lines` lines with word wrapping and the last visible line truncated, or one line.
    func draw(_ string: String, in rect: CGRect, font: NSFont, color: NSColor, lines: Int = 1, alignment: NSTextAlignment = .left,
              verticallyCentered: Bool = false, truncation: NSLineBreakMode = .byTruncatingTail) {
        guard rect.width > 2, !string.isEmpty else { return }
        drawnTexts?.append(string)
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = lines > 1 ? .byWordWrapping : truncation
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        var target = rect
        if verticallyCentered {
            let height = CodeMonitorFonts.lineHeight(font)
            target = CGRect(x: rect.minX, y: (rect.midY - height / 2).rounded(), width: rect.width, height: height)
        }
        (string as NSString).draw(with: target, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }
}
