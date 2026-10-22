import AppKit

/// The command sheet's window: borderless, non-activating, floating beside the block, and it can never become key or
/// main. Keys keep going where they went before, so Return, Enter, Space or Escape typed anywhere never reach it: this
/// is the guarantee that a stray key cannot confirm. As a second guard, key events that reach it anyway are dropped
/// here. Mouse events work (non-activating), so the user clicks it without Pitbox taking the keyboard from the app they
/// are in.
final class CommandSheetPanel: NSPanel {
    /// A click or scroll in the sheet (the 10-minute timer restarts).
    var onActivity: (() -> Void)?

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: CommandSheetView.defaultWidth, height: 400),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        worksWhenModal = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        tabbingMode = .disallowed
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        level = .floating
        // Best effort only: screen capture may ignore it (Pitbox promises nothing about screen sharing).
        sharingType = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func makeKey() {}
    override func makeMain() {}

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown, .keyUp, .flagsChanged:
            return
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
            onActivity?()
        default:
            break
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool { false }
}

/// Where the sheet goes (screen coordinates, y up): beside the block on its window side, the side facing the rest of
/// the screen (left of a block in the right half, right of one in the left half), else on the other side, else at the
/// screen's left margin; level with the monitor it came from, kept on screen, at most 80 % of the screen high, and
/// never under the pointer. Pure.
enum CommandSheetPlacement {
    static let gap: CGFloat = 10
    static let margin: CGFloat = 10
    static let heightShare: CGFloat = 0.8

    /// - Parameter block: the frame the sheet sits beside (the block's window, or the docked area); nil: the anchor's.
    static func frame(size: CGSize, anchor: CGRect, block: CGRect?, screen: CGRect, pointer: CGPoint?) -> CGRect {
        let width = min(size.width, max(screen.width - 2 * margin, 200))
        let height = min(size.height, max(screen.height * heightShare, 200), screen.height - 2 * margin)
        let reference = block ?? anchor
        let left = reference.minX - gap - width >= screen.minX + margin ? reference.minX - gap - width : nil
        let right = reference.maxX + gap + width <= screen.maxX - margin ? reference.maxX + gap : nil
        // The window side: towards the middle of the screen.
        let windowSideIsLeft = reference.midX >= screen.midX
        let x = (windowSideIsLeft ? left ?? right : right ?? left) ?? screen.minX + margin
        var y = anchor.midY - height / 2
        y = min(max(y, screen.minY + margin), screen.maxY - margin - height)
        var frame = CGRect(x: x, y: y, width: width, height: height)
        if let pointer, frame.insetBy(dx: -4, dy: -4).contains(pointer) {
            // Never under the pointer: above it, below it, or beside it, whichever fits first.
            let above = pointer.y + 16
            let below = pointer.y - 16 - height
            if above + height <= screen.maxY - margin {
                frame.origin.y = above
            } else if below >= screen.minY + margin {
                frame.origin.y = below
            } else if pointer.x - 16 - width >= screen.minX + margin {
                frame.origin.x = pointer.x - 16 - width
            } else {
                frame.origin.x = min(pointer.x + 16, screen.maxX - margin - width)
            }
        }
        return frame
    }
}

/// "Arming counts only while the sheet is fully visible": on screen, inside its screen, not occluded,
/// and no other on-screen window above it overlapping it (window bounds from the window server, which needs no
/// permission; names are never read).
enum CommandSheetCoverage {
    @MainActor
    static func isFullyVisible(_ panel: NSWindow) -> Bool {
        guard panel.isVisible, panel.occlusionState.contains(.visible), let screen = panel.screen,
              screen.frame.contains(panel.frame) else { return false }
        guard panel.windowNumber > 0,
              let above = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow], CGWindowID(panel.windowNumber)) as? [[String: Any]]
        else { return false }   // no answer from the window server: not known to be visible, so fail closed
        let mainHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let frame = panel.frame
        let flipped = CGRect(x: frame.minX, y: mainHeight - frame.maxY, width: frame.width, height: frame.height)
        for info in above {
            let alpha = (info[kCGWindowAlpha as String] as? Double) ?? 1
            guard alpha > 0.05, let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary),
                  bounds.width > 2, bounds.height > 2 else { continue }
            if bounds.intersects(flipped) { return false }
        }
        return true
    }
}

/// Copies from the sheet: the exact text on the general pasteboard, marked
/// `org.nspasteboard.ConcealedType` and `org.nspasteboard.TransientType`, so clipboard managers that follow
/// nspasteboard.org never record it. Plain text only.
enum CommandPasteboard {
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    @MainActor
    @discardableResult
    static func copy(_ text: String, to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, concealedType, transientType], owner: nil)
        let wroteText = pasteboard.setString(text, forType: .string)
        let concealed = pasteboard.setData(Data(), forType: concealedType)
        let transient = pasteboard.setData(Data(), forType: transientType)
        return wroteText && concealed && transient
    }
}
