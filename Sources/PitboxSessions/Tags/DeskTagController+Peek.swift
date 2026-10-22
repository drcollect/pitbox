import AppKit
import Foundation
import PitboxKit

// The desk peek: one at a time, next to its tag on the side away from the block's region, never key. It closes 0.25 s
// after the pointer left the tag and the peek, when its tag hides, when the block hides, on `dismissOverlays`, and on
// Escape only through a local key monitor while the app is the active app.
extension DeskTagController {
    func togglePeek(_ id: String, focus: DeskPeekFocus) {
        if let peek, peek.sessionID == id {
            closePeek()
            return
        }
        openPeek(id, focus: focus)
    }

    func openPeek(_ id: String, focus: DeskPeekFocus) {
        closePeek()
        guard let tag = tags[id], tag.shownFrame != nil, let model = peekModel(id) else { return }
        let peek = DeskPeekPanel(sessionID: id, model: model)
        peek.view.now = { [weak self] in self?.scheduler.now ?? 0 }
        peek.view.pointer = { [weak self] in self?.system.pointerLocation() ?? .zero }
        peek.view.onAction = { [weak self] action, anchor in self?.peekAction(action, anchor: anchor) }
        peek.view.onHover = { [weak self] inside in
            self?.peekHovered = inside
            self?.peekHoverChanged()
        }
        self.peek = peek
        peekFocus = focus
        peekHovered = false
        placePeek(reorder: true)
        peek.view.scroll(to: focus)
        peek.view.noteLayout(at: scheduler.now)
        escapeMonitor = system.addEscapeMonitor { [weak self] in
            guard let self, self.peek != nil, self.system.isOwnAppActive() else { return false }
            self.closePeek()
            return true
        }
        DeskTagLog.info("desk peek opened \(DeskTagLog.tag(tag.index)) focus=\(focus)")
    }

    func peekModel(_ id: String) -> DeskPeekModel? {
        guard let session = sessions[id] else { return nil }
        return DeskPeekBuilder.model(DeskPeekBuilder.Inputs(
            session: session, suppressed: suppressed, textHidden: textHidden(session), warningsShown: settings.warnings,
            now: dateNow(), clock: clock, homeDirectory: homeDirectory, commands: settings.commands))
    }

    /// Places the peek next to its tag (it follows the tag when the window moves).
    func placePeek(reorder: Bool = false) {
        guard let peek, let tag = tags[peek.sessionID], let tagFrame = tag.shownFrame else { return }
        let height = system.primaryHeight
        let quartzTag = ScreenSpace.quartz(fromAppKit: tagFrame, primaryHeight: height)
        guard let display = DeskTagPlacement.display(for: quartzTag, in: displays) else { closePeek(); return }
        let maxHeight = min(DeskTagTuning.peekMaxHeight, display.visibleFrame.height - 2 * DeskTagTuning.peekMargin)
        let size = peek.size(maxHeight: maxHeight)
        let frame = DeskTagPlacement.peekFrame(tag: quartzTag, size: size, display: display, strips: stripRegions())
        let appKit = ScreenSpace.appKit(fromQuartz: frame, primaryHeight: height)
        let moved = peek.panel.frame != appKit
        windowing.show(peek.panel, frame: appKit, level: panelLevel(tag), above: orderTarget(tag), reorder: reorder)
        if moved { peek.view.noteLayout(at: scheduler.now) }
    }

    /// New session data while the peek is open.
    func refreshPeek() {
        guard let peek else { return }
        guard let model = peekModel(peek.sessionID) else { closePeek(); return }
        peek.view.update(model: model)
        placePeek()
        peek.view.noteLayout(at: scheduler.now)
    }

    func peekHoverChanged() {
        guard let peek else { return }
        let inside = peekHovered || tags[peek.sessionID]?.hovered == true
        if inside {
            peekCloseTimer?.cancel()
            peekCloseTimer = nil
        } else if peekCloseTimer == nil {
            peekCloseTimer = scheduler.after(DeskTagTuning.peekCloseDelay) { [weak self] in
                guard let self else { return }
                self.peekCloseTimer = nil
                self.closePeek()
            }
        }
    }

    func closePeek() {
        guard let current = peek else { return }
        windowing.hide(current.panel)
        peek = nil
        peekHovered = false
        peekCloseTimer?.cancel()
        peekCloseTimer = nil
        if let escapeMonitor { system.removeEscapeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    func peekAction(_ action: DeskPeekModel.Action, anchor: CGRect) {
        guard let peek else { return }
        let id = peek.sessionID
        let index = tags[id]?.index
        switch action {
        case .offer(let offer):
            DeskTagLog.info("desk peek clicked \(DeskTagLog.tag(index)) kind=command")
            actions.openOffer(offer, sessionID: id, anchor: anchor)
        case .result(let result):
            DeskTagLog.info("result opened \(DeskTagLog.tag(index)) kind=result")
            actions.openResult(result, sessionID: id, anchor: anchor)
        case .dashboard:
            DeskTagLog.info("result opened \(DeskTagLog.tag(index)) kind=dashboard")
            actions.openDashboard(sessionID: id)
        case .park:
            DeskTagLog.info("desk peek clicked \(DeskTagLog.tag(index)) kind=park")
            closePeek()
            actions.park(sessionID: id)
        case .copyLink:
            DeskTagLog.info("desk peek clicked \(DeskTagLog.tag(index)) kind=copy_link")
            actions.copyLink(sessionID: id)
        }
    }
}
