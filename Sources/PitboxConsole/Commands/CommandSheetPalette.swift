import AppKit
import PitboxKit

/// The sheet's colours and fonts: an opaque card (nothing can draw into it), the theme's text tokens, red for red lines,
/// amber for warnings and non-ASCII marks, green for Yes, run this.
struct CommandSheetPalette: Equatable {
    let dark: Bool

    init(dark: Bool) { self.dark = dark }
    init(_ appearance: NSAppearance) { dark = ThemeColor.isDark(appearance) }

    /// The card: opaque in both appearances.
    var fill: NSColor { dark ? Self.rgb(0x1B1E25) : Self.rgb(0xFBFBFD) }
    var outline: NSColor { dark ? Self.rgb(0x3D4352) : Self.rgb(0xC9CBD4) }
    var fg: NSColor { dark ? Self.rgb(0xE7E9EE) : Self.rgb(0x1D1F24) }
    var dim: NSColor { dark ? Self.rgb(0xA3A9B6) : Self.rgb(0x5C6170) }
    var faint: NSColor { dark ? Self.rgb(0x6F7686) : Self.rgb(0x8A8F9C) }
    var line: NSColor { dark ? Self.rgb(0x2E333F) : Self.rgb(0xDCDEE5) }
    /// Session text's own background: its extent is visible, so a quote mark inside it cannot pass for the end.
    var sessionBackground: NSColor { dark ? Self.rgb(0x262A33) : Self.rgb(0xEEF0F4) }
    /// The command area.
    var screen: NSColor { dark ? Self.rgb(0x101215) : Self.rgb(0xF4F5F8) }
    var screenFG: NSColor { dark ? Self.rgb(0xEEF0F4) : Self.rgb(0x16181D) }
    var gutter: NSColor { dark ? Self.rgb(0x5D6474) : Self.rgb(0x9095A2) }
    /// The faint panel behind a here-doc body in the command area.
    var hereDocument: NSColor { dark ? Self.rgb(0x1D2129) : Self.rgb(0xE6E8EE) }
    var red: NSColor { dark ? Self.rgb(0xEF5B5B) : Self.rgb(0xC62828) }
    var redFill: NSColor { dark ? Self.rgb(0x2A1414) : Self.rgb(0xFDECEC) }
    var redLine: NSColor { dark ? Self.rgb(0x5A2626) : Self.rgb(0xF1B9B9) }
    var redText: NSColor { dark ? Self.rgb(0xFFD0D0) : Self.rgb(0x8B1A1A) }
    var amber: NSColor { dark ? Self.rgb(0xF2A33A) : Self.rgb(0x9A5B00) }
    var amberFill: NSColor { dark ? Self.rgb(0x4A3412) : Self.rgb(0xFFE8BF) }
    var go: NSColor { dark ? Self.rgb(0x57D38C) : Self.rgb(0x1E8E4F) }
    var onGo: NSColor { dark ? Self.rgb(0x04150B) : Self.rgb(0xFFFFFF) }
    var danger: NSColor { dark ? Self.rgb(0xEF5B5B) : Self.rgb(0xC62828) }
    var onDanger: NSColor { dark ? Self.rgb(0x1A0606) : Self.rgb(0xFFFFFF) }
    var secondary: NSColor { dark ? Self.rgb(0x232731) : Self.rgb(0xECEDF2) }
    var secondaryHover: NSColor { dark ? Self.rgb(0x2D323E) : Self.rgb(0xE1E3EA) }
    var accent: NSColor { PitboxTheme.accent.color(dark: dark) }
    var accentSoft: NSColor { PitboxTheme.accentSoft.color(dark: dark) }

    static func rgb(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor { ThemeColor.srgb(value, alpha: alpha) }
}

/// The sheet's fonts.
enum CommandSheetFonts {
    static let title = NSFont.systemFont(ofSize: 15, weight: .semibold)
    static let label = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let value = NSFont.systemFont(ofSize: 13, weight: .regular)
    static let note = NSFont.systemFont(ofSize: 12, weight: .regular)
    static let button = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let monoSmall = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let codePoint = NSFont.monospacedSystemFont(ofSize: 8.5, weight: .medium)
    static let gutter = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    static func width(_ text: String, _ font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}
