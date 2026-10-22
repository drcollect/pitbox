import AppKit
import Foundation
import PitboxKit

/// One button of a session's results as the views draw it: host words, with file names
/// (session text) through the plain-text renderer, cut in the middle at 32 characters.
public struct CodeResultButton: Hashable, Sendable, Identifiable {
    /// What a press does (the block hands it to `CodeResultActions`).
    public enum Action: String, Hashable, Sendable {
        /// ↗ a preview or an artifact in the browser; ▤ a document in its default app.
        case open
        /// ▤ a web document in the app's script-free preview.
        case preview
        case showInFinder
        /// An SSH session's preview: the address to the pasteboard.
        case copyLink
        /// ⤓ the Fetch file sheet (it arms itself).
        case fetch
    }

    /// The colour of its kind: result link purple, file blue, neutral.
    public enum Tone: String, Hashable, Sendable { case result, file, neutral }

    /// `CodeResult.id` of the result it acts on.
    public var resultID: String
    public var action: Action
    public var title: String
    public var tone: Tone
    /// It opens something, so it arms 0.8 s after it appeared or moved and never under the pointer.
    public var arms: Bool

    public var id: String { resultID + "#" + action.rawValue }

    public init(resultID: String, action: Action, title: String, tone: Tone, arms: Bool) {
        self.resultID = resultID; self.action = action; self.title = title; self.tone = tone; self.arms = arms
    }
}

/// The words of results. Pure.
public enum CodeResultWords {
    /// File names are cut in the middle at this many characters.
    public static let nameLimit = 32

    /// The buttons of one result, in order (a web document has Preview and Show in Finder). Peek-only results (other
    /// paths, an SSH preview's line) have no button but Copy link. With Hide text file names read "hidden".
    public static func buttons(for result: CodeResult, hidden: Bool = false) -> [CodeResultButton] {
        let name = fileName(result.label, hidden: hidden)
        func button(_ action: CodeResultButton.Action, _ title: String, _ tone: CodeResultButton.Tone) -> CodeResultButton {
            CodeResultButton(resultID: result.id, action: action, title: title, tone: tone,
                             arms: action != .copyLink && action != .fetch)
        }
        switch result.kind {
        case .preview: return [button(.open, "↗ Open preview · \(address(result.label))", .result)]
        case .artifact, .earlierArtifact: return [button(.open, "↗ Open artifact", .result)]
        case .document: return [button(.open, "▤ Open \(name)", .result)]
        case .webDocument: return [button(.preview, "▤ Preview \(name)", .result), button(.showInFinder, "Show in Finder", .neutral)]
        case .otherFile: return [button(.showInFinder, "▤ Show \(name) in Finder", .neutral)]
        case .serverFile: return [button(.fetch, "⤓ Fetch \(name)…", .file)]
        case .serverPreview: return [button(.copyLink, "Copy link", .neutral)]
        case .mentionedPath: return []
        }
    }

    /// The buttons of every result that has one (the peek's list), earlier artifacts and peek-only lines left out.
    public static func workButtons(_ results: [CodeResult], hidden: Bool = false) -> [CodeResultButton] {
        results.filter(isWorkButton).flatMap { buttons(for: $0, hidden: hidden) }
    }

    /// The large monitor's result line and the Finished card: the first result's first button, and "+2 more"
    /// when the work has more results with buttons.
    public static func firstLine(_ results: [CodeResult], hidden: Bool = false) -> (button: CodeResultButton, more: String?)? {
        let work = results.filter(isWorkButton)
        guard let first = work.first, let button = buttons(for: first, hidden: hidden).first else { return nil }
        return (button, work.count > 1 ? "+\(work.count - 1) more" : nil)
    }

    /// A result of the work with a button of its own (not an earlier artifact, an SSH preview's line or peek text).
    public static func isWorkButton(_ result: CodeResult) -> Bool {
        ![.earlierArtifact, .mentionedPath, .serverPreview].contains(result.kind)
    }

    /// "Preview on buildbox: localhost:5173" for an SSH session's preview.
    public static func serverPreviewLine(_ result: CodeResult, alias: String?) -> String {
        let host = alias.flatMap { CodePlainText.line($0, limit: 64) } ?? "the server"
        return "Preview on \(host): \(address(result.label))"
    }

