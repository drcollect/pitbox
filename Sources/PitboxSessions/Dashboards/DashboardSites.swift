import Foundation

/// One dashboard site from the settings file's `dashboards`: links
/// `https://<host><pathPrefix><handle>/` in a session's own writing give it a ▦ Dashboard button. The host is an exact
/// allowlist entry (lowercase, no port, no user info, no other label before it); the handle keeps the link grammar and,
/// with `handlePattern`, must also match that expression in full. The address that opens is always rebuilt from the
/// checked parts (`url(handle:)`), never taken from the text.
public struct CodeDashboardSite: Sendable, Hashable {
    /// The exact host ("dash.example.com").
    public let host: String
    /// Starts and ends with "/" ("/dash/").
    public let pathPrefix: String
    /// The extra expression a handle must match in full, as the settings file gives it.
    public let handlePattern: String?
    private let matcher: HandleMatcher?

    /// Nil when the host, the prefix or the pattern fails its check.
    public init?(host: String, pathPrefix: String = "/", handlePattern: String? = nil) {
        guard Self.isValidHost(host), Self.isValidPathPrefix(pathPrefix) else { return nil }
        var matcher: HandleMatcher?
        if let handlePattern {
            guard let compiled = Self.compile(handlePattern) else { return nil }
            matcher = compiled
        }
        self.host = host
        self.pathPrefix = pathPrefix
        self.handlePattern = handlePattern
        self.matcher = matcher
    }

    /// The site a settings entry names (already checked by `CodeSettings`).
    public init?(_ setting: CodeSettings.Dashboard) {
        self.init(host: setting.host, pathPrefix: setting.pathPrefix, handlePattern: setting.handlePattern)
    }

    /// "dash.example.com/dash/": what every link of the site holds, and how a stored dashboard names its site.
    public var key: String { host + pathPrefix }

    /// The key's bytes (the scans search for them).
    var marker: [UInt8] { Array(key.utf8) }

    /// The link grammar (`CodeDashboard.isValidHandle`) and the site's own pattern.
    public func isValidHandle(_ handle: String) -> Bool {
        CodeDashboard.isValidHandle(handle) && (matcher?.matchesWhole(handle) ?? true)
    }

    /// `https://<host><pathPrefix><handle>/`, built from the checked parts; nil for a handle that fails.
    public func url(handle: String) -> URL? {
        guard isValidHandle(handle) else { return nil }
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = host
        parts.path = pathPrefix + handle + "/"
        return parts.url
    }

    public static func == (a: CodeDashboardSite, b: CodeDashboardSite) -> Bool {
        a.host == b.host && a.pathPrefix == b.pathPrefix && a.handlePattern == b.handlePattern
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(host)
        hasher.combine(pathPrefix)
        hasher.combine(handlePattern)
    }

    // MARK: Checks

    /// Lowercase labels of letters, digits and "-" (not at a label's ends), at least two, at most 120 characters (so
    /// a site's key fits a memory record's string limit).
    static func isValidHost(_ host: String) -> Bool {
        guard (3...120).contains(host.utf8.count) else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        return labels.allSatisfy { label in
            guard (1...63).contains(label.utf8.count), label.utf8.first != 0x2D, label.utf8.last != 0x2D else { return false }
            return label.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D }
        }
    }

    /// "/" or "/a/b/": segments of lowercase letters, digits, ".", "_" and "-" (never "." or ".."), at most 64 characters.
    static func isValidPathPrefix(_ prefix: String) -> Bool {
        guard (1...64).contains(prefix.utf8.count), prefix.hasPrefix("/"), prefix.hasSuffix("/") else { return false }
        guard prefix != "/" else { return true }
        let segments = prefix.dropFirst().dropLast().split(separator: "/", omittingEmptySubsequences: false)
        return segments.allSatisfy { segment in
            guard !segment.isEmpty, segment != ".", segment != ".." else { return false }
            return segment.utf8.allSatisfy {
                ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2E || $0 == 0x5F || $0 == 0x2D
            }
        }
    }

    /// The pattern compiled, anchored to the whole handle; nil when it does not compile or is longer than 200 characters.
    static func compile(_ pattern: String) -> HandleMatcher? {
        guard (1...200).contains(pattern.count),
              let expression = try? NSRegularExpression(pattern: "^(?:" + pattern + ")$") else { return nil }
        return HandleMatcher(expression: expression)
    }

    /// A compiled handle pattern (`NSRegularExpression` is immutable and safe to use from any thread).
    final class HandleMatcher: @unchecked Sendable {
        let expression: NSRegularExpression
        init(expression: NSRegularExpression) { self.expression = expression }

        func matchesWhole(_ text: String) -> Bool {
            let range = NSRange(text.startIndex..., in: text)
            return expression.firstMatch(in: text, options: [.anchored], range: range)?.range == range
        }
    }
}

/// The dashboard sites the app knows, built once at start from the settings file's `dashboards`.
/// Empty (the default) turns the dashboard feature off: no link is looked for, no transcript is scanned, no ▦ button
/// shows. The derivers, the result links and the opener all take the same value.
public struct CodeDashboardSites: Sendable, Equatable {
    /// The sites in the file's order.
    public let all: [CodeDashboardSite]

    /// No site: the feature is off.
    public static let none = CodeDashboardSites([])

    public init(_ sites: [CodeDashboardSite]) {
        var seen = Set<String>()
        all = sites.filter { seen.insert($0.key).inserted }
    }

    /// The sites `settings` lists.
    public init(_ settings: CodeSettings) {
        self.init(settings.dashboards.compactMap(CodeDashboardSite.init))
    }

    public var isEmpty: Bool { all.isEmpty }

    /// The site a stored dashboard names by its key; a record from before sites were named (no key) belongs to the
    /// site only while exactly one is configured (with several, which one it came from is unknown). Nil when the site
    /// is not (or no longer) in the list: that dashboard is not shown.
    public func site(key: String?) -> CodeDashboardSite? {
        guard let key else { return all.count == 1 ? all.first : nil }
        return all.first { $0.key == key }
    }

    /// The site a parsed link belongs to: its host exactly, and a path starting with the site's prefix.
    func site(host: String, path: String) -> CodeDashboardSite? {
        all.first { $0.host == host && path.hasPrefix($0.pathPrefix) }
    }
}
