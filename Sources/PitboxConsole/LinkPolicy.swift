import Darwin
import Foundation
import PitboxKit

/// Decides what a Cmd-click on a link in the terminal may do. The text comes from a program's output, so it is data:
/// only web and mail links open in the default app, and files are opened only when opening them cannot run code.
///
/// Two rules for output that lies:
/// - A path is never looked up under `/net`, `/home`, `/Volumes`, `/Network` or an automount point
///   (docs/THREAT_MODEL.md, T33): it is checked as text first, then walked part by part (`LocalPathWalk`), links on the
///   way included. Such a link opens nothing.
/// - An explicit (OSC 8) link whose shown text reads as an address other than its target opens nothing (the console
///   beeps): a program cannot show `https://bank.example` and open another page on the user's click. Text with spaces is
///   weighed piece by piece, so `https://bank.example /login` or `visit https://a.example` cannot hide the claim either.
enum LinkPolicy {
    enum Action: Equatable {
        case open(URL)
        /// Show in Finder instead of opening (programs, scripts, apps, installers).
        case reveal(URL)
        case ignore
        /// An OSC 8 link whose shown text names another address: nothing opens.
        case misleading
    }

    static let openSchemes: Set<String> = ["http", "https", "mailto"]
    /// Extensions whose default action would run or install something.
    static let revealExtensions: Set<String> = [
        "app", "command", "tool", "terminal", "sh", "zsh", "bash", "csh", "ksh", "fish", "pkg", "mpkg", "dmg", "scpt",
        "scptd", "workflow", "action", "jar", "exe", "bat", "cmd", "pl", "py", "rb", "js", "webloc", "inetloc", "url",
        "prefpane", "saver", "kext", "plugin", "wflow",
    ]

    /// - Parameters:
    ///   - link: the link text (an OSC 8 target or a detected URL or path).
    ///   - directory: the session's folder, for relative paths like `src/main.swift:12`.
    ///   - shownText: for an OSC 8 link, the text each run of cells with this target shows on screen (empty for a
    ///     detected link, whose text is the link itself).
    ///   - fs, pathGuard: the lookups for paths and the network check they run under (tests pass fakes; nil: this Mac's
    ///     mount table now).
    static func action(for link: String, directory: String?, home: String = NSHomeDirectory(), shownText: [String] = [],
                       fs: LocalPathFileSystem = LiveLocalPathFileSystem(), guard pathGuard: NetworkPathGuard? = nil) -> Action {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count < 4096, !trimmed.contains("\0") else { return .ignore }
        if shownText.contains(where: { misleads($0, target: trimmed) }) { return .misleading }
        // A URL has "scheme://" (or is mailto:). Text like `main.swift:12:5` also parses as a URL but is a file and line.
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme.count > 1,
           scheme == "mailto" || trimmed.lowercased().hasPrefix(scheme + "://") {
            if openSchemes.contains(scheme) { return url.host?.isEmpty == false || scheme == "mailto" ? .open(url) : .ignore }
            if scheme == "file", url.isFileURL, url.path.hasPrefix("/") {
                return fileAction(path: FolderText.lexical(url.path), guard: pathGuard ?? .current(), fs: fs)
            }
            return .ignore   // ssh:, vnc:, custom app schemes
        }
        let checked = pathGuard ?? .current()
        for candidate in candidates(trimmed, directory: directory, home: home) {
            let action = fileAction(path: candidate, guard: checked, fs: fs)
            if action != .ignore { return action }
        }
        return .ignore
    }

    /// `~/x`, `/abs`, `rel/x` (against `directory`), each optionally with a `:line[:column]` suffix that is dropped when
    /// the full text is not a file; made absolute and lexical by text only (no lookup: unlike `standardizingPath`, which
    /// asks the disk before it drops `/private` or `/private/var/automount`).
    static func candidates(_ text: String, directory: String?, home: String) -> [String] {
        var forms = [text]
        if let range = text.range(of: #":[0-9]+(:[0-9]+)?$"#, options: .regularExpression) {
            forms.append(String(text[..<range.lowerBound]))
        }
        return forms.compactMap { form in
            var expanded = form
            if expanded == "~" {
                expanded = home
            } else if expanded.hasPrefix("~/") {
                expanded = home + String(expanded.dropFirst(1))
            } else if !expanded.hasPrefix("/") {
                guard let directory, directory.hasPrefix("/") else { return nil }
                expanded = directory + "/" + expanded
            }
            return FolderText.lexical(expanded)
        }
    }

