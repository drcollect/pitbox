import Foundation
import UniformTypeIdentifiers

/// How a file a session produced may be opened, decided by its (resolved) name only.
enum ResultFileKind: Equatable, Sendable {
    /// "▤ Open <file>": in its default app.
    case document
    /// "▤ Preview <file>" and "Show in Finder": the app's script-free preview, never the browser.
    case webDocument
    /// "▤ Show <file> in Finder" only: scripts, programs, apps, archives, unknown types, deceptive names.
    case other
}

/// The type and name rules of results and of Fetch file. Pure functions over strings: nothing here touches the
/// filesystem. Names are judged, never repaired. The name and remote-path rules are the Fetch runner's
/// (the console's `Fetch/FetchNames.swift`), kept here as a copy because the targets do not import each other.
enum ResultFileTypes {
    /// Documents.
    static let documents: Set<String> = [
        "md", "markdown", "txt", "log", "csv", "tsv", "json", "pdf", "png", "jpg", "jpeg", "gif", "webp", "heic", "mp4",
        "mov", "mp3", "m4a", "wav", "rtf", "docx", "xlsx", "pptx", "pages", "numbers", "key",
    ]
    /// Web documents.
    static let webDocuments: Set<String> = ["html", "htm", "xhtml", "svg", "webarchive"]
    /// Types a document must never conform to on this Mac.
    static let refusedTypes: [UTType] = [.executable, .script, .applicationBundle, .package, .archive]

    /// The lowercase extension of `name` (`"report.MD"` → `"md"`), nil without one.
    static func pathExtension(_ name: String) -> String? {
        let ext = (name as NSString).pathExtension.lowercased()
        return ext.isEmpty ? nil : ext
    }

    /// Document, web document or other, by the name's extension, its type on this Mac and the deceptive-name rule.
    /// `webPreview` false (the preview not verified script-free) turns web documents into other files: Show in
    /// Finder only.
    static func kind(ofFileName name: String, webPreview: Bool) -> ResultFileKind {
        guard isAcceptableFileName(name), let ext = pathExtension(name) else { return .other }
        if documents.contains(ext) { return conformsToRefusedType(ext) ? .other : .document }
        if webDocuments.contains(ext) { return webPreview && !conformsToRefusedType(ext) ? .webDocument : .other }
        return .other
    }

    /// The file's type, by its extension, conforms to an executable, script, app, package or archive type.
    static func conformsToRefusedType(_ ext: String) -> Bool {
        guard let type = UTType(filenameExtension: ext) else { return false }
        return refusedTypes.contains { type.conforms(to: $0) }
    }

    /// A file on the server that may be fetched: a document or a web document, or `zip`, `tar.gz`, `tgz`.
    static func isFetchable(_ name: String) -> Bool {
        guard isAcceptableFileName(name), let ext = pathExtension(name) else { return false }
        let lower = name.lowercased()
        return documents.contains(ext) || webDocuments.contains(ext) || ext == "zip" || ext == "tgz" || lower.hasSuffix(".tar.gz")
    }

    // MARK: Names

    /// The longest name accepted, in UTF-8 bytes.
    static let maxNameBytes = 200

    /// The name rules: refused when it holds a B1 or B2 character (any non-ASCII character), `/`, `:`, a control
    /// character, starts with `.` or `-`, starts or ends with a space, is longer than 200 bytes, or hides its real type.
    static func isAcceptableFileName(_ name: String) -> Bool {
        let scalars = name.unicodeScalars
        guard let first = scalars.first, name.utf8.count <= maxNameBytes else { return false }
        guard first != ".", first != "-", first != " ", scalars.last != " " else { return false }
        for scalar in scalars {
            guard scalar.isASCII else { return false }
            if scalar.value < 0x20 || scalar.value == 0x7F || scalar == "/" || scalar == ":" { return false }
        }
        return !hidesItsType(name)
    }

