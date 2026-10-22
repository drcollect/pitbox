import Foundation

/// One row of the peek's results, in the order it is shown. Host words and rendered session text:
/// the peek turns `.label` and `.text` into its own text elements and `.buttons` into its own buttons (armed with
/// `OpenButtonArming` where `arms`), or `CodeResultsSectionView` draws them as one self-contained view.
enum CodeResultPeekRow: Equatable {
    /// "Results", "Earlier artifacts" (the peek draws its labels in capitals).
    case label(String)
    /// "Preview on buildbox: localhost:5173", "2 other links in the reply (open them from the session)", a path line.
    case text(String, dim: Bool)
    /// A row of buttons.
    case buttons([CodeResultButton])
}

/// The peek's rows for a session's results: "Results" with every button of the work; each SSH preview as its line and
/// Copy link; "2 other links in the reply …"; other paths of the reply as plain text with their notes; "Earlier
/// artifacts" with their times. Empty when there is nothing (no label without content). Pure.
enum CodeResultPeekRows {
    static func rows(results: [CodeResult], otherLinkCount: Int, alias: String?, hidden: Bool,
                     time: (Date) -> String) -> [CodeResultPeekRow] {
        var rows: [CodeResultPeekRow] = []
        let work = CodeResultWords.workButtons(results, hidden: hidden)
        let previews = results.filter { $0.kind == .serverPreview }
        let earlier = results.filter { $0.kind == .earlierArtifact }
        let paths = results.filter { $0.kind == .mentionedPath }
        if !work.isEmpty || !previews.isEmpty || otherLinkCount > 0 || !paths.isEmpty { rows.append(.label("Results")) }
        if !work.isEmpty { rows.append(.buttons(work)) }
        for preview in previews {
            rows.append(.text(CodeResultWords.serverPreviewLine(preview, alias: alias), dim: false))
            rows.append(.buttons(CodeResultWords.buttons(for: preview, hidden: hidden)))
        }
        if let others = CodeResultWords.otherLinks(otherLinkCount) { rows.append(.text(others, dim: true)) }
        for path in paths { rows.append(.text(CodeResultWords.pathLine(path, hidden: hidden), dim: true)) }
        if !earlier.isEmpty {
            rows.append(.label("Earlier artifacts"))
            rows.append(.buttons(earlier.flatMap { artifact in
                CodeResultWords.buttons(for: artifact, hidden: hidden).map { button in
                    var titled = button
                    if let at = artifact.at { titled.title += " · " + time(at) }
                    return titled
                }
            }))
        }
        return rows
    }

    /// An earlier artifact's time: this Mac's zone, the system's 12- or 24-hour form, with the day ("19 Oct 14:02").
    static func defaultTime(_ date: Date) -> String { formatter.string(from: date) }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("d MMM j:mm")
        return formatter
    }()
}
