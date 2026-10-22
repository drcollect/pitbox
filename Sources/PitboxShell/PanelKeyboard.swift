import AppKit

/// The window calls the keyboard handoff makes. `PitboxPanel` provides them as an `NSPanel`; tests use a fake that
/// records the calls, so the handoff is checked without a window on screen.
@MainActor
protocol KeyboardHandoffWindow: AnyObject {
    /// True while the window holds keyboard focus.
    var isKeyWindow: Bool { get }
    /// True while the window is ordered in.
    var isVisible: Bool { get }
    /// Allows the window to become key and makes it key, without activating the app.
    func makeKeyForTyping()
    func orderFrontRegardless()
    func orderOut(_ sender: Any?)
}

extension PitboxPanel: KeyboardHandoffWindow {}

/// The panel's keyboard handoff, without ever activating the app: the panel takes the keyboard only when something in
/// it needs typing (a bucket name field, the console, Escape during a drag) and gives it back to the app that had it.
/// The menu bar and the window order stay with the user's app throughout.
///
/// Moved out of the source project's panel controller so the new controller (with its own show, hide and layout) can
/// reuse it unchanged: the controller owns one, passes its window, its own shown state (`show()` to `hide()`, which
/// is not the window's `isVisible` while a hide fades out) and its `show()`.
@MainActor
final class PanelKeyboard {
    private let window: () -> KeyboardHandoffWindow?
    private let isShown: () -> Bool
    private let show: () -> Void

    /// - Parameters:
    ///   - window: the panel window, nil until the controller made it.
    ///   - isShown: true between the controller's `show()` and `hide()`.
    ///   - show: shows the panel (and makes its window), as the controller's `show()` does.
    init(window: @escaping () -> KeyboardHandoffWindow?, isShown: @escaping () -> Bool, show: @escaping () -> Void) {
        self.window = window
        self.isShown = isShown
        self.show = show
    }

    /// True while the panel holds keyboard focus.
    var hasFocus: Bool { window()?.isKeyWindow ?? false }

    /// `true`: take keyboard focus now, showing the panel first if it is hidden. `false`: hand it back to the app that
    /// had it (nothing happens when the panel does not hold it).
    func setNeeds(_ needs: Bool) {
        if needs {
            if !isShown() { show() }
            take()
        } else {
            giveBack()
        }
    }

    /// Key without activation: the menu bar and window order stay with the user's app (measured in the source project).
    func take() {
        guard let window = window() else { return }
        window.makeKeyForTyping()
        window.orderFrontRegardless()
    }

    /// Gives keyboard focus back to the app that had it. The app itself never activated, so ordering the panel out and
    /// straight back in returns key focus to that app's key window (measured: keys route back, nothing reorders). A
    /// panel that is being hidden stays out.
    func giveBack() {
        guard let window = window(), window.isKeyWindow else { return }
        let wasVisible = window.isVisible
        window.orderOut(nil)
        if wasVisible, isShown() { window.orderFrontRegardless() }
    }
}
