import AppKit
import PitboxKit

/// The summary band in the block's summary slot (`CodeMonitorsTileView.summaryAccessory`): the summary line under
/// the block header, 20 pt, gone when every count is zero, and the dashboards list, which "▦ N dashboards" opens as a
/// panel inside the block.
///
/// It observes the block model and counts the sessions the data side follows (`source.sessions`: pop-outs and the
/// watched ones). Ready items come from `readyCounts` (the Ready list's count, else a count from each snapshot), open
/// Finished items from the snapshots' finished marks unless `justFinished` is set. The panel lists the followed
/// sessions with a dashboard in the block's order (its monitors bucket by bucket, then the others), closes on a click
/// outside it, Escape (a local monitor, while the app is active), a second click on "▦ N dashboards", or whatever
/// closes the block's overlays (the block hiding or folding), and opens a dashboard only on an armed Open.
final class CodeSummaryAccessory: NSView, CodeTileAccessory {
    let lineView: CodeSummaryLineView
    private weak var model: CodeMonitorsModel?
    private let opener: CodeDashboardOpener
    private let clock: CodeClockFormat
    /// The Ready list's open Finished items over the followed sessions; nil counts the snapshots' open finished marks.
    var justFinished: (([CodeSessionSnapshot]) -> Int)?
    /// Sessions active only on their own (the followed set): their list rows have no Open, so a session the user has
    /// not used gets no open button.
    var ownActivityOnly: () -> Set<String> = { [] }
    private(set) var panel: DashboardListView?
    private var overlayGeneration: Int
    private var eventMonitor: Any?

    /// The panel's width at most (two of the block's columns, like the peek).
    static let panelWidth: CGFloat = 657

    init(model: CodeMonitorsModel, opener: CodeDashboardOpener, clock: CodeClockFormat = .system) {
        self.model = model
        self.opener = opener
        self.clock = clock
        lineView = CodeSummaryLineView()
        overlayGeneration = model.overlayGeneration
        super.init(frame: .zero)
        addSubview(lineView)
        lineView.onOpenDashboards = { [weak self] in self?.toggleDashboards() }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Running summary")
        model.observe(self) { [weak self] in self?.refresh() }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func accessoryHeight(forWidth width: CGFloat) -> CGFloat {
        lineView.line.isEmpty ? 0 : CodeSummaryLineView.height
    }

    /// VoiceOver reaches the line and, while it is open, the dashboards list (a subview of the block, not of this
    /// band: the block lists this band among its children).
    override func accessibilityChildren() -> [Any]? {
        [lineView] + (panel.map { [$0] } ?? [])
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        lineView.frame = bounds
        placePanel()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let model else { return }
        if window == nil {
            closeDashboards()
            model.stopObserving(self)
        } else {
            model.observe(self) { [weak self] in self?.refresh() }
            refresh()
        }
    }

    /// Counts again from the model (it calls this on every change).
    func refresh() {
        guard let model else { return }
        if model.overlayGeneration != overlayGeneration {
            overlayGeneration = model.overlayGeneration
            closeDashboards()
        }
        let sessions = model.source.sessions
        let counter = model.readyCounts ?? CodeReadyCounts.fromSnapshot
        let ready = sessions.reduce(0) { total, session in
            let counts = counter(session)
            return total + counts.commands + counts.files
        }
        let wasEmpty = lineView.line.isEmpty
        lineView.line = CodeSummaryLine.make(sessions: sessions, readyItems: ready, justFinished: justFinished?(sessions),
                                             now: model.now(), clock: clock)
        if wasEmpty != lineView.line.isEmpty { (superview as? CodeMonitorsTileView)?.accessoriesChanged() }
        if let panel {
            let rows = dashboardRows()
            if rows.isEmpty { closeDashboards() } else { panel.rows = rows; placePanel() }
        }
    }

    // MARK: The dashboards list

    /// The list's rows: the followed sessions with a dashboard, the block's monitors first in their order.
    func dashboardRows() -> [DashboardListRow] {
        guard let model else { return [] }
        let sessions = model.source.sessions
        var byID: [String: CodeSessionSnapshot] = [:]
        for session in sessions where byID[session.id] == nil { byID[session.id] = session }
        var ordered = model.snapshot.monitors.compactMap { byID[$0.id] }
        let placed = Set(ordered.map(\.id))
        ordered += sessions.filter { !placed.contains($0.id) }
        let hideAll = model.hideText
        return DashboardList.rows(ordered, ownActivityOnly: ownActivityOnly(), hidden: { session in
            hideAll || model.settings.showText[session.profile.letter] == false
        }, clock: clock)
    }

    /// Opens the list, or closes it when open.
    func toggleDashboards() {
        if panel != nil { closeDashboards() } else { showDashboards() }
    }

    func showDashboards() {
        guard panel == nil, let host = superview else { return }
        let rows = dashboardRows()
        guard !rows.isEmpty else { return }
        let list = DashboardListView(rows: rows, frame: .zero)
        list.onOpen = { [weak self] sessionID in
            guard let self, let model = self.model else { return }
            model.openDashboard(sessionID: sessionID, opener: self.opener)
        }
        host.addSubview(list)
        list.setAccessibilityParent(self)
        panel = list
        placePanel()
        CodeTileLog.info("dashboards list opened rows=\(rows.count)")
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) {
            [weak self] event in
            // Local monitors run on the main thread.
            let consumed = MainActor.assumeIsolated { () -> Bool in self?.handle(event) ?? false }
            return consumed ? nil : event
        }
    }

    func closeDashboards() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        guard let panel else { return }
        panel.removeFromSuperview()
        self.panel = nil
    }

    /// The panel under the summary line, as wide as two of the block's columns (or the block), as tall as its rows
    /// allow.
    private func placePanel() {
        guard let panel, let host = panel.superview else { return }
        let top = frame.maxY + 4
        let width = min(Self.panelWidth, host.bounds.width)
        let height = min(DashboardListView.preferredHeight(rows: panel.rows.count), max(80, host.bounds.height - top - 4))
        panel.frame = CGRect(x: 0, y: top, width: width, height: height).integral
    }

    /// A click outside the panel closes it (the click goes on); Escape closes it and is consumed (true).
    func handle(_ event: NSEvent) -> Bool {
        guard let panel else { return false }
        if event.type == .keyDown {
            guard event.keyCode == 53 else { return false }
            closeDashboards()
            return true
        }
        guard event.window === panel.window else {
            closeDashboards()
            return false
        }
        if panel.bounds.contains(panel.convert(event.locationInWindow, from: nil)) { return false }
        if lineView.isDashboardsButton(at: lineView.convert(event.locationInWindow, from: nil)) { return false }
        closeDashboards()
        return false
    }
}
