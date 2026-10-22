import Darwin
import Foundation
import PitboxKit

/// The settings: `settings.json` in the app-support folder (`Paths.settingsFile`). The keys of the old
/// `code-settings.json` keep their names and meanings (so a copy of that file is a valid settings file); Pitbox's own
/// keys are added (`CodeSettings+Keys.swift`). Read tolerantly: unknown keys are ignored and a wrong value falls back
/// to its default without discarding the rest. The file is read carefully (no link followed, a regular file of the
/// user's, at most 256 KB, nesting 16, a duplicated key fails it). The app writes the defaults once when the file is
/// missing, and otherwise only through `apply(_:at:)` (the menu and the settings window), which changes that key and
/// keeps every other one, unknown ones included; file-only keys (`fileOnlyKeys`) can never be written by the app. Hand
/// edits apply at once (`CodeSettingsWatcher`).
public struct CodeSettings: Equatable, Sendable {
    /// The shell offers run in.
    public enum CommandShell: String, Sendable { case clean, login }
    /// Monitors, or slim rows.
    public enum Look: String, Sendable { case monitors, rows }
    /// Desk windows get desk tags and Ready items only, or a monitor too.
    public enum DeskWindows: String, Sendable { case tags, monitors }

    /// The warnings that can be switched off per kind.
    public struct Warnings: Equatable, Sendable {
        /// "Looks stuck" (failures in a row, silence) and "Same file".
        public var stuck = true
        public var sameFile = true
        /// Both on by default.
        public init(stuck: Bool = true, sameFile: Bool = true) { self.stuck = stuck; self.sameFile = sameFile }
    }

    // MARK: Commands, servers and privacy (file only)

    /// The shell offers run in: `clean` (default) or `login`.
    public var commandShell: CommandShell = .clean
    /// Absolute folders added to the clean shell's PATH. Use `usableExtraPath(...)`, which drops unsafe entries.
    public var extraPath: [String] = []
    /// Other names of a server, per SSH alias (never filled from a reply).
    public var serverNames: [String: [String]] = [:]
    /// Per copy letter: false hides that copy's monitor text for good; a letter not listed shows its text.
    public var showText: [String: Bool] = [:]

    // MARK: Look, desk windows, Ready and alerts

    /// Monitors or slim rows; desk windows as desk tags or monitors too.
    public var look: Look = .monitors
    public var deskWindows: DeskWindows = .tags
    /// The hover peek's delay: 0 (off) or 0.3-3 s.
    public var peekDelaySeconds: Double = 1.2
    /// Desk tags beside desk windows (the file's key is `deskTags`, older files say `jTags`), drag-to-park, the chime
    /// and Say it when work finishes.
    public var deskTags = true
    public var dragToPark = true
    public var chime = false
    public var sayIt = false
    /// File only: Say it speaks headlines, which are session text (docs/THREAT_MODEL.md).
    public var sayHeadlines = false
    /// "While you were away".
    public var awayRecap = true
    /// Minutes without input before "away" (5-120).
    public var recapAfterMinutes = CodeTuning.recapAfterMinutes
    /// Work shorter than this many minutes gets no Finished item (0-60).
    public var finishedMinMinutes = 3
    /// Recent main-window sessions are followed for this many hours (0-48; 0: pop-outs only).
    public var readyRecentHours: Double = CodeTuning.readyRecentHours
    /// Which warnings show.
    public var warnings = Warnings()
    /// File only: the IANA zone zone-less ETAs of an SSH alias's sessions are read in; an alias not listed means UTC.
    public var serverTimeZones: [String: String] = [:]

    // MARK: Pitbox's own keys (CodeSettings+Keys.swift)

