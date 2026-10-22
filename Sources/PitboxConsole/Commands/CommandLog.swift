import Foundation
import PitboxKit

/// A value in a `[code]` or `[terminal]` line: a number, a fixed label, or an offer's local number. There is no case
/// for free text, so no command text, path, host, title, TL;DR or output can reach the log (docs/THREAT_MODEL.md):
/// the one initializer that takes text is private, so only the builders below make values.
struct CommandLogValue: Equatable {
    let text: String

    private init(text: String) { self.text = text }

    static func number(_ value: Int) -> CommandLogValue { CommandLogValue(text: String(value)) }
    static func label<L: CommandLogLabel>(_ value: L) -> CommandLogValue { CommandLogValue(text: value.logLabel) }
    /// `#3.1`: the session's local index and the block number, never a session id.
    static func offer(_ id: CommandOffer.ID) -> CommandLogValue { CommandLogValue(text: id.description) }
    /// `#3.file`: a result fetch's session, by its local index (never a path or a tool_use id).
    static func resultFile(_ sessionIndex: Int) -> CommandLogValue { CommandLogValue(text: "#\(sessionIndex).file") }
    static func flag(_ value: Bool) -> CommandLogValue { CommandLogValue(text: value ? "yes" : "no") }
}

extension CommandLogValue: ExpressibleByIntegerLiteral {
    init(integerLiteral value: Int) { text = String(value) }
}

/// Things with a fixed log label (enums of this module and the contract's).
protocol CommandLogLabel {
    var logLabel: String { get }
}

extension CommandTabRole: CommandLogLabel { var logLabel: String { rawValue } }
extension CommandAssessment.Class: CommandLogLabel { var logLabel: String { rawValue } }
extension CommandRule: CommandLogLabel { var logLabel: String { rawValue } }
extension CommandExecutionDescriptor.Kind: CommandLogLabel { var logLabel: String { rawValue } }
extension CommandExecutionDescriptor.Shell: CommandLogLabel { var logLabel: String { rawValue } }
extension CommandSpawnPath: CommandLogLabel { var logLabel: String { rawValue } }
extension CommandEnvironmentRules.ExtraPathProblem: CommandLogLabel { var logLabel: String { rawValue } }

/// Fixed words for log lines.
enum CommandLogWord: String, CommandLogLabel {
    case shellNotReady = "shell-not-ready"
    case stale, superseded, unknown, fresh
    case folder, terminal, limits, checking, assessment = "assessment-changed"
    case cancel, blockHidden = "block-hidden", timeout, replaced, superseding = "superseded-open"
    case runOff = "run-off"

    var logLabel: String { rawValue }
}

/// The `[code]` lines of the sheet and the `[terminal]` lines of the command tabs. They go through `TerminalLog.enabled`
/// (off in tests), and tests can record every line (`addRecorder`) to prove nothing but labels and numbers is written.
enum CommandLog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorders: [UUID: (String, String) -> Void] = [:]

    static func code(_ event: StaticString, _ fields: KeyValuePairs<String, CommandLogValue> = [:]) {
        write("code", event, fields)
    }

    static func terminal(_ event: StaticString, _ fields: KeyValuePairs<String, CommandLogValue> = [:]) {
        write("terminal", event, fields)
    }

    static func line(_ event: StaticString, _ fields: KeyValuePairs<String, CommandLogValue>) -> String {
        ([event.description] + fields.map { "\($0.key)=\($0.value.text)" }).joined(separator: " ")
    }

    /// Tests: `recorder` receives (category, line) for every line until `removeRecorder`.
    static func addRecorder(_ recorder: @escaping (String, String) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { recorders[id] = recorder }
        return id
    }

    static func removeRecorder(_ id: UUID) {
        _ = lock.withLock { recorders.removeValue(forKey: id) }
    }

    private static func write(_ category: String, _ event: StaticString, _ fields: KeyValuePairs<String, CommandLogValue>) {
        let text = line(event, fields)
        let current = lock.withLock { Array(recorders.values) }
        for recorder in current { recorder(category, text) }
        if TerminalLog.enabled { Log.info(text, category) }
    }
}
