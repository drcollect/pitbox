import Foundation
import PitboxKit

/// Why a session file or `session-popouts.json` could not be used. `label` is safe to log.
enum ClaudeFileFailure: Error, Equatable, Sendable {
    case read(CarefulReadFailure)
    case json(StrictJSONFailure)
    /// The document is not a JSON object.
    case notObject

    var label: String {
        switch self {
        case .read(let failure): return failure.label
        case .json(let failure): return failure.label
        case .notObject: return "not-object"
        }
    }

    /// Whether the file exists but its content failed the checks (a possible format change), as opposed to a
    /// file that is missing or could not be opened.
    var isContentFailure: Bool {
        switch self {
        case .read(let failure): return failure == .tooLarge
        case .json, .notObject: return true
        }
    }
}

/// What the app reads from one `local_<id>.json` session file, leniently: unknown keys are ignored and a
/// missing or mistyped key means "unknown". Every string here is model- or user-written text: shown only through the
/// block's plain-text renderer, never parsed for commands or links, never logged.
struct ClaudeSessionFile: Equatable, Sendable {
    /// `postTurnSummary`.
    struct Summary: Equatable, Sendable {
        var category: String?
        var detail: String?
        var needsAction: String?
        var summarizesUUID: String?
    }

    var title: String?
    var titleSource: String?
    var previousTitles: [String] = []
    var cwd: String?
    /// `cliSessionId` when it matches `^[0-9A-Fa-f-]{36}$`; nil otherwise (see `cliSessionIDRejected`).
    var cliSessionID: String?
    /// The file has a `cliSessionId` that failed the check: no transcript path is built from it.
    var cliSessionIDRejected = false
    var model: String?
    var effort: String?
    var permissionMode: String?
    var isArchived = false
    var lastActivityAt: Date?
    var lastFocusedAt: Date?
    /// When the user last sent the session a message (with `lastFocusedAt`, the user's own activity).
    var latestUserFrameAt: Date?
    /// `publishedArtifacts[].url` and `updatedAt`, newest first, at most `maxArtifacts` (`title` is never read).
    var publishedArtifacts: [CodeTurnDigest.PublishedArtifact] = []
    var completedTurns: Int?
    /// `sshConfig` is an object: the session runs over SSH.
    var hasSSHConfig = false
    /// `sshConfig.sshHost` as written (unchecked; see `SSHAlias`).
    var sshHost: String?
    /// `sshReattach.midTurn == true`.
    var midTurn = false
    var summary: Summary?
    var summaryFor: String?
    var lastAssistantUUID: String?
    /// `turnWrapUp.needsUser == true`.
    var wrapUpNeedsUser = false
    var hasError = false
    var errorCategory: String?
    var interruptedAwaitingPerson = false
    var stoppedUntilPersonSends = false

    /// The size limit before parsing. 1 MB was the first limit, but real files outgrow it: a measurement (sizes and key
    /// names only) found 3 of 149 session files, all active, at 1.02 MB, about 1.00 MB of it `remoteMcpServersConfig`,
    /// a key never read here. 4 MB keeps them readable; keys not read are skipped (still checked for syntax, nesting
    /// and duplicates), never built into values.
    static let maxBytes = 4 << 20
    /// The keys read; every other key is checked and skipped.
    static let keysRead: Set<String> = [
        "title", "titleSource", "previousTitles", "cwd", "cliSessionId", "model", "effort", "permissionMode", "isArchived",
        "lastActivityAt", "lastFocusedAt", "latestUserFrameAt", "completedTurns", "sshConfig", "sshReattach",
        "postTurnSummary", "postTurnSummaryFor", "lastAssistantUuid", "turnWrapUp", "error", "errorCategory",
        "interruptedAwaitingPerson", "stoppedUntilPersonSends",
    ]
    /// `publishedArtifacts` (read by its own reader: only `url` and `updatedAt` are decoded).
    static let artifactsKey = "publishedArtifacts"
    /// Artifacts kept (the newest) and read at most.
    static let maxArtifacts = 32
    static let maxArtifactsRead = 256
    static let titleScalars = 512
    static let summaryScalars = 1024
    static let otherScalars = 4096