    /// A document-looking name with an app or script extension at the end (`report.pdf.command`, `notes.md.app`):
    /// Finder hides the last extension when extensions are hidden, so it would show as a document.
    static func hidesItsType(_ name: String) -> Bool {
        let parts = name.lowercased().split(separator: ".", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3, let last = parts.last, executableExtensions.contains(last) else { return false }
        return parts[1..<(parts.count - 1)].contains { documentLookingExtensions.contains($0) }
    }

    // MARK: Server paths

    /// One file on the server: absolute or `~/…` (a relative path would be taken from the server's home folder by scp,
    /// not from the session's folder, so it is refused), at most 1,024 characters, printable ASCII, no glob or escape
    /// character, `$` or backtick, no `..` part, no trailing `/`.
    static func isAcceptableRemotePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.unicodeScalars.count <= 1_024, ResultPaths.characterRefusal(path) == nil else { return false }
        guard path.hasPrefix("/") || path.hasPrefix("~/") else { return false }
        guard !path.unicodeScalars.contains(where: { remotePathForbidden.contains($0) }), !path.hasSuffix("/") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        if parts.contains("..") { return false }
        guard let last = parts.last, !last.isEmpty, last != ".", last != "~" else { return false }
        return true
    }

    // MARK: Tables

    /// Characters a remote path may not hold: glob characters, the glob escape, `$`, backtick and the shell's quotes.
    private static let remotePathForbidden = Set("*?[]{}\\$`'\"".unicodeScalars)

    /// Extensions that make Finder or `open` run something (the Fetch runner's list).
    static let executableExtensions: Set<String> = [
        "app", "appex", "command", "tool", "terminal", "sh", "bash", "zsh", "csh", "tcsh", "ksh", "fish", "py", "pyc",
        "pyw", "rb", "pl", "pm", "php", "js", "mjs", "cjs", "jxa", "scpt", "scptd", "applescript", "workflow", "wflow",
        "action", "shortcut", "pkg", "mpkg", "dmg", "iso", "img", "sparseimage", "sparsebundle", "jar", "exe", "bat",
        "cmd", "com", "scr", "msi", "vbs", "vbe", "jse", "wsf", "wsh", "ps1", "psm1", "lnk", "hta", "reg",
        "webloc", "inetloc", "fileloc", "url", "desktop", "plugin", "bundle", "kext", "dylib", "so", "prefpane",
        "saver", "service", "qlgenerator", "mdimporter", "osax", "xpc", "framework", "run", "bin", "out", "ipa",
    ]

    /// Extensions that make a name look like a document, picture, sound, film or archive (the Fetch runner's list).
    static let documentLookingExtensions: Set<String> = [
        "pdf", "md", "markdown", "txt", "text", "rtf", "rtfd", "doc", "docx", "odt", "pages", "xls", "xlsx", "ods",
        "csv", "tsv", "numbers", "ppt", "pptx", "odp", "key", "json", "xml", "yaml", "yml", "toml", "ini", "log",
        "html", "htm", "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp", "svg", "psd", "mp3",
        "m4a", "wav", "aiff", "flac", "aac", "ogg", "mp4", "m4v", "mov", "avi", "mkv", "webm", "zip", "tar", "gz",
        "tgz", "bz2", "xz", "7z", "rar", "epub", "ics", "vcf", "eml", "sql", "srt", "vtt", "ipynb",
    ]
}

/// The type rules for the composition root: what a file that Fetch file saved in Downloads gets beside
/// Show in Finder. The console's sheet takes it through its initializer's `fetchedFileOpening:` parameter, the Ready
/// list's result rows through `fetchedFileOpens` (documents only: their button reads "Open").
public enum CodeResultFiles {
    public enum Opening: String, Sendable, Equatable { case open, preview, showInFinderOnly }

    /// Open for documents, Preview for web documents (while the preview is script-free), Show in Finder only for
    /// archives, scripts, apps, unknown types and deceptive names. By the saved name.
    public static func fetchedOpening(fileName name: String) -> Opening {
        switch ResultFileTypes.kind(ofFileName: name, webPreview: CodeWebPreview.isScriptFree) {
        case .document: return .open
        case .webDocument: return .preview
        case .other: return .showInFinderOnly
        }
    }
}
