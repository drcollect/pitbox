import Foundation
import PitboxKit

/// The records of `code-memory.json` as the store accepts them, on write and on read alike, so the writer never writes
/// what the reader would reject. Each feature owns its record types; whatever it encodes must fit these shapes (dates
/// as ISO 8601 strings, which `CodeMemoryStore` writes for every `Date`):
///
/// | Key | Shape | Required fields | Limit and life |
/// | --- | --- | --- | --- |
/// | `seen` | object | `at` date | one |
/// | `finished` | list of objects | `reply` uuid, `at` date (`ranSeconds` ≥ 0, `open`, `expired` optional) | the last 16; 24 h after `at` |
/// | `ready` | object of item key → object | key `cmd:`/`file:`/`fin:`/`warn:` of this session; `state` later or dismissed, `at` date | the newest 64; 24 h after `at` |
/// | `eta` | object | `at` date (`statedAt` date, `reply` uuid optional) | one; until 2 h after `at` |
/// | `background` | list of objects | `task` 16 hex characters, `launchedAt` date (`kind` agent, workflow or bash optional) | the last 64; 6 h after `launchedAt` |
/// | `silenced` | list of objects | `rule` word, `until` date | the last 16; until `until` |
/// | `dashboard` | object | `handle`, `firstSeen` date (`lastBuilderCallAt` date, `site` key optional) | one |
/// | `dashboardScan` | object | `at` date, `found` bool (`bytes` ≥ 0 optional) | one |
///
/// A dashboard's `handle` must pass `CodeDashboard.isValidHandle`.
/// Lists are kept oldest first (write them that way): the first elements are dropped beyond the limit. Other fields
/// may be added; every string must be at most `maxString` bytes (session ids, uuids, hashes, times, handles and rule
/// words fit; titles, paths, URLs and commands are never stored), numbers finite, a record at most 6 levels deep.
/// Records that fail are dropped one by one; an empty list or object counts as absent.
enum CodeMemorySchema {
    static let maxString = 200
    static let maxMembers = 64
    static let maxElements = 256
    static let maxRecordDepth = 6

