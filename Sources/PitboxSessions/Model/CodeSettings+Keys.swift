import Foundation
import PitboxKit

// The settings file's keys that are new in Pitbox, their value types, defaults and checks. Each key is read on its own:
// a wrong value gives that key's default (a list or a map keeps its valid entries) and never costs the others. The keys
// that change what runs or what is read are file-only (`CodeSettings.fileOnlyKeys`): the app never writes them.

extension CodeSettings {
    /// `commands`: what a command offer's sheet allows.
    public enum Commands: String, Sendable {
        /// Copy and Type into the console; no Run. New installs start here.
        case copyOnly
        /// Run after review, as the run sheet always did.
        case run
    }

    /// One extra Claude desktop copy (`profiles`), besides the default `~/Library/Application Support/Claude`.
    public struct Profile: Equatable, Sendable {
        /// The folder name directly under `~/Library/Application Support` (one path component, not `Claude`).
        public var folder: String
        /// One capital letter B-Z, unique (A is the default copy's).
        public var letter: String
        /// The name on the profile mark ("B · <name>"); the folder when the file gives none.
        public var name: String
        /// The mark's colour `0xRRGGBB` (the file says "#RRGGBB"); nil: the palette's own.
        public var colour: UInt32?

        public init(folder: String, letter: String, name: String, colour: UInt32? = nil) {
            self.folder = folder; self.letter = letter; self.name = name; self.colour = colour
        }
    }

    /// One dashboard site (`dashboards`): links `https://<host><pathPrefix><handle>/` in a session's own replies get a
    /// ▦ button. The host is an exact allowlist entry; the handle keeps the dashboard grammar
    /// (`^[a-z0-9]+(?:-[a-z0-9]+)*$`, 1-64 characters) and, when given, must also match `handlePattern` in full.
    public struct Dashboard: Equatable, Sendable {
        /// Lowercase host name, at least two labels, no port.
        public var host: String
        /// Starts and ends with "/" ("/dash/"); "/" for handles right after the host.
        public var pathPrefix: String
        /// An extra regular expression the whole handle must match (nil: the grammar alone).
        public var handlePattern: String?

        public init(host: String, pathPrefix: String = "/", handlePattern: String? = nil) {
            self.host = host; self.pathPrefix = pathPrefix; self.handlePattern = handlePattern
        }
    }

    /// `dock`: whether the dock link is on, and which host apps may dock (bundle ids; file-only).
    public struct Dock: Equatable, Sendable {
        public var enabled = true
        public var hosts: [String] = []
        public init(enabled: Bool = true, hosts: [String] = []) { self.enabled = enabled; self.hosts = hosts }
    }

    /// `console`: how the command console looks.
    public struct Console: Equatable, Sendable {
        public enum Theme: String, Sendable { case system, light, dark }
        /// Points, 8-32.
        public var fontSize: Double = 12
        public var theme: Theme = .system
        public init(fontSize: Double = 12, theme: Theme = .system) { self.fontSize = fontSize; self.theme = theme }
    }

    /// `hotkeys`: the two global keys as the shell parses them ("ctrl+opt+p"); the shell checks each one.
    public struct Hotkeys: Equatable, Sendable {
        public var park = "ctrl+opt+p"
        public var fold = "ctrl+opt+c"
        public init(park: String = "ctrl+opt+p", fold: String = "ctrl+opt+c") { self.park = park; self.fold = fold }
    }

    /// The keys the app never writes: they change what runs or what is read.
    /// `dock.hosts` is file-only inside the otherwise harmless `dock`.
    public static let fileOnlyKeys: Set<String> = [
        "commands", "commandShell", "extraPath", "sandboxDenyFolders", "sandboxAllowSocketFolders", "serverNames",
        "serverTimeZones", "showText", "sayHeadlines", "profiles", "dashboards",
    ]

    // MARK: Limits

    static let columnsRange = 1...2
    /// A top or bottom gap, in points.
    public static let gapRange: ClosedRange<Double> = 0...600
    static let cellWidthRange: ClosedRange<Double> = 300...360
    static let consoleFontRange: ClosedRange<Double> = 8...32   // the console's own TerminalSettings.fontSizeRange
    static let maxProfiles = 25
    static let maxDashboards = 8
    static let maxNeverSay = 32
    static let maxFolders = 64
    static let maxFocusNames = 32

    // MARK: Reading the new keys

