import AppKit
import PitboxKit

/// Where everything of the Ready list goes at one width: a 24 pt header, the recap card, 60 pt
/// cards and 28 pt result rows 6 pt apart, the "N more ▾" line, 28 pt Later rows, and the line for items hidden by the
/// cap. Pure, so the block can ask the list's height before laying itself out.
struct CodeReadyLayout {
    /// One button: the item's (or the list's) action, where it is, and how it is drawn.
    struct Button: Equatable {
        enum Style: Equatable {
            /// A filled pill in the card's kind colour.
            case primary
            /// A faint pill.
            case secondary
            /// A text-only button (Undo, "4 more ▾", the hidden-items line).
            case link
            /// The text of a Later row: a click unfolds it; not drawn as a button.
            case area
        }
        /// Stable while the item and its button stay (the arming follows it).
        var id: String
        var action: CodeReadyAction
        var title: String
        var rect: CGRect
        var style: Style
        var opensSomething: Bool
        var kind: CodeReadyItem.Kind?
        var color: ButtonColor = .kind
    }

    /// Buttons whose colour is their own (▦ is pink, ↗ violet) rather than the card's kind.
    enum ButtonColor: Equatable { case kind, dashboard, link }

    /// A block of the list.
    enum Block: Equatable {
        case header(CGRect)
        case recap(CGRect)
        case card(CodeReadySnapshot.Entry, CGRect)
        case later(CodeReadySnapshot.Entry, CGRect)
        case result(CodeReadySnapshot.Entry, CodeReadySnapshot.ResultRow, CGRect)
    }

    static let headerHeight: CGFloat = 24
    /// Between blocks; the first block sits `firstGap` under the header; `bottomPadding` separates the list from the
    /// buckets. 3 cards and the "more" line then fit the block's height budget (798 pt at 3 × 10).
    static let gap: CGFloat = 6
    static let firstGap: CGFloat = 4
    static let lineButtonHeight: CGFloat = 18
    static let bottomPadding: CGFloat = 6
    static let cardPadding: CGFloat = 10
    static let buttonHeight: CGFloat = 18
    static let buttonGap: CGFloat = 6

    private(set) var blocks: [Block] = []
    private(set) var buttons: [Button] = []
    private(set) var height: CGFloat = 0

    /// The layout of `snapshot` at `width`. `fetchedOpens` says whether a fetched file gets Open.
    init(_ snapshot: CodeReadySnapshot, width: CGFloat, fetchedOpens: (String) -> Bool = { _ in false }) {
        guard !snapshot.isEmpty, width > 40 else { return }
        var y: CGFloat = 0
        blocks.append(.header(CGRect(x: 0, y: 0, width: width, height: Self.headerHeight)))
        if let header = snapshot.header, header.undoShown {
            let title = "Undo"
            let w = Self.textWidth(title, CodeReadyFonts.headerNote) + 8
            buttons.append(Button(id: "list|undo", action: .undoDismiss, title: title,
                                  rect: CGRect(x: width - w, y: 3, width: w, height: 18), style: .link, opensSomething: false,
                                  kind: nil))
        }
        y += Self.headerHeight
        var first = true
        /// The top of the next block (a gap above it, a smaller one under the header).
        func next(_ height: CGFloat) -> CGRect {
            y += first ? Self.firstGap : Self.gap
            first = false
            defer { y += height }
            return CGRect(x: 0, y: y, width: width, height: height)
        }
        if let recap = snapshot.recap {
            blocks.append(.recap(next(CodeAwayRecapView.height(of: recap, width: width))))
        }
        for entry in snapshot.entries {
            switch entry.style {
            case .card:
                let rect = next(CodeTuning.cardHeight)
                blocks.append(.card(entry, rect))
                addCardButtons(entry.item, card: rect)
            case .result(let row):
                let rect = next(Self.rowHeight)
                blocks.append(.result(entry, row, rect))
                addResultButtons(entry.item, row: row, rect: rect, fetchedOpens: fetchedOpens)
            case .later:
                break
            }
        }
        if snapshot.more > 0 {
            let title = snapshot.expanded ? "Show fewer ▴" : "\(snapshot.more) more ▾"
            let rect = next(Self.lineButtonHeight)
            buttons.append(Button(id: "list|more", action: .showMore, title: title,
                                  rect: CGRect(x: 0, y: rect.minY, width: Self.textWidth(title, CodeReadyFonts.button) + 12,
                                               height: rect.height),
                                  style: .link, opensSomething: false, kind: nil))
        }
        for entry in snapshot.later {
            let rect = next(Self.rowHeight)
            blocks.append(.later(entry, rect))
            addLaterButtons(entry.item, row: rect)
        }
        if snapshot.hiddenRecent > 0 {
            let title = "\(snapshot.hiddenRecent) more in sessions you have not opened recently"
            let rect = next(Self.lineButtonHeight)
            buttons.append(Button(id: "list|hidden", action: .showHidden, title: title,
                                  rect: CGRect(x: 0, y: rect.minY, width: min(width, Self.textWidth(title, CodeReadyFonts.button) + 12),
                                               height: rect.height),
                                  style: .link, opensSomething: false, kind: nil))
        }
        height = (y + Self.bottomPadding).rounded(.up)
    }