    /// The block's width in columns: 2 or 1.
    public var columns = 2
    /// Folded to the 24 pt rail.
    public var folded = false
    /// The screen edge when alone (docked, the host's edge wins).
    public var edge: Edge = .right
    /// "main", or the UUID of the display to use when alone.
    public var display = "main"
    /// A column's width when alone, 300-360 pt.
    public var cellWidth: Double = 323
    /// The dock link: on, and the host apps that may dock (`hosts` is file-only).
    public var dock = Dock()
    /// File only: extra Claude copies besides the default one (`CodeProfiles`).
    public var profiles: [Profile] = []
    /// Focus names (as a dock host sends them) and the profile letters each shows (`MonitorFocus`).
    public var focusProfiles: [String: [String]] = [:]
    /// File only: the dashboard sites; empty turns the dashboard feature off (`CodeDashboardSites`).
    public var dashboards: [Dashboard] = []
    /// Words the spoken line never says (a headline holding one is replaced by the generic phrase).
    public var neverSay: [String] = []
    /// File only: Copy and Type only (`copyOnly`, new installs) or Run after review (`run`).
    public var commands: Commands = .copyOnly
    /// File only: more folders the command sandbox denies, and folders whose sockets it lets commands connect to.
    public var sandboxDenyFolders: [String] = []
    public var sandboxAllowSocketFolders: [String] = []
    /// The command console's font size and theme.
    public var console = Console()
    /// The global keys: pit the front window, fold the block.
    public var hotkeys = Hotkeys()
    /// Points kept free above and below the block when alone (0-600; the menu's Top Gap and Bottom Gap).
    public var topGap: Double = 0
    public var bottomGap: Double = 0
    /// Alone: above normal windows (the default) or behind them (the menu's Keep Above Windows).
    public var keepAboveWindows = true
    /// Start at login (the menu's Launch at Login; the app reconciles the system's login item with it).
    public var launchAtLogin = false

    /// Every key at its default.
    public init() {}

    /// The settings file's location (`Paths.settingsFile`).
    public static var fileURL: URL { Paths.settingsFile }

    /// The zone zone-less ETAs of `alias`'s sessions are read in: its `serverTimeZones` entry, else UTC.
    public func serverTimeZone(for alias: String) -> TimeZone {
        serverTimeZones[alias].flatMap(TimeZone.init(identifier:)) ?? TimeZone(identifier: "UTC") ?? .gmt
    }

    // MARK: Reading

    /// The settings as the file says now, read with the careful rules; nil when the file is missing or fails the read
    /// (the caller keeps what it has). Never writes (unlike `loadOrCreate`).
    public static func read(at url: URL = fileURL, owner: uid_t = getuid()) -> CodeSettings? {
        guard case .success(let object) = CodeStateFiles.readObject(at: url, owner: owner,
                                                                     maxBytes: CodeTuning.settingsReadMax) else { return nil }
        return decode(object: object)
    }

    /// Parses `data` (strict JSON, nesting at most 16); anything unreadable gives the defaults. Never throws.
    public static func decode(_ data: Data) -> CodeSettings {
        guard case .success(let object) = CodeStateFiles.parseObject(data) else { return CodeSettings() }
        return decode(object: object)
    }

    /// The settings in a parsed file: every key on its own, a wrong value giving that key's default.
    static func decode(object o: [String: JSONValue]) -> CodeSettings {
        var s = CodeSettings()
        if let raw = o["commandShell"]?.stringValue, let shell = CommandShell(rawValue: raw) { s.commandShell = shell }
        if let list = o["extraPath"]?.arrayValue { s.extraPath = list.compactMap(\.stringValue) }
        if let names = o["serverNames"]?.objectValue {
            var out: [String: [String]] = [:]
            for (alias, value) in names { out[alias] = value.arrayValue?.compactMap(\.stringValue) ?? [] }
            s.serverNames = out
        }
        if let show = o["showText"]?.objectValue {
            for (letter, value) in show { if let flag = value.boolValue { s.showText[letter] = flag } }
        }
        if let raw = o["look"]?.stringValue, let look = Look(rawValue: raw) { s.look = look }
        if let raw = o["deskWindows"]?.stringValue, let desk = DeskWindows(rawValue: raw) { s.deskWindows = desk }
        if let delay = o["peekDelaySeconds"]?.doubleValue, Self.isValidPeekDelay(delay) { s.peekDelaySeconds = delay }
        if let flag = (o["deskTags"] ?? o["jTags"])?.boolValue { s.deskTags = flag }   // `jTags`: files from before the rename
        if let flag = o["dragToPark"]?.boolValue { s.dragToPark = flag }
        if let flag = o["chime"]?.boolValue { s.chime = flag }
        if let flag = o["sayIt"]?.boolValue { s.sayIt = flag }
        if let flag = o["sayHeadlines"]?.boolValue { s.sayHeadlines = flag }
        if let flag = o["awayRecap"]?.boolValue { s.awayRecap = flag }
        if let minutes = o["recapAfterMinutes"]?.intValue, Self.recapMinutesRange.contains(minutes) {
            s.recapAfterMinutes = minutes
        }
        if let minutes = o["finishedMinMinutes"]?.intValue, (0...60).contains(minutes) { s.finishedMinMinutes = minutes }
        if let hours = o["readyRecentHours"]?.doubleValue, Self.isValidRecentHours(hours) { s.readyRecentHours = hours }
        if let kinds = o["warnings"]?.objectValue {
            if let flag = kinds["stuck"]?.boolValue { s.warnings.stuck = flag }
            if let flag = kinds["sameFile"]?.boolValue { s.warnings.sameFile = flag }
        }
        if let zones = o["serverTimeZones"]?.objectValue {
            var out: [String: String] = [:]
            for (alias, value) in zones {
                guard SSHConfigReader.isValidAlias(alias), let name = value.stringValue, TimeZone(identifier: name) != nil
                else { continue }
                out[alias] = name
            }
            s.serverTimeZones = out
        }
        decodePitboxKeys(o, into: &s)
        return s
    }

