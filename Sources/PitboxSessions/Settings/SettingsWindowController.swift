import AppKit
import PitboxKit

/// The settings window: a titled, non-activating panel that never takes keyboard focus away from another app on its
/// own. It is ordered in without activating Pitbox and becomes key only when the user clicks a control that needs
/// typing (a hotkey field); pop-ups, checkboxes, the slider and the stepper work without it. It follows light and dark
/// (no fixed appearance), sits beside the block rather than over it, and stays where the user moves it while open.
/// Main thread.
///
/// ```swift
/// let window = SettingsWindowController(model: SettingsWindowModel(settings: current, …))
/// menu.openSettings = { window.show(avoiding: panel.frame) }
/// watcher change → window.model.update(settings:)
/// ```
@MainActor
public final class SettingsWindowController: NSObject, NSWindowDelegate {
    /// The window's model (its controls follow `model.update(settings:)`).
    public let model: SettingsWindowModel
    /// Called when the window closes.
    public var onClose: (() -> Void)?
    /// Orders the window in without activating the app or making it key (tests record the call instead).
    var orderIn: @MainActor (NSWindow) -> Void = { $0.orderFrontRegardless() }
    /// The visible frame of the display the window opens on (tests pass an off-screen one).
    var visibleFrame: @MainActor () -> CGRect? = { (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame }

    private(set) var panel: NSPanel?
    private(set) var view: SettingsWindowView?

    /// The window's content size.
    static let size = CGSize(width: SettingsWindowView.width, height: 640)

    public init(model: SettingsWindowModel) {
        self.model = model
        super.init()
    }

    /// True while the window is on screen.
    public var isShown: Bool { panel?.isVisible ?? false }

    /// Shows the window (or brings it forward), beside `block` (the block's frame, AppKit space) when it is new. Never
    /// activates the app and never makes the window key.
    public func show(avoiding block: CGRect? = nil) {
        let panel = self.panel ?? makePanel()
        if !panel.isVisible, let visible = visibleFrame() {
            panel.setFrame(Self.frame(size: panel.frame.size, visible: visible, avoiding: block), display: false)
        }
        model.refresh()
        orderIn(panel)
    }

    /// Closes the window.
    public func close() { panel?.close() }

    // MARK: NSWindowDelegate

    public func windowWillClose(_ notification: Notification) {
        // Typing focus goes back with the window; an edit in progress is committed by the field's end-editing action.
        onClose?()
    }

    // MARK: Building

    private func makePanel() -> NSPanel {
        let view = SettingsWindowView(model: model)
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: Self.size),
                            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.title = "\(AppIdentity.displayName) Settings"
        panel.isFloatingPanel = false
        panel.level = .normal
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.initialFirstResponder = nil
        panel.contentView = view
        panel.delegate = self
        panel.setAccessibilityIdentifier("pitbox.settings")
        self.panel = panel
        self.view = view
        return panel
    }

    /// Where a new window goes: vertically centred in `visible`, horizontally centred in the wider part of `visible`
    /// that `block` does not cover (the whole width when nothing is to be avoided or nothing is left), kept inside.
    static func frame(size: CGSize, visible: CGRect, avoiding block: CGRect?) -> CGRect {
        var span = (minX: visible.minX, maxX: visible.maxX)
        if let block, block.width > 0, block.intersects(visible) {
            let left = (minX: visible.minX, maxX: max(visible.minX, block.minX))
            let right = (minX: min(visible.maxX, block.maxX), maxX: visible.maxX)
            let wider = (left.maxX - left.minX) >= (right.maxX - right.minX) ? left : right
            if wider.maxX - wider.minX >= size.width { span = wider }
        }
        let x = span.minX + ((span.maxX - span.minX) - size.width) / 2
        let y = visible.minY + (visible.height - size.height) / 2
        let clampedX = min(max(x, visible.minX), max(visible.minX, visible.maxX - size.width))
        let clampedY = min(max(y, visible.minY), max(visible.minY, visible.maxY - size.height))
        return CGRect(x: clampedX.rounded(), y: clampedY.rounded(), width: size.width, height: size.height)
    }
}
