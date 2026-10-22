import AppKit
import Testing
@testable import PitboxShell

/// Records the window calls of the keyboard handoff; never touches the window server.
@MainActor
private final class FakeHandoffWindow: KeyboardHandoffWindow {
    var isKeyWindow = false
    var isVisible = false
    var calls: [String] = []

    func makeKeyForTyping() {
        calls.append("makeKey")
        isKeyWindow = true
    }

    func orderFrontRegardless() {
        calls.append("orderFront")
        isVisible = true
    }

    func orderOut(_ sender: Any?) {
        calls.append("orderOut")
        isVisible = false
        isKeyWindow = false
    }
}

/// A stand-in for the panel controller: its window, its shown state and its `show()`.
@MainActor
private final class Host {
    var window: FakeHandoffWindow?
    var shown = false
    var shows = 0
    lazy var keyboard = PanelKeyboard(window: { [unowned self] in self.window }, isShown: { [unowned self] in self.shown },
                                      show: { [unowned self] in self.showPanel() })

    init(window: FakeHandoffWindow?, shown: Bool) {
        self.window = window
        self.shown = shown
        if shown { window?.isVisible = true }
    }

    func showPanel() {
        shows += 1
        shown = true
        if window == nil { window = FakeHandoffWindow() }
        window?.isVisible = true
    }
}

@Suite @MainActor struct PanelKeyboardTests {
    @Test func takingTheKeyboardMakesTheShownPanelKeyWithoutShowingItAgain() {
        let host = Host(window: FakeHandoffWindow(), shown: true)
        host.keyboard.setNeeds(true)
        #expect(host.shows == 0)
        #expect(host.window?.calls == ["makeKey", "orderFront"])
        #expect(host.keyboard.hasFocus)
    }

    @Test func aHiddenPanelIsShownFirstThenTakesTheKeyboard() {
        let host = Host(window: nil, shown: false)
        host.keyboard.setNeeds(true)
        #expect(host.shows == 1, "show() makes the window, so it runs before the key handoff")
        #expect(host.window?.calls == ["makeKey", "orderFront"])
        #expect(host.keyboard.hasFocus)
    }

    @Test func givingBackOrdersTheShownPanelOutAndStraightBackIn() {
        let host = Host(window: FakeHandoffWindow(), shown: true)
        host.keyboard.take()
        host.window?.calls = []
        host.keyboard.setNeeds(false)
        #expect(host.window?.calls == ["orderOut", "orderFront"])
        #expect(host.window?.isVisible == true)
        #expect(!host.keyboard.hasFocus)
    }

    @Test func aPanelBeingHiddenStaysOutWhenItGivesTheKeyboardBack() {
        let host = Host(window: FakeHandoffWindow(), shown: true)
        host.keyboard.take()
        host.shown = false   // hide() ran; the window is still fading out
        host.window?.calls = []
        host.keyboard.giveBack()
        #expect(host.window?.calls == ["orderOut"])
        #expect(host.window?.isVisible == false)
    }

    @Test func aKeyWindowThatIsNotOrderedInIsNotBroughtBack() {
        let host = Host(window: FakeHandoffWindow(), shown: true)
        host.window?.isKeyWindow = true
        host.window?.isVisible = false
        host.keyboard.giveBack()
        #expect(host.window?.calls == ["orderOut"])
    }

    @Test func givingBackWithoutFocusDoesNothing() {
        let host = Host(window: FakeHandoffWindow(), shown: true)
        host.keyboard.giveBack()
        host.keyboard.setNeeds(false)
        #expect(host.window?.calls == [])
        #expect(host.shows == 0)
    }

    @Test func noWindowYetIsHarmless() {
        let host = Host(window: nil, shown: false)
        host.keyboard.take()
        host.keyboard.giveBack()
        host.keyboard.setNeeds(false)
        #expect(host.window == nil)
        #expect(host.shows == 0)
        #expect(!host.keyboard.hasFocus)
    }

    @Test func theRealPanelConformsAndStartsWithoutFocus() {
        // Built, never ordered in: nothing reaches the screen.
        let panel = PitboxPanel(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100), level: .aboveWindows,
                                hideInFullscreen: true)
        let keyboard = PanelKeyboard(window: { panel }, isShown: { false }, show: {})
        #expect(!keyboard.hasFocus)
        keyboard.giveBack()
        #expect(!panel.isVisible)
        #expect(!panel.canBecomeKey, "key only after a text click or makeKeyForTyping()")
    }
}