    static let recapMinutesRange = 5...120

    static func isValidPeekDelay(_ seconds: Double) -> Bool { seconds == 0 || (0.3...3).contains(seconds) }

    static func isValidRecentHours(_ hours: Double) -> Bool { hours.isFinite && (0...48).contains(hours) }

    /// The file's content when the app writes it for the first time: every key with its default, pretty-printed with
    /// sorted keys.
    public func encodedDefaults() -> Data {
        CodeStateFiles.serialize(jsonObject(), pretty: true) ?? Data()
    }

    /// These settings as a JSON object (every key).
    func jsonObject() -> [String: JSONValue] {
        let old: [String: JSONValue] = [
            "commandShell": .string(commandShell.rawValue), "extraPath": .array(extraPath.map(JSONValue.string)),
            "serverNames": .object(serverNames.mapValues { .array($0.map(JSONValue.string)) }),
            "showText": .object(showText.mapValues(JSONValue.bool)),
            "look": .string(look.rawValue), "deskWindows": .string(deskWindows.rawValue),
            "peekDelaySeconds": .number(peekDelaySeconds), "deskTags": .bool(deskTags), "dragToPark": .bool(dragToPark),
            "chime": .bool(chime), "sayIt": .bool(sayIt), "sayHeadlines": .bool(sayHeadlines),
            "awayRecap": .bool(awayRecap), "recapAfterMinutes": .number(Double(recapAfterMinutes)),
            "finishedMinMinutes": .number(Double(finishedMinMinutes)), "readyRecentHours": .number(readyRecentHours),
            "warnings": .object(["stuck": .bool(warnings.stuck), "sameFile": .bool(warnings.sameFile)]),
            "serverTimeZones": .object(serverTimeZones.mapValues(JSONValue.string)),
        ]
        return old.merging(pitboxKeysJSON()) { current, _ in current }
    }

    /// Reads the file carefully, writing the defaults first (0600, an exclusive create that never replaces anything)
    /// when nothing is there. A file that fails the careful read gives the defaults and is left as it is.
    public static func loadOrCreate(at url: URL = fileURL) -> CodeSettings {
        switch CodeStateFiles.readObject(at: url, owner: getuid(), maxBytes: CodeTuning.settingsReadMax) {
        case .success(let object):
            return decode(object: object)
        case .failure(.missing):
            if CodeStateFiles.createExclusively(CodeSettings().encodedDefaults(), at: url) {
                Log.info("settings: wrote defaults", "code")
            }
            return CodeSettings()
        case .failure(let failure):
            Log.warn("settings: unreadable (\(failure.label)), using defaults", "code")
            return CodeSettings()
        }
    }

    // MARK: Writing (the menu and the settings window only)

