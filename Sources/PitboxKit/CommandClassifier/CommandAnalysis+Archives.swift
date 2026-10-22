import Foundation

// Archives unpacked into a folder: `tar x`, `bsdtar`, `unzip`, `ditto -x` and
// `7z x` write whatever the archive holds. Into the home folder or a protected settings path that can replace startup
// and settings files (R5); elsewhere it is a note.

extension CommandAnalysis {
    static let tarPrograms: Set<String> = ["tar", "bsdtar", "gtar", "gnutar"]
    static let sevenZipPrograms: Set<String> = ["7z", "7za", "7zz", "7zr"]

    func ruleArchives(_ seg: Segment) {
        guard let destination = archiveDestination(seg) else { return }
        let paths: [String]?
        if let d = destination.word { paths = localPaths(d, in: seg) } else { paths = seg.folder.map { [$0] } }
        let folder: String
        if let p = paths, p.count == 1 { folder = shownPath(p[0]) }
        else if let d = destination.word { folder = describe(d) }
        else { folder = "the folder it runs in" }
        let userHome = "/users/" + facts.userName.lowercased()
        let replacesSettings = paths?.contains { p in
            let l = p.lowercased()
            return l == home.lowercased() || l == userHome || isProtectedSettingsPath(p)
        } ?? false
        if replacesSettings {
            addFlag(.r5, "Unpacks an archive into \(folder); it can replace startup and settings files", in: seg,
                    range: destination.word?.range)
        } else {
            addNote(.writes, "Unpacks an archive into \(folder); its contents are not shown")
        }
    }

    /// Where an extraction writes: its destination word, or nil for the folder it runs in. Nil when nothing is unpacked.
    func archiveDestination(_ seg: Segment) -> (word: CWord?, explicit: Bool)? {
        let key = seg.key
        let args = seg.args
        if Self.tarPrograms.contains(key) {
            var extract = false
            var destination: CWord?
            var k = 0
            // Old-style `tar xzf a.tgz -C dir`: the letters' values follow in order.
            if let first = args.first?.text, !first.hasPrefix("-"), !first.isEmpty, first.allSatisfy(\.isLetter) {
                if first.contains("x") { extract = true }
                var next = 1
                for c in first where "fCbTXsK".contains(c) {
                    if c == "C", next < args.count { destination = args[next] }
                    next += 1
                }
                k = next
            }
            while k < args.count {
                let w = args[k]
                guard let t = w.text else { k += 1; continue }
                if t == "--extract" || t == "--get" { extract = true }
                else if t.hasPrefix("--directory=") { destination = Self.attached(String(t.dropFirst("--directory=".count)), of: w) }
                else if t == "--directory", k + 1 < args.count { destination = args[k + 1]; k += 1 }
                else if t.hasPrefix("-"), !t.hasPrefix("--") {
                    let letters = Array(t.dropFirst())
                    for (j, c) in letters.enumerated() {
                        if c == "x" { extract = true }
                        guard "fCbTXsK".contains(c) else { continue }
                        let rest = String(letters[(j + 1)...])
                        if c == "C" {
                            destination = rest.isEmpty ? (k + 1 < args.count ? args[k + 1] : nil) : Self.attached(rest, of: w)
                        }
                        if rest.isEmpty { k += 1 }
                        break
                    }
                }
                k += 1
            }
            return extract ? (destination, destination != nil) : nil
        }
        if key == "unzip" {
            let p = parseArgs(args, ArgSpec(["d", "P"]))
            if p.has("l", "t", "v", "Z", "p", "c", "z") { return nil }
            if let d = p.option("d") {
                if let w = d.valueWord { return (w, true) }
                if let v = d.value { return (Self.attached(v, of: d.word), true) }
            }
            return (nil, false)
        }
        if key == "ditto" {
            let p = parseArgs(args, ArgSpec(["V", "-arch", "-bom"]))
            guard p.has("x"), p.operands.count >= 2, let last = p.operands.last else { return nil }
            return (last, true)
        }
        if Self.sevenZipPrograms.contains(key) {
            guard let verb = args.first?.text?.lowercased(), verb == "x" || verb == "e" else { return nil }
            for w in args.dropFirst() {
                if let t = w.text, t.hasPrefix("-o"), t.count > 2 { return (Self.attached(String(t.dropFirst(2)), of: w), true) }
            }
            return (nil, false)
        }
        return nil
    }

    /// A word for a value written inside another word (`-C~/x`, `--directory=/x`, `-o/x`).
    static func attached(_ value: String, of w: CWord) -> CWord {
        let part = ShellWordPart.text(value, quoting: .none, decodedEscapes: false, utf16Range: w.range)
        return CWord(word: ShellWord(parts: [part], utf16Range: w.range), text: value,
                     tilde: value == "~" || value.hasPrefix("~/"))
    }
}