    /// What a click on the file at the lexical absolute `path` does, after the network check and a checked walk. A
    /// path that is missing, refused or unreadable ignores the click.
    private static func fileAction(path: String, guard pathGuard: NetworkPathGuard, fs: LocalPathFileSystem) -> Action {
        guard case .found(let real, let info) = LocalPathWalk.resolve(path, followLastLink: true, guard: pathGuard, fs: fs) else {
            return .ignore
        }
        let isDirectory = info.kind == .directory
        let url = URL(fileURLWithPath: path, isDirectory: isDirectory)
        if revealExtensions.contains(url.pathExtension.lowercased()) { return .reveal(url) }
        // `faccessat` with `AT_SYMLINK_NOFOLLOW_ANY`: the real path has no link, and one swapped in since is refused.
        if !isDirectory, faccessat(AT_FDCWD, real, X_OK, AT_SYMLINK_NOFOLLOW_ANY) == 0 { return .reveal(url) }
        return .open(url)
    }

    /// Whether an OSC 8 link's shown text names an address other than its target. The text is weighed piece by piece
    /// (split at every space, tab, no-break space or other whitespace), each without the brackets, quotes and punctuation
    /// prose puts around an address (`trimmed`: `(https://a.example/docs).` is `https://a.example/docs`). A piece reads as
    /// an address when, as it reads (`skeleton`: fullwidth and other compatibility forms, case, accents, look-alike
    /// letters of other scripts and invisible format characters folded away), it contains `://` anywhere, or starts with
    /// `mailto:` or `www.` (`claimsAddress`); the piece as written (trimmed) must then equal the target, except for the case of the scheme and host, a trailing `/`, and (for
    /// `www.` text) http or https. Any piece that names another address makes the whole text misleading
    /// (`https://bank.example /login`, `visit https://a.example` for another target, a bare `https://`, `һttps://…` with a
    /// Cyrillic letter). Pieces that name no address ("docs", `main.swift:12`, a file name) claim nothing. An address that
    /// cannot be compared (a look-alike one never can) counts as misleading.
    static func misleads(_ shown: String, target: String) -> Bool {
        shown.split(whereSeparator: { $0.isWhitespace }).contains { pieceMisleads(String($0), target: target) }
    }

    /// Whether one piece (no whitespace) claims an address: without the brackets, quotes and punctuation around it
    /// (`trimmed`), and as it reads (`skeleton`), it contains `://` anywhere, or starts with `mailto:` or `www.`.
    static func claimsAddress(_ piece: String) -> Bool {
        let reads = skeleton(trimmed(piece))
        return reads.hasPrefix("www.") || reads.hasPrefix("mailto:") || reads.contains("://")
    }

    /// `misleads` for one piece without whitespace.
    private static func pieceMisleads(_ piece: String, target: String) -> Bool {
        let text = trimmed(piece)
        guard !text.isEmpty else { return false }
        let reads = skeleton(text)
        let schemeShown: Bool
        let claimedText: String
        if reads.hasPrefix("www.") {
            schemeShown = false
            claimedText = "https://" + text
        } else if reads.hasPrefix("mailto:") || reads.contains("://") {
            schemeShown = true
            claimedText = text
        } else {
            return false
        }
        guard let claimed = URLComponents(string: claimedText),
              let actual = URLComponents(string: target.trimmingCharacters(in: .whitespacesAndNewlines)) else { return true }
        func trimmedPath(_ path: String) -> String { path.hasSuffix("/") ? String(path.dropLast()) : path }
        if schemeShown, claimed.scheme?.lowercased() != actual.scheme?.lowercased() { return true }
        if !schemeShown, !["http", "https"].contains(actual.scheme?.lowercased() ?? "") { return true }
        return claimed.host?.lowercased() != actual.host?.lowercased() || claimed.port != actual.port
            || claimed.user != actual.user || claimed.password != actual.password
            || trimmedPath(claimed.percentEncodedPath) != trimmedPath(actual.percentEncodedPath)
            || claimed.percentEncodedQuery != actual.percentEncodedQuery
            || claimed.percentEncodedFragment != actual.percentEncodedFragment
    }