    /// A change the menu or the settings window makes. File-only keys (`fileOnlyKeys`, and `dock.hosts`) have no case:
    /// the app can never write them.
    public enum MenuChange: Sendable, Equatable {
        /// Look ▸ Monitors · Slim rows.
        case look(Look)
        /// Desk windows ▸ Desk tags · Monitors too.
        case deskWindows(DeskWindows)
        /// Hover peek ▸ 0.4 s · 1.2 s · Off (0).
        case peekDelaySeconds(Double)
        /// Ready for you ▸ Pop-outs only (0) · Also sessions you used in the last 6 hours (6).
        case readyRecentHours(Double)
        /// Chime when done.
        case chime(Bool)
        /// Say it.
        case sayIt(Bool)
        /// While you were away ▸ Off (nil) · after 15 / 30 / 60 min (also turns the recap on).
        case awayRecap(afterMinutes: Int?)
        /// Drag windows into the block to pit them.
        case dragToPark(Bool)
        /// Desk tags beside desk windows (the file's `deskTags`).
        case deskTags(Bool)
        /// Columns ▸ 2 · 1.
        case columns(Int)
        /// Fold (−) and unfold (+), remembered across launches.
        case folded(Bool)
        /// Edge ▸ Right · Left (alone).
        case edge(Edge)
        /// Display ▸ Main display, or a display's UUID.
        case display(String)
        /// The column width when alone (300-360 pt).
        case cellWidth(Double)
        /// Dock with a host app: on or off (`dock.enabled`; `dock.hosts` stays as the file has it).
        case dockEnabled(Bool)
        /// The console's font size (8-32 pt).
        case consoleFontSize(Double)
        /// The console's theme.
        case consoleTheme(Console.Theme)
        /// The hotkey that pits the front window ("ctrl+opt+p").
        case parkHotkey(String)
        /// The hotkey that folds the block ("ctrl+opt+c").
        case foldHotkey(String)
        /// Warnings ▸ Looks stuck (`warnings.stuck`; `warnings.sameFile` stays as the file has it).
        case warningsStuck(Bool)
        /// Warnings ▸ Same file (`warnings.sameFile`).
        case warningsSameFile(Bool)
        /// Top Gap ▸ points (0-600, whole points).
        case topGap(Double)
        /// Bottom Gap ▸ points (0-600, whole points).
        case bottomGap(Double)
        /// Keep Above Windows.
        case keepAboveWindows(Bool)
        /// Launch at Login.
        case launchAtLogin(Bool)

        /// The top-level keys written and their values, given the file's `object` now (nested keys keep their other
        /// members); nil when a value is out of its range.
        func members(in object: [String: JSONValue]) -> [String: JSONValue]? {
            func nested(_ key: String, _ member: String, _ value: JSONValue) -> [String: JSONValue] {
                var inner = object[key]?.objectValue ?? CodeSettings().jsonObject()[key]?.objectValue ?? [:]
                inner[member] = value
                return [key: .object(inner)]
            }
            switch self {
            case .look(let look): return ["look": .string(look.rawValue)]
            case .deskWindows(let desk): return ["deskWindows": .string(desk.rawValue)]
            case .peekDelaySeconds(let delay):
                return CodeSettings.isValidPeekDelay(delay) ? ["peekDelaySeconds": .number(delay)] : nil
            case .readyRecentHours(let hours):
                return CodeSettings.isValidRecentHours(hours) ? ["readyRecentHours": .number(hours)] : nil
            case .chime(let flag): return ["chime": .bool(flag)]
            case .sayIt(let flag): return ["sayIt": .bool(flag)]
            case .awayRecap(let minutes):
                guard let minutes else { return ["awayRecap": .bool(false)] }
                guard CodeSettings.recapMinutesRange.contains(minutes) else { return nil }
                return ["awayRecap": .bool(true), "recapAfterMinutes": .number(Double(minutes))]
            case .dragToPark(let flag): return ["dragToPark": .bool(flag)]
            case .deskTags(let flag): return ["deskTags": .bool(flag)]
            case .columns(let columns):
                return CodeSettings.columnsRange.contains(columns) ? ["columns": .number(Double(columns))] : nil
            case .folded(let flag): return ["folded": .bool(flag)]
            case .edge(let edge): return ["edge": .string(edge.rawValue)]
            case .display(let display): return CodeSettings.isValidDisplay(display) ? ["display": .string(display)] : nil
            case .cellWidth(let width):
                return CodeSettings.cellWidthRange.contains(width) ? ["cellWidth": .number(width)] : nil
            case .dockEnabled(let flag): return nested("dock", "enabled", .bool(flag))
            case .consoleFontSize(let size):
                return CodeSettings.consoleFontRange.contains(size) ? nested("console", "fontSize", .number(size)) : nil
            case .consoleTheme(let theme): return nested("console", "theme", .string(theme.rawValue))
            case .parkHotkey(let key): return CodeSettings.isValidHotkey(key) ? nested("hotkeys", "park", .string(key)) : nil
            case .foldHotkey(let key): return CodeSettings.isValidHotkey(key) ? nested("hotkeys", "fold", .string(key)) : nil
            case .warningsStuck(let flag): return nested("warnings", "stuck", .bool(flag))
            case .warningsSameFile(let flag): return nested("warnings", "sameFile", .bool(flag))
            case .topGap(let points): return CodeSettings.isValidGap(points) ? ["topGap": .number(points.rounded())] : nil
            case .bottomGap(let points):
                return CodeSettings.isValidGap(points) ? ["bottomGap": .number(points.rounded())] : nil
            case .keepAboveWindows(let flag): return ["keepAboveWindows": .bool(flag)]
            case .launchAtLogin(let flag): return ["launchAtLogin": .bool(flag)]
            }
        }
    }

