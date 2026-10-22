import AppKit
import PitboxKit

/// The Ready list's colours: dark values from the original design, light values chosen to pass the contrast rule's
/// 4.5:1 for text and 3:1 for outlines in both themes (checked by `ReadyPaletteTests`). Each card is its own object on
/// the block's glass, like the monitors: its kind's colour shows on the 1 pt border, the title and the main button,
/// never as the only signal (each title has its sign and word). The list's own header sits on the glass and uses the
/// block header's colours (`CodeMonitorPalette`).
struct CodeReadyPalette {
    /// One kind's colours in one appearance.
    struct Tone: Equatable {
        /// Title words, the main button's words and the border.
        var accent: UInt32
        /// The card's background.
        var background: UInt32
        /// The main button's fill (the accent at `fillAlpha` over the background).
        var fillAlpha: CGFloat
        /// The main button's words on that fill.
        var words: UInt32
    }

    let dark: Bool

    // Dark (the original design's accents and backgrounds).
    static let commandDark = Tone(accent: 0x57D38C, background: 0x10241A, fillAlpha: 0.2, words: 0xC9F5DB)
    static let fileDark = Tone(accent: 0x6CB6FF, background: 0x0F1D2C, fillAlpha: 0.2, words: 0xD3E8FF)
    static let finishedDark = Tone(accent: 0x6FCF73, background: 0x121C14, fillAlpha: 0.2, words: 0xCDEFD0)
    static let warningDark = Tone(accent: 0xFFB36B, background: 0x231A0F, fillAlpha: 0.2, words: 0xFFE0C2)
    static let neutralDark = Tone(accent: 0x9AA1AD, background: 0x1B1E25, fillAlpha: 0.2, words: 0xE2E5EA)
    static let textDark: UInt32 = 0xE7E9EE
    static let dimDark: UInt32 = 0xA9AFBC
    static let buttonTextDark: UInt32 = 0xE2E5EA
    /// ▦ (pink) and ↗ (violet) buttons: their fill colour and their words.
    static let dashboardDark: UInt32 = 0xF58AC4, dashboardWordsDark: UInt32 = 0xFFD6EC
    static let linkDark: UInt32 = 0xB9A3FF, linkWordsDark: UInt32 = 0xE6DEFF
    static let outlineNeutralDark: UInt32 = 0x959DAE

    // Light (chosen here).
    static let commandLight = Tone(accent: 0x166B3B, background: 0xEDF8F1, fillAlpha: 0.12, words: 0x0E4A28)
    static let fileLight = Tone(accent: 0x1A5A9E, background: 0xEDF4FC, fillAlpha: 0.12, words: 0x0F3F73)
    static let finishedLight = Tone(accent: 0x26702A, background: 0xEEF7EE, fillAlpha: 0.12, words: 0x18501B)
    static let warningLight = Tone(accent: 0x8A4700, background: 0xFFF4E8, fillAlpha: 0.12, words: 0x5E3000)
    static let neutralLight = Tone(accent: 0x5A6070, background: 0xF6F5FA, fillAlpha: 0.12, words: 0x30343F)
    static let textLight: UInt32 = 0x1E1B2E
    static let dimLight: UInt32 = 0x4A4560
    static let buttonTextLight: UInt32 = 0x2E2A44
    static let dashboardLight: UInt32 = 0x9C1F66, dashboardWordsLight: UInt32 = 0x6E0F45
    static let linkLight: UInt32 = 0x5235C7, linkWordsLight: UInt32 = 0x371F99
    static let outlineNeutralLight: UInt32 = 0x58556C

    func tone(_ kind: CodeReadyItem.Kind?) -> Tone {
        switch kind {
        case .command?: return dark ? Self.commandDark : Self.commandLight
        case .file?: return dark ? Self.fileDark : Self.fileLight
        case .finished?: return dark ? Self.finishedDark : Self.finishedLight
        case .warning?: return dark ? Self.warningDark : Self.warningLight
        case nil: return dark ? Self.neutralDark : Self.neutralLight
        }
    }

    var text: NSColor { Self.color(dark ? Self.textDark : Self.textLight) }
    var dim: NSColor { Self.color(dark ? Self.dimDark : Self.dimLight) }
    var buttonText: NSColor { Self.color(dark ? Self.buttonTextDark : Self.buttonTextLight) }
    var dashboard: NSColor { Self.color(dark ? Self.dashboardDark : Self.dashboardLight) }
    var link: NSColor { Self.color(dark ? Self.linkDark : Self.linkLight) }
    /// The border of the recap card and of Later and result rows (the block's neutral card line).
    var neutralOutline: NSColor { Self.color(dark ? Self.outlineNeutralDark : Self.outlineNeutralLight) }
    /// Secondary buttons: a faint fill of the text colour.
    var secondaryFill: NSColor { dark ? Self.color(0xFFFFFF, 0.08) : Self.color(0x000000, 0.06) }
    var secondaryHover: NSColor { dark ? Self.color(0xFFFFFF, 0.14) : Self.color(0x000000, 0.1) }
    var disabledText: NSColor { dim.withAlphaComponent(0.55) }

    static func color(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor { ThemeColor.srgb(value, alpha: alpha) }
}

/// The list's fonts: 12 pt or larger everywhere.
enum CodeReadyFonts {
    static let title = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let detail = NSFont.systemFont(ofSize: 12)
    static let line = NSFont.systemFont(ofSize: 12)
    static let command = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let chip = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let button = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let header = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let headerNote = NSFont.systemFont(ofSize: 12)
    static let section = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
}
