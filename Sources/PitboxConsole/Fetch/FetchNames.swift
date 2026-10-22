import Foundation

// Fetch file: the grammars and name rules the runner applies itself, whatever the classifier already decided. Pure
// functions over strings; nothing here touches the file system. Names are refused, never repaired.

enum FetchNames {
    // MARK: Server and user

    /// An SSH alias Pitbox may connect through: `^[A-Za-z0-9._-]{1,64}$`, no leading `-`. Whether it is an
    /// exact `Host` token of `~/.ssh/config` is checked separately.
    static func isValidAlias(_ alias: String) -> Bool {
        let scalars = alias.unicodeScalars
        guard (1...64).contains(scalars.count), scalars.first != "-" else { return false }
        return scalars.allSatisfy { isASCIIAlphanumeric($0) || $0 == "." || $0 == "_" || $0 == "-" }
    }

    /// A user name taken from a reply: `^[a-z_][a-z0-9_-]{0,31}$`.
    static func isValidReplyUser(_ user: String) -> Bool {
        let scalars = Array(user.unicodeScalars)
        guard (1...32).contains(scalars.count), let first = scalars.first else { return false }
        guard isLowercaseASCIILetter(first) || first == "_" else { return false }
        return scalars.dropFirst().allSatisfy { isLowercaseASCIILetter($0) || isASCIIDigit($0) || $0 == "_" || $0 == "-" }
    }

