import Foundation

// Rules that look at the block as a whole rather than one segment: assignments that change which program runs or what
// code it loads (an extension of R11 and R18: `PATH=/tmp/x:$PATH; ls` runs whatever `/tmp/x/ls` is).

extension CommandAnalysis {
    static let loaderVariables: Set<String> = [
        "LD_PRELOAD", "LD_LIBRARY_PATH", "BASH_ENV", "ENV", "ZDOTDIR", "NODE_OPTIONS", "PERL5OPT", "RUBYOPT",
        "PYTHONSTARTUP", "GIT_SSH_COMMAND", "GIT_EXEC_PATH",
    ]

    func applyBlockRules() {
        let topSegments = tops.map { segments[$0] }
        for (n, seg) in topSegments.enumerated() {
            let laterCommands = topSegments[(n + 1)...].contains { $0.programIndex != nil }
            var assigned: [(String, Range<Int>)] = seg.assignments.map { ($0.name, $0.utf16Range) }
            for w in seg.words.prefix(seg.programIndex ?? seg.words.count) {
                if let t = w.text, Self.isAssignmentWord(t), let eq = t.firstIndex(of: "=") { assigned.append((String(t[..<eq]), w.range)) }
            }
            if ["export", "typeset", "declare", "local", "readonly"].contains(seg.key) {
                for w in seg.args {
                    let prefix = w.staticPrefix
                    if let eq = prefix.firstIndex(of: "=") { assigned.append((String(prefix[..<eq]), w.range)) }
                }
            }
            let standalone = seg.programIndex == nil || seg.key == "export" || seg.key == "typeset" || seg.key == "declare"
            let runsSomething = standalone ? laterCommands : seg.programIndex != nil
            guard runsSomething else { continue }
            for (name, range) in assigned {
                if name == "PATH" || name == "path" {
                    addFlag(.r11, "Changes where programs are found (PATH); what runs may not be what you see", range,
                            segment: seg.id)
                } else if Self.loaderVariables.contains(name) || name.hasPrefix("DYLD_") {
                    addFlag(.r18, "Changes what code programs load or run (\(name)); that code is not shown here", range,
                            segment: seg.id)
                }
            }
        }
    }

    /// R3: the program is a file a downloader wrote earlier in the block (download, `chmod +x` and run).
    func checkRunsDownload(_ seg: Segment) {
        guard let k = seg.programIndex, wasDownloaded(seg.words[k], in: seg) else { return }
        addFlag(.r3, "Runs code it downloaded in this block without showing it", in: seg, range: seg.words[k].range)
    }
}