    /// Why a menu change was not written.
    public enum WriteFailure: Error, Sendable, Equatable {
        /// The file failed the careful read or is not a JSON object (the label says why; safe to log): nothing written.
        case unreadable(String)
        /// The value is outside its range.
        case invalidValue
        /// The result would be larger than the reader accepts.
        case tooLarge
        case writeFailed

        /// The menu's words.
        public var message: String {
            switch self {
            case .unreadable: return "Can't change: the settings file couldn't be read"
            case .invalidValue, .tooLarge, .writeFailed: return "Can't change the settings file"
            }
        }
    }

    /// Changes one menu key: the file is read carefully, the key changed, and the whole object written back atomically
    /// (0600), every other key kept as it was, unknown ones included. A file that fails the read is never written; a
    /// missing file is created from the defaults with the change. Returns the settings as now in the file. Runs on the
    /// caller's thread (a small file).
    public static func apply(_ change: MenuChange, at url: URL = fileURL) -> Result<CodeSettings, WriteFailure> {
        var object: [String: JSONValue]
        switch CodeStateFiles.readObject(at: url, owner: getuid(), maxBytes: CodeTuning.settingsReadMax) {
        case .success(let read): object = read
        case .failure(.missing): object = CodeSettings().jsonObject()
        case .failure(let failure):
            return change.members(in: [:]) == nil ? .failure(.invalidValue) : .failure(.unreadable(failure.label))
        }
        guard let members = change.members(in: object) else { return .failure(.invalidValue) }
        for (key, value) in members { object[key] = value }
        guard let data = CodeStateFiles.serialize(object, pretty: true) else { return .failure(.writeFailed) }
        guard data.count <= CodeTuning.settingsReadMax else { return .failure(.tooLarge) }
        do {
            try CodeStateFiles.writeAtomically(data, to: url)
        } catch {
            Log.warn("settings: write failed (\((error as? CodeStateFiles.WriteFailure)?.label ?? "error"))", "code")
            return .failure(.writeFailed)
        }
        Log.info("settings: changed keys=\(members.keys.sorted().joined(separator: ","))", "code")
        return .success(decode(object: object))
    }

    // MARK: Helpers

    /// The `extraPath` entries that are safe to add: absolute, existing folders that are not group- or
    /// world-writable. `isSafeFolder` is injectable for tests.
    public func usableExtraPath(isSafeFolder: (String) -> Bool = CodeSettings.isSafeFolder) -> [String] {
        extraPath.filter { $0.hasPrefix("/") && !$0.contains(":") && isSafeFolder($0) }
    }

    /// An existing folder (not a link) without group or world write permission.
    public static func isSafeFolder(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return false }
        return (st.st_mode & (S_IWGRP | S_IWOTH)) == 0
    }
}
