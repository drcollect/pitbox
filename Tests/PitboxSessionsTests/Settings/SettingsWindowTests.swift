import AppKit
import Foundation
import Testing
@testable import PitboxSessions
import PitboxKit

/// The settings window itself: a non-activating panel that never takes the keyboard on its own, placed beside the block,
/// following light and dark, and its controls reading and writing through the model. Off screen: the window is made
/// but never ordered in (`orderIn` is recorded instead), with `animationBehavior = .none`.
@MainActor
@Suite("Settings window", .serialized)
struct SettingsWindowTests {
    /// An off-screen display (x ≥ 20000), so nothing could ever land on a real screen.
    static let visible = CGRect(x: 20000, y: 0, width: 1440, height: 900)

    @MainActor
    final class Window {
        let rig: SettingsWindowModelTests.Rig
        let controller: SettingsWindowController
        var orderedIn: [NSWindow] = []
        var shownFile = 0

        init(_ text: String = "{}") {
            rig = SettingsWindowModelTests.Rig(text)
            controller = SettingsWindowController(model: rig.model)
            controller.visibleFrame = { SettingsWindowTests.visible }
            controller.orderIn = { [unowned self] in self.orderedIn.append($0) }
            rig.model.showSettingsFile = { [unowned self] in self.shownFile += 1 }
        }

        func show() throws -> (NSPanel, SettingsWindowView) {
            controller.show(avoiding: CGRect(x: 20750, y: 0, width: 690, height: 900))
            return (try #require(controller.panel), try #require(controller.view))
        }
    }

    static func send(_ control: NSControl) {
        _ = control.sendAction(control.action, to: control.target)
    }

    @Test func showingNeverActivatesNorTakesTheKeyboard() throws {
        let w = Window()
        let (panel, _) = try w.show()
        #expect(w.orderedIn.count == 1 && w.orderedIn.first === panel)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.becomesKeyOnlyIfNeeded, "key only after a click into a field that needs typing")
        #expect(!panel.hidesOnDeactivate && !panel.isFloatingPanel)
        #expect(panel.animationBehavior == .none)
        #expect(panel.initialFirstResponder == nil)
        #expect(!panel.isKeyWindow && !panel.isVisible)
        #expect(panel.appearance == nil, "follows the system's light or dark")
        #expect(panel.title == "Pitbox Settings")
        // Beside the block: centred in the free part left of it, inside the display.
        #expect(panel.frame.maxX <= 20750 && panel.frame.minX >= 20000)
        #expect(abs(panel.frame.midY - Self.visible.midY) <= 1)
        // A second show brings the same window forward.
        w.controller.show(avoiding: nil)
        #expect(w.orderedIn.count == 2 && w.controller.panel === panel)
    }

    @Test func newWindowsGoBesideTheBlock() {
        let size = CGSize(width: 560, height: 668)
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let right = SettingsWindowController.frame(size: size, visible: screen, avoiding: CGRect(x: 750, y: 0, width: 690, height: 875))
        #expect(right == CGRect(x: 95, y: 104, width: 560, height: 668))
        let left = SettingsWindowController.frame(size: size, visible: screen, avoiding: CGRect(x: 0, y: 0, width: 690, height: 875))
        #expect(left == CGRect(x: 785, y: 104, width: 560, height: 668))
        let centred = SettingsWindowController.frame(size: size, visible: screen, avoiding: nil)
        #expect(centred.minX == 440)
        // Too little room beside the block: centred on the whole display, kept inside it.
        let wide = SettingsWindowController.frame(size: size, visible: screen, avoiding: CGRect(x: 300, y: 0, width: 1000, height: 875))
        #expect(wide.minX == 440)
        let tiny = SettingsWindowController.frame(size: size, visible: CGRect(x: 0, y: 0, width: 400, height: 300), avoiding: nil)
        #expect(tiny.minX == 0 && tiny.minY == 0)
    }

