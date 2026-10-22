import Foundation

/// The dim echo a command tab writes into its terminal view before the shell starts:
/// `$ ` before the first line and `> ` before continuation lines. It goes into the emulator only, never to the
/// process. Characters a terminal would act on (ESC, the C0 and C1 controls, DEL) and every hidden character are shown
/// as `⟨U+…⟩` text, so the echo can never draw anything but itself (a runnable text has none of them anyway, B1).
enum CommandEcho {
    static func text(for command: String) -> String {
        var out = ""
        let lines = command.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            out += "\u{1b}[2m" + (index == 0 ? "$ " : "> ")
            for scalar in line.unicodeScalars {
                if scalar == "\t" {
                    out.unicodeScalars.append(scalar)
                } else if scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) || CommandHiddenCharacters.isHidden(scalar) {
                    out += CommandHiddenCharacters.escaped(scalar)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
            out += "\u{1b}[0m\r\n"
        }
        return out
    }
}

/// A log label for a start failure.
struct CommandStartLabel: CommandLogLabel {
    let logLabel: String
    init(_ failure: CommandStartFailure?) { logLabel = failure?.logLabel ?? "other" }
}
