import CoreGraphics
import Foundation
import PitboxKit

/// Reading and writing the dock messages as JSON objects (docs/DOCK_PROTOCOL.md "Messages"). Every field is checked
/// for its type and range; unknown fields and unknown words are counted, never obeyed.
enum DockWire {
    /// What reading one object gave.
    enum Decoded<Message: Equatable>: Equatable {
        /// A known message; `unknownFields` counts the fields (and list entries) this build ignored.
        case message(Message, unknownFields: Int)
        /// A `t` this build does not know for this direction: ignored.
        case unknownType
        /// A known message with a missing or wrong field: the line is dropped. The label names the message and field.
        case badFields(String)
        /// No `t` string: not a dock message at all.
        case notAMessage
    }

    // MARK: Limits of single fields

    /// The largest int a field takes: below 10^15 (`JSONValue.intValue`'s exact range).
    static let maxSeq = 999_999_999_999_999
    /// Coordinates within ±10^5 points and sizes up to 10^5 (a far larger virtual desktop is no use).
    static let maxCoordinate = 100_000.0
    static let maxCount = 1_000_000
    static let maxAppBytes = 200
    static let maxBuildBytes = 100
    static let maxDisplayUUIDBytes = 64
    static let maxFocusBytes = 64
    static let maxWakeWords = 64
    static let maxWakeWordCharacters = 64
    static let maxFeatures = 64
    /// Entries per `private` list in one `hello` (real hosts announce one or two).
    static let maxFolders = 16
    static let maxFolderBytes = 1024

    // MARK: Host → guest

    static func decodeHost(_ value: JSONValue) -> Decoded<HostMessage> {
        guard let object = value.objectValue, let type = object["t"]?.stringValue else { return .notAMessage }
        var reader = FieldReader(object: object, type: type)
        let message: HostMessage?
        switch type {
        case "hello": message = reader.hello(expecting: .host).map(HostMessage.hello)
        case "place": message = reader.place().map(HostMessage.place)
        case "appearance":
            let scheme = reader.word("scheme", default: DockAppearance.Scheme.system)
            let backdrop = reader.word("backdrop", default: DockAppearance.Backdrop.glass)
            message = .appearance(DockAppearance(scheme: scheme, backdrop: backdrop))
        case "focus":
            message = reader.focusKey().map(HostMessage.focus)
        case "speech.ok":
            message = reader.int("id", 0...maxSeq).map { HostMessage.speechOK(id: $0) }
        case "speech.no":
            let id = reader.int("id", 0...maxSeq)
            let why = reader.word("why", default: DockSpeechNoReason.other)
            message = id.map { HostMessage.speechNo(id: $0, why: why) }
        case "fold": message = reader.bool("folded").map(HostMessage.fold)
        case "ping": message = .ping
        case "pong": message = .pong
        case "bye": message = .bye(reader.word("why", default: DockByeReason.other))
        default: return .unknownType
        }
        return reader.result(message)
    }

    static func encode(_ message: GuestMessage) -> Data {
        DockJSONWriter.line(object(message))
    }

    static func object(_ message: GuestMessage) -> JSONValue {
        switch message {
        case .hello(let hello): return helloObject(hello)
        case .busy: return ["t": "busy"]
        case let .area(seq, frame, folded, visible):
            return ["t": "area", "seq": .number(Double(seq)), "frame": rectObject(frame), "folded": .bool(folded),
                    "visible": .bool(visible)]
        case let .claim(pid, windowNumber):
            return ["t": "claim", "pid": .number(Double(pid)), "windowNumber": .number(Double(windowNumber))]
        case let .release(pid, windowNumber, parked):
            return ["t": "release", "pid": .number(Double(pid)), "windowNumber": .number(Double(windowNumber)),
                    "parked": .bool(parked)]
        case .mouseUp: return ["t": "mouseUp"]
        case let .attention(needsYou, finished, running):
            return ["t": "attention", "needsYou": .number(Double(needsYou)), "finished": .number(Double(finished)),
                    "running": .number(Double(running))]
        case .speechBegin(let id): return ["t": "speech.begin", "id": .number(Double(id))]
        case .speechEnd(let id): return ["t": "speech.end", "id": .number(Double(id))]
        case .ping: return ["t": "ping"]
        case .pong: return ["t": "pong"]
        case .bye(let why): return ["t": "bye", "why": .string(why.rawValue)]
        }
    }

    // MARK: Guest → host (the host's half; used by the fake hosts in the tests, kept beside the guest's so both
    // directions are read by the same rules)

