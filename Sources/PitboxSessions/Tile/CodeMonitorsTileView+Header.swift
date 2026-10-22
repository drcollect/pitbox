import AppKit
import PitboxKit

/// The header band: "4 in the pit · 2 on track · 1 needs you" on the left (each count only above zero; Pit all done's
/// note for a few seconds), and the buttons Hide text / Show text, Pit all done (n) and + New bucket on the right; the
/// fold "−" in the top corner on the block's window side when the block has a fold action
/// (`PitboxBlock.onFoldRequested`). Also the banner lines (session files changed, the buckets file's note, the
/// one-time pit hint) and the empty state.
extension CodeMonitorsTileView: NSViewToolTipOwner {
    enum HeaderButton: Equatable { case hideText, parkAllDone, newBucket, fold }

    struct HeaderButtonLayout: Equatable {
        var kind: HeaderButton
        var title: String
        var rect: CGRect
        var enabled: Bool
    }

    /// The tooltip of "+ New bucket" at the limit.
    static let bucketLimitTip = "20 buckets is the limit"

    var palette: CodeMonitorPalette { CodeMonitorPalette(dark: ThemeColor.isDark(effectiveAppearance)) }

    /// The words on the left keep at least this much room: on a narrow block "+ New bucket" becomes "+".
    static let headerWordsMin: CGFloat = 150

    /// The fold "−": its title and its width (a square button, the header buttons' height plus a little).
    static let foldTitle = "\u{2212}"
    static let foldWidth: CGFloat = 24

    func headerButtons() -> [HeaderButtonLayout] {
        let full = headerButtons(compact: false)
        guard let left = Self.rightButtonsMinX(full), left - wordsMinX(full) < Self.headerWordsMin else { return full }
        return headerButtons(compact: true)
    }

    /// The left edge of the right-hand buttons (the fold "−" on the left side does not count).
    static func rightButtonsMinX(_ buttons: [HeaderButtonLayout]) -> CGFloat? {
        buttons.filter { $0.kind != .fold || $0.rect.minX > 0 }.map(\.rect.minX).min()
    }

    /// Where the header's words start: after the fold "−" when it sits on the left.
    func wordsMinX(_ buttons: [HeaderButtonLayout]) -> CGFloat {
        buttons.first { $0.kind == .fold && $0.rect.minX == 0 }.map { $0.rect.maxX + 8 } ?? 0
    }

    private func headerButtons(compact: Bool) -> [HeaderButtonLayout] {
        let header = snapshot.header
        let height: CGFloat = 20
        let y = (Self.headerHeight - height) / 2
        var x = bounds.width
        var out: [HeaderButtonLayout] = []
        func add(_ kind: HeaderButton, _ title: String, enabled: Bool, width fixed: CGFloat? = nil) {
            let width = fixed ?? ceil((title as NSString).size(withAttributes: [.font: CodeMonitorFonts.button]).width) + 20
            x -= width
            out.append(HeaderButtonLayout(kind: kind, title: title, rect: CGRect(x: x, y: y, width: width, height: height), enabled: enabled))
            x -= 8
        }
        let foldSide = foldButtonSide?()
        if foldSide == .left {
            out.append(HeaderButtonLayout(kind: .fold, title: Self.foldTitle,
                                          rect: CGRect(x: 0, y: y, width: Self.foldWidth, height: height), enabled: true))
        } else if foldSide == .right {
            add(.fold, Self.foldTitle, enabled: true, width: Self.foldWidth)
        }
        add(.newBucket, compact ? "+" : "+ New bucket", enabled: header.canCreateBucket)
        add(.parkAllDone, header.parkAllDone > 0 ? "Pit all done (\(header.parkAllDone))" : "Pit all done", enabled: header.parkAllDone > 0)
        add(.hideText, header.hideText ? "Show text" : "Hide text", enabled: !snapshot.monitors.isEmpty || header.hideText)
        return out
    }

    /// The header's words: "4 in the pit", "2 on track", "1 needs you" (each only above zero; the last in the attention
    /// colour), or Pit all done's note while it shows. With buckets and nothing to show: the empty
    /// state's title ("No Code pop-outs"), as the buckets take the place of the empty state.
    func headerWords() -> [(text: String, attention: Bool, faint: Bool)] {
        let header = snapshot.header
        if let note = header.note { return [(note, false, false)] }
        var out: [(String, Bool, Bool)] = []
        if header.parked > 0 { out.append(("\(header.parked) in the pit", false, false)) }
        if header.onDesk > 0 { out.append(("\(header.onDesk) on track", false, false)) }
        if header.needYou > 0 { out.append(("\(header.needYou) need\(header.needYou == 1 ? "s" : "") you", true, false)) }
        if out.isEmpty, snapshot.bucketMode, snapshot.monitors.isEmpty, let title = snapshot.emptyTitle { out.append((title, false, true)) }
        return out
    }

