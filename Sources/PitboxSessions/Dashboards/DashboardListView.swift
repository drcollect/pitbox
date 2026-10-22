import AppKit
import PitboxKit

/// One row of the dashboards list.
struct DashboardListRow: Equatable, Sendable {
    var sessionID: String
    /// The session's local index (`#3` in logs).
    var index: Int
    var state: CodeSessionState
    var stateWord: String
    /// Session text, already through the plain-text renderer.
    var headline: String
    /// "dash.example.com/dash/polar-shore/ · updated 23:14"; "dashboard · …" with Hide text.
    var detail: String
    /// The full address (none with Hide text).
    var tooltip: String?
    /// Sessions active only on their own (no input of the user's) get no Open button: no open button from a session
    /// the user has not used.
    var canOpen: Bool
}

/// The list's rows from the followed sessions, in the order the caller passes them (bucket order, then the order
/// inside). Pure.
enum DashboardList {
    /// The rows, with Hide text for all of them or none.
    static func rows(_ sessions: [CodeSessionSnapshot], ownActivityOnly: Set<String>, hideText: Bool,
                     clock: CodeClockFormat) -> [DashboardListRow] {
        rows(sessions, ownActivityOnly: ownActivityOnly, hidden: { _ in hideText }, clock: clock)
    }

    /// The rows; `hidden` says per session whether its text is hidden (Hide text, or `showText` false for its copy):
    /// its address then reads "dashboard" and it has no tooltip; the headline stays.
    static func rows(_ sessions: [CodeSessionSnapshot], ownActivityOnly: Set<String>, hidden: (CodeSessionSnapshot) -> Bool,
                     clock: CodeClockFormat) -> [DashboardListRow] {
        sessions.compactMap { session in
            guard let dashboard = session.dashboard else { return nil }
            let headline = CodePlainText.line(session.headline, limit: 160) ?? CodePlainText.line(session.title, limit: 160)
                ?? "Untitled session"
            let hideText = hidden(session)
            return DashboardListRow(sessionID: session.id, index: session.index, state: session.state,
                                    stateWord: CodePlainText.line(session.stateWord, limit: 40) ?? session.state.word,
                                    headline: headline,
                                    detail: DashboardWords.listLine(dashboard, hideText: hideText, clock: clock),
                                    tooltip: hideText ? nil : DashboardWords.tooltip(dashboard),
                                    canOpen: !ownActivityOnly.contains(session.id))
        }
    }

    /// "Dashboards · 6".
    static func title(count: Int) -> String { "Dashboards · \(count)" }
}

/// The dashboards list: a panel drawn inside the block like the peek (opaque, dark in both appearances, 12 pt corners,
/// a shadow), one 44 pt row per followed session with a dashboard: the state dot and word, the headline, the address
/// with "updated 23:14", and **Open** (an armed `DashboardButtonView`, `onOpen` with the session id). The summary band
/// shows it when "▦ N dashboards" in the summary line is clicked and closes it on a click outside, Escape or the block
/// hiding. Taller content scrolls. It never takes the keyboard; VoiceOver labels hold no session text.
final class DashboardListView: NSView {
    var rows: [DashboardListRow] {
        didSet { if rows != oldValue { relayout() } }
    }

    /// Open was clicked (armed) on the row of this session id.
    var onOpen: ((String) -> Void)?
    /// Tests: every string drawn, and the buttons' clock and pointer.
    var drawnTexts: [String]?
    var buttonClock: () -> TimeInterval = { MonotonicClock.now() } {
        didSet { for button in buttons.values { button.clock = buttonClock } }
    }

    static let padding: CGFloat = 13
    static let titleHeight: CGFloat = 26
    static let rowHeight: CGFloat = 44
    static let cornerRadius: CGFloat = 12

    private(set) var buttons: [String: DashboardButtonView] = [:]
    private(set) var scrollOffset: CGFloat = 0