    /// Reads the Pitbox keys of `o` into `s`, each on its own.
    static func decodePitboxKeys(_ o: [String: JSONValue], into s: inout CodeSettings) {
        if let columns = o["columns"]?.intValue, columnsRange.contains(columns) { s.columns = columns }
        if let flag = o["folded"]?.boolValue { s.folded = flag }
        if let raw = o["edge"]?.stringValue, let edge = Edge(rawValue: raw) { s.edge = edge }
        if let display = o["display"]?.stringValue, isValidDisplay(display) { s.display = display }
        if let width = o["cellWidth"]?.doubleValue, cellWidthRange.contains(width) { s.cellWidth = width }
        if let dock = o["dock"]?.objectValue {
            if let flag = dock["enabled"]?.boolValue { s.dock.enabled = flag }
            if let hosts = dock["hosts"]?.arrayValue { s.dock.hosts = unique(hosts.compactMap(\.stringValue).filter(isValidBundleID)) }
        }
        if let list = o["profiles"]?.arrayValue { s.profiles = profiles(list) }
        if let map = o["focusProfiles"]?.objectValue { s.focusProfiles = focusProfiles(map) }
        if let list = o["dashboards"]?.arrayValue { s.dashboards = dashboards(list) }
        if let list = o["neverSay"]?.arrayValue {
            s.neverSay = Array(unique(list.compactMap(\.stringValue).filter(isValidNeverSay)).prefix(maxNeverSay))
        }
        if let raw = o["commands"]?.stringValue, let commands = Commands(rawValue: raw) { s.commands = commands }
        if let list = o["sandboxDenyFolders"]?.arrayValue { s.sandboxDenyFolders = folders(list) }
        if let list = o["sandboxAllowSocketFolders"]?.arrayValue { s.sandboxAllowSocketFolders = folders(list) }
        if let console = o["console"]?.objectValue {
            if let size = console["fontSize"]?.doubleValue, consoleFontRange.contains(size) { s.console.fontSize = size }
            if let raw = console["theme"]?.stringValue, let theme = Console.Theme(rawValue: raw) { s.console.theme = theme }
        }
        if let keys = o["hotkeys"]?.objectValue {
            if let park = keys["park"]?.stringValue, isValidHotkey(park) { s.hotkeys.park = park }
            if let fold = keys["fold"]?.stringValue, isValidHotkey(fold) { s.hotkeys.fold = fold }
        }
        if let gap = o["topGap"]?.doubleValue, isValidGap(gap) { s.topGap = gap }
        if let gap = o["bottomGap"]?.doubleValue, isValidGap(gap) { s.bottomGap = gap }
        if let flag = o["keepAboveWindows"]?.boolValue { s.keepAboveWindows = flag }
        if let flag = o["launchAtLogin"]?.boolValue { s.launchAtLogin = flag }
    }

    /// The Pitbox keys as JSON (the defaults file and the menu's writes).
    func pitboxKeysJSON() -> [String: JSONValue] {
        [
            "columns": .number(Double(columns)), "folded": .bool(folded), "edge": .string(edge.rawValue),
            "display": .string(display), "cellWidth": .number(cellWidth),
            "dock": .object(["enabled": .bool(dock.enabled), "hosts": .array(dock.hosts.map(JSONValue.string))]),
            "profiles": .array(profiles.map { profile in
                var entry: [String: JSONValue] = ["folder": .string(profile.folder), "letter": .string(profile.letter),
                                                  "name": .string(profile.name)]
                if let colour = profile.colour { entry["colour"] = .string(Self.hexColour(colour)) }
                return .object(entry)
            }),
            "focusProfiles": .object(focusProfiles.mapValues { .array($0.map(JSONValue.string)) }),
            "dashboards": .array(dashboards.map { site in
                var entry: [String: JSONValue] = ["host": .string(site.host), "pathPrefix": .string(site.pathPrefix)]
                if let pattern = site.handlePattern { entry["handlePattern"] = .string(pattern) }
                return .object(entry)
            }),
            "neverSay": .array(neverSay.map(JSONValue.string)), "commands": .string(commands.rawValue),
            "sandboxDenyFolders": .array(sandboxDenyFolders.map(JSONValue.string)),
            "sandboxAllowSocketFolders": .array(sandboxAllowSocketFolders.map(JSONValue.string)),
            "console": .object(["fontSize": .number(console.fontSize), "theme": .string(console.theme.rawValue)]),
            "hotkeys": .object(["park": .string(hotkeys.park), "fold": .string(hotkeys.fold)]),
            "topGap": .number(topGap), "bottomGap": .number(bottomGap), "keepAboveWindows": .bool(keepAboveWindows),
            "launchAtLogin": .bool(launchAtLogin),
        ]
    }

    // MARK: Checks

    /// A usable top or bottom gap: finite, 0-600 points.
    static func isValidGap(_ points: Double) -> Bool { points.isFinite && gapRange.contains(points) }

    /// "main" or a display's UUID (letters, digits and "-", at most 64 characters).
    static func isValidDisplay(_ text: String) -> Bool {
        guard (1...64).contains(text.utf8.count) else { return false }
        return text.utf8.allSatisfy { isAlphanumeric($0) || $0 == 0x2D }
    }

    /// A bundle id: two or more labels of letters, digits and "-", joined by ".", at most 255 characters.
    static func isValidBundleID(_ text: String) -> Bool {
        guard (3...255).contains(text.utf8.count), text.contains("."), !text.hasPrefix("."), !text.hasSuffix("."),
              !text.contains("..") else { return false }
        return text.utf8.allSatisfy { isAlphanumeric($0) || $0 == 0x2D || $0 == 0x2E }
    }