    /// The string cap for a value below `key`.
    static func scalarCap(forKey key: String?) -> Int {
        switch key {
        case "title", "previousTitles": return titleScalars
        case "status_detail", "needs_action": return summaryScalars
        default: return otherScalars
        }
    }

    /// Parses the bytes of a session file (already size-checked by the careful reader).
    static func parse(_ data: Data) -> Result<ClaudeSessionFile, ClaudeFileFailure> {
        let members: [String: JSONValue]?
        var artifacts: [CodeTurnDigest.PublishedArtifact] = []
        do {
            members = try data.withUnsafeBytes { bytes in
                try StrictJSONReader.read(bytes) { reader -> [String: JSONValue]? in
                    guard try reader.kind() == .object else {
                        try reader.skipValue()
                        return nil
                    }
                    var read: [String: JSONValue] = [:]
                    try reader.readObject { r, key in
                        if key == artifactsKey {
                            artifacts = try readArtifacts(&r)
                        } else if keysRead.contains(key) {
                            read[key] = try r.tree(key: key, cap: scalarCap(forKey:))
                        } else {
                            try r.skipValue()
                        }
                    }
                    return read
                }
            }
        } catch let failure as StrictJSONFailure {
            return .failure(.json(failure))
        } catch {
            return .failure(.json(.syntax))
        }
        guard let o = members else { return .failure(.notObject) }
        var file = ClaudeSessionFile()
        file.publishedArtifacts = artifacts
        file.latestUserFrameAt = date(o["latestUserFrameAt"])
        file.title = o["title"]?.nonEmptyString
        file.titleSource = CodeText.identifier(o["titleSource"]?.stringValue)
        file.previousTitles = (o["previousTitles"]?.arrayValue ?? []).compactMap { $0.nonEmptyString }
        file.cwd = o["cwd"]?.nonEmptyString
        if let raw = o["cliSessionId"]?.stringValue {
            if CodeIDs.isCLISessionID(raw) { file.cliSessionID = raw } else { file.cliSessionIDRejected = true }
        } else if o["cliSessionId"]?.isSet == true {
            file.cliSessionIDRejected = true
        }
        file.model = CodeText.identifier(o["model"]?.stringValue)
        file.effort = CodeText.identifier(o["effort"]?.stringValue)
        file.permissionMode = CodeText.identifier(o["permissionMode"]?.stringValue)
        file.isArchived = o["isArchived"]?.boolValue ?? false
        file.lastActivityAt = date(o["lastActivityAt"])
        file.lastFocusedAt = date(o["lastFocusedAt"])
        file.completedTurns = o["completedTurns"]?.intValue
        if case .object(let ssh) = o["sshConfig"] {
            file.hasSSHConfig = true
            file.sshHost = ssh["sshHost"]?.nonEmptyString
        }
        if case .object(let reattach) = o["sshReattach"] { file.midTurn = reattach["midTurn"]?.boolValue == true }
        if case .object(let s) = o["postTurnSummary"] {
            file.summary = Summary(category: CodeText.identifier(s["status_category"]?.stringValue),
                                   detail: s["status_detail"]?.nonEmptyString,
                                   needsAction: s["needs_action"]?.nonEmptyString,
                                   summarizesUUID: CodeIDs.entryUUID(s["summarizes_uuid"]?.stringValue))
        }
        file.summaryFor = CodeIDs.entryUUID(o["postTurnSummaryFor"]?.stringValue)
        file.lastAssistantUUID = CodeIDs.entryUUID(o["lastAssistantUuid"]?.stringValue)
        if case .object(let wrap) = o["turnWrapUp"] { file.wrapUpNeedsUser = wrap["needsUser"]?.boolValue == true }
        file.hasError = o["error"]?.isSet ?? false
        file.errorCategory = o["errorCategory"]?.isSet == true ? (CodeText.identifier(o["errorCategory"]?.stringValue) ?? "set") : nil
        file.interruptedAwaitingPerson = o["interruptedAwaitingPerson"]?.isSet ?? false
        file.stoppedUntilPersonSends = o["stoppedUntilPersonSends"]?.isSet ?? false
        return .success(file)
    }

