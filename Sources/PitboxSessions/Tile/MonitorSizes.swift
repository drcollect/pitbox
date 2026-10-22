import CoreGraphics
import Foundation

/// The three monitor sizes of a bucket: like an iPhone folder, 1-4 monitors are large, 5-9 medium, 10 or more small,
/// the same size for every monitor of the bucket. Past a page (the original design's 4, 9 and 12 at three columns,
/// fewer on a narrower block: `CodeMonitorGrid`) the bucket gets pages with dots. The numbers are `CodeTuning`'s.
public enum CodeMonitorSize: String, CaseIterable, Sendable {
    case large, medium, small

    /// The size for a bucket of `count` monitors.
    public static func forCount(_ count: Int) -> CodeMonitorSize {
        if count < CodeTuning.densityMediumFrom { return .large }
        return count < CodeTuning.densitySmallFrom ? .medium : .small
    }

    /// Monitors on one page at most: 4, 9, 12 (the original design's numbers; a block of fewer columns pages sooner).
    public var perPage: Int {
        switch self {
        case .large: return CodeTuning.perPageLarge
        case .medium: return CodeTuning.perPageMedium
        case .small: return CodeTuning.perPageSmall
        }
    }

    /// Rows one page may have: 2, 3, 2, so a page never grows taller than the body planned for its size.
    public var rowsAPage: Int {
        switch self {
        case .large: return CodeTuning.rowsPerPageLarge
        case .medium: return CodeTuning.rowsPerPageMedium
        case .small: return CodeTuning.rowsPerPageSmall
        }
    }

    /// A monitor's height: large 219 pt (the full-size monitor), medium 150, small 104.
    public var height: CGFloat {
        switch self {
        case .large: return CodeTuning.largeHeight
        case .medium: return CodeTuning.mediumHeight
        case .small: return CodeTuning.smallHeight
        }
    }

    /// Monitors per grid column: small ones sit two to a column.
    var perColumn: Int { self == .small ? 2 : 1 }

    /// Monitors on one page at `columns` monitor columns: the original design's number, or the rows a page
    /// allows, whichever is smaller. At 1, 2, 3 and 4 grid columns: 2 / 3 / 4, 4 / 6 / 8, 4 / 9 / 12, 4 / 9 / 12.
    func perPage(columns: Int) -> Int { max(1, min(perPage, rowsAPage * max(1, columns))) }
}

/// Slim rows (`look: "rows"`): one 36 pt row per monitor across the block, 6 pt apart, 8 a page.
enum CodeMonitorRows {
    static let height = CodeTuning.rowHeight
    static let gap: CGFloat = 6
    static let perPage = CodeTuning.perPageRows
}