    /// A word the spoken line never says: at least one letter, at most 64 characters, no control character.
    static func isValidNeverSay(_ text: String) -> Bool {
        (1...64).contains(text.count) && text.contains(where: \.isLetter)
            && !text.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    /// A hotkey as the shell spells it: 1-64 printable ASCII characters ("ctrl+opt+p"); the shell parses and checks it.
    static func isValidHotkey(_ text: String) -> Bool {
        (1...64).contains(text.utf8.count) && text.utf8.allSatisfy { $0 > 0x20 && $0 < 0x7F }
    }

    /// The listed copies: each entry checked on its own, later duplicates of a letter or folder dropped.
    static func profiles(_ list: [JSONValue]) -> [Profile] {
        var out: [Profile] = []
        var letters: Set<String> = []
        var folders: Set<String> = [CodeProfile.defaultFolderName.lowercased()]
        for value in list {
            guard out.count < maxProfiles, let entry = value.objectValue,
                  let folder = entry["folder"]?.stringValue, isValidProfileFolder(folder),
                  let letter = entry["letter"]?.stringValue, isValidProfileLetter(letter),
                  !letters.contains(letter), !folders.contains(folder.lowercased()) else { continue }
            let name = entry["name"]?.stringValue.flatMap(profileName) ?? folder
            let colour = entry["colour"]?.stringValue.flatMap(parseColour)
            letters.insert(letter)
            folders.insert(folder.lowercased())
            out.append(Profile(folder: folder, letter: letter, name: name, colour: colour))
        }
        return out
    }

    /// One folder name directly under Application Support: 1-64 characters, no "/" or NUL, no leading ".", no control
    /// character.
    static func isValidProfileFolder(_ name: String) -> Bool {
        guard (1...64).contains(name.count), !name.hasPrefix("."), !name.contains("/"), !name.contains("\u{0}") else {
            return false
        }
        return !name.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    /// One capital letter B-Z.
    static func isValidProfileLetter(_ letter: String) -> Bool {
        guard letter.utf8.count == 1, let byte = letter.utf8.first else { return false }
        return byte >= 0x42 && byte <= 0x5A
    }

    /// A profile's display name: plain text on one line without control characters, at most 32 characters; nil when
    /// nothing is left.
    static func profileName(_ raw: String) -> String? {
        let visible = String(String.UnicodeScalarView(raw.unicodeScalars.filter { $0.properties.generalCategory != .control }))
        return CodePlainText.line(visible, limit: 32)
    }

    /// "#RRGGBB" (or without "#") as `0xRRGGBB`.
    static func parseColour(_ text: String) -> UInt32? {
        let hex = text.hasPrefix("#") ? String(text.dropFirst()) : text
        guard hex.utf8.count == 6, hex.utf8.allSatisfy(isHexDigit) else { return nil }
        return UInt32(hex, radix: 16)
    }

    static func hexColour(_ value: UInt32) -> String {
        let digits = String(value & 0xFFFFFF, radix: 16, uppercase: true)
        return "#" + String(repeating: "0", count: max(0, 6 - digits.count)) + digits
    }

    /// Focus names (1-32 characters, trimmed) and their profile letters (A-Z).
    static func focusProfiles(_ map: [String: JSONValue]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for name in map.keys.sorted() {
            let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard out.count < maxFocusNames, (1...32).contains(key.count), key.lowercased() != "all",
                  let letters = map[name]?.arrayValue else { continue }
            out[key] = unique(letters.compactMap(\.stringValue).filter { $0 == "A" || isValidProfileLetter($0) })
        }
        return out
    }

    /// The dashboard sites: each entry checked on its own, at most `maxDashboards`, later duplicates dropped.
    static func dashboards(_ list: [JSONValue]) -> [Dashboard] {
        var out: [Dashboard] = []
        for value in list {
            guard out.count < maxDashboards, let entry = value.objectValue, let host = entry["host"]?.stringValue,
                  CodeDashboardSite.isValidHost(host) else { continue }
            let prefix = entry["pathPrefix"]?.stringValue ?? "/"
            guard CodeDashboardSite.isValidPathPrefix(prefix) else { continue }
            let pattern = entry["handlePattern"]?.stringValue
            if let pattern, CodeDashboardSite.compile(pattern) == nil { continue }
            let site = Dashboard(host: host, pathPrefix: prefix, handlePattern: pattern)
            if !out.contains(where: { $0.host == site.host && $0.pathPrefix == site.pathPrefix }) { out.append(site) }
        }
        return out
    }

    /// Absolute folders (or "~/…"), at most 1024 bytes each, no NUL; at most `maxFolders`.
    static func folders(_ list: [JSONValue]) -> [String] {
        let valid = list.compactMap(\.stringValue).filter { path in
            (path.hasPrefix("/") || path.hasPrefix("~/")) && path.utf8.count <= 1024 && !path.contains("\u{0}")
        }
        return Array(unique(valid).prefix(maxFolders))
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func isAlphanumeric(_ c: UInt8) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
    }

    private static func isHexDigit(_ c: UInt8) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66)
    }
}
