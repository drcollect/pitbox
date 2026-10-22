import Foundation

/// Tool calls in words for the "Now" line and the last steps: file names only, never paths; nothing a tool ran is
/// quoted (a Bash call shows its `description`, never its command).
enum StepWords {
    /// `mcp__ccd_turn__update_plan` (the desktop app's plan).
    static let updatePlan = "mcp__ccd_turn__update_plan"
    static let todoWrite = "TodoWrite"

    /// Bookkeeping tools do not break the final reply's run of text blocks (this list, nothing else).
    static let bookkeeping: Set<String> = [
        updatePlan, "mcp__ccd_session__mark_chapter", "mcp__ccd_session__spawn_task", "mcp__ccd_session__dismiss_task",
        todoWrite,
        // The turn's wrap-up call records the wrap-up and runs nothing (25 calls in 5 sessions in 30 days); without it,
        // a reply that ends with it would lose its commands.
        "mcp__ccd_turn__wrap_up",
    ]

    static func isBookkeeping(_ name: String) -> Bool { bookkeeping.contains(name) }

    /// Tools that read web pages (the first note on the sheet).
    static func readsWeb(_ name: String) -> Bool {
        name == "WebFetch" || name == "WebSearch" || name.hasPrefix("mcp__claude-in-chrome__")
            || name.hasPrefix("mcp__Claude_Browser__") || name.hasPrefix("mcp__computer-use__")
    }

    /// A subagent works in its own transcript, so a long wait for its result says nothing about permission prompts.
    static func isSubagent(_ name: String) -> Bool { name == "Task" || name == "Agent" }

    /// The words for one tool call.
    static func words(for tool: TranscriptToolUse) -> String {
        let input = tool.input
        switch tool.name {
        case "Bash":
            if let description = cleaned(input.description, limit: 40) { return "running: \(description)" }
            return "running a command"
        case "Read":
            return fileName(input.filePath).map { "reading \($0)" } ?? "reading a file"
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            return fileName(input.filePath ?? input.notebookPath).map { "editing \($0)" } ?? "editing a file"
        case "Grep", "Glob":
            return "searching"
        case "WebFetch", "WebSearch":
            return "reading the web"
        case "Task", "Agent":
            if let description = cleaned(input.description, limit: 40) { return "subagent: \(description)" }
            return "subagent"
        case "AskUserQuestion":
            return "asking you"
        default:
            if tool.name.hasPrefix("mcp__") {
                let rest = tool.name.dropFirst(5)
                if let split = rest.range(of: "__") {
                    let server = cleaned(String(rest[..<split.lowerBound]), limit: 24) ?? "tool"
                    let action = cleaned(String(rest[split.upperBound...]), limit: 24) ?? "call"
                    return "\(server): \(action)"
                }
            }
            return cleaned(tool.name, limit: 32).map { "using \($0)" } ?? "using a tool"
        }
    }

    /// A tool the API ran itself (`server_tool_use`).
    static func serverToolWords(_ name: String) -> String {
        name.lowercased().contains("web") ? "reading the web" : (cleaned(name, limit: 32).map { "using \($0)" } ?? "using a tool")
    }

    /// The last path component, cleaned to one line; nil for no path.
    static func fileName(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        let name = trimmed.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? trimmed
        return cleaned(name, limit: 60)
    }

    private static func cleaned(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let line = CodeText.oneLine(text, limit: limit)
        return line.isEmpty ? nil : line
    }
}
