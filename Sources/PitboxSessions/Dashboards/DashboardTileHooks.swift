import Foundation

/// The ▦ pill on the block's monitors and slim rows, through the model's mark slot (`CodeMonitorMark`): a foot pill
/// "▦ Dashboard" on large monitors and rows, "▦" on medium and small ones, pink with dark words. The monitor view arms
/// it (0.8 s after it appears or moves, never the first press under a resting pointer) and hands a click to
/// `CodeMonitorsModel.onMarkClick`.
enum CodeDashboardMark {
    /// The mark's id in `onMarkClick`.
    static let id = "dashboard"

    /// The pill.
    static var mark: CodeMonitorMark {
        CodeMonitorMark(id: id, place: .footPill, text: DashboardWords.button, short: "▦", fill: DashboardPill.pink,
                        ink: DashboardPill.pinkText, label: "Open the dashboard", opens: true)
    }

    /// Adds the pill to the item of a session that has a dashboard (with Hide text too: it holds no session text).
    static func decorate(_ session: CodeSessionSnapshot, _ item: inout CodeMonitorItem) {
        guard session.dashboard != nil else { return }
        item.marks.append(mark)
    }
}

extension CodeMonitorsModel {
    /// The ▦ pill on every monitor and slim row of a session with a dashboard, and its click: the session's dashboard
    /// opens through `opener` (the address rebuilt from the checked handle). Clicks on other marks go on
    /// to the handler that was set before. Call once while wiring.
    func installDashboardMarks(opener: CodeDashboardOpener) {
        itemDecorators.append { session, item in CodeDashboardMark.decorate(session, &item) }
        let earlier = onMarkClick
        onMarkClick = { [weak self] sessionID, markID in
            guard markID == CodeDashboardMark.id else {
                earlier?(sessionID, markID)
                return
            }
            self?.openDashboard(sessionID: sessionID, opener: opener)
        }
    }

    /// Opens the dashboard of `sessionID` as the data side knows it now; nothing when it has none.
    @discardableResult
    func openDashboard(sessionID: String, opener: CodeDashboardOpener) -> Bool {
        guard let session = source.sessions.first(where: { $0.id == sessionID }), let dashboard = session.dashboard else {
            return false
        }
        return opener.open(dashboard, sessionIndex: session.index)
    }
}
