import Foundation

/// Tab labels. The text can come from a program (its name, its window title), so it is cleaned before it is shown.
enum SessionTitle {
    /// The label for a tab.
    ///
    /// - An idle shell shows its folder (`~` for home, else the last path component).
    /// - A running program shows its name (`vim`, `ssh`, `claude`); an interpreter shows its script's name.
    /// - Until the shell has exec'ed a preset's program (its name is still the shell's), or when nothing is known, the
    ///   preset's name is used.
    static func label(kind: TerminalPreset.Kind, shellName: String, presetName: String, foreground: ForegroundInfo?,
                      directory: String?, home: String) -> String {
        let name = foreground?.name.map { clean($0) }.flatMap { $0.isEmpty ? nil : $0 }
        switch kind {
        case .shell:
            if foreground?.isSessionLeader ?? true {
                if let directory { return directoryLabel(directory, home: home) }
                return presetName
            }
            if let name, name != shellName { return name }
            return directory.map { directoryLabel($0, home: home) } ?? presetName
        case .program, .script:
            if let name, name != shellName { return name }
            return presetName
        case .command:
            // "▶ <headline>": fixed, whatever the command runs (a program's name could be anything it chose).
            return presetName
        }
    }

    /// `~` for the home folder, `/` for the root, else the last path component.
    static func directoryLabel(_ directory: String, home: String) -> String {
        if directory == home { return "~" }
        if directory == "/" { return "/" }
        let last = URL(fileURLWithPath: directory).lastPathComponent
        return clean(last.isEmpty ? directory : last)
    }

    /// Removes control and bidirectional-formatting characters, collapses runs of white space, trims, and caps the length.
    static func clean(_ text: String, limit: Int = 60) -> String {
        var out = String.UnicodeScalarView()
        var lastWasSpace = false
        for scalar in text.unicodeScalars {
            let v = scalar.value
            let isControl = v < 0x20 || (0x7f...0x9f).contains(v)
            let isFormat = (0x200b...0x200f).contains(v) || (0x202a...0x202e).contains(v) || (0x2066...0x2069).contains(v)
                || v == 0xfeff || v == 0x2028 || v == 0x2029
            if isControl || isFormat {
                if (v == 0x09 || v == 0x0a || v == 0x0d), !lastWasSpace { out.append(" "); lastWasSpace = true }
                continue
            }
            if scalar.properties.isWhitespace {
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true
            } else {
                out.append(scalar)
                lastWasSpace = false
            }
        }
        let trimmed = String(out).trimmingCharacters(in: .whitespaces)
        return trimmed.count > limit ? String(trimmed.prefix(limit - 1)) + "…" : trimmed
    }
}