    /// "2 other links in the reply (open them from the session)"; nil for none.
    public static func otherLinks(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return "\(count) other link\(count == 1 ? "" : "s") in the reply (open them from the session)"
    }

    /// A peek-only path line (session text through the renderer), with its note: "/x/y.md · not checked: network path".
    public static func pathLine(_ result: CodeResult, hidden: Bool = false) -> String {
        let path = hidden ? "hidden" : middleCut(CodePlainText.line(result.path ?? result.label, limit: 400) ?? "", limit: 64)
        return [path, result.note].compactMap { $0 }.joined(separator: " · ")
    }

    /// A file name through the renderer, cut in the middle at `nameLimit`; "hidden" with Hide text.
    public static func fileName(_ label: String, hidden: Bool) -> String {
        guard !hidden else { return "hidden" }
        return middleCut(CodePlainText.line(label, limit: 400) ?? "file", limit: nameLimit)
    }

    /// `text` cut in the middle with "…" so its start and its end (the extension) stay: "a-very-long…report.md".
    public static func middleCut(_ text: String, limit: Int) -> String {
        guard text.count > limit, limit >= 5 else { return text }
        let tail = (limit - 1) / 2
        let head = limit - 1 - tail
        return String(text.prefix(head)) + "…" + String(text.suffix(tail))
    }

    /// The host and port of a preview label, rendered (they come from the link's checked parts).
    private static func address(_ label: String) -> String { CodePlainText.line(label, limit: 64) ?? "" }
}

/// The colours of result buttons (result link `#9B7BFF`, file `#6CB6FF`). On a monitor's screen and in the peek
/// the dark values apply in both appearances (a monitor is a dark object); `dark: false` is for surfaces on the block's
/// light glass. Contrast is checked by `ResultViewTests` (4.5:1 for words, 3:1 for outlines).
struct CodeResultPalette: Equatable {
    var dark: Bool

    static let resultLink: UInt32 = 0x9B7BFF, resultLinkLight: UInt32 = 0x3F22A8
    static let file: UInt32 = 0x6CB6FF, fileLight: UInt32 = 0x08407A
    static let resultText: UInt32 = 0xD4C2FF, resultFill: UInt32 = 0x1D1530, resultOutline: UInt32 = 0x6A50B8
    static let fileText: UInt32 = 0xBFE0FF, fileFill: UInt32 = 0x0F1D2E, fileOutline: UInt32 = 0x3D6E9E
    static let neutralText: UInt32 = 0xCFD3DA, neutralFill: UInt32 = 0x23262D, neutralOutline: UInt32 = 0x6B707C
    static let lightFill: UInt32 = 0xFFFFFF
    static let dimDark: UInt32 = 0x9097A4, dimLight: UInt32 = 0x4A4560
    static let textDark: UInt32 = 0xCFD3DA, textLight: UInt32 = 0x1E1B2E

    func text(_ tone: CodeResultButton.Tone) -> UInt32 {
        switch tone {
        case .result: return dark ? Self.resultText : Self.resultLinkLight
        case .file: return dark ? Self.fileText : Self.fileLight
        case .neutral: return dark ? Self.neutralText : Self.textLight
        }
    }

    func fill(_ tone: CodeResultButton.Tone) -> UInt32 {
        guard dark else { return Self.lightFill }
        switch tone {
        case .result: return Self.resultFill
        case .file: return Self.fileFill
        case .neutral: return Self.neutralFill
        }
    }

    func outline(_ tone: CodeResultButton.Tone) -> UInt32 {
        switch tone {
        case .result: return dark ? Self.resultOutline : Self.resultLinkLight
        case .file: return dark ? Self.fileOutline : Self.fileLight
        case .neutral: return dark ? Self.neutralOutline : Self.dimLight
        }
    }

    var dim: UInt32 { dark ? Self.dimDark : Self.dimLight }
    var plain: UInt32 { dark ? Self.textDark : Self.textLight }

    static func color(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor { ThemeColor.srgb(value, alpha: alpha) }
}
