import AppKit
import PitboxKit
import SwiftTerm

/// Colors of one appearance: the 16 ANSI colors, default text and background, selection.
struct TerminalPalette: Equatable {
    var isDark: Bool
    var foreground: NSColor
    /// The tint under the text. The console paints it with `backgroundOpacity`; the terminal's own default background is
    /// transparent, so the glass shows through and text stays fully opaque.
    var background: NSColor
    /// ANSI 0...7 then the bright 8...15.
    var ansi: [NSColor]
    var selectionBackground: NSColor
    var selectionForeground: NSColor
    var accent: NSColor
}

enum TerminalTheme {
    static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
                blue: CGFloat(value & 0xff) / 255, alpha: alpha)
    }

    /// Light text on a near-black tint. The ANSI colors are a softened One-Dark-like set that keeps its contrast on the
    /// translucent background. Accent (tab highlight, focus ring) and selection come from the block's theme
    /// (`PitboxTheme`): lavender accent, indigo-violet selection under white text (7.0:1).
    static let dark = TerminalPalette(
        isDark: true, foreground: hex(0xE6E9EF), background: hex(0x0C0E13),
        ansi: [0x3F4551, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xABB2BF,
               0x6B7385, 0xFF7B86, 0xA9D68B, 0xF0CE8E, 0x79BEFF, 0xD78EEB, 0x6BC8D4, 0xE6EAF2].map { hex($0) },
        selectionBackground: hex(PitboxTheme.Palette.indigoViolet), selectionForeground: hex(0xFFFFFF),
        accent: PitboxTheme.accent.color(dark: true))

    /// Dark text on a near-white tint, with darker variants of every ANSI color so they stay readable on white. Accent
    /// and selection from the theme: indigo-violet accent, pale lavender selection under near-black indigo text.
    static let light = TerminalPalette(
        isDark: false, foreground: hex(0x1F2328), background: hex(0xFCFCFE),
        ansi: [0x24292F, 0xCF222E, 0x116329, 0x7D4E00, 0x0550AE, 0x8250DF, 0x0E7C86, 0x6E7781,
               0x57606A, 0xA40E26, 0x1A7F37, 0x9A6700, 0x0969DA, 0xA371F7, 0x1C8F9A, 0x6B747E].map { hex($0) },
        selectionBackground: hex(PitboxTheme.Palette.paleLavender), selectionForeground: hex(0x17153A),
        accent: PitboxTheme.accent.color(dark: false))

    static func palette(isDark: Bool) -> TerminalPalette { isDark ? dark : light }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// The configured font. `SF Mono` (or an empty or unknown name, or a proportional font) means the system monospaced
    /// font, which is SF Mono on macOS.
    static func font(name: String, size: Double) -> NSFont {
        let points = CGFloat(min(max(size, TerminalSettings.fontSizeRange.lowerBound), TerminalSettings.fontSizeRange.upperBound))
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let system = ["", "sf mono", "sfmono-regular", "system", "system monospaced"]
        if !system.contains(trimmed.lowercased()), let font = NSFont(name: trimmed, size: points), font.isFixedPitch { return font }
        return NSFont.monospacedSystemFont(ofSize: points, weight: .regular)
    }

    /// `#RRGGBB` of a color (for tests and logs).
    static func hexString(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        func byte(_ v: CGFloat) -> Int { Int((v * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }

    /// WCAG relative luminance of an sRGB color.
    static func luminance(_ color: NSColor) -> Double {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        func channel(_ value: CGFloat) -> Double {
            let v = Double(value)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(rgb.redComponent) + 0.7152 * channel(rgb.greenComponent) + 0.0722 * channel(rgb.blueComponent)
    }

    /// WCAG contrast ratio, 1...21.
    static func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}

extension TerminalPalette {
    /// The palette's tint with the configured opacity, for the console to paint.
    func tint(opacity: Double) -> NSColor { background.withAlphaComponent(CGFloat(opacity)) }
}

extension CursorShape {
    var swiftTerm: CursorStyle {
        switch self {
        case .blinkBlock: return .blinkBlock
        case .steadyBlock: return .steadyBlock
        case .blinkBar: return .blinkBar
        case .steadyBar: return .steadyBar
        case .blinkUnderline: return .blinkUnderline
        case .steadyUnderline: return .steadyUnderline
        }
    }
}

extension BellMode {
    var swiftTerm: BellStyle {
        switch self {
        case .visual: return .visual
        case .sound: return .sound
        case .soundAndVisual: return .soundAndVisual
        case .none: return .none
        }
    }
}