    /// The login the user's own config gives (`ssh -G`'s `user`). It comes from their file, not from a reply, so it is not
    /// held to the reply grammar (a config may say `first.last`); it only has to keep `user@alias:path` unambiguous:
    /// 1-64 printable ASCII characters without `@`, `:`, `/`, spaces or quotes, not starting with `-`.
    static func isUsableConfigUser(_ user: String) -> Bool {
        let scalars = user.unicodeScalars
        guard (1...64).contains(scalars.count), scalars.first != "-" else { return false }
        return scalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7F && !"@:/\\'\"`$".unicodeScalars.contains($0) }
    }

    // MARK: Remote path

    /// The remote path rules, checked again by the runner: one file (absolute, `~/…` or relative to the remote
    /// home), at most 1,024 characters, no B1 character, no glob or escape character (scp's SFTP mode expands globs in
    /// remote paths), no `$` or backtick, no `..` part, no trailing `/`, and `~` only as a leading `~/`.
    static func isAcceptableRemotePath(_ path: String) -> Bool {
        let scalars = path.unicodeScalars
        guard !scalars.isEmpty, scalars.count <= 1_024 else { return false }
        for scalar in scalars {
            if isB1(scalar) { return false }
            switch scalar.properties.generalCategory {
            case .unassigned, .privateUse, .surrogate: return false
            default: break
            }
            if Self.remotePathForbidden.contains(scalar) { return false }
        }
        if path.hasSuffix("/") { return false }
        if path.hasPrefix("~"), !path.hasPrefix("~/") { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        if parts.contains("..") { return false }
        guard let last = parts.last, !last.isEmpty, last != ".", last != "~" else { return false }
        return true
    }

    /// The remote file's base name (`release-notes.md` of `/home/alex/drafts/release-notes.md`), nil when there is none.
    static func baseName(ofRemotePath path: String) -> String? {
        guard let last = path.split(separator: "/", omittingEmptySubsequences: false).last, !last.isEmpty else { return nil }
        return String(last)
    }

    // MARK: File name in Downloads

    /// The longest name accepted, in UTF-8 bytes.
    static let maxNameBytes = 200

    /// The name rules: refused (never repaired) when it holds a B1 or B2 character (B2 in a file name: any
    /// non-ASCII character, so a Cyrillic `р` in `rероrt.pdf` cannot pass), `/`, `:`, a control character, starts with
    /// `.` or `-`, starts or ends with a space, is longer than 200 bytes, or hides its real type.
    static func isAcceptableFileName(_ name: String) -> Bool {
        let scalars = name.unicodeScalars
        guard let first = scalars.first, name.utf8.count <= maxNameBytes else { return false }
        guard first != ".", first != "-", first != " ", scalars.last != " " else { return false }
        for scalar in scalars {
            guard scalar.isASCII, !isB1(scalar) else { return false }
            if scalar.value < 0x20 || scalar.value == 0x7F || scalar == "/" || scalar == ":" { return false }
        }
        return !hidesItsType(name)
    }

    /// A document-looking name with an app or script extension at the end (`report.pdf.command`, `notes.md.app`,
    /// `photo.JPG .app`): Finder hides the last extension when extensions are hidden, so it would show as a document.
    static func hidesItsType(_ name: String) -> Bool {
        let parts = name.lowercased().split(separator: ".", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3, let last = parts.last, executableExtensions.contains(last) else { return false }
        return parts[1..<(parts.count - 1)].contains { documentExtensions.contains($0) }
    }

    /// The names Downloads is tried with, in order, as Finder numbers copies: `name`, `name 2.ext`, … `name 99.ext`
    /// (`archive.tar 2.gz`; `README 2` without an extension).
    static func candidates(for name: String, upTo limit: Int = 99) -> [String] {
        let nsName = name as NSString
        let ext = nsName.pathExtension
        let stem = ext.isEmpty ? name : nsName.deletingPathExtension
        guard limit >= 2 else { return [name] }
        return [name] + (2...limit).map { ext.isEmpty ? "\(stem) \($0)" : "\(stem) \($0).\(ext)" }
    }

    // MARK: B1

    /// B1, hidden or deceptive characters, from the Unicode data of the running system: every Cc and Cf character,
    /// every Default_Ignorable_Code_Point (U+034F, U+115F, U+17B4, U+180B-U+180F, U+3164, the variation selectors and
    /// tags among them), U+2028 and U+2029, and every space other than U+0020. Unlike in command text (where tab and
    /// newline are allowed), the callers here refuse tab and newline too.
    static func isB1(_ scalar: Unicode.Scalar) -> Bool {
        let properties = scalar.properties
        switch properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator: return true
        case .spaceSeparator: return scalar != " "
        default: return properties.isDefaultIgnorableCodePoint
        }
    }

    // MARK: Tables

    /// Characters a remote path may not hold after unquoting: glob characters, the glob escape, `$` and backtick.
    private static let remotePathForbidden = Set("*?[]{}\\$`".unicodeScalars)

    /// Extensions that make Finder or `open` run something: apps and their parts, scripts, installers, disk images,
    /// automation and link files.
    static let executableExtensions: Set<String> = [
        "app", "appex", "command", "tool", "terminal", "sh", "bash", "zsh", "csh", "tcsh", "ksh", "fish", "py", "pyc",
        "pyw", "rb", "pl", "pm", "php", "js", "mjs", "cjs", "jxa", "scpt", "scptd", "applescript", "workflow", "wflow",
        "action", "shortcut", "pkg", "mpkg", "dmg", "iso", "img", "sparseimage", "sparsebundle", "jar", "exe", "bat",
        "cmd", "com", "scr", "msi", "vbs", "vbe", "jse", "wsf", "wsh", "ps1", "psm1", "lnk", "hta", "reg",
        "webloc", "inetloc", "fileloc", "url", "desktop", "plugin", "bundle", "kext", "dylib", "so", "prefpane",
        "saver", "service", "qlgenerator", "mdimporter", "osax", "xpc", "framework", "run", "bin", "out", "ipa",
    ]

    /// Extensions that make a name look like a document, picture, sound, film or archive.
    static let documentExtensions: Set<String> = [
        "pdf", "md", "markdown", "txt", "text", "rtf", "rtfd", "doc", "docx", "odt", "pages", "xls", "xlsx", "ods",
        "csv", "tsv", "numbers", "ppt", "pptx", "odp", "key", "json", "xml", "yaml", "yml", "toml", "ini", "log",
        "html", "htm", "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp", "svg", "psd", "mp3",
        "m4a", "wav", "aiff", "flac", "aac", "ogg", "mp4", "m4v", "mov", "avi", "mkv", "webm", "zip", "tar", "gz",
        "tgz", "bz2", "xz", "7z", "rar", "epub", "ics", "vcf", "eml", "sql", "srt", "vtt", "ipynb",
    ]

    // MARK: ASCII helpers

    private static func isASCIIDigit(_ s: Unicode.Scalar) -> Bool { (0x30...0x39).contains(s.value) }
    private static func isLowercaseASCIILetter(_ s: Unicode.Scalar) -> Bool { (0x61...0x7A).contains(s.value) }
    private static func isASCIIAlphanumeric(_ s: Unicode.Scalar) -> Bool {
        isASCIIDigit(s) || isLowercaseASCIILetter(s) || (0x41...0x5A).contains(s.value)
    }
}
