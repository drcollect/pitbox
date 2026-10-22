import CoreGraphics

/// Widths of the tabs in a strip of a given width, and the scrolling that takes over when they cannot all fit.
///
/// Three regimes, from roomy to crowded:
/// 1. **Roomy**: every tab gets the same share, up to `maxWidth`.
/// 2. **Crowded**: the selected tab keeps `selectedMinWidth` (its title stays readable) and the others share the rest, down to
///    `minWidth`. A tab narrower than `compactBelow` shows only its number.
/// 3. **Overflow**: even `minWidth` tabs do not fit. The tabs keep those widths and the strip scrolls sideways; it keeps the
///    selected tab in view.
enum TabLayout {
    /// The narrowest a tab gets: room for the number badge and its status dot.
    static let minWidth: CGFloat = 40
    /// Below this width a tab has no room for a title and shows its number only (and no close button).
    static let compactBelow: CGFloat = 72
    static let maxWidth: CGFloat = 180
    /// A selected tab keeps at least this much when the strip is crowded, so its title stays readable.
    static let selectedMinWidth: CGFloat = 116
    static let spacing: CGFloat = 4
    /// How much of the neighbours stays in view when the strip scrolls to reveal a tab.
    static let revealMargin: CGFloat = 28

    /// One width per tab, in whole points (the display is 1x, so tab edges land on pixels and the 1 pt outlines stay crisp).
    /// The widths plus spacing never exceed `available` unless even the compressed tabs cannot fit (`contentWidth` then
    /// exceeds `available` and the strip scrolls).
    static func widths(count: Int, selectedIndex: Int?, available: CGFloat) -> [CGFloat] {
        guard count > 0 else { return [] }
        let gaps = CGFloat(count - 1) * spacing
        let share = ((available - gaps) / CGFloat(count)).rounded(.down)
        if share >= selectedMinWidth || count == 1 || selectedIndex == nil {
            return Array(repeating: min(maxWidth, max(minWidth, share)), count: count)
        }
        let selected = min(selectedMinWidth, max(minWidth, available.rounded(.down)))
        let others = max(minWidth, ((available - gaps - selected) / CGFloat(count - 1)).rounded(.down))
        return (0..<count).map { $0 == selectedIndex ? selected : others }
    }

    /// The total length of the tabs and the gaps between them.
    static func contentWidth(of widths: [CGFloat]) -> CGFloat {
        widths.reduce(0, +) + CGFloat(max(0, widths.count - 1)) * spacing
    }

    /// True when a tab of this width shows only its number.
    static func isCompact(_ width: CGFloat) -> Bool { width < compactBelow }

    /// `offset` limited to what the content can actually scroll.
    static func clampedOffset(_ offset: CGFloat, content: CGFloat, viewport: CGFloat) -> CGFloat {
        max(0, min(offset, max(0, content - viewport)))
    }

    /// The scroll offset that brings `frame` (in content coordinates) into view with a little of its neighbours, changing
    /// `current` as little as possible. In a viewport too narrow for the tab plus both margins the margins shrink, so the
    /// whole tab (its number, title and close button) stays in view; a tab wider than the viewport shows its start.
    static func offset(revealing frame: CGRect, current: CGFloat, content: CGFloat, viewport: CGFloat) -> CGFloat {
        let margin = min(revealMargin, max(0, ((viewport - frame.width) / 2).rounded(.down)))
        var offset = current
        if frame.minX - margin < offset {
            offset = frame.minX - margin
        } else if frame.maxX + margin > offset + viewport {
            offset = min(frame.maxX + margin - viewport, frame.minX - margin)
        }
        return clampedOffset(offset, content: content, viewport: viewport)
    }
}

/// Which tab a shortcut selects, and the number a tab shows.
enum TabNumbering {
    /// The number on a tab's badge: its position, starting at 1.
    static func badge(index: Int) -> Int { index + 1 }

    /// The digit of the Cmd-key shortcut that selects this tab: Cmd-1 to Cmd-8 the first eight, Cmd-9 the last tab
    /// (like browsers). Nil for the tabs in between.
    static func shortcutDigit(index: Int, count: Int) -> Int? {
        if index < 8 { return index + 1 }
        return index == count - 1 ? 9 : nil
    }
}