    @Test func theControlsShowTheFile() throws {
        let w = Window(#"{"columns":1,"edge":"left","cellWidth":340,"chime":true,"console":{"fontSize":14,"theme":"dark"},"hotkeys":{"park":"ctrl+opt+k"},"commands":"run"}"#)
        let (_, view) = try w.show()
        #expect(Set(view.popUps.keys) == Set(SettingsField.popUps))
        #expect(Set(view.checkboxes.keys) == Set(SettingsField.checkboxes))
        #expect(view.popUps[.columns]?.titleOfSelectedItem == "1")
        #expect(view.popUps[.edge]?.titleOfSelectedItem == "Left")
        #expect(view.popUps[.consoleTheme]?.titleOfSelectedItem == "Dark")
        #expect(view.checkboxes[.chime]?.state == .on && view.checkboxes[.sayIt]?.state == .off)
        #expect(view.cellWidthSlider.doubleValue == 340 && view.cellWidthValue.stringValue == "340 pt")
        #expect(view.fontSizeStepper.doubleValue == 14 && view.fontSizeValue.stringValue == "14 pt")
        #expect(view.hotkeyFields[.park]?.stringValue == "ctrl+opt+k")
        #expect(view.hotkeyLines[.park]?.stringValue == "⌃⌥P is taken by another app")
        #expect(view.hotkeyLines[.fold]?.isHidden == true)
        #expect(view.fileOnlyValues["commands"]?.stringValue == "run (Run after review)")
        #expect(view.fileOnlyValues.count == CodeSettings.fileOnlyKeys.count + 1)
        #expect(view.errorLine.isHidden)
        for (field, control) in view.popUps { #expect(control.accessibilityIdentifier() == field.rawValue) }
    }

    @Test func usingTheControlsWritesTheFile() throws {
        let w = Window()
        let (_, view) = try w.show()
        let look = try #require(view.popUps[.look])
        look.selectItem(withTitle: "Slim rows")
        Self.send(look)
        let sayIt = try #require(view.checkboxes[.sayIt])
        sayIt.state = .on
        Self.send(sayIt)
        view.cellWidthSlider.doubleValue = 330.4
        Self.send(view.cellWidthSlider)
        view.fontSizeStepper.doubleValue = 16
        Self.send(view.fontSizeStepper)
        let fold = try #require(view.hotkeyFields[.fold])
        fold.stringValue = "ctrl+opt+j"
        Self.send(fold)
        let file = w.rig.file
        #expect(file.look == .rows && file.sayIt && file.cellWidth == 330 && file.console.fontSize == 16)
        #expect(file.hotkeys.fold == "ctrl+opt+j")
        #expect(w.rig.written.count == 5)
        #expect(view.cellWidthValue.stringValue == "330 pt")
        view.showFileButton.performClick(nil)
        #expect(w.shownFile == 1)
    }

    @Test func aRefusedChangeShowsWhyAndTheControlGoesBack() throws {
        let w = Window()
        let (_, view) = try w.show()
        try Data(#"{"chime":"#.utf8).write(to: w.rig.url)
        let chime = try #require(view.checkboxes[.chime])
        chime.state = .on
        Self.send(chime)
        #expect(!view.errorLine.isHidden)
        #expect(view.errorLine.stringValue == "Can't change: the settings file couldn't be read")
        #expect(chime.state == .off, "the box shows the file again")
        let park = try #require(view.hotkeyFields[.park])
        w.rig.model.checkHotkey = { _ in "Not a shortcut" }
        park.stringValue = "ctrl+opt+?"
        Self.send(park)
        #expect(view.hotkeyLines[.park]?.stringValue == "Not a shortcut")
        #expect(view.hotkeyLines[.park]?.textColor == .systemRed)
        #expect(park.stringValue == "ctrl+opt+?", "the refused text stays for the user to fix")
    }

    @Test func itFollowsLightAndDark() throws {
        let w = Window()
        let (panel, view) = try w.show()
        #expect(panel.appearance == nil && view.appearance == nil)
        #expect(view.errorLine.textColor == .systemRed)
        #expect(view.cellWidthValue.textColor == .secondaryLabelColor)
        // System colours only: the same view resolves differently under light and dark.
        var resolved: [String] = []
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            view.appearance = NSAppearance(named: name)
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                resolved.append(NSColor.labelColor.usingColorSpace(.sRGB)?.description ?? "")
            }
        }
        #expect(resolved.count == 2 && resolved[0] != resolved[1])
        view.appearance = nil
    }
}
