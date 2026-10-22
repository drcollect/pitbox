import AppKit
import PitboxKit

/// The monitors' colours, in the original design's look. A monitor is a dark object in both
/// appearances (its screen is near-black even in the light theme: it is a monitor), so the screen colours are fixed;
/// the header band and the foot labels sit on the block's glass and follow its appearance. Status colours keep their
/// own meaning and are not part of the accent (PitboxTheme's rule); copy A's mark is the theme's accent. Contrast
/// is checked by `PaletteTests`: text 4.5:1 on the screen, dots 3:1 on the bezel.
struct CodeMonitorPalette {
    /// The glass behind the block is dark (header band and foot labels only).
    let dark: Bool

    // MARK: The monitor (fixed)

    static let screen: UInt32 = 0x101215
    static let bezel: UInt32 = 0x3A3D45
    static let bezelHighlight: UInt32 = 0x4A4E59
    static let stand: UInt32 = 0x5C606A
    static let headline: UInt32 = 0xF3F4F6
    static let text: UInt32 = 0xCFD3DA
    /// Nickname, bottom bar, chips.
    static let dim: UInt32 = 0x9097A4
    static let working: UInt32 = 0x4C9BFF
    static let nowText: UInt32 = 0x8EC0FF
    static let amber: UInt32 = 0xF2A33A
    static let askText: UInt32 = 0xFFC978
    static let green: UInt32 = 0x6FCF73
    static let red: UInt32 = 0xEF5B5B
    static let white: UInt32 = 0xF3F4F6
    static let grey: UInt32 = 0x9AA1AD
    /// Command offers (cyan).
    static let cyan: UInt32 = 0x5FD4E6
    /// Profile marks (only when more than one copy runs): A in the accent, B red, C green, unless `profiles` gives a colour.
    static let profileA: UInt32 = PitboxTheme.accent.dark
    static let profileB: UInt32 = 0xEF5B5B
    static let profileC: UInt32 = 0x6FBF4A

    static func color(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor { ThemeColor.srgb(value, alpha: alpha) }

    // MARK: On the block's glass (follows the appearance)

    // Measured on the block's glass without a card (the block has none): the theme's glass tint over the stand-in
    // backdrops of ThemeTests (#413A77 dark, #C0B8E2 light), checked by PaletteTests.
    static let headerTitleDark: UInt32 = 0xF2F0F8, headerTitleLight: UInt32 = 0x1E1B2E
    static let headerTextDark: UInt32 = 0xC9C4DA, headerTextLight: UInt32 = 0x3F3A56
    static let headerFaintDark: UInt32 = 0xB8B2CC, headerFaintLight: UInt32 = 0x4A4560
    static let attentionDark: UInt32 = 0xF6B65A, attentionLight: UInt32 = 0x6B3C00
    /// Header button labels: on the accent's soft fill over the glass, the accent's own text colour is too faint.
    static let buttonTextDark: UInt32 = 0xF2F0F8, buttonTextLight: UInt32 = PitboxTheme.Palette.indigo

    var headerTitle: NSColor { Self.color(dark ? Self.headerTitleDark : Self.headerTitleLight) }
    var headerText: NSColor { Self.color(dark ? Self.headerTextDark : Self.headerTextLight) }
    var headerFaint: NSColor { Self.color(dark ? Self.headerFaintDark : Self.headerFaintLight) }
    var buttonFill: NSColor { PitboxTheme.accentSoft.color(dark: dark) }
    var buttonHover: NSColor { PitboxTheme.accent.color(dark: dark).withAlphaComponent(dark ? 0.32 : 0.22) }
    var buttonText: NSColor { Self.color(dark ? Self.buttonTextDark : Self.buttonTextLight) }
    var buttonDisabledText: NSColor { headerFaint.withAlphaComponent(0.7) }
    var dotOn: NSColor { dark ? Self.color(0xF2F0F8) : Self.color(0x2E2A44) }
    var dotOff: NSColor { dark ? Self.color(0xF2F0F8, 0.28) : Self.color(0x2E2A44, 0.25) }
    var footLabel: NSColor { headerText }
    /// The needs-you count in the header and the banner.
    var attention: NSColor { Self.color(dark ? Self.attentionDark : Self.attentionLight) }

    /// A copy's mark: its own colour from the settings file when it has one, else A in the accent and B and C in the
    /// palette's red and green, any other letter grey.
    static func profileColor(letter: String, colour: UInt32? = nil) -> NSColor {
        if let colour { return color(colour) }
        switch letter {
        case "A": return color(profileA)
        case "B": return color(profileB)
        case "C": return color(profileC)
        default: return color(grey)
        }
    }
}

/// The monitors' fonts: SF for words, SF Mono for nicknames, "Now" lines and command previews. All screen text is 12 pt
/// or larger.
enum CodeMonitorFonts {
    static func headline(_ size: CodeMonitorSize) -> NSFont {
        switch size {
        case .large: return .systemFont(ofSize: 13, weight: .semibold)
        case .medium: return .systemFont(ofSize: 13, weight: .semibold)
        case .small: return .systemFont(ofSize: 12, weight: .semibold)
        }
    }
    static let body = NSFont.systemFont(ofSize: 12)
    static let bodyStrong = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let status = NSFont.systemFont(ofSize: 12)
    static let chip = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let header = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let headerDetail = NSFont.systemFont(ofSize: 12, weight: .regular)
    static let button = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let footLabel = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let peekTitle = NSFont.systemFont(ofSize: 13.5, weight: .semibold)
    static let peekText = NSFont.systemFont(ofSize: 12.5)
    static let peekSmall = NSFont.systemFont(ofSize: 12)
    static let peekLabel = NSFont.systemFont(ofSize: 11, weight: .semibold)
    /// A slim row's headline and a bucket's name.
    static let rowHeadline = NSFont.systemFont(ofSize: 13, weight: .semibold)
    /// The words of a mark's pill (`CodeMonitorMark`), and of a small monitor's glyph-only pill.
    static let mark = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let markSmall = NSFont.systemFont(ofSize: 12, weight: .bold)

    /// One line's height for `font` (ascender to descender, plus leading), rounded up.
    static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }
}
