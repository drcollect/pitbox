import AppKit
import CoreGraphics
import Foundation
import PitboxKit
import Testing
@testable import PitboxSessions

// The drop label's panel and the slot view: the panel is made but never ordered in (nothing appears on screen);
// pictures render off screen when PITBOX_TEST_OUT is set:
// `PITBOX_TEST_OUT=<dir> scripts/test.sh --filter renderDropPictures`.

/// A view that counts the key events that reach it.
private final class KeyCounter: NSView {
    var keys = 0
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { keys += 1 }
    override func keyUp(with event: NSEvent) { keys += 1 }
}

@MainActor
@Suite("Drop label and slot")
struct DropViewsTests {
    @Test func theLabelPanelNeverTakesTheKeyboardFocusOrTheMouse() throws {
        let panel = DropLabelPanel()
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(!panel.becomesKeyOnlyIfNeeded)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.styleMask.contains(.borderless))
        #expect(!panel.styleMask.contains(.titled))
        #expect(panel.ignoresMouseEvents, "the drop always reaches the window server")
        #expect(!panel.hidesOnDeactivate)
        #expect(!panel.isMovable)
        #expect(panel.collectionBehavior.isSuperset(of: [.canJoinAllSpaces, .transient, .ignoresCycle]))
        #expect(panel.level.rawValue > NSWindow.Level.floating.rawValue, "above the strip and an always-on-top pop-out")
        #expect(panel.level.rawValue < NSWindow.Level.popUpMenu.rawValue, "under menus")
        #expect(panel.defaultButtonCell == nil, "no default button")
        // Key events are never delivered, not even to a view made first responder.
        let counter = KeyCounter(frame: CGRect(x: 0, y: 0, width: 100, height: 22))
        panel.contentView = counter
        _ = panel.makeFirstResponder(counter)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                                      windowNumber: panel.windowNumber, context: nil, characters: "\r",
                                                      charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            panel.sendEvent(event)
            #expect(!panel.performKeyEquivalent(with: event), "no key equivalent")
        }
        #expect(counter.keys == 0)
        #expect(!panel.isVisible)
        panel.close()
    }

    @Test func theLabelHasNoTextFieldAndTakesNoClick() {
        let view = DropLabelView()
        view.update(text: "Drop to pit in Unsorted", failure: false)
        #expect(view.subviews.isEmpty, "drawn words only: no text field, ever")
        #expect(view.hitTest(CGPoint(x: 5, y: 5)) == nil)
        #expect(!view.acceptsFirstResponder)
        #expect(view.accessibilityLabel() == "Drop to pit in Unsorted")
    }

    @Test func thePillIsOpaqueReadableAndAtMost260PointsWide() {
        #expect(PaletteTests.contrast(DropLabelView.text, DropLabelView.fill) >= 4.5)
        #expect(PaletteTests.contrast(DropLabelView.failureText, DropLabelView.fill) >= 4.5)
        #expect(PaletteTests.contrast(DropLabelView.text, DropLabelView.mark) >= 4.5, "the mark on its circle")
        let view = DropLabelView()
        view.update(text: "Drop to pit in Unsorted", failure: false)
        #expect(view.pillSize.height == 22)
        #expect(view.pillSize.width > 120 && view.pillSize.width < 220)
        view.update(text: "Drop to pit in " + String(repeating: "W", count: 32), failure: false)
        #expect(view.pillSize.width == 260, "cut at the end beyond 260 pt")
    }

    /// Below and right of the pointer; left of it near the screen's right edge (beside a right-hand strip); above it near
    /// the bottom; always inside the screen (AppKit coordinates).
    @Test func theLabelSitsBesideThePointerInsideItsScreen() {
        let screen = CGRect(x: 0, y: 0, width: 5120, height: 1440)
        let size = CGSize(width: 180, height: 22)
        #expect(DropLabelPanelController.frame(size: size, near: CGPoint(x: 4000, y: 800), screen: screen)
                == CGRect(x: 4016, y: 758, width: 180, height: 22))
        #expect(DropLabelPanelController.frame(size: size, near: CGPoint(x: 5050, y: 800), screen: screen)
                == CGRect(x: 4854, y: 758, width: 180, height: 22))
        #expect(DropLabelPanelController.frame(size: size, near: CGPoint(x: 4000, y: 10), screen: screen)
                == CGRect(x: 4016, y: 30, width: 180, height: 22))
        let second = CGRect(x: 5120, y: 0, width: 1920, height: 1080)
        let frame = DropLabelPanelController.frame(size: size, near: CGPoint(x: 7030, y: 1075), screen: second)
        #expect(second.contains(frame))
    }

    @Test func theSlotIsAPictureOnly() {
        let slot = DropSlotView(frame: CGRect(x: 0, y: 0, width: 323, height: 219))
        #expect(slot.hitTest(CGPoint(x: 100, y: 100)) == nil, "clicks go to the block")
        #expect(!slot.acceptsFirstResponder)
        #expect(slot.accessibilityLabel() == "Drop to pit")
        #expect(slot.subviews.isEmpty)
    }

    /// The pictures, for looking at: the slot at each monitor size and as a slim row, in a bucket colour and the accent,
    /// dark and light; the label armed and failed.
    @Test func renderDropPictures() throws {
        let out = ProcessInfo.processInfo.environment["PITBOX_TEST_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let amber = ThemeColor.srgb(0xF2A33A)
        let slots: [(String, CGSize, NSColor?, CGFloat)] = [
            ("slot-large", CGSize(width: 323, height: 219), nil, 10),
            ("slot-medium-amber", CGSize(width: 323, height: 150), amber, 8),
            ("slot-small", CGSize(width: 155, height: 104), nil, 7),
            ("slot-row-amber", CGSize(width: 992, height: 36), amber, 6),
        ]
        for dark in [true, false] {
            for (name, size, tint, radius) in slots {
                let view = DropSlotView(frame: CGRect(origin: .zero, size: size))
                view.tint = tint
                view.cornerRadius = radius
                let png = try #require(PictureTests.picture(of: view, size: size, dark: dark))
                #expect(png.count > 500)
                try write(png, "\(name)-\(dark ? "dark" : "light")", to: out)
            }
        }
        for (name, text, failure) in [("label-armed", "Drop to pit in Toy Cube", false),
                                      ("label-failed", "couldn't pit (Claude didn't answer)", true)] {
            let view = DropLabelView()
            view.update(text: text, failure: failure)
            let size = view.pillSize
            view.frame = CGRect(origin: .zero, size: size)
            let png = try #require(PictureTests.picture(of: view, size: size, dark: true))
            #expect(png.count > 300)
            try write(png, name, to: out)
        }
    }

    private func write(_ png: Data, _ name: String, to folder: URL?) throws {
        guard let folder else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(to: folder.appendingPathComponent("\(name).png"))
    }
}
