import AppKit
import Foundation

// What moves tags: the observer's window reads and app events, the
// system's Space and display changes, drags, and clicks on the pills.
extension DeskTagController {
    // MARK: Observer events

    func handle(_ event: CodeWindowObserverEvent) {
        switch event {
        case .windows(let states):
            var touched: [String] = []
            for state in states {
                guard let id = keyIndex[state.key], var tag = tags[id] else { continue }
                apply(state, to: &tag)
                tags[id] = tag
                touched.append(id)
                if state.reason == .notifications { labState.noteLatency(scheduler.now - state.at) }
            }
            for id in touched { render(id) }
            if dragTimer == nil, tags.values.contains(where: { $0.facts.dragging }) { scheduleDragPoll() }
            updateClockTimer()
        case .app(let pid, let note):
            handleApp(pid: pid, note)
        case .fullScreen(let key, let value):
            guard let id = keyIndex[key] else { return }
            tags[id]?.facts.fullScreen = value
            render(id)
        case .frontToBack(let list):
            frontToBack = list
            if coverMode == .floating { for id in tags.keys where tags[id]?.content != nil { render(id) } }
            if lab.enabled { labCheckOrder() }
        case .trust:
            break
        case .note(let pid, let note, let down, let at):
            labNote(pid: pid, note, buttonDown: down, at: at)
        }
    }

    /// One window read: its entry, minimized, and the drag state (a move with the button down hides the tag).
    private func apply(_ state: CodeWindowState, to tag: inout Tag) {
        tag.facts.window = state.window
        tag.facts.wasRead = true
        if let window = state.window, window.isOnScreen {
            tag.facts.minimized = false
        } else if state.notifications.contains(.miniaturized) {
            tag.facts.minimized = true
        }
        guard state.notifications.contains(.moved), state.window?.isOnScreen == true else { return }
        if state.buttonDown {
            tag.facts.dragging = true
            tag.dragLastMove = state.at
        } else if tag.facts.dragging {
            tag.dragLastMove = state.at
        }
    }

    private func handleApp(pid: pid_t, _ note: CodeWindowNotification) {
        switch note {
        case .appHidden, .appShown:
            for (id, tag) in tags where tag.desk.pid == pid {
                tags[id]?.facts.appHidden = note == .appHidden
                render(id)
            }
        case .appActivated, .focusedWindowChanged, .mainWindowChanged:
            // Claude raised a window: put its tags back directly above their windows (first cover mode).
            reorder(pid: pid)
        case .appDeactivated, .miniaturized, .deminiaturized, .moved, .resized, .destroyed:
            break
        }
    }

    // MARK: System events

    func handle(_ event: DeskTagSystemEvent) {
        switch event {
        case .spaceChanged:
            // Every tag is checked again at once; the 1 Hz pass stays the backstop.
            observer.refreshAll()
        case .screensChanged:
            displays = system.displays()
            for id in tags.keys { render(id) }
            observer.refreshAll()
        case .appActivated(let pid):
            if pid == ownPID {
                // The app itself became active, which can bring its windows forward: every tag goes back directly
                // above its Claude window (first cover mode).
                for claude in Set(tags.values.map(\.desk.pid)) { reorder(pid: claude) }
            } else if coverMode == .floating, !watchedKeys.contains(where: { $0.pid == pid }) {
                observer.refreshAll()
            }
        }
    }

    // MARK: Drags

    /// While a drag runs, the button is read every 50 ms; a tag shows again once the button is up and 0.15 s have passed
    /// since the window's last move. No timer otherwise.
    func scheduleDragPoll() {
        guard dragTimer == nil else { return }
        dragTimer = scheduler.after(DeskTagTuning.dragPoll) { [weak self] in
            guard let self else { return }
            self.dragTimer = nil
            self.dragTick()
        }
    }

    func dragTick() {
        let now = scheduler.now
        let down = button.isLeftButtonDown()
        var running = false
        var ended: [String] = []
        for (id, tag) in tags where tag.facts.dragging {
            // Shown again once the button is up and the last move is 0.15 s old (a move after the release counts too).
            if !down, now + 1e-9 >= (tag.dragLastMove ?? now) + DeskTagTuning.showAfterDrag {
                tags[id]?.facts.dragging = false
                tags[id]?.dragLastMove = nil
                ended.append(id)
            } else {
                running = true
            }
        }
        for id in ended { render(id) }
        if !ended.isEmpty { observer.refreshAll() }
        if running { scheduleDragPoll() }
    }

    // MARK: Clicks

    /// A press on pill `index` of the tag of session `id` (the arming, where it applies, was checked by the view).
    func pressed(_ id: String, index: Int) {
        guard let tag = tags[id], let content = tag.content, content.pills.indices.contains(index),
              let anchor = tag.shownFrame else { return }
        let pill = content.pills[index]
        DeskTagLog.info("tag clicked \(DeskTagLog.tag(tag.index)) kind=\(pill.logKind)")
        switch pill.action {
        case .openOffer(let offer):
            closePeek()
            actions.openOffer(offer, sessionID: id, anchor: anchor)
        case .openPeek(let focus):
            togglePeek(id, focus: focus)
        case .openDashboard:
            actions.openDashboard(sessionID: id)
            DeskTagLog.info("result opened \(DeskTagLog.tag(tag.index)) kind=dashboard")
        }
        // A click may have raised the panel: back directly above its window.
        if coverMode == .orderedAbove, let panel = tag.panel {
            windowing.show(panel.panel, frame: anchor, level: panelLevel(tag), above: tag.desk.windowNumber, reorder: true)
        }
        if lab.enabled { labCheckClick(pid: tag.desk.pid, index: tag.index) }
    }

    func tagHover(_ id: String, inside: Bool) {
        tags[id]?.hovered = inside
        if peek?.sessionID == id { peekHoverChanged() }
    }
}
