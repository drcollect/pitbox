import Foundation
import Testing
@testable import PitboxSessions
import PitboxKit

/// The Ready cards' colours: text 4.5:1 on its background, outlines 3:1 against the glass,
/// in both appearances.
@Suite("Ready colours")
struct ReadyPaletteTests {
    typealias P = CodeReadyPalette
    static let kinds: [CodeReadyItem.Kind?] = [.command, .file, .finished, .warning, nil]

    func check(dark: Bool) {
        let palette = P(dark: dark)
        let glass = dark ? PaletteTests.darkGlass : PaletteTests.lightGlass
        let text = dark ? P.textDark : P.textLight
        let dim = dark ? P.dimDark : P.dimLight
        let buttonText = dark ? P.buttonTextDark : P.buttonTextLight
        for kind in Self.kinds {
            let tone = palette.tone(kind)
            let name = "\(kind.map(\.rawValue) ?? "neutral") \(dark ? "dark" : "light")"
            #expect(PaletteTests.contrast(text, tone.background) >= 4.5, "text \(name)")
            #expect(PaletteTests.contrast(dim, tone.background) >= 4.5, "dim \(name)")
            #expect(PaletteTests.contrast(tone.accent, tone.background) >= 4.5, "title \(name)")
            // The main button: its words on the accent's fill over the card (hovered too).
            for alpha in [tone.fillAlpha, tone.fillAlpha + 0.12] {
                let fill = PaletteTests.over(tone.accent, Double(alpha), tone.background)
                #expect(PaletteTests.contrast(tone.words, fill) >= 4.5, "button \(name) at \(alpha)")
            }
            // Secondary buttons: a faint fill of white (dark) or black (light).
            let secondary = PaletteTests.over(dark ? 0xFFFFFF : 0x000000, dark ? 0.14 : 0.1, tone.background)
            #expect(PaletteTests.contrast(buttonText, secondary) >= 4.5, "secondary \(name)")
            // Dashboard and link buttons on any card.
            let specials = dark ? [(P.dashboardDark, P.dashboardWordsDark), (P.linkDark, P.linkWordsDark)]
                : [(P.dashboardLight, P.dashboardWordsLight), (P.linkLight, P.linkWordsLight)]
            for (special, words) in specials {
                for alpha in [tone.fillAlpha, tone.fillAlpha + 0.12] {
                    let fill = PaletteTests.over(special, Double(alpha), tone.background)
                    #expect(PaletteTests.contrast(words, fill) >= 4.5, "special \(String(special, radix: 16)) \(name)")
                }
            }
            if kind != nil { #expect(PaletteTests.contrast(tone.accent, glass) >= 3, "outline \(name)") }
        }
        let neutral = dark ? P.outlineNeutralDark : P.outlineNeutralLight
        #expect(PaletteTests.contrast(neutral, glass) >= 3, "neutral outline \(dark ? "dark" : "light")")
    }

    @Test func darkTheme() { check(dark: true) }
    @Test func lightTheme() { check(dark: false) }
}
