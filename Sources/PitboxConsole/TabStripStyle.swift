import AppKit

/// What a tab's small dot says. One state at a time; the most urgent wins.
enum TabStatus: Equatable {
    case none
    /// A program (not an idle shell) is running in the tab.
    case running
    /// Output arrived while the tab was in the background.
    case activity
    /// The bell rang while the tab was in the background.
    case attention
    /// The process ended.
    case exited
    /// The process ended with an error.
    case failed

    /// Words for the tooltip and VoiceOver.
    var summary: String? {
        switch self {
        case .none: return nil
        case .running: return "Running a program"
        case .activity: return "New output"
        case .attention: return "The bell rang"
        case .exited: return "The process has ended"
        case .failed: return "The process ended with an error"
        }
    }
}

/// The colors of the tab strip, derived from the terminal's palette so the strip matches the terminal in dark and light.
///
/// The strip sits on the terminal's tint, which sits on the strip's glass. Every fill here is translucent (so the glass
/// still shows) except the active tab in the light theme; titles are always opaque or nearly so and are contrast-checked
/// in the tests against the fill they sit on.
struct TabStripStyle: Equatable {
    enum TabState { case inactive, hovered, active, warning }

    /// The paint of one tab in one state.
    struct TabColors: Equatable {
        var fill: NSColor
        var outline: NSColor
        var title: NSColor
        var badgeFill: NSColor
        var badgeText: NSColor
    }

    let isDark: Bool
    let accent: NSColor
    /// The darkening (or lightening) under the whole strip that sets it apart from the terminal area.
    let band: NSColor
    let separator: NSColor
    /// The ring around a status dot, so the dot stays crisp on any tab.
    let halo: NSColor
    let inactive: TabColors
    let hovered: TabColors
    let active: TabColors
    /// The "Kill? click again" state of a tab.
    let warning: TabColors
    let buttonFill: NSColor
    let buttonHoverFill: NSColor
    /// "+" while the mouse button is down on it: one step further from the strip than the hover (tested: the glyph keeps 3:1).
    let buttonPressedFill: NSColor
    let buttonOutline: NSColor
    let glyph: NSColor
    let glyphDisabled: NSColor
    /// The auto-rotate indicator: an "on" toggle painted like the active tab's number badge (accent fill, contrasting glyph).
    let toggleFill: NSColor
    let toggleHoverFill: NSColor
    let togglePressedFill: NSColor
    let toggleGlyph: NSColor
    /// The close button's circle, drawn in the tab's title color at these opacities when hovered and while pressed (the X
    /// keeps 3:1 on the pressed circle, tested).
    static let closeHoverAlpha: CGFloat = 0.22
    static let closePressedAlpha: CGFloat = 0.3
    /// The status dots, fixed per theme (not the appearance-dependent system colors): good green, bad red and a dimmed
    /// grey (the bell is orange). On the light theme the
    /// dots sit on a near-white ring, so they are the darker variants: 3:1 or better against it (tested).
    let running: NSColor
    let attention: NSColor
    let failed: NSColor
    let exited: NSColor
    /// A soft shadow under the active tab (light theme only).
    let activeShadow: NSColor?
    /// The opacity of the title of a background tab whose process has ended: dimmed, but still 4.5:1 or better (tested).
    let exitedTitleAlpha: CGFloat