    /// A piece without what prose puts around an address: leading `(`, `<`, `[`, straight and typographic quotes and
    /// guillemets; trailing quotes, guillemets, `.`, `,`, `;`, `:`, `!`, `?`, and `)`, `]`, `>` only while the piece has
    /// more of them than of their openers (`…/wiki/Foo_(bar)` keeps its own). Brackets cannot hide a claim: what is left
    /// is weighed and compared as before.
    static func trimmed(_ piece: String) -> String {
        var text = Substring(piece)
        while let first = text.first, leadingPunctuation.contains(first) { text = text.dropFirst() }
        while let last = text.last {
            if trailingPunctuation.contains(last) {
                text = text.dropLast()
            } else if let opener = closers[last], text.filter({ $0 == last }).count > text.filter({ $0 == opener }).count {
                text = text.dropLast()
            } else {
                break
            }
        }
        return String(text)
    }

    private static let leadingPunctuation: Set<Character> = ["(", "<", "[", "\"", "'", "\u{201C}", "\u{2018}", "\u{00AB}", "\u{2039}"]
    private static let trailingPunctuation: Set<Character> = ["\"", "'", ".", ",", ";", ":", "!", "?", "\u{201D}", "\u{2019}",
                                                              "\u{00BB}", "\u{203A}"]
    private static let closers: [Character: Character] = [")": "(", "]": "[", ">": "<"]

    /// A piece as it reads, for deciding whether it claims an address: compatibility forms mapped to their plain forms
    /// (fullwidth `ｈｔｔｐｓ`, `：`, `／`, the one-dot leader `․`), case, width and accents folded, look-alike letters of other
    /// scripts mapped to the Latin letters they pass for, and invisible format characters (zero-width space, joiners, soft
    /// hyphen) dropped. Only for that decision: the comparison uses the piece as written.
    static func skeleton(_ text: String) -> String {
        let folded = text.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: nil)
        var reads = ""
        for character in folded {
            let invisible = character.unicodeScalars.allSatisfy {
                $0.properties.generalCategory == .format || $0.properties.isDefaultIgnorableCodePoint
            }
            if invisible { continue }
            reads.append(lookAlikes[character] ?? character)
        }
        return reads
    }

    /// Letters of other scripts (after case folding) that pass for Latin ones in terminal fonts, after Unicode's
    /// confusables list: Cyrillic, Greek and Armenian letters and a few Latin variants. Folding upper case first, the
    /// capitals that look Latin (`Н`, `Т`, `Р`, `Η`, `Τ`, `Ρ`, …) are covered through their small letters.
    static let lookAlikes: [Character: Character] = [
        // Cyrillic
        "\u{0430}": "a", "\u{0432}": "b", "\u{0441}": "c", "\u{0501}": "d", "\u{0435}": "e", "\u{04BB}": "h", "\u{043D}": "h",
        "\u{0456}": "i", "\u{0458}": "j", "\u{043A}": "k", "\u{04CF}": "l", "\u{043C}": "m", "\u{043E}": "o", "\u{0440}": "p",
        "\u{051B}": "q", "\u{0455}": "s", "\u{0442}": "t", "\u{0443}": "y", "\u{04AF}": "y", "\u{0445}": "x", "\u{051D}": "w",
        // Greek
        "\u{03B1}": "a", "\u{03B2}": "b", "\u{03F2}": "c", "\u{03B5}": "e", "\u{03B7}": "h", "\u{03B9}": "i", "\u{03F3}": "j",
        "\u{03BA}": "k", "\u{03BC}": "m", "\u{03BD}": "v", "\u{03BF}": "o", "\u{03C1}": "p", "\u{03C4}": "t", "\u{03C5}": "u",
        "\u{03C7}": "x", "\u{03C9}": "w", "\u{03B6}": "z",
        // Armenian
        "\u{0570}": "h", "\u{0578}": "n", "\u{0585}": "o", "\u{057D}": "u",
        // Latin variants
        "\u{0131}": "i", "\u{0237}": "j", "\u{0251}": "a", "\u{0261}": "g",
    ]
}