    static func decodeGuest(_ value: JSONValue) -> Decoded<GuestMessage> {
        guard let object = value.objectValue, let type = object["t"]?.stringValue else { return .notAMessage }
        var reader = FieldReader(object: object, type: type)
        let message: GuestMessage?
        switch type {
        case "hello": message = reader.hello(expecting: .guest).map(GuestMessage.hello)
        case "busy": message = .busy
        case "area":
            let seq = reader.int("seq", 0...maxSeq)
            let frame = reader.rect("frame")
            let folded = reader.bool("folded")
            let visible = reader.bool("visible")
            if let seq, let frame, let folded, let visible {
                message = .area(seq: seq, frame: frame, folded: folded, visible: visible)
            } else {
                message = nil
            }
        case "claim", "release":
            let pid = reader.int("pid", 1...Int(Int32.max))
            let window = reader.int("windowNumber", 0...Int(UInt32.max))
            if type == "claim" {
                message = zip(pid, window).map { GuestMessage.claim(pid: Int32($0), windowNumber: UInt32($1)) }
            } else {
                let parked = reader.bool("parked")
                message = zip(pid, window).flatMap { pair in
                    parked.map { GuestMessage.release(pid: Int32(pair.0), windowNumber: UInt32(pair.1), parked: $0) }
                }
            }
        case "mouseUp": message = .mouseUp
        case "attention":
            let needsYou = reader.int("needsYou", 0...maxCount)
            let finished = reader.int("finished", 0...maxCount)
            let running = reader.int("running", 0...maxCount)
            if let needsYou, let finished, let running {
                message = .attention(needsYou: needsYou, finished: finished, running: running)
            } else {
                message = nil
            }
        case "speech.begin": message = reader.int("id", 0...maxSeq).map { GuestMessage.speechBegin(id: $0) }
        case "speech.end": message = reader.int("id", 0...maxSeq).map { GuestMessage.speechEnd(id: $0) }
        case "ping": message = .ping
        case "pong": message = .pong
        case "bye": message = .bye(reader.word("why", default: DockByeReason.other))
        default: return .unknownType
        }
        return reader.result(message)
    }

    static func encode(_ message: HostMessage) -> Data {
        DockJSONWriter.line(object(message))
    }

    static func object(_ message: HostMessage) -> JSONValue {
        switch message {
        case .hello(let hello): return helloObject(hello)
        case .place(let place):
            var members: [String: JSONValue] = [
                "t": "place", "seq": .number(Double(place.seq)), "displayID": .number(Double(place.displayID)),
                "edge": .string(place.edge.rawValue), "host": rectObject(place.host), "visible": .bool(place.visible),
                "level": .string(place.level.rawValue), "live": .bool(place.live),
                "cell": ["width": .number(place.cell.width), "gutter": .number(place.cell.gutter),
                         "padding": .number(place.cell.padding), "row": .number(place.cell.row)],
                "maxWidth": .number(place.maxWidth),
            ]
            if let uuid = place.displayUUID { members["displayUUID"] = .string(uuid) }
            return .object(members)
        case .appearance(let look):
            return ["t": "appearance", "scheme": .string(look.scheme.rawValue), "backdrop": .string(look.backdrop.rawValue)]
        case .focus(let focus): return ["t": "focus", "key": .string(focus.key)]
        case .speechOK(let id): return ["t": "speech.ok", "id": .number(Double(id))]
        case let .speechNo(id, why): return ["t": "speech.no", "id": .number(Double(id)), "why": .string(why.rawValue)]
        case .fold(let folded): return ["t": "fold", "folded": .bool(folded)]
        case .ping: return ["t": "ping"]
        case .pong: return ["t": "pong"]
        case .bye(let why): return ["t": "bye", "why": .string(why.rawValue)]
        }
    }

    // MARK: Shared pieces

    static func helloObject(_ hello: DockHello) -> JSONValue {
        var members: [String: JSONValue] = [
            "t": "hello",
            "proto": [.number(Double(hello.proto.lowerBound)), .number(Double(hello.proto.upperBound))],
            "role": .string(hello.role.rawValue), "app": .string(hello.app), "build": .string(hello.build),
            "features": .array(hello.features.map(\.rawValue).sorted().map(JSONValue.string)),
        ]
        if let minor = hello.minor { members["minor"] = .number(Double(minor)) }
        if hello.role == .host {
            members["wakeWords"] = .array(hello.wakeWords.map(JSONValue.string))
            members["private"] = ["folders": .array(hello.privateFolders.folders.map(JSONValue.string)),
                                  "socketFolders": .array(hello.privateFolders.socketFolders.map(JSONValue.string))]
        }
        return .object(members)
    }