    /// `value` cleaned for `key` of `session` at `now`: invalid or expired parts dropped, limits applied; nil when
    /// nothing valid is left.
    static func clean(_ key: CodeMemoryKey, _ value: JSONValue, session: String, now: Date) -> JSONValue? {
        switch key {
        case .seen, .eta, .dashboard, .dashboardScan:
            // One record: well formed as a whole.
            guard isWellFormed(value, depth: 1) else { return nil }
        case .finished, .background, .silenced, .ready:
            // Lists and the Ready map: each element or member on its own (a flood keeps its newest records).
            break
        }
        switch key {
        case .seen:
            return record(value, dates: ["at"], optionalDates: []).map(JSONValue.object)
        case .eta:
            guard let kept = record(value, dates: ["at"], optionalDates: ["statedAt"], optionalUUIDs: ["reply"]),
                  let at = date(kept["at"]), at.addingTimeInterval(CodeTuning.etaKeepAfter) >= now else { return nil }
            return .object(kept)
        case .dashboard:
            guard let kept = record(value, dates: ["firstSeen"], optionalDates: ["lastBuilderCallAt"]),
                  let handle = kept["handle"]?.stringValue, CodeDashboard.isValidHandle(handle),
                  kept["site"].map({ $0.stringValue != nil }) ?? true else { return nil }
            return .object(kept)
        case .dashboardScan:
            guard let kept = record(value, dates: ["at"], optionalDates: []), kept["found"]?.boolValue != nil,
                  kept["bytes"].map(isNonNegativeNumber) ?? true else { return nil }
            return .object(kept)
        case .finished:
            return list(value, limit: CodeTuning.memoryFinishedMax) { element in
                guard let kept = record(element, dates: ["at"], optionalDates: []),
                      let reply = kept["reply"]?.stringValue, CodeIDs.isEntryUUID(reply),
                      kept["ranSeconds"].map(isNonNegativeNumber) ?? true,
                      kept["open"].map({ $0.boolValue != nil }) ?? true,
                      kept["expired"].map({ $0.boolValue != nil }) ?? true,
                      let at = date(kept["at"]), at.addingTimeInterval(CodeTuning.finishedRecordLife) >= now else { return nil }
                return kept
            }
        case .background:
            return list(value, limit: CodeTuning.backgroundMaxPending) { element in
                guard let kept = record(element, dates: ["launchedAt"], optionalDates: []),
                      let task = kept["task"]?.stringValue, isHash16(task),
                      kept["kind"].map({ ["agent", "workflow", "bash"].contains($0.stringValue ?? "") }) ?? true,
                      let launched = date(kept["launchedAt"]),
                      launched.addingTimeInterval(CodeTuning.backgroundMaxAge) >= now else { return nil }
                return kept
            }
        case .silenced:
            return list(value, limit: CodeTuning.memorySilencedMax) { element in
                guard let kept = record(element, dates: ["until"], optionalDates: []),
                      let rule = kept["rule"]?.stringValue, isRuleWord(rule),
                      let until = date(kept["until"]), until >= now else { return nil }
                return kept
            }
        case .ready:
            guard case .object(let members) = value else { return nil }
            var kept: [(key: String, value: JSONValue, at: Date)] = []
            for (itemKey, state) in members {
                guard itemKey.utf8.count <= maxString, isItemKey(itemKey, session: session),
                      isWellFormed(state, depth: 2), let fields = record(state, dates: ["at"], optionalDates: []),
                      let word = fields["state"]?.stringValue, word == "later" || word == "dismissed",
                      let at = date(fields["at"]), at.addingTimeInterval(CommandOffer.maxAge) >= now else { continue }
                kept.append((itemKey, .object(fields), at))
            }
            kept.sort { $0.at != $1.at ? $0.at > $1.at : $0.key < $1.key }
            let newest = kept.prefix(CodeTuning.memoryReadyKeysMax)
            guard !newest.isEmpty else { return nil }
            return .object(Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) }))
        }
    }

    // MARK: Shapes

    /// An object whose `dates` fields are dates, whose `optionalDates` are dates when present, and whose
    /// `optionalUUIDs` are uuids when present.
    private static func record(_ value: JSONValue, dates: [String], optionalDates: [String],
                               optionalUUIDs: [String] = []) -> [String: JSONValue]? {
        guard case .object(let fields) = value else { return nil }
        for name in dates where date(fields[name]) == nil { return nil }
        for name in optionalDates where fields[name] != nil && date(fields[name]) == nil { return nil }
        for name in optionalUUIDs {
            if let field = fields[name] {
                guard let text = field.stringValue, CodeIDs.isEntryUUID(text) else { return nil }
            }
        }
        return fields
    }

    /// The valid elements of a list (each well formed on its own), the last `limit` of them; nil when none is left.
    private static func list(_ value: JSONValue, limit: Int, element: (JSONValue) -> [String: JSONValue]?) -> JSONValue? {
        guard case .array(let elements) = value else { return nil }
        let kept = elements.compactMap { isWellFormed($0, depth: 2) ? element($0) : nil }.suffix(limit)
        return kept.isEmpty ? nil : .array(kept.map(JSONValue.object))
    }

    /// Strings and member names short, numbers finite, few members and elements, nested at most `maxRecordDepth`
    /// (`depth` is the level `value` sits at inside the session's record).
    private static func isWellFormed(_ value: JSONValue, depth: Int) -> Bool {
        switch value {
        case .string(let text):
            return text.utf8.count <= maxString
        case .number(let number):
            return number.isFinite
        case .bool, .null:
            return true
        case .array(let elements):
            guard depth <= maxRecordDepth, elements.count <= maxElements else { return false }
            return elements.allSatisfy { isWellFormed($0, depth: depth + 1) }
        case .object(let members):
            guard depth <= maxRecordDepth, members.count <= maxMembers else { return false }
            return members.allSatisfy { $0.key.utf8.count <= maxString && isWellFormed($0.value, depth: depth + 1) }
        }
    }

    // MARK: Values

    static func date(_ value: JSONValue?) -> Date? { value?.stringValue.flatMap(CodeDates.parse) }

    private static func isNonNegativeNumber(_ value: JSONValue) -> Bool { (value.doubleValue ?? -1) >= 0 }

    /// 16 lowercase hex characters (the first 16 of a SHA-256, as in the run records).
    static func isHash16(_ text: String) -> Bool {
        text.utf8.count == 16 && text.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    /// A rule word: lowercase letters, digits, `_`, `-`, `.`, `:`, 1-96 characters (`failed_in_a_row`,
    /// `same_file:<hash16>`).
    static func isRuleWord(_ text: String) -> Bool {
        (1...96).contains(text.utf8.count) && text.utf8.allSatisfy {
            ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x5F || $0 == 0x2D || $0 == 0x2E || $0 == 0x3A
        }
    }

    /// A Ready item key of `session`: `cmd:<session>:<uuid>:<number>:<hash16>`, `file:<session>:<uuid>:<hash16>`,
    /// `fin:<session>:<uuid>` or `warn:<session>:<rule>`.
    static func isItemKey(_ key: String, session: String) -> Bool {
        let parts = key.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[1] == session else { return false }
        let rest = parts[2]
        switch parts[0] {
        case "cmd":
            let tail = rest.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard tail.count == 3, CodeIDs.isEntryUUID(tail[0]), isHash16(tail[2]),
                  let number = Int(tail[1]), (1...99).contains(number), tail[1].utf8.count <= 2 else { return false }
            return true
        case "file":
            let tail = rest.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            return tail.count == 2 && CodeIDs.isEntryUUID(tail[0]) && isHash16(tail[1])
        case "fin":
            return CodeIDs.isEntryUUID(rest)
        case "warn":
            return isRuleWord(rest)
        default:
            return false
        }
    }
}
