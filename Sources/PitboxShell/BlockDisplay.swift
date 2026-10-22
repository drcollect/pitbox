import AppKit
import PitboxKit

/// A display as the block sees it, in AppKit screen space (origin bottom-left of the primary display, y up). Decoupled
/// from `NSScreen` so the geometry and the menu are testable without a window server.
public struct BlockDisplay: Equatable, Sendable {
    /// `CGDirectDisplayID` (0 if unknown). Changes across reconnects; `uuid` does not.
    public var displayID: UInt32
    /// The display's UUID (`CGDisplayCreateUUIDFromDisplayID`), the value the settings remember; "" if unknown.
    public var uuid: String
    /// The name macOS shows for the display ("Built-in Retina Display").
    public var name: String
    /// The whole display.
    public var frame: CGRect
    /// The display minus the menu bar and the Dock (`NSScreen.visibleFrame`).
    public var visibleFrame: CGRect
    /// True for the main display: the one with the menu bar (`NSScreen.screens.first`).
    public var isMain: Bool

    public init(displayID: UInt32, uuid: String, name: String, frame: CGRect, visibleFrame: CGRect, isMain: Bool) {
        self.displayID = displayID
        self.uuid = uuid
        self.name = name
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.isMain = isMain
    }

    /// The connected displays, the main display first.
    @MainActor
    public static func current() -> [BlockDisplay] {
        NSScreen.screens.enumerated().map { index, screen in
            let id = ScreenSpace.displayID(of: screen)
            return BlockDisplay(displayID: id, uuid: uuid(of: id) ?? "", name: screen.localizedName, frame: screen.frame,
                                visibleFrame: screen.visibleFrame, isMain: index == 0)
        }
    }

    /// The UUID string of a display id, or nil when the system has none for it.
    public static func uuid(of displayID: UInt32) -> String? {
        guard displayID != 0, let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    /// The value the settings use for "the main display, whichever it is".
    public static let mainSetting = "main"

    /// True when a remembered display value means the main display (nil, empty or `mainSetting`).
    public static func meansMain(_ remembered: String?) -> Bool {
        guard let remembered else { return true }
        let trimmed = remembered.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.lowercased() == mainSetting
    }

    /// The display the block uses alone: the remembered one by UUID when it is connected, else the main display (else
    /// the first one). Nil only when no display is connected.
    public static func choose(remembered: String?, among displays: [BlockDisplay]) -> BlockDisplay? {
        if !meansMain(remembered), let remembered,
           let match = displays.first(where: { !$0.uuid.isEmpty && $0.uuid.caseInsensitiveCompare(remembered) == .orderedSame }) {
            return match
        }
        return displays.first(where: \.isMain) ?? displays.first
    }
}
