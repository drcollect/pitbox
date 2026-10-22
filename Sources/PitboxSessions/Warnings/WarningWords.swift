import Foundation
import PitboxKit

/// The words of warnings (on monitors, the Warning card and the desk tag). The app's own words; the other session's
/// headline and the file's path are session text through the plain-text renderer. With Hide text reasons and paths read
/// "hidden" and headlines stay. Pure.
public enum CodeWarningWords {
    /// The orange line of large and medium monitors: "⚠ Looks stuck: 4 commands failed in a row", "⚠ Looks stuck: quiet
    /// for 30 min, nothing running", "⚠ Also edited by “<headline>”: src/checkout.tsx".
    public static func line(_ warning: CodeWarning, now: Date, hidden: Bool = false) -> String {
        "⚠ " + statement(warning, now: now, hidden: hidden)
    }

    /// A small monitor's: "⚠ stuck", "⚠ same file".
    public static func short(_ warning: CodeWarning) -> String {
        warning.kind == .sameFile ? "⚠ same file" : "⚠ stuck"
    }

    /// The Ready card's title: "⚠ Looks stuck", "⚠ Same file in two sessions".
    public static func cardTitle(_ warning: CodeWarning) -> String {
        warning.kind == .sameFile ? "⚠ Same file in two sessions" : "⚠ Looks stuck"
    }

    /// The Ready card's reason, 1-2 lines; "hidden" with Hide text.
    public static func reason(_ warning: CodeWarning, now: Date, hidden: Bool = false) -> String {
        guard !hidden else { return "hidden" }
        switch warning.kind {
        case .failedInARow:
            let count = warning.failures ?? CodeTuning.stuckRunLength
            let exit = warning.lastExitCode.map { "; the last one ended with exit code \($0)" } ?? ""
            return "\(count) commands failed in a row\(exit)."
        case .silence:
            return "Quiet for \(duration(since: warning.since, now: now)), nothing running."
        case .sameFile:
            return statement(warning, now: now, hidden: false) + "."
        }
    }

    /// The desk tag's pill: "⚠ Looks stuck", "⚠ Same file as “<other headline>”" ("⚠ Same file in two sessions" with Hide
    /// text: the tag shows no session text then).
    public static func tag(_ warning: CodeWarning, hidden: Bool = false) -> String {
        guard warning.kind == .sameFile else { return "⚠ Looks stuck" }
        guard !hidden else { return "⚠ Same file in two sessions" }
        return "⚠ Same file as “\(headline(warning.otherHeadline))”"
    }

    /// The peek's details: the statement, then the facts (the last exit code, since when, nothing written since).
    public static func peekLines(_ warning: CodeWarning, now: Date, hidden: Bool = false,
                                 time: (Date) -> String = clock) -> [String] {
        var lines = [statement(warning, now: now, hidden: hidden)]
        switch warning.kind {
        case .failedInARow:
            if let code = warning.lastExitCode { lines.append("Last failure: exit code \(code)") }
            lines.append("Failing since \(time(warning.since))")
        case .silence:
            lines.append("Nothing written since \(time(warning.since))")
        case .sameFile:
            lines.append("Both edited it since \(time(warning.since))")
        }
        return lines
    }

    /// The statement without the sign: "Looks stuck: 4 commands failed in a row".
    public static func statement(_ warning: CodeWarning, now: Date, hidden: Bool) -> String {
        switch warning.kind {
        case .failedInARow:
            return "Looks stuck: \(warning.failures ?? CodeTuning.stuckRunLength) commands failed in a row"
        case .silence:
            return "Looks stuck: quiet for \(duration(since: warning.since, now: now)), nothing running"
        case .sameFile:
            let path = hidden ? "hidden" : (CodePlainText.line(warning.path, limit: 120) ?? "a file")
            return "Also edited by “\(headline(warning.otherHeadline))”: \(path)"
        }
    }

    /// "30 min", "1 h 12 min" (minutes rounded down, at least the silence's 30 minutes once it is a warning).
    static func duration(since: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(since) / 60))
        if minutes < 60 { return "\(minutes) min" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(rest) min"
    }

    /// The other session's headline, rendered and cut at 40 characters.
    static func headline(_ text: String?) -> String { CodePlainText.line(text, limit: 40) ?? "another session" }

    /// This Mac's local time in the system's 12- or 24-hour form ("14:02").
    public static func clock(_ date: Date) -> String { timeFormatter.string(from: date) }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("j:mm")
        return formatter
    }()
}
