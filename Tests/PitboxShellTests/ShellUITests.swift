import AppKit
import Foundation
import SwiftUI
import Testing
@testable import PitboxShell

/// Non-visual checks: nothing here puts a window or a status item on screen.
@Suite @MainActor struct ShellUITests {
    @Test func editMenuRoutesStandardActionsToTheFirstResponder() {
        let menu = EditMenu.makeEditMenu()
        let byTitle = Dictionary(uniqueKeysWithValues: menu.items.filter { !$0.isSeparatorItem }.map { ($0.title, $0) })
        let expected: [(String, String, String, NSEvent.ModifierFlags)] = [
            ("Undo", "undo:", "z", .command), ("Redo", "redo:", "z", [.command, .shift]),
            ("Cut", "cut:", "x", .command), ("Copy", "copy:", "c", .command), ("Paste", "paste:", "v", .command),
            ("Paste and Match Style", "pasteAsPlainText:", "v", [.command, .option, .shift]),
            ("Select All", "selectAll:", "a", .command),
        ]
        for (title, action, key, mods) in expected {
            let item = byTitle[title]
            #expect(item?.action.map(NSStringFromSelector) == action, "\(title)")
            #expect(item?.keyEquivalent == key, "\(title)")
            #expect(item?.keyEquivalentModifierMask == mods, "\(title)")
            #expect(item?.target == nil, "\(title) must target the first responder")
        }
        #expect(byTitle["Delete"]?.action.map(NSStringFromSelector) == "delete:")
        #expect(!menu.items.contains { $0.keyEquivalent == "q" }, "no Quit in the hidden menu")
    }

    @Test func panelKeyPolicyRecognisesTextInputViews() {
        let editable = NSTextField(string: "x")
        #expect(PitboxPanel.wantsKeyboard(editable))
        let label = NSTextField(labelWithString: "x")
        #expect(!PitboxPanel.wantsKeyboard(label))
        #expect(!PitboxPanel.wantsKeyboard(NSButton(title: "b", target: nil, action: nil)))
        let textView = NSTextView()
        let inner = NSView()
        textView.addSubview(inner)
        #expect(PitboxPanel.wantsKeyboard(inner), "descendants of text views count")
        let readOnly = NSTextView()
        readOnly.isEditable = false
        readOnly.isSelectable = false
        #expect(!PitboxPanel.wantsKeyboard(readOnly))

        // SwiftUI: the hosting view claims needsPanelToBecomeKey, but only real text inputs inside it count.
        let host = NSHostingView(rootView: Button("Monitor action") {})
        #expect(!PitboxPanel.wantsKeyboard(host))
        let chrome = NSView()
        host.addSubview(chrome)
        #expect(!PitboxPanel.wantsKeyboard(chrome))
        let hostedField = NSTextField(string: "")
        host.addSubview(hostedField)
        #expect(PitboxPanel.wantsKeyboard(hostedField))
    }

    @Test func panelWindowPolicy() {
        let panel = PitboxPanel(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100), level: .desktop,
                                 hideInFullscreen: true)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.level.rawValue == Int(CGWindowLevelForKey(.desktopIconWindow)) + 3)
        #expect(panel.level.rawValue < NSWindow.Level.normal.rawValue)
        #expect(panel.collectionBehavior.isSuperset(of: [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]))
        #expect(!panel.collectionBehavior.contains(.transient), "behind windows: stationary, not transient")
        #expect(!panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(!panel.hidesOnDeactivate)
        #expect(!panel.hasShadow)
        #expect(panel.becomesKeyOnlyIfNeeded)
        #expect(!panel.canBecomeKey, "key only on a text click or an explicit request")
        #expect(!panel.canBecomeMain)
        #expect(panel.isExcludedFromWindowsMenu)
        panel.applyCollectionBehavior(hideInFullscreen: false)
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(!panel.collectionBehavior.contains(.fullScreenNone))
        #expect(PanelLevel.backstop.windowLevel.rawValue == Int(CGWindowLevelForKey(.backstopMenu)))
    }

    @Test func aboveWindowsLevelIsBelowFloatingPopUps() {
        // A screenshot tool's share pop-up is a floating window (level 3) in a corner: it must draw over the panel.
        let level = PanelLevel.aboveWindows.windowLevel.rawValue
        #expect(level == 2)
        #expect(level == NSWindow.Level.floating.rawValue - 1)
        #expect(level == Int(CGWindowLevelForKey(.floatingWindow)) - 1)
        // Above every normal window (level 0) and the levels just above it, so no app window covers the panel.
        #expect(level > Int(CGWindowLevelForKey(.normalWindow)))
        #expect(level > NSWindow.Level.normal.rawValue)
        // Below floating (3), status, modal, pop-up, main menu and Dock windows, so those draw over the panel.
        for key in [CGWindowLevelKey.floatingWindow, .tornOffMenuWindow, .modalPanelWindow, .utilityWindow, .dockWindow,
                    .mainMenuWindow, .statusWindow, .popUpMenuWindow, .overlayWindow, .assistiveTechHighWindow] {
            #expect(level < Int(CGWindowLevelForKey(key)), "panel must be below window level key \(key.rawValue)")
        }
        // Behind-windows mode is unchanged and stays below normal windows.
        #expect(PanelLevel.desktop.windowLevel.rawValue == Int(CGWindowLevelForKey(.desktopIconWindow)) + 3)
        #expect(PanelLevel.desktop.windowLevel.rawValue < level)
    }

    @Test func panelWindowUsesTheAboveWindowsLevel() {
        let panel = PitboxPanel(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100), level: .aboveWindows,
                                 hideInFullscreen: true)
        #expect(panel.level.rawValue == 2)
        panel.applyLevel(.desktop)
        #expect(panel.level.rawValue == Int(CGWindowLevelForKey(.desktopIconWindow)) + 3)
        panel.applyLevel(.aboveWindows)
        #expect(panel.level.rawValue == 2)
        #expect(panel.collectionBehavior.contains(.transient) && !panel.collectionBehavior.contains(.stationary))
    }

    @Test func loginItemIsInertOutsideAnAppBundle() {
        // The test runner is not an app bundle: nothing may be registered from here.
        guard Bundle.main.bundleURL.pathExtension != "app" else { return }
        if case .unavailable = LoginItem.status {} else { Issue.record("expected unavailable, got \(LoginItem.status)") }
        #expect(LoginItem.reconcile(wanted: true) == LoginItem.status)
        #expect(!LoginItem.isEnabled)
    }

    /// An app macOS has never seen reports `.notFound`; a wanted login item must register then too (the old rule
    /// only registered from `.notRegistered`, so the app never reached Login Items). Approval stays pending.
    @Test func reconcileRegistersAnAppTheSystemDoesNotKnowYet() {
        #expect(LoginItem.change(wanted: true, system: .notFound) == .register)
        #expect(LoginItem.change(wanted: true, system: .notRegistered) == .register)
        #expect(LoginItem.change(wanted: true, system: .enabled) == .none)
        #expect(LoginItem.change(wanted: true, system: .requiresApproval) == .none)
        #expect(LoginItem.change(wanted: false, system: .enabled) == .unregister)
        #expect(LoginItem.change(wanted: false, system: .requiresApproval) == .unregister)
        #expect(LoginItem.change(wanted: false, system: .notRegistered) == .none)
        #expect(LoginItem.change(wanted: false, system: .notFound) == .none)
    }
}