    func drawHeader() {
        let p = palette
        let buttons = headerButtons()
        let left = (Self.rightButtonsMinX(buttons) ?? bounds.width) - 10
        let start = wordsMinX(buttons) + 2
        let line = NSMutableAttributedString()
        for (index, word) in headerWords().enumerated() {
            let color = word.attention ? p.attention : (word.faint ? p.headerFaint : p.headerText)
            line.append(NSAttributedString(string: (index == 0 ? "" : " · ") + word.text,
                                           attributes: [.font: CodeMonitorFonts.headerDetail, .foregroundColor: color]))
        }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
        let height = CodeMonitorFonts.lineHeight(CodeMonitorFonts.header)
        line.draw(with: CGRect(x: start, y: (Self.headerHeight - height) / 2, width: max(0, left - start), height: height),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        for button in buttons {
            let fill: NSColor
            if !button.enabled {
                fill = p.buttonFill.withAlphaComponent(0.08)
            } else if pressedHeader == button.kind {
                fill = p.buttonHover.withAlphaComponent(0.5)
            } else if hoveredHeader == button.kind {
                fill = p.buttonHover
            } else {
                fill = p.buttonFill
            }
            fill.setFill()
            NSBezierPath(roundedRect: button.rect, xRadius: button.rect.height / 2, yRadius: button.rect.height / 2).fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: CodeMonitorFonts.button,
                                                             .foregroundColor: button.enabled ? p.buttonText : p.buttonDisabledText]
            let size = (button.title as NSString).size(withAttributes: attributes)
            (button.title as NSString).draw(at: CGPoint(x: button.rect.midX - size.width / 2, y: button.rect.midY - size.height / 2),
                                            withAttributes: attributes)
        }
    }

    /// The banner lines: the source's (session files changed) and the buckets file's note in the attention colour, and
    /// the one-time pit hint in the header's text colour.
    func drawBanner() {
        for (index, text) in bannerLines.enumerated() {
            let rect = CGRect(x: 2, y: Self.headerHeight + CGFloat(index) * Self.bannerHeight, width: bounds.width - 4,
                              height: Self.bannerHeight)
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            let color = text == snapshot.hint ? palette.headerText : palette.attention
            (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                    attributes: [.font: CodeMonitorFonts.headerDetail, .foregroundColor: color,
                                                 .paragraphStyle: style])
        }
    }

    /// With Unsorted alone and no monitor: a title and a detail line in the free area (above the Ready list when it
    /// shows; the list follows the buckets).
    func drawEmpty() {
        guard let title = snapshot.emptyTitle else { return }
        let p = palette
        var area = contentFrame.finiteInset(dx: 16, dy: 0)
        if let ready = readyAccessory, !ready.isHidden, !content.isHidden {
            let listTop = contentFrame.minY + ready.frame.minY   // the list's frame is in the scrolled content's space
            area = CGRect(x: area.minX, y: area.minY, width: area.width, height: max(0, min(area.maxY, listTop) - area.minY))
        }
        let titleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
        let detailFont = NSFont.systemFont(ofSize: 12.5)
        let titleHeight = CodeMonitorFonts.lineHeight(titleFont)
        let detailHeight = snapshot.emptyDetail == nil ? 0 : CodeMonitorFonts.lineHeight(detailFont) * 2
        let block = titleHeight + 4 + detailHeight
        guard area.height >= block else { return }   // too little room above the list, or scrolled away under the header
        var y = max(area.minY, (area.midY - block / 2 - area.height * 0.06).rounded())
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        center.lineBreakMode = .byWordWrapping
        (title as NSString).draw(with: CGRect(x: area.minX, y: y, width: area.width, height: titleHeight),
                                 options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                 attributes: [.font: titleFont, .foregroundColor: p.headerTitle, .paragraphStyle: center])
        y += titleHeight + 4
        if let detail = snapshot.emptyDetail {
            (detail as NSString).draw(with: CGRect(x: area.minX, y: y, width: area.width, height: detailHeight),
                                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                      attributes: [.font: detailFont, .foregroundColor: p.headerFaint, .paragraphStyle: center])
        }
    }

    func headerButton(at point: CGPoint) -> HeaderButtonLayout? {
        headerButtons().first { $0.rect.contains(point) }
    }

    func activateHeader(_ kind: HeaderButton) {
        switch kind {
        case .hideText:
            closePeek()
            model.toggleHideText()
        case .parkAllDone:
            model.parkAllDone()
        case .newBucket:
            startNewBucket()
        case .fold:
            closePeek()
            onFold?()
        }
    }

    func accessibilityLabel(for kind: HeaderButton) -> String {
        switch kind {
        case .hideText: return snapshot.header.hideText ? "Show monitor text" : "Hide monitor text"
        case .parkAllDone: return snapshot.header.parkAllDone > 0 ? "Pit all done, \(snapshot.header.parkAllDone) windows" : "Pit all done, none"
        case .newBucket: return snapshot.header.canCreateBucket ? "New bucket" : "New bucket, off: \(Self.bucketLimitTip)"
        case .fold: return "Fold \(AppIdentity.displayName)"
        }
    }

    /// The header buttons' tooltips: "+ New bucket" at the limit, and its short form "+".
    func headerToolTip(_ button: HeaderButtonLayout) -> String? {
        if button.kind == .fold { return "Fold \(AppIdentity.displayName) (the rail keeps the counts)" }
        guard button.kind == .newBucket else { return nil }
        if !button.enabled { return Self.bucketLimitTip }
        return button.title == "+" ? "New bucket" : nil
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        headerButton(at: point).flatMap(headerToolTip) ?? ""
    }
}
