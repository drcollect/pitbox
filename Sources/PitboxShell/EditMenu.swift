import AppKit
import PitboxKit

/// Hidden main menu for the accessory app. An LSUIElement app shows no menu bar, but AppKit still routes key
/// equivalents through `NSApp.mainMenu`; without an Edit menu, Cmd-C / Cmd-V / Cmd-A / Cmd-Z do nothing in text
/// fields, web views and terminals. Dictation tools insert text with Cmd-V, so this is what makes dictation into a
/// bucket name or the console work.
///
/// There is deliberately no Quit (Cmd-Q) item: a stray Cmd-Q while typing in the panel must not kill it. Quit lives in
/// the status menu.
public enum EditMenu {
    /// Installs the menu once (idempotent). Call early, after `NSApplication.shared` exists.
    @MainActor
    public static func install() {
        let main = NSApp.mainMenu ?? NSMenu(title: "Main Menu")
        if main.items.contains(where: { $0.submenu?.title == "Edit" }) { return }
        if main.items.isEmpty {
            let appItem = NSMenuItem(title: AppIdentity.displayName, action: nil, keyEquivalent: "")
            appItem.submenu = NSMenu(title: AppIdentity.displayName)
            main.addItem(appItem)
        }
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = makeEditMenu()
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    /// The Edit menu: Undo, Redo, Cut, Copy, Paste, Paste and Match Style, Delete, Select All. Items target the first
    /// responder (nil target), so they work for NSTextView, SwiftUI text fields, WKWebView and terminal views.
    @MainActor
    public static func makeEditMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", "undo:", "z"))
        menu.addItem(item("Redo", "redo:", "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", "cut:", "x"))
        menu.addItem(item("Copy", "copy:", "c"))
        menu.addItem(item("Paste", "paste:", "v"))
        menu.addItem(item("Paste and Match Style", "pasteAsPlainText:", "v", [.command, .option, .shift]))
        menu.addItem(item("Delete", "delete:", ""))
        menu.addItem(item("Select All", "selectAll:", "a"))
        return menu
    }

    @MainActor
    private static func item(_ title: String, _ action: String, _ key: String,
                             _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: Selector(action), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = nil
        return item
    }
}
