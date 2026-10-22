import Foundation

/// A link found in a final reply, by its shape: a reply's links may be hostile (docs/THREAT_MODEL.md).
enum ResultLink: Equatable, Sendable {
    /// A local preview: `localhost`, `127.0.0.1`, `[::1]` or `0.0.0.0` with a written port 1024-65535. `url` is rebuilt
    /// from the checked parts as `<scheme>://<host>:<port>/` (path, query and fragment dropped; `0.0.0.0` becomes
    /// `localhost`); `label` is "localhost:5173".
    case preview(url: URL, label: String)
    /// `https://claude.ai/artifact/<id>` or `https://claude.ai/code/artifact/<id>`, rebuilt without query or fragment.
    case artifact(URL)
    /// A configured dashboard site's link (`CodeDashboardSites`): the dashboards' own, never a result and never an
    /// "other link".
    case dashboard
    /// Any other link: not a button, only counted ("2 other links in the reply").
    case other
}

/// Finds links in reply text and checks their shapes. The raw text of a link is never opened: what opens is
/// rebuilt from its parsed and checked parts. Parsing fails closed: a link is a result only when `URLComponents`
/// agrees byte for byte with its raw host text, the scheme is lowercase `http` or `https`, and there is no user info.
enum ResultLinks {
    /// Hosts of a local preview, byte for byte (no `LOCALHOST`, `localhost.`, `127.1`, `0x7f000001`, percent-encoding or
    /// IDN), and the host each opens as.
    static let previewHosts: [String: String] = ["localhost": "localhost", "127.0.0.1": "127.0.0.1", "[::1]": "[::1]",
                                                 "0.0.0.0": "localhost"]
    static let previewPorts = 1024...65535
    static let artifactHost = "claude.ai"
    /// Links per reply at most (a flood of links costs nothing beyond this).
    static let maxLinksPerReply = 256

    // MARK: Finding