    init(rows: [DashboardListRow], frame: CGRect) {
        self.rows = rows
        super.init(frame: frame)
        wantsLayer = true
        shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
            shadow.shadowBlurRadius = 18
            shadow.shadowOffset = CGSize(width: 0, height: -6)
            return shadow
        }()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Dashboards")
        relayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The height that shows every row (the summary band caps it at the block's room; the rest scrolls).
    static func preferredHeight(rows: Int) -> CGFloat {
        padding + titleHeight + CGFloat(max(1, rows)) * rowHeight + padding
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { relayout() }
    }

    private var listArea: CGRect {
        CGRect(x: 0, y: Self.padding + Self.titleHeight, width: bounds.width,
               height: max(0, bounds.height - Self.padding - Self.titleHeight - Self.padding / 2))
    }

    private var maxScrollOffset: CGFloat { max(0, CGFloat(rows.count) * Self.rowHeight - listArea.height) }

    /// The rect of row `index` at the current scroll.
    func rowRect(_ index: Int) -> CGRect {
        CGRect(x: Self.padding, y: listArea.minY + CGFloat(index) * Self.rowHeight - scrollOffset,
               width: bounds.width - 2 * Self.padding, height: Self.rowHeight)
    }

    private func relayout() {
        scrollOffset = min(max(0, scrollOffset), maxScrollOffset)
        var kept: [String: DashboardButtonView] = [:]
        for (index, row) in rows.enumerated() where row.canOpen {
            let rect = rowRect(index)
            let size = DashboardPill.size(.panel(DashboardWords.open))
            let frame = CGRect(x: rect.maxX - size.width, y: (rect.midY - size.height / 2).rounded(), width: size.width,
                               height: size.height)
            let button = buttons[row.sessionID] ?? {
                let view = DashboardButtonView(style: .panel(DashboardWords.open), tooltip: row.tooltip)
                view.clock = buttonClock
                let id = row.sessionID
                view.onOpen = { [weak self] in self?.onOpen?(id) }
                addSubview(view)
                return view
            }()
            button.toolTip = row.tooltip
            button.setAccessibilityLabel("Open dashboard, row \(index + 1)")
            // Moving re-arms the button (`setFrameOrigin`): a row that slides under the pointer never opens at once.
            button.frame = frame
            button.isHidden = !listArea.contains(CGPoint(x: frame.midX, y: frame.midY))
            kept[row.sessionID] = button
        }
        for (id, button) in buttons where kept[id] == nil { button.removeFromSuperview() }
        buttons = kept
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let radius = Self.cornerRadius
        let panel = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        ThemeColor.srgb(0x1B1E25).setFill()
        panel.fill()
        ThemeColor.srgb(0x3D4352).setStroke()
        panel.lineWidth = 1
        panel.stroke()
        drawText(DashboardList.title(count: rows.count),
                 in: CGRect(x: Self.padding, y: Self.padding, width: bounds.width - 2 * Self.padding, height: Self.titleHeight - 6),
                 font: .systemFont(ofSize: 13.5, weight: .semibold), color: 0xF3F4F6)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: listArea).addClip()
        for (index, row) in rows.enumerated() {
            let rect = rowRect(index)
            guard rect.maxY > listArea.minY, rect.minY < listArea.maxY else { continue }
            drawRow(row, in: rect, first: index == 0)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawRow(_ row: DashboardListRow, in rect: CGRect, first: Bool) {
        if !first {
            ThemeColor.srgb(0x3D4352, alpha: 0.7).setFill()
            CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 0.5).fill()
        }
        let dot = CGRect(x: rect.minX, y: rect.minY + 10, width: 9, height: 9)
        Self.drawStateDot(row.state, in: dot)
        let buttonWidth = row.canOpen ? DashboardPill.size(.panel(DashboardWords.open)).width + 10 : 0
        let wordFont = NSFont.systemFont(ofSize: 12)
        let wordWidth = min(140, ceil((row.stateWord as NSString).size(withAttributes: [.font: wordFont]).width))
        let textX = dot.maxX + 9
        let textWidth = max(20, rect.maxX - buttonWidth - wordWidth - 12 - textX)
        drawText(row.headline, in: CGRect(x: textX, y: rect.minY + 5, width: textWidth, height: 17),
                 font: .systemFont(ofSize: 13, weight: .semibold), color: 0xF3F4F6)
        drawText(row.detail, in: CGRect(x: textX, y: rect.minY + 23, width: textWidth, height: 16),
                 font: .monospacedSystemFont(ofSize: 12, weight: .regular), color: 0x9097A4, middle: true)
        drawText(row.stateWord, in: CGRect(x: rect.maxX - buttonWidth - wordWidth, y: rect.minY + 5, width: wordWidth, height: 17),
                 font: wordFont, color: 0x9097A4, alignment: .right)
    }

    /// The state dot: the monitors' LED colours (blue working, amber needs you, green review ready, white done, a
    /// white ring for done without a summary, red problem, grey unknown).
    static func drawStateDot(_ state: CodeSessionState, in rect: CGRect) {
        let color: UInt32
        switch state {
        case .working, .quietUnfinished: color = 0x4C9BFF
        case .needsYou, .maybeNeedsYou: color = 0xF2A33A
        case .reviewReady: color = 0x6FCF73
        case .done, .doneNoSummary: color = 0xF3F4F6
        case .problem: color = 0xEF5B5B
        case .unknown: color = 0x9AA1AD
        }
        if state == .doneNoSummary || state == .unknown {
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.9, dy: 0.9))
            ring.lineWidth = 1.8
            ThemeColor.srgb(color).setStroke()
            ring.stroke()
        } else {
            ThemeColor.srgb(color).setFill()
            NSBezierPath(ovalIn: rect).fill()
        }
    }

    private func drawText(_ string: String, in rect: CGRect, font: NSFont, color: UInt32, middle: Bool = false,
                          alignment: NSTextAlignment = .left) {
        guard rect.width > 2, !string.isEmpty else { return }
        drawnTexts?.append(string)
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = middle ? .byTruncatingMiddle : .byTruncatingTail
        (string as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                  attributes: [.font: font, .foregroundColor: ThemeColor.srgb(color), .paragraphStyle: style])
    }

    // MARK: Scrolling

    override func scrollWheel(with event: NSEvent) {
        guard maxScrollOffset > 0 else { return super.scrollWheel(with: event) }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
        scroll(to: scrollOffset - delta)
    }

    /// Scrolls the rows (buttons move, so they arm again).
    func scroll(to offset: CGFloat) {
        let next = min(max(0, offset), maxScrollOffset)
        guard next != scrollOffset else { return }
        scrollOffset = next
        relayout()
    }
}