    static func rectObject(_ rect: CGRect) -> JSONValue {
        ["x": .number(Double(rect.origin.x)), "y": .number(Double(rect.origin.y)),
         "w": .number(Double(rect.size.width)), "h": .number(Double(rect.size.height))]
    }

    /// One line of text: no control characters (C0, DEL, C1, line and paragraph separators), at most `maxBytes` UTF-8
    /// bytes, not empty after trimming.
    static func isOneLine(_ text: String, maxBytes: Int) -> Bool {
        guard !text.isEmpty, text.utf8.count <= maxBytes else { return false }
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return !text.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) || scalar.value == 0x2028 || scalar.value == 0x2029
        }
    }
}

private func zip<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}

/// Reads the fields of one message object, remembering which it used, so the rest count as unknown.
private struct FieldReader {
    let object: [String: JSONValue]
    let type: String
    private var used: Set<String> = ["t"]
    private var ignored = 0
    private var bad: String?

    init(object: [String: JSONValue], type: String) {
        self.object = object
        self.type = type
    }

    mutating func result<Message>(_ message: Message?) -> DockWire.Decoded<Message> {
        if let bad { return .badFields("\(type).\(bad)") }
        guard let message else { return .badFields(type) }
        let unknown = object.keys.filter { !used.contains($0) }.count
        return .message(message, unknownFields: unknown + ignored)
    }

    private mutating func fail(_ field: String) {
        if bad == nil { bad = field }
    }

    private mutating func take(_ field: String) -> JSONValue? {
        used.insert(field)
        return object[field]
    }

    mutating func int(_ field: String, _ range: ClosedRange<Int>) -> Int? {
        guard let value = take(field)?.intValue, range.contains(value) else { fail(field); return nil }
        return value
    }

    mutating func optionalInt(_ field: String, _ range: ClosedRange<Int>) -> Int?? {
        guard let raw = take(field) else { return .some(nil) }
        guard let value = raw.intValue, range.contains(value) else { fail(field); return nil }
        return .some(value)
    }

    mutating func bool(_ field: String) -> Bool? {
        guard let value = take(field)?.boolValue else { fail(field); return nil }
        return value
    }

    mutating func optionalBool(_ field: String, default fallback: Bool) -> Bool? {
        guard let raw = take(field) else { return fallback }
        guard let value = raw.boolValue else { fail(field); return nil }
        return value
    }

    /// A protocol word with a default: missing or unknown words read as the default (an unknown word is counted).
    mutating func word<W: RawRepresentable>(_ field: String, default fallback: W) -> W where W.RawValue == String {
        guard let raw = take(field) else { return fallback }
        guard let text = raw.stringValue else { fail(field); return fallback }
        guard let word = W(rawValue: text) else { ignored += 1; return fallback }
        return word
    }

    mutating func string(_ field: String, maxBytes: Int) -> String? {
        guard let text = take(field)?.stringValue, DockWire.isOneLine(text, maxBytes: maxBytes) else { fail(field); return nil }
        return text
    }

    mutating func double(_ field: String, in range: ClosedRange<Double>) -> Double? {
        guard let value = take(field)?.doubleValue, value.isFinite, range.contains(value) else { fail(field); return nil }
        return value
    }

