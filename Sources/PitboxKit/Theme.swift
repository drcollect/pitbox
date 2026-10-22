import AppKit

// Pitbox's colour theme: an indigo-to-lavender palette and the roles the block draws with, for light and dark. This
// file is the one source of truth: every view reads these values.
//
// Colours that keep their own meaning are not part of the accent and stay as they are: good/warn/bad (green, amber, red)
// and the blue of "running".

/// One theme colour: an sRGB value (and opacity) for light appearances and one for dark appearances.
public struct ThemeColor: Sendable, Equatable {
    /// `0xRRGGBB` for light appearances (aqua and its high-contrast variant).
    public let light: UInt32
    /// `0xRRGGBB` for dark appearances (darkAqua and its high-contrast variant).
    public let dark: UInt32
    /// Opacity of the light variant, 0...1.
    public let lightAlpha: CGFloat
    /// Opacity of the dark variant, 0...1.
    public let darkAlpha: CGFloat

    public init(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) {
        self.light = light & 0xFF_FFFF
        self.dark = dark & 0xFF_FFFF
        self.lightAlpha = min(max(lightAlpha, 0), 1)
        self.darkAlpha = min(max(darkAlpha, 0), 1)
    }

    /// The same colours at other opacities, for example a translucent fill made from the accent.
    public func opacity(light: CGFloat, dark: CGFloat) -> ThemeColor {
        ThemeColor(light: self.light, dark: self.dark, lightAlpha: light, darkAlpha: dark)
    }

    /// The variant for an appearance the caller already knows, as a fixed sRGB colour (the monitors' palettes pick by
    /// `dark`).
    public func color(dark: Bool) -> NSColor {
        Self.srgb(dark ? self.dark : light, alpha: dark ? darkAlpha : lightAlpha)
    }

    /// A dynamic colour that resolves to the light or dark variant for the appearance it is drawn with: AppKit drawing,
    /// layer colours set inside `NSAppearance.performAsCurrentDrawingAppearance`, and SwiftUI through `Color(nsColor:)`.
    public var nsColor: NSColor {
        let value = self
        return NSColor(name: nil) { appearance in value.color(dark: ThemeColor.isDark(appearance)) }
    }


    /// Whether `appearance` is one of the dark ones (darkAqua, vibrantDark, high-contrast dark).
    public static func isDark(_ appearance: NSAppearance) -> Bool {
        let match = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
        return match == .darkAqua || match == .accessibilityHighContrastDarkAqua
    }

    /// An sRGB colour from `0xRRGGBB`.
    public static func srgb(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }

}

/// The block's colours: the palette and the roles built from it.
///
/// Which role to use:
/// - a glyph, icon, dot, focus ring, outline, meter, selection mark, or a translucent fill made from it: `accent`;
/// - a soft background for a chip, a selected or pressed row, a header band (text on it stays the normal text colour):
///   `accentSoft`;
/// - words and links in the accent colour: `accentText`;
/// - a solid fill under a white label (primary button, number badge, "on" toggle): `accentStrong` with `onAccent`;
/// - the block's glass: `glassTint`; the card behind each monitor and its hairline: `card`, `cardLine`.
public enum PitboxTheme {
    /// The palette, dark to light (`0xRRGGBB`), with each colour's share of the source image.
    public enum Palette {
        /// 20 % of the image.
        public static let indigo: UInt32 = 0x2E309A
        /// 16 %.
        public static let indigoViolet: UInt32 = 0x5447BA
        /// 11 %.
        public static let violet: UInt32 = 0x7D65D2
        /// 10 %.
        public static let lavender: UInt32 = 0xA487E5
        /// 23 %.
        public static let lightLavender: UInt32 = 0xBEA3F1
        /// 19 %.
        public static let paleLavender: UInt32 = 0xDED2FD
        /// All six, dark to light.
        public static let all: [UInt32] = [indigo, indigoViolet, violet, lavender, lightLavender, paleLavender]
    }

    /// Glyphs, icons, dots, focus rings, outlines, meters and selection marks, and the base of translucent accent fills.
    /// Light #5447BA (5.65:1 on a light block), dark #A487E5 (4.77:1 on a dark block). Too light for white text in
    /// dark: a filled control with a white label uses `accentStrong`.
    public static let accent = ThemeColor(light: Palette.indigoViolet, dark: Palette.lavender)

    /// Solid fills that carry a white label (`onAccent`): primary buttons, number badges, "on" toggles. #5447BA in both
    /// appearances: white on it is 7.03:1.
    public static let accentStrong = ThemeColor(light: Palette.indigoViolet, dark: Palette.indigoViolet)

    /// Soft translucent fills: chips, selected or pressed rows, header bands. The normal text colour stays readable on it.
    public static let accentSoft = ThemeColor(light: Palette.indigoViolet, dark: Palette.lavender, lightAlpha: 0.14, darkAlpha: 0.22)

    /// Words and links in the accent colour. Light #5447BA (5.65:1 on a light block), dark #BEA3F1 (6.45:1 on a dark
    /// block).
    public static let accentText = ThemeColor(light: Palette.indigoViolet, dark: Palette.lightLavender)

    /// Labels and glyphs drawn on `accentStrong`.
    public static let onAccent = ThemeColor(light: 0xFFFFFF, dark: 0xFFFFFF)

    /// The tint of the block's Liquid Glass (`NSGlassEffectView.tintColor`) and of the overlay on the non-glass fallback.
    /// Strong on purpose: the block reads as purple over any wallpaper; the monitors' own cards (`card`) keep the text
    /// readable on it.
    public static let glassTint = ThemeColor(light: Palette.violet, dark: Palette.indigoViolet, lightAlpha: 0.36, darkAlpha: 0.52)

    /// The card behind every monitor: a purple wash instead of a grey one.
    public static let card = ThemeColor(light: Palette.violet, dark: Palette.lavender, lightAlpha: 0.13, darkAlpha: 0.15)

    /// The hairline around a monitor's card.
    public static let cardLine = ThemeColor(light: Palette.indigoViolet, dark: Palette.lightLavender, lightAlpha: 0.24, darkAlpha: 0.28)


    /// A plain blue for meanings that are blue by convention and must not turn purple with the accent ("running").
    /// #007AFF light, #0A84FF dark. Never use it as an accent.
    public static let blue = ThemeColor(light: 0x007AFF, dark: 0x0A84FF)

}
