import AppKit
import PitboxKit

/// A bucket's colour: one of 8 named colours, stored by name in `code-buckets.json`. The colour shows only on the
/// bucket's 14 pt square and as the 2 pt line under its header, never on monitors, so it is never read as a state.
///
/// Dark values are the original design's. Light values were chosen for this build to keep 3:1 against the block's
/// glass in the light appearance (the glass tint over ThemeTests' stand-in backdrop, #C0B8E2; checked by
/// `BucketPaletteTests`); the design's own values are too pale there (1.1-1.8:1).
public enum CodeBucketColor: String, CaseIterable, Sendable {
    case violet, amber, teal, red, green, blue, pink, grey

    /// The menu's word: "Violet", "Amber", …
    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// `0xRRGGBB` in dark appearances (the original design's palette).
    public var dark: UInt32 {
        switch self {
        case .violet: return 0x8F7CF6
        case .amber: return 0xF2A33A
        case .teal: return 0x4FB3A9
        case .red: return 0xEF5B5B
        case .green: return 0x6FBF4A
        case .blue: return 0x4C9BFF
        case .pink: return 0xE57AC9
        case .grey: return 0x9AA1AD
        }
    }

    /// `0xRRGGBB` in light appearances (3:1 or more on the light glass).
    public var light: UInt32 {
        switch self {
        case .violet: return 0x5B44C8
        case .amber: return 0x8A5200
        case .teal: return 0x0D6A62
        case .red: return 0xB4232A
        case .green: return 0x346B17
        case .blue: return 0x1C5BBD
        case .pink: return 0x9C3383
        case .grey: return 0x5A606C
        }
    }

    /// The value for an appearance.
    func value(dark isDark: Bool) -> UInt32 { isDark ? dark : light }

    /// The colour for an appearance.
    func color(dark isDark: Bool) -> NSColor { ThemeColor.srgb(value(dark: isDark)) }

    /// The colour a new bucket gets: the first in palette order that no bucket uses, else the one after the
    /// newest bucket's colour.
    static func forNewBucket(existing: [CodeBucket]) -> CodeBucketColor {
        let used = Set(existing.map(\.color))
        if let free = allCases.first(where: { !used.contains($0) }) { return free }
        let last = existing.last(where: { !$0.isUnsorted })?.color ?? .grey
        let index = allCases.firstIndex(of: last) ?? 0
        return allCases[(index + 1) % allCases.count]
    }
}

/// The badge pills of a bucket header: solid fills with dark words, the same in both appearances (the words
/// carry the meaning; colour is never the only signal). From the original design.
enum CodeBucketBadgeColors {
    /// "2 need you": amber.
    static let needYou: (fill: UInt32, ink: UInt32) = (0xF2A33A, 0x1B1203)
    /// "▶ 3": the command green.
    static let commands: (fill: UInt32, ink: UInt32) = (0x57D38C, 0x04150B)
    /// "⤓ 1": the file blue.
    static let files: (fill: UInt32, ink: UInt32) = (0x6CB6FF, 0x04111F)
    /// "✓ 2 new": Review ready green.
    static let finished: (fill: UInt32, ink: UInt32) = (0x6FCF73, 0x06140A)
    /// "⚠ 1": the warning orange.
    static let warnings: (fill: UInt32, ink: UInt32) = (0xFFB36B, 0x1B1203)
}