    mutating func rect(_ field: String) -> CGRect? {
        guard let raw = take(field)?.objectValue else { fail(field); return nil }
        let limit = DockWire.maxCoordinate
        guard let x = raw["x"]?.doubleValue, let y = raw["y"]?.doubleValue,
              let w = raw["w"]?.doubleValue, let h = raw["h"]?.doubleValue,
              [x, y, w, h].allSatisfy(\.isFinite), abs(x) <= limit, abs(y) <= limit,
              w > 0, h > 0, w <= limit, h <= limit else { fail(field); return nil }
        ignored += raw.keys.filter { !["x", "y", "w", "h"].contains($0) }.count
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// A list of strings: entries that are not strings or not valid are dropped and counted; a non-list fails.
    mutating func strings(_ field: String, maxCount: Int, valid: (String) -> Bool) -> [String]? {
        guard let raw = take(field) else { return [] }
        guard let list = raw.arrayValue else { fail(field); return nil }
        var kept: [String] = []
        for entry in list {
            guard kept.count < maxCount, let text = entry.stringValue, valid(text), !kept.contains(text) else {
                ignored += 1
                continue
            }
            kept.append(text)
        }
        return kept
    }

    mutating func hello(expecting role: DockHello.Role) -> DockHello? {
        guard let protoList = take("proto")?.arrayValue, protoList.count == 2,
              let low = protoList[0].intValue, let high = protoList[1].intValue,
              (1...9999).contains(low), (low...9999).contains(high) else { fail("proto"); return nil }
        guard case .some(let minor) = optionalInt("minor", 0...9999) else { return nil }
        guard let roleText = take("role")?.stringValue, let sender = DockHello.Role(rawValue: roleText),
              sender == role else { fail("role"); return nil }
        guard let app = string("app", maxBytes: DockWire.maxAppBytes),
              let build = string("build", maxBytes: DockWire.maxBuildBytes) else { return nil }
        guard let featureWords = strings("features", maxCount: DockWire.maxFeatures,
                                         valid: { DockWire.isOneLine($0, maxBytes: 64) }) else { return nil }
        var features: Set<DockFeature> = []
        for word in featureWords {
            if let feature = DockFeature(rawValue: word) { features.insert(feature) } else { ignored += 1 }
        }
        var wakeWords: [String] = []
        var folders = HostPrivateFolders()
        if role == .host {
            guard let words = strings("wakeWords", maxCount: DockWire.maxWakeWords, valid: {
                $0.count <= DockWire.maxWakeWordCharacters && DockWire.isOneLine($0, maxBytes: 4 * DockWire.maxWakeWordCharacters)
            }) else { return nil }
            wakeWords = words
            if let raw = take("private") {
                guard let privateObject = raw.objectValue else { fail("private"); return nil }
                var inner = FieldReader(object: privateObject, type: "private")
                inner.used = []
                let valid: (String) -> Bool = { DockWire.isOneLine($0, maxBytes: DockWire.maxFolderBytes) }
                guard let list = inner.strings("folders", maxCount: DockWire.maxFolders, valid: valid),
                      let sockets = inner.strings("socketFolders", maxCount: DockWire.maxFolders, valid: valid),
                      inner.bad == nil else { fail("private"); return nil }
                ignored += inner.ignored + privateObject.keys.filter { !inner.used.contains($0) }.count
                folders = HostPrivateFolders(folders: list, socketFolders: sockets)
            }
        }
        return DockHello(proto: low...high, minor: minor, role: sender, app: app, build: build, features: features,
                         wakeWords: wakeWords, privateFolders: folders)
    }

    mutating func place() -> HostPlace? {
        let seq = int("seq", 0...DockWire.maxSeq)
        let displayID = int("displayID", 0...Int(UInt32.max))
        var uuid: String?
        if let raw = take("displayUUID") {
            guard let text = raw.stringValue, DockWire.isOneLine(text, maxBytes: DockWire.maxDisplayUUIDBytes) else {
                fail("displayUUID")
                return nil
            }
            uuid = text
        }
        guard let edgeText = take("edge")?.stringValue, let edge = Edge(rawValue: edgeText) else { fail("edge"); return nil }
        let host = rect("host")
        let visible = bool("visible")
        let level = word("level", default: HostPlace.Level.above)
        let live = optionalBool("live", default: false)
        let cell = cellValue()
        let maxWidth = double("maxWidth", in: 0...DockWire.maxCoordinate)
        guard let seq, let displayID, let host, let visible, let live, let cell, let maxWidth else { return nil }
        return HostPlace(seq: seq, displayID: UInt32(displayID), displayUUID: uuid, edge: edge, host: host,
                         visible: visible, level: level, live: live, cell: cell, maxWidth: maxWidth)
    }

    private mutating func cellValue() -> HostPlace.Cell? {
        guard let raw = take("cell")?.objectValue else { fail("cell"); return nil }
        let limit = 10_000.0
        func number(_ key: String, _ fallback: Double?, positive: Bool) -> Double? {
            guard let value = raw[key] else { return fallback }
            guard let number = value.doubleValue, number.isFinite, number <= limit,
                  positive ? number > 0 : number >= 0 else { return nil }
            return number
        }
        guard let width = number("width", nil, positive: true), let gutter = number("gutter", 12, positive: false),
              let padding = number("padding", 16, positive: false), let row = number("row", 69, positive: true) else {
            fail("cell")
            return nil
        }
        ignored += raw.keys.filter { !["width", "gutter", "padding", "row"].contains($0) }.count
        return HostPlace.Cell(width: width, gutter: gutter, padding: padding, row: row)
    }

    mutating func focusKey() -> DockFocus? {
        guard let key = string("key", maxBytes: DockWire.maxFocusBytes) else { return nil }
        return key == "all" ? .all : .named(key)
    }
}