    /// `publishedArtifacts`: each entry's `url` (at most 2,048 characters) and `updatedAt`; `title`, `sourcePath` and
    /// every other field are checked and skipped, never decoded. The newest `maxArtifacts` are kept.
    private static func readArtifacts(_ r: inout StrictJSONReader) throws -> [CodeTurnDigest.PublishedArtifact] {
        var list: [CodeTurnDigest.PublishedArtifact] = []
        var seen = 0
        try r.array { element in
            seen += 1
            guard seen <= maxArtifactsRead else {
                try element.skipValue()
                return
            }
            var url: String?
            var updatedAt: Date?
            try element.object { a, key in
                switch key {
                case "url":
                    url = try a.string(max: 2048)
                case "updatedAt":
                    switch try a.kind() {
                    case .number: updatedAt = try a.number().flatMap(CodeDates.fromNumber)
                    case .string: updatedAt = try a.string(max: 64).flatMap(CodeDates.parse)
                    default: try a.skipValue()
                    }
                default:
                    try a.skipValue()
                }
            }
            if let url, !url.isEmpty { list.append(CodeTurnDigest.PublishedArtifact(url: url, updatedAt: updatedAt)) }
        }
        let newestFirst = list.enumerated().sorted { a, b in
            let x = a.element.updatedAt ?? .distantPast
            let y = b.element.updatedAt ?? .distantPast
            return x != y ? x > y : a.offset > b.offset
        }.map(\.element)
        return Array(newestFirst.prefix(maxArtifacts))
    }

    /// A number of milliseconds or seconds since 1970, or an ISO 8601 string.
    private static func date(_ value: JSONValue?) -> Date? {
        switch value {
        case .number(let number)?: return CodeDates.fromNumber(number)
        case .string(let text)?: return CodeDates.parse(text)
        default: return nil
        }
    }
}

/// `<profile>/session-popouts.json`: which sessions Claude has in pop-out windows, with their titles and the
/// bounds the file holds (which may be stale).
struct ClaudePopouts: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        var sessionID: String
        var sessionType: String?
        var isSSH: Bool?
        var title: String?
        var bounds: CGRect?
        var alwaysOnTop: Bool?
    }

    var version: Int?
    var entries: [Entry] = []
    /// Entries left out because their `sessionId` failed `^local_[A-Za-z0-9-]{1,64}$`.
    var rejected = 0

    static let fileName = "session-popouts.json"
    static let maxBytes = 256 * 1024

    static func parse(_ data: Data) -> Result<ClaudePopouts, ClaudeFileFailure> {
        let root: JSONValue
        do {
            root = try data.withUnsafeBytes { bytes in
                try StrictJSONReader.read(bytes) { reader in try reader.tree(key: nil, cap: ClaudeSessionFile.scalarCap(forKey:)) }
            }
        } catch let failure as StrictJSONFailure {
            return .failure(.json(failure))
        } catch {
            return .failure(.json(.syntax))
        }
        guard case .object(let o) = root else { return .failure(.notObject) }
        var popouts = ClaudePopouts(version: o["version"]?.intValue)
        var seen = Set<String>()
        for item in o["popouts"]?.arrayValue ?? [] {
            guard case .object(let p) = item else {
                popouts.rejected += 1
                continue
            }
            guard let id = p["sessionId"]?.stringValue, CodeIDs.isSessionID(id) else {
                popouts.rejected += 1
                continue
            }
            guard seen.insert(id).inserted else { continue }
            var bounds: CGRect?
            if case .object(let b) = p["bounds"], let x = b["x"]?.doubleValue, let y = b["y"]?.doubleValue,
               let w = b["width"]?.doubleValue, let h = b["height"]?.doubleValue,
               [x, y, w, h].allSatisfy({ $0.isFinite && abs($0) < 1_000_000 }), w >= 0, h >= 0 {
                bounds = CGRect(x: x, y: y, width: w, height: h)
            }
            popouts.entries.append(Entry(sessionID: id, sessionType: CodeText.identifier(p["sessionType"]?.stringValue),
                                         isSSH: p["isSsh"]?.boolValue, title: p["title"]?.nonEmptyString,
                                         bounds: bounds, alwaysOnTop: p["alwaysOnTop"]?.boolValue))
        }
        return .success(popouts)
    }
}

