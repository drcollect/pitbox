import AppKit

/// How the block looks: light, dark or the system's, on glass, vibrancy or a solid backdrop. Docked, the host's
/// `appearance` (docs/DOCK_PROTOCOL.md §5.7) so the docked area reads as one surface; alone, `.system` (the system's
/// light or dark, on glass).
public struct BlockAppearance: Equatable, Sendable {
    /// Light or dark.
    public enum Scheme: String, Sendable, CaseIterable {
        /// Follow the system.
        case system, light, dark

        /// The window appearance for the scheme (nil follows the system).
        public var nsAppearance: NSAppearance? {
            switch self {
            case .system: return nil
            case .light: return NSAppearance(named: .aqua)
            case .dark: return NSAppearance(named: .darkAqua)
            }
        }
    }

    /// The material behind the content.
    public enum Backdrop: String, Sendable, CaseIterable {
        /// Liquid Glass (`NSGlassEffectView`) with the theme's tint.
        case glass
        /// Behind-window vibrancy (`NSVisualEffectView`) with the theme's tint.
        case vibrancy
        /// An opaque window background with the theme's tint.
        case solid
    }

    public var scheme: Scheme
    public var backdrop: Backdrop

    public init(scheme: Scheme = .system, backdrop: Backdrop = .glass) {
        self.scheme = scheme
        self.backdrop = backdrop
    }

    /// The look alone: the system's light or dark, on glass.
    public static let system = BlockAppearance()
}
