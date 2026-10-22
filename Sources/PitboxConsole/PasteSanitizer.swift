import AppKit

/// Cleans text on its way from the clipboard or a drop into the terminal.
///
/// A terminal that pastes clipboard text verbatim can be attacked with it: text copied from a web page may contain the
/// end marker of a bracketed paste (`ESC [ 201 ~`) followed by commands, which the shell would then run as if typed.
/// So every control character except tab and return is removed (which removes ESC and with it the marker), including the
/// C1 range and DEL, and newlines become carriage returns, which is what Return sends.
enum PasteSanitizer {
    static func clean(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            let v = scalar.value
            switch v {
            case 0x0d:
                out.append("\r")
                previousWasCR = true
                continue
            case 0x0a:
                if !previousWasCR { out.append("\r") }
            case 0x09:
                out.append(scalar)
            case 0x00...0x1f, 0x7f...0x9f, 0x2028, 0x2029:
                break   // control characters, DEL, C1, line and paragraph separators
            default:
                out.append(scalar)
            }
            previousWasCR = false
        }
        return String(out)
    }

    /// The text to paste from a pasteboard: its string, else the paths of copied files (escaped for a shell prompt).
    static func text(from pasteboard: NSPasteboard) -> String? {
        if let string = pasteboard.string(forType: .string), !string.isEmpty { return string }
        return filePaths(from: pasteboard)
    }

    /// Text for a drop: paths of dropped files (escaped, space separated, with a trailing space so the next argument can
    /// be typed), else a dropped URL, else dropped text.
    static func dropText(from pasteboard: NSPasteboard) -> String? {
        if let paths = filePaths(from: pasteboard) { return paths + " " }
        if let url = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first, !url.isFileURL { return url.absoluteString }
        if let string = pasteboard.string(forType: .string), !string.isEmpty { return string }
        return nil
    }

    static func filePaths(from pasteboard: NSPasteboard) -> String? {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return nil }
        return urls.map { ShellQuote.escapePath($0.path) }.joined(separator: " ")
    }
}