/// The checked forms of Claude's identifiers: anything else never becomes part of a path.
enum CodeIDs {
    /// `^local_[A-Za-z0-9-]{1,64}$`.
    static func isSessionID(_ text: String) -> Bool {
        guard text.hasPrefix("local_") else { return false }
        let rest = text.utf8.dropFirst(6)
        guard (1...64).contains(rest.count) else { return false }
        return rest.allSatisfy { isAlphanumeric($0) || $0 == 0x2D }
    }

    /// `^[0-9A-Fa-f-]{36}$`.
    static func isCLISessionID(_ text: String) -> Bool {
        let bytes = text.utf8
        guard bytes.count == 36 else { return false }
        return bytes.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x46) || ($0 >= 0x61 && $0 <= 0x66) || $0 == 0x2D }
    }

    /// A transcript entry uuid as written, when it matches `^[0-9A-Za-z-]{1,64}$`:
    /// anything else is not compared, and nothing (no offer, finished record, seen mark or key) is made from it.
    static func entryUUID(_ text: String?) -> String? {
        guard let text, isEntryUUID(text) else { return nil }
        return text
    }

    /// `^[0-9A-Za-z-]{1,64}$`.
    static func isEntryUUID(_ text: String) -> Bool {
        (1...64).contains(text.utf8.count) && text.utf8.allSatisfy { isAlphanumeric($0) || $0 == 0x2D }
    }

    static func isAlphanumeric(_ c: UInt8) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
    }
}

/// Small text helpers for values the app shows or compares.
enum CodeText {
    /// A short identifier-like value (model, effort, permission mode, category): printable ASCII letters, digits and
    /// `-_.:[]@/`, at most 96 characters; nil for anything else.
    static func identifier(_ text: String?) -> String? {
        guard let text, (1...96).contains(text.utf8.count) else { return nil }
        let ok = text.utf8.allSatisfy { c in
            CodeIDs.isAlphanumeric(c) || c == 0x2D || c == 0x5F || c == 0x2E || c == 0x3A || c == 0x5B || c == 0x5D
                || c == 0x40 || c == 0x2F
        }
        return ok ? text : nil
    }

    /// One line for the monitor: control and format characters become spaces, runs of whitespace one space, cut at
    /// `limit` characters with "…". The block's plain-text renderer still escapes what it must; this only keeps the
    /// app's own composed lines ("running: …") on one line.
    static func oneLine(_ text: String, limit: Int) -> String {
        var out = ""
        var lastWasSpace = true
        var count = 0
        for scalar in text.unicodeScalars {
            let isSpace = scalar.properties.isWhitespace || scalar.properties.generalCategory == .control
                || scalar.properties.generalCategory == .format || scalar.properties.generalCategory == .lineSeparator
                || scalar.properties.generalCategory == .paragraphSeparator
            if isSpace {
                if !lastWasSpace {
                    out.unicodeScalars.append(" ")
                    lastWasSpace = true
                }
                continue
            }
            out.unicodeScalars.append(scalar)
            lastWasSpace = false
            count += 1
            if count > limit { break }
        }
        var trimmed = out.trimmingCharacters(in: .whitespaces)
        if trimmed.count > limit {
            trimmed = String(trimmed.prefix(max(1, limit - 1))).trimmingCharacters(in: .whitespaces) + "…"
        }
        return trimmed
    }

    /// The first `count` non-empty lines of `text`, each made one line and cut at `limit` characters.
    static func firstLines(_ text: String, count: Int, limit: Int) -> String? {
        var lines: [String] = []
        for raw in text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) {
            let line = oneLine(String(raw), limit: limit)
            guard !line.isEmpty else { continue }
            lines.append(line)
            if lines.count == count { break }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