    /// The raw links of `text` in order: bare `http://` and `https://` (and other `scheme://`) text, Markdown link
    /// targets and `<…>` autolinks, in prose and in code, but not in blockquotes (a quotation) and never inside a Markdown
    /// link's text. Trailing `.,;:!?)]}>'"` is trimmed.
    static func find(in text: String) -> [String] {
        var out: [String] = []
        var inFence = false
        var fenceMarker = ""
        var quoteContinues = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.drop { $0 == " " }
            let indent = line.count - trimmed.count
            if inFence {
                if indent <= 3, trimmed.hasPrefix(fenceMarker) { inFence = false } else { scanLine(line, into: &out) }
                continue
            }
            if indent <= 3, trimmed.hasPrefix(">") {
                quoteContinues = true
                continue
            }
            if trimmed.isEmpty { quoteContinues = false; continue }
            // A lazy continuation line of a blockquote's paragraph is part of the quotation (CommonMark).
            if quoteContinues { continue }
            if indent <= 3, let marker = fence(trimmed) {
                inFence = true
                fenceMarker = marker
                continue
            }
            scanLine(line, into: &out)
            if out.count >= maxLinksPerReply { break }
        }
        return Array(out.prefix(maxLinksPerReply))
    }

    /// "```" or "~~~" (or longer) when `line` opens a fenced block.
    private static func fence(_ line: Substring) -> String? {
        for mark in ["`", "~"] {
            let run = line.prefix { String($0) == mark }
            if run.count >= 3 { return String(run) }
        }
        return nil
    }

    /// Every `scheme://…` occurrence of one line outside Markdown link texts.
    private static func scanLine(_ line: String, into out: inout [String]) {
        let chars = Array(line.unicodeScalars)
        let excluded = linkTextRanges(chars)
        var index = 0
        while index + 2 < chars.count {
            guard chars[index] == ":", chars[index + 1] == "/", chars[index + 2] == "/" else { index += 1; continue }
            var start = index
            while start > 0, isSchemeCharacter(chars[start - 1]) { start -= 1 }
            while start < index, !isASCIILetter(chars[start]) { start += 1 }
            guard start < index, !excluded.contains(where: { $0.contains(start) }) else { index += 3; continue }
            var end = index + 3
            while end < chars.count, !isTerminator(chars[end]) { end += 1 }
            var raw = String(String.UnicodeScalarView(chars[start..<end]))
            while let last = raw.unicodeScalars.last, trailing.contains(last) { raw.unicodeScalars.removeLast() }
            if raw.unicodeScalars.count > index - start + 3 { out.append(raw) }
            index = end
        }
    }

    /// The scalar ranges of `[text](target)` link texts: a link found there is never used.
    private static func linkTextRanges(_ chars: [Unicode.Scalar]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var open: [Int] = []
        var index = 0
        while index < chars.count {
            if chars[index] == "[" {
                open.append(index)
            } else if chars[index] == "]", let start = open.popLast(), index + 1 < chars.count, chars[index + 1] == "(" {
                ranges.append(start..<(index + 1))
            }
            index += 1
        }
        return ranges
    }

    private static let trailing = Set(".,;:!?)]}>'\"".unicodeScalars)

    private static func isTerminator(_ c: Unicode.Scalar) -> Bool {
        c.properties.isWhitespace || c == "<" || c == ">" || c == "\"" || c == "`" || c == "|" || c.value < 0x20
            || c.value == 0x7F || c == "\u{00A0}"
    }

    private static func isASCIILetter(_ c: Unicode.Scalar) -> Bool { (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") }

    private static func isSchemeCharacter(_ c: Unicode.Scalar) -> Bool {
        isASCIILetter(c) || (c >= "0" && c <= "9") || c == "+" || c == "-" || c == "."
    }

    // MARK: Shapes

    /// The shape of one raw link (`find`'s output).
    static func classify(_ raw: String, dashboardSites: CodeDashboardSites = .none) -> ResultLink {
        let isHTTP = raw.hasPrefix("http://"), isHTTPS = raw.hasPrefix("https://")
        guard isHTTP || isHTTPS, let parts = URLComponents(string: raw), parts.user == nil, parts.password == nil,
              let authority = rawAuthority(raw), !authority.contains("@"), let split = splitHost(authority),
              parts.percentEncodedHost == split.host, parts.host == split.host else {
            return dashboardShape(raw, sites: dashboardSites) ? .dashboard : .other
        }
        let scheme = isHTTPS ? "https" : "http"
        if let openHost = previewHosts[split.host] {
            guard let portText = split.port, let port = Int(portText), String(port) == portText, previewPorts.contains(port),
                  parts.port == port, let url = URL(string: "\(scheme)://\(openHost):\(port)/") else { return .other }
            return .preview(url: url, label: "\(openHost):\(port)")
        }
        if split.host == artifactHost, isHTTPS, split.port == nil, parts.port == nil,
           let url = artifactURL(path: parts.percentEncodedPath) {
            return .artifact(url)
        }
        if split.port == nil, dashboardSites.site(host: split.host, path: parts.percentEncodedPath) != nil { return .dashboard }
        return .other
    }

    /// A `publishedArtifacts` url or an `Artifact` tool result's url, when it has the artifact shape exactly.
    static func artifactURL(_ raw: String) -> URL? {
        if case .artifact(let url) = classify(raw) { return url }
        return nil
    }

    /// `https://claude.ai/artifact/<id>` (or `/code/artifact/<id>`) for a raw path holding an id of
    /// `^[A-Za-z0-9_-]{8,64}$`, with at most one trailing `/`.
    private static func artifactURL(path: String) -> URL? {
        var rest = Substring(path)
        if rest.hasSuffix("/") { rest = rest.dropLast() }
        let prefix: String
        if rest.hasPrefix("/artifact/") { prefix = "/artifact/" } else if rest.hasPrefix("/code/artifact/") { prefix = "/code/artifact/" } else {
            return nil
        }
        let id = rest.dropFirst(prefix.count)
        guard (8...64).contains(id.utf8.count), id.utf8.allSatisfy({ CodeIDs.isAlphanumeric($0) || $0 == 0x5F || $0 == 0x2D }) else {
            return nil
        }
        return URL(string: "https://\(artifactHost)\(prefix)\(id)")
    }

    /// The raw text between `://` and the first `/`, `?` or `#`.
    private static func rawAuthority(_ raw: String) -> String? {
        guard let range = raw.range(of: "://") else { return nil }
        let rest = raw[range.upperBound...]
        let end = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? rest.endIndex
        let authority = String(rest[..<end])
        return authority.isEmpty ? nil : authority
    }

    /// The raw host (`[::1]` with its brackets) and the raw port text of an authority.
    private static func splitHost(_ authority: String) -> (host: String, port: String?)? {
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return nil }
            let host = String(authority[...close])
            let rest = authority[authority.index(after: close)...]
            if rest.isEmpty { return (host, nil) }
            guard rest.hasPrefix(":") else { return nil }
            return (host, String(rest.dropFirst()))
        }
        let pieces = authority.split(separator: ":", omittingEmptySubsequences: false)
        switch pieces.count {
        case 1: return (authority, nil)
        case 2: return (String(pieces[0]), String(pieces[1]))
        default: return nil
        }
    }

    /// A configured site's `<host><pathPrefix>…` in any scheme or none: never counted as an "other link"
    /// (the dashboards own it).
    private static func dashboardShape(_ raw: String, sites: CodeDashboardSites) -> Bool {
        guard let range = raw.range(of: "://") else { return false }
        let rest = raw[range.upperBound...]
        return sites.all.contains { rest.hasPrefix($0.key) }
    }
}