    /// Later and result rows.
    static let rowHeight: CGFloat = 28

    /// The card's buttons, left to right on its bottom row. On a narrow card a long result label loses its detail
    /// ("↗ Open preview · localhost:5173" → "↗ Open preview"), then the buttons that open something give way (the peek
    /// has them too), so the window button, OK, Later and Dismiss always stay.
    private mutating func addCardButtons(_ item: CodeReadyItem, card: CGRect) {
        var x = card.minX + Self.cardPadding
        let y = card.maxY - 4 - Self.buttonHeight
        var titles = item.buttons.map(\.title)
        let room = card.width - 2 * Self.cardPadding
        func needed(_ indices: [Int]) -> CGFloat {
            indices.map { Self.buttonWidth(titles[$0]) }.reduce(0, +) + CGFloat(max(0, indices.count - 1)) * Self.buttonGap
        }
        var kept = Array(item.buttons.indices)
        if needed(kept) > room {
            for index in titles.indices where item.buttons[index].opensSomething {
                titles[index] = titles[index].components(separatedBy: " · ").first ?? titles[index]
            }
        }
        while needed(kept) > room, let last = kept.last(where: { item.buttons[$0].opensSomething }) {
            kept.removeAll { $0 == last }
        }
        for index in kept {
            let button = item.buttons[index]
            let title = titles[index]
            let w = Self.buttonWidth(title)
            guard x + w <= card.maxX - Self.cardPadding else { break }
            buttons.append(Button(id: "\(item.id)|\(index)", action: button.action, title: title,
                                  rect: CGRect(x: x, y: y, width: w, height: Self.buttonHeight),
                                  style: button.primary ? .primary : .secondary, opensSomething: button.opensSomething,
                                  kind: item.kind, color: Self.color(button.action)))
            x += w + Self.buttonGap
        }
    }

    /// A Later row: its text unfolds it; its main button (Run…, Review…, Fetch…) sits on the right.
    private mutating func addLaterButtons(_ item: CodeReadyItem, row: CGRect) {
        var right = row.maxX - Self.cardPadding
        var areaEnd = right
        for (index, button) in item.buttons.enumerated().reversed() {
            if case .unfold = button.action {
                buttons.append(Button(id: "\(item.id)|\(index)", action: button.action, title: button.title,
                                      rect: CGRect(x: row.minX, y: row.minY, width: max(0, areaEnd - row.minX - 4), height: row.height),
                                      style: .area, opensSomething: false, kind: item.kind))
                continue
            }
            let w = Self.buttonWidth(button.title)
            let rect = CGRect(x: right - w, y: row.minY + (row.height - Self.buttonHeight) / 2, width: w, height: Self.buttonHeight)
            buttons.append(Button(id: "\(item.id)|\(index)", action: button.action, title: button.title, rect: rect,
                                  style: .primary, opensSomething: button.opensSomething, kind: item.kind))
            right = rect.minX - Self.buttonGap
            areaEnd = right
        }
    }

    /// A result row's buttons: Show output, Open and Show in Finder after a fetch, OK.
    private mutating func addResultButtons(_ item: CodeReadyItem, row: CodeReadySnapshot.ResultRow, rect: CGRect,
                                           fetchedOpens: (String) -> Bool) {
        var list: [(CodeReadyAction, String, Bool)] = []
        switch row.state {
        case .running, .finished, .stopped:
            if let runID = row.runID { list.append((.revealRun(runID), "Show output", false)) }
        case .fetched(let name, _):
            if fetchedOpens(name) { list.append((.openFetched(fileName: name), "Open", true)) }
            list.append((.showFetchedInFinder(fileName: name), "Show in Finder", true))
        case .typed, .fetchFailed:
            break
        }
        if row.state != .running { list.append((.ok(item.id), "OK", false)) }
        var right = rect.maxX - Self.cardPadding
        for (index, entry) in list.enumerated().reversed() {
            let w = Self.buttonWidth(entry.1)
            let frame = CGRect(x: right - w, y: rect.minY + (rect.height - Self.buttonHeight) / 2, width: w, height: Self.buttonHeight)
            buttons.append(Button(id: "\(item.id)|r\(index)", action: entry.0, title: entry.1, rect: frame, style: .secondary,
                                  opensSomething: entry.2, kind: nil))
            right = frame.minX - Self.buttonGap
        }
    }

    /// Where a result row's text may go (left of its buttons).
    func resultTextWidth(_ rect: CGRect, item: CodeReadyItem) -> CGFloat {
        let left = buttons.filter { $0.id.hasPrefix(item.id + "|r") }.map(\.rect.minX).min() ?? rect.maxX - Self.cardPadding
        return max(20, left - rect.minX - 2 * Self.cardPadding)
    }

    private static func color(_ action: CodeReadyAction) -> ButtonColor {
        switch action {
        case .openDashboard: return .dashboard
        case .openResult: return .link
        default: return .kind
        }
    }

    static func buttonWidth(_ title: String) -> CGFloat { textWidth(title, CodeReadyFonts.button) + 16 }

    static func textWidth(_ text: String, _ font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// The list's height for `snapshot` at `width` (0 when there is no list).
    static func height(of snapshot: CodeReadySnapshot, width: CGFloat) -> CGFloat {
        CodeReadyLayout(snapshot, width: width).height
    }
}