    init(palette: TerminalPalette) {
        isDark = palette.isDark
        accent = palette.accent
        halo = palette.background
        let fg = palette.foreground
        let danger = palette.ansi[1]
        // `ink` is the color translucent fills are made of: white on the dark theme, black on the light one.
        let ink: NSColor = palette.isDark ? .white : .black
        func a(_ color: NSColor, _ alpha: CGFloat) -> NSColor { color.withAlphaComponent(alpha) }
        if palette.isDark {
            band = a(.black, 0.32)
            separator = a(.white, 0.13)
            inactive = TabColors(fill: a(ink, 0.09), outline: a(ink, 0.24), title: a(fg, 0.82),
                                 badgeFill: a(ink, 0.15), badgeText: a(fg, 0.88))
            hovered = TabColors(fill: a(ink, 0.17), outline: a(ink, 0.38), title: fg,
                                badgeFill: a(ink, 0.12), badgeText: fg)
            active = TabColors(fill: a(ink, 0.24), outline: a(palette.accent, 0.90), title: .white,
                               badgeFill: palette.accent, badgeText: palette.background)
            activeShadow = nil
        } else {
            band = a(.black, 0.09)
            separator = a(.black, 0.16)
            inactive = TabColors(fill: a(ink, 0.06), outline: a(ink, 0.28), title: a(fg, 0.82),
                                 badgeFill: a(ink, 0.10), badgeText: a(fg, 0.88))
            hovered = TabColors(fill: a(ink, 0.11), outline: a(ink, 0.42), title: fg,
                                badgeFill: a(ink, 0.15), badgeText: fg)
            active = TabColors(fill: .white, outline: a(palette.accent, 0.90), title: .black,
                               badgeFill: palette.accent, badgeText: .white)
            activeShadow = a(.black, 0.16)
        }
        warning = TabColors(fill: a(danger, palette.isDark ? 0.26 : 0.10), outline: a(danger, 0.95), title: palette.isDark ? .white : (danger.blended(withFraction: 0.5, of: .black) ?? danger),
                            badgeFill: danger, badgeText: palette.isDark ? palette.background : .white)
        buttonFill = a(ink, palette.isDark ? 0.12 : 0.07)
        buttonHoverFill = a(ink, palette.isDark ? 0.24 : 0.15)
        buttonPressedFill = a(ink, palette.isDark ? 0.30 : 0.22)
        buttonOutline = a(ink, palette.isDark ? 0.30 : 0.30)
        glyph = a(fg, 0.95)
        glyphDisabled = a(fg, 0.32)
        toggleFill = palette.accent
        toggleHoverFill = palette.accent.blended(withFraction: 0.2, of: palette.isDark ? .white : .black) ?? palette.accent
        togglePressedFill = palette.accent.blended(withFraction: 0.35, of: palette.isDark ? .white : .black) ?? palette.accent
        toggleGlyph = palette.isDark ? palette.background : .white
        func pick(dark: UInt32, light: UInt32) -> NSColor { TerminalTheme.hex(palette.isDark ? dark : light) }
        running = pick(dark: 0x30D158, light: 0x248A3D)
        attention = pick(dark: 0xFF9F0A, light: 0xB25000)
        failed = pick(dark: 0xFF453A, light: 0xD70015)
        exited = pick(dark: 0x9E9E9E, light: 0x6B6B6B)
        // 0.7 on the light theme left 3.9:1 on a hovered tab over light glass; 0.8 keeps it above 4.5.
        exitedTitleAlpha = palette.isDark ? 0.7 : 0.8
    }

    func colors(for state: TabState) -> TabColors {
        switch state {
        case .inactive: return inactive
        case .hovered: return hovered
        case .active: return active
        case .warning: return warning
        }
    }

    /// The dot color for a status.
    func dotColor(for status: TabStatus) -> NSColor? {
        switch status {
        case .none: return nil
        case .running: return running
        case .activity: return accent
        case .attention: return attention
        case .failed: return failed
        case .exited: return exited
        }
    }
}

/// The words on the strip's tooltips: the shortcuts the console handles while the terminal has the keyboard.
enum TabStripHelp {
    static let newTab = """
    New tab  \u{2318}T
    Switch tab  \u{2318}1 \u{2013} \u{2318}8, \u{2318}9 = last
    Next / previous  \u{2303}Tab / \u{2303}\u{21E7}Tab, \u{2318}\u{21E7}] / \u{2318}\u{21E7}[, \u{2318}\u{2325}\u{2192} / \u{2318}\u{2325}\u{2190}
    Close tab  \u{2318}W (or middle-click)
    Give the keyboard back  \u{2318}\u{238B}
    """
    static let newTabDisabled = "The tab limit is reached. Close a tab to open another (\u{2318}W)."
    static let presets = "Open a preset (Shell, Claude, \u{2026}), turn tab auto-rotate on or off, edit presets"
    static let rotate = "Tabs rotate by themselves. Click to turn auto-rotate off."
    /// What a tab says after a first click on its close button while a program runs in it.
    static let killLabel = "Kill? click again"
    static let killHelp = "A program is running: close the tab again within 3 seconds to end it"

    /// What VoiceOver says when a close asks "Kill?" (the tab's label changes, but the VoiceOver cursor may be elsewhere).
    static func killAnnouncement(title: String) -> String { "\(title): \(killHelp)" }

    /// The extra lines of a tab's tooltip: what its dot means and which shortcut selects it.
    static func tabLines(index: Int, count: Int, status: TabStatus) -> [String] {
        var lines: [String] = []
        if let summary = status.summary { lines.append(summary) }
        if let digit = TabNumbering.shortcutDigit(index: index, count: count) {
            lines.append("Select: \u{2318}\(digit)\(digit == 9 && index >= 8 ? " (last tab)" : "")")
        }
        return lines
    }
}

extension TerminalTheme {
    /// `top` painted over an opaque `bottom` (both sRGB), for contrast checks against what is really behind a title.
    static func composite(_ top: NSColor, over bottom: NSColor) -> NSColor {
        let t = top.usingColorSpace(.sRGB) ?? top
        let b = bottom.usingColorSpace(.sRGB) ?? bottom
        let alpha = t.alphaComponent
        func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x * alpha + y * (1 - alpha) }
        return NSColor(srgbRed: mix(t.redComponent, b.redComponent), green: mix(t.greenComponent, b.greenComponent),
                       blue: mix(t.blueComponent, b.blueComponent), alpha: 1)
    }
}
