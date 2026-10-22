import AppKit
import Testing
@testable import PitboxKit

/// The theme's roles, measured: WCAG 2 contrast on the monitor backgrounds the block draws (the card over the stand-in
/// for the glass: #2C2C2E dark, #E6E6EB light) and white on filled controls.
@Suite("Theme")
struct ThemeTests {
    static let darkTile: UInt32 = 0x2C2C2E
    static let lightTile: UInt32 = 0xE6E6EB

    static func channel(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    static func luminance(_ rgb: UInt32) -> Double {
        let r = channel(Double((rgb >> 16) & 0xFF) / 255), g = channel(Double((rgb >> 8) & 0xFF) / 255)
        let b = channel(Double(rgb & 0xFF) / 255)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    @Test func whiteLabelsOnFilledControlsReachAA() {
        let strong = PitboxTheme.accentStrong
        #expect(Self.contrast(0xFFFFFF, strong.light) >= 4.5)
        #expect(Self.contrast(0xFFFFFF, strong.dark) >= 4.5)
        #expect(PitboxTheme.onAccent.light == 0xFFFFFF && PitboxTheme.onAccent.dark == 0xFFFFFF)
        // Why dark mode needs its own fill: white on the dark accent would not be readable.
        #expect(Self.contrast(0xFFFFFF, PitboxTheme.accent.dark) < 4.5)
    }

    @Test func accentTextIsReadableOnTiles() {
        #expect(Self.contrast(PitboxTheme.accentText.light, Self.lightTile) >= 4.5)
        #expect(Self.contrast(PitboxTheme.accentText.dark, Self.darkTile) >= 4.5)
        // The plain accent is readable as text too, and well above the 3:1 needed for glyphs and outlines.
        #expect(Self.contrast(PitboxTheme.accent.light, Self.lightTile) >= 4.5)
        #expect(Self.contrast(PitboxTheme.accent.dark, Self.darkTile) >= 4.5)
    }

    @Test func rolesComeFromThePalette() {
        let palette = Set(PitboxTheme.Palette.all)
        for role in [PitboxTheme.accent, PitboxTheme.accentStrong, PitboxTheme.accentSoft, PitboxTheme.accentText,
                     PitboxTheme.glassTint] {
            #expect(palette.contains(role.light) && palette.contains(role.dark))
        }
        #expect(PitboxTheme.Palette.all == [0x2E309A, 0x5447BA, 0x7D65D2, 0xA487E5, 0xBEA3F1, 0xDED2FD])
        // The glass tint stays faint; the soft fill stays a tint.
        #expect(PitboxTheme.glassTint.lightAlpha <= 0.6 && PitboxTheme.glassTint.darkAlpha <= 0.6)
        #expect(PitboxTheme.accentSoft.lightAlpha < 0.3 && PitboxTheme.accentSoft.darkAlpha < 0.3)
    }

    @Test func dynamicColourFollowsTheAppearance() throws {
        let dynamic = PitboxTheme.accent.nsColor
        for (name, dark) in [(NSAppearance.Name.aqua, false), (.darkAqua, true), (.vibrantDark, true), (.vibrantLight, false),
                             (.accessibilityHighContrastDarkAqua, true), (.accessibilityHighContrastAqua, false)] {
            let appearance = try #require(NSAppearance(named: name))
            #expect(ThemeColor.isDark(appearance) == dark)
            var resolved: NSColor?
            appearance.performAsCurrentDrawingAppearance { resolved = dynamic.usingColorSpace(.sRGB) }
            let c = try #require(resolved)
            let rgb = (UInt32((c.redComponent * 255).rounded()) << 16) | (UInt32((c.greenComponent * 255).rounded()) << 8)
                | UInt32((c.blueComponent * 255).rounded())
            #expect(rgb == (dark ? PitboxTheme.accent.dark : PitboxTheme.accent.light))
        }
        let soft = try #require(PitboxTheme.accentSoft.color(dark: true).usingColorSpace(.sRGB))
        #expect(abs(soft.alphaComponent - 0.22) < 0.001)
    }


    @Test func opacityClampsAndKeepsTheColours() {
        let c = PitboxTheme.accent.opacity(light: 2, dark: -1)
        #expect(c.light == PitboxTheme.accent.light && c.dark == PitboxTheme.accent.dark)
        #expect(c.lightAlpha == 1 && c.darkAlpha == 0)
        #expect(ThemeColor(light: 0x1FF_FFFF, dark: 0).light == 0xFF_FFFF)
    }
}
