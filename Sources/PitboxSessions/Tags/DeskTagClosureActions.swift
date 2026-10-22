import AppKit
import Foundation
import PitboxKit

/// `DeskTagActions` for the composition root: the sheet, result and dashboard paths it already has for the Ready list,
/// as closures, and Park and Copy link done here (the window side's park; the peek's link on the general pasteboard).
/// Main thread.
@MainActor
public final class DeskTagClosureActions: DeskTagActions {
    private let parker: CodeWindowParking
    private let openOfferHandler: @MainActor (CommandOffer.ID, String, CGRect) -> Void
    private let openResultHandler: @MainActor (String, String, CGRect) -> Void
    private let openDashboardHandler: @MainActor (String) -> Void
    private let copy: @MainActor (String) -> Void

    /// - Parameters:
    ///   - parker: the window side; Park calls `perform(.park, sessionID:)`.
    ///   - openOffer: opens the sheet of an offer of a followed session (offer, session id, anchor), the Ready list's
    ///     path, so the sheet's events reach the run book and the list.
    ///   - openResult: opens a result after its click-time checks (result id, session id, anchor).
    ///   - openDashboard: opens a session's dashboard.
    ///   - copyText: puts a link on the pasteboard; by default the general pasteboard, as the block's Copy link.
    public init(parker: CodeWindowParking,
                openOffer: @escaping @MainActor (CommandOffer.ID, String, CGRect) -> Void,
                openResult: @escaping @MainActor (String, String, CGRect) -> Void,
                openDashboard: @escaping @MainActor (String) -> Void,
                copyText: @escaping @MainActor (String) -> Void = DeskTagClosureActions.copyToGeneralPasteboard) {
        self.parker = parker
        openOfferHandler = openOffer
        openResultHandler = openResult
        openDashboardHandler = openDashboard
        copy = copyText
    }

    public func openOffer(_ offer: CommandOffer.ID, sessionID: String, anchor: CGRect) {
        openOfferHandler(offer, sessionID, anchor)
    }

    public func openResult(_ resultID: String, sessionID: String, anchor: CGRect) {
        openResultHandler(resultID, sessionID, anchor)
    }

    public func openDashboard(sessionID: String) {
        openDashboardHandler(sessionID)
    }

    public func park(sessionID: String) {
        parker.perform(.park, sessionID: sessionID)
    }

    /// Copies `claude://claude.ai/epitaxy/local_<id>` (the link format Claude itself hands out); nothing for an id that
    /// fails the grammar.
    public func copyLink(sessionID: String) {
        guard let link = CodeDeepLink.shareLink(sessionID: sessionID) else { return }
        copy(link)
    }

    /// The general pasteboard, plain text.
    public static func copyToGeneralPasteboard(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }
}
