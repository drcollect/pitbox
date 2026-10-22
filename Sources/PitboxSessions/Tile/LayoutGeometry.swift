import CoreGraphics

// Finite layout geometry. The block once crashed the app on its first layout: SwiftUI hosted it at width 0, `insetBy`
// returned `CGRect.null` (whose origin is infinite), ∞ − ∞ gave NaN, and `Int(NaN)` trapped in
// `CodeMonitorLayout.placeLarge`. Layout code takes its rects through these helpers so that no size AppKit hands over can
// produce an infinite or NaN coordinate (DegenerateSizeTests).

extension CGRect {
    /// True when origin and size are finite numbers: not `CGRect.null`, not `CGRect.infinite`, no NaN.
    var isFiniteRect: Bool {
        // `CGRect.infinite` is made of huge finite numbers, so it is named explicitly.
        !isInfinite && origin.x.isFinite && origin.y.isFinite && size.width.isFinite && size.height.isFinite
    }

    /// The rect itself when it is finite (standardized), else `.zero`: the entry guard of every layout.
    var finiteOrZero: CGRect { isFiniteRect ? standardized : .zero }

    /// `insetBy(dx:dy:)` that never returns `CGRect.null`: a rect too small for the inset keeps its centre and gets zero
    /// width or height.
    func finiteInset(dx: CGFloat, dy: CGFloat) -> CGRect {
        let rect = finiteOrZero
        let width = max(0, rect.width - 2 * dx), height = max(0, rect.height - 2 * dy)
        return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }
}

/// Whole-number counts (lines, rows, columns) from layout arithmetic: 0 instead of a trap for NaN or ±∞, and never beyond
/// ±10 000.
enum LayoutCount {
    static func floor(_ value: CGFloat) -> Int { whole(value.rounded(.down)) }
    static func ceil(_ value: CGFloat) -> Int { whole(value.rounded(.up)) }
    static func nearest(_ value: CGFloat) -> Int { whole(value.rounded()) }

    private static func whole(_ value: CGFloat) -> Int {
        guard value.isFinite else { return 0 }
        return Int(min(max(value, -10_000), 10_000))
    }
}
