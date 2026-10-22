import AppKit
import PitboxKit

/// The panel of desk tags and the desk peek: borderless
/// and non-activating, and unlike the app's other small pop-ups it can never become key or main
/// (`becomesKeyOnlyIfNeeded` false too), so Claude stays the active app and its window stays key: typing goes on into
/// Claude whatever is clicked here. Key events that reach it anyway are dropped, it has no default button and no key
/// equivalent, and Escape does nothing through the responder chain (the desk peek closes on Escape only through a local
/// key monitor while the app is the active app). Collection behaviour `[.canJoinAllSpaces, .transient,
/// .ignoresCycle]`: out of Mission Control, App Exposé and the window cycle; never on a full-screen Space (no
/// `.fullScreenAuxiliary`). The window guard never moves it (it skips the app's own windows).
final class DeskTagNonKeyPanel: NSPanel {
    init(contentRect: CGRect, title: String) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        self.title = title
        isFloatingPanel = false
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        tabbingMode = .disallowed
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        level = .normal
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func makeKey() {}
    override func makeMain() {}
    override func makeKeyAndOrderFront(_ sender: Any?) { orderFrontRegardless() }

    override var defaultButtonCell: NSButtonCell? {
        get { nil }
        set {}
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown, .keyUp, .flagsChanged:
            return
        default:
            super.sendEvent(event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool { false }
    override func cancelOperation(_ sender: Any?) {}
    override func keyDown(with event: NSEvent) {}
}

/// One desk window's tag: a never-key panel holding the stack of pills.
@MainActor
final class DeskTagPanel {
    let panel: DeskTagNonKeyPanel
    let view: DeskTagStackView

    init() {
        view = DeskTagStackView(frame: CGRect(x: 0, y: 0, width: 120, height: DeskTagTuning.pillHeight))
        panel = DeskTagNonKeyPanel(contentRect: view.frame, title: "\(AppIdentity.displayName) tag")
        panel.contentView = view
    }
}
