import Foundation
import PitboxKit

/// Why a strict JSON read failed. `label` is safe to log.
enum StrictJSONFailure: Error, Equatable, Sendable {
    case syntax, tooDeep, duplicateKey, longKey

    var label: String {
        switch self {
        case .syntax: return "syntax"
        case .tooDeep: return "too-deep"
        case .duplicateKey: return "duplicate-key"
        case .longKey: return "long-key"
        }
    }
}

/// A strict reader of one JSON document held in memory: RFC 8259 structure, at most 64 levels
/// of nesting, and a key that appears twice in one object (compared after decoding escapes) fails the whole document,
/// because two readers could disagree about which one counts (`JSONSerialization` cannot tell). The caller walks the
/// document and decides, key by key, which values to decode and which to skip. Strings are cut at a number of Unicode
/// scalars while they are decoded, so a 10 MB title never becomes a 10 MB string; skipped values are still checked
/// completely (their nesting and their keys), only their text is not decoded.
struct StrictJSONReader {
    static let maxDepth = 64
    /// A key longer than this fails the document (no key of Claude's is near it).
    static let maxKeyScalars = 1024

    enum Kind: Equatable { case object, array, string, number, bool, null }

    private let base: UnsafePointer<UInt8>
    private let count: Int
    private(set) var index = 0
    private var depth = 0

    private init(base: UnsafePointer<UInt8>, count: Int) {
        self.base = base
        self.count = count
    }

    /// Runs `body` over the document in `bytes` and then checks that only whitespace follows it.
    static func read<T>(_ bytes: UnsafeRawBufferPointer, _ body: (inout StrictJSONReader) throws -> T) throws -> T {
        guard bytes.count > 0, let raw = bytes.baseAddress else { throw StrictJSONFailure.syntax }
        var reader = StrictJSONReader(base: raw.assumingMemoryBound(to: UInt8.self), count: bytes.count)
        let value = try body(&reader)
        try reader.finish()
        return value
    }

    /// The kind of the value at the reader (whitespace skipped).
    mutating func kind() throws -> Kind {
        skipWhitespace()
        guard index < count else { throw StrictJSONFailure.syntax }
        switch base[index] {
        case 0x7B: return .object
        case 0x5B: return .array
        case 0x22: return .string
        case 0x74, 0x66: return .bool
        case 0x6E: return .null
        case 0x2D, 0x30...0x39: return .number
        default: throw StrictJSONFailure.syntax
        }
    }

    /// Reads an object; `member` is called with each decoded key and must consume exactly that key's value.
    mutating func readObject(_ member: (inout StrictJSONReader, String) throws -> Void) throws {
        skipWhitespace()
        guard index < count, base[index] == 0x7B else { throw StrictJSONFailure.syntax }
        depth += 1
        guard depth <= Self.maxDepth else { throw StrictJSONFailure.tooDeep }
        index += 1
        skipWhitespace()
        if index < count, base[index] == 0x7D {
            index += 1
            depth -= 1
            return
        }
        var keys = Set<String>()
        while true {
            skipWhitespace()
            guard index < count, base[index] == 0x22 else { throw StrictJSONFailure.syntax }
            let (key, cut) = try decodeString(maxScalars: Self.maxKeyScalars)
            guard !cut else { throw StrictJSONFailure.longKey }
            guard keys.insert(key).inserted else { throw StrictJSONFailure.duplicateKey }
            skipWhitespace()
            guard index < count, base[index] == 0x3A else { throw StrictJSONFailure.syntax }
            index += 1
            try member(&self, key)
            skipWhitespace()
            guard index < count else { throw StrictJSONFailure.syntax }
            if base[index] == 0x2C {
                index += 1
                continue
            }
            guard base[index] == 0x7D else { throw StrictJSONFailure.syntax }
            index += 1
            break
        }
        depth -= 1
    }

    /// Reads an array; `element` is called for each element and must consume it.
    mutating func readArray(_ element: (inout StrictJSONReader) throws -> Void) throws {
        skipWhitespace()
        guard index < count, base[index] == 0x5B else { throw StrictJSONFailure.syntax }
        depth += 1
        guard depth <= Self.maxDepth else { throw StrictJSONFailure.tooDeep }
        index += 1
        skipWhitespace()
        if index < count, base[index] == 0x5D {
            index += 1
            depth -= 1
            return
        }
        while true {
            try element(&self)
            skipWhitespace()
            guard index < count else { throw StrictJSONFailure.syntax }
            if base[index] == 0x2C {
                index += 1
                continue
            }
            guard base[index] == 0x5D else { throw StrictJSONFailure.syntax }
            index += 1
            break
        }
        depth -= 1
    }

    /// Skips the value at the reader, checking it completely (nesting, keys, syntax).
    mutating func skipValue() throws {
        switch try kind() {
        case .object: try readObject { reader, _ in try reader.skipValue() }
        case .array: try readArray { reader in try reader.skipValue() }
        case .string: try skipString()
        case .number: try scanNumber()
        case .bool: _ = try readBool()
        case .null: try readNull()
        }
    }

    // MARK: Typed reads (nil and skipped when the value has another kind)

    /// The string at the reader cut at `max` Unicode scalars, and whether it was cut; nil (value skipped) for any
    /// other kind of value.
    mutating func stringValue(max: Int) throws -> (text: String, cut: Bool)? {
        guard try kind() == .string else {
            try skipValue()
            return nil
        }
        return try decodeString(maxScalars: max)
    }

    /// The string at the reader cut at `max` scalars; nil (value skipped) for any other kind.
    mutating func string(max: Int) throws -> String? { try stringValue(max: max)?.text }

    mutating func bool() throws -> Bool? {
        guard try kind() == .bool else {
            try skipValue()
            return nil
        }
        return try readBool()
    }

    mutating func number() throws -> Double? {
        guard try kind() == .number else {
            try skipValue()
            return nil
        }
        let start = index
        try scanNumber()
        let text = String(decoding: UnsafeBufferPointer(start: base + start, count: index - start), as: UTF8.self)
        return Double(text)
    }

    /// Reads the object at the reader with `member`; false (value skipped) when it is not an object.
    @discardableResult
    mutating func object(_ member: (inout StrictJSONReader, String) throws -> Void) throws -> Bool {
        guard try kind() == .object else {
            try skipValue()
            return false
        }
        try readObject(member)
        return true
    }

    /// Reads the array at the reader with `element`; false (value skipped) when it is not an array.
    @discardableResult
    mutating func array(_ element: (inout StrictJSONReader) throws -> Void) throws -> Bool {
        guard try kind() == .array else {
            try skipValue()
            return false
        }
        try readArray(element)
        return true
    }

    /// The whole value as a tree; strings below a key are cut at `cap(key)` scalars (array elements use the array's key).
    mutating func tree(key: String?, cap: (String?) -> Int) throws -> JSONValue {
        switch try kind() {
        case .object:
            var members: [String: JSONValue] = [:]
            try readObject { reader, name in members[name] = try reader.tree(key: name, cap: cap) }
            return .object(members)
        case .array:
            var elements: [JSONValue] = []
            try readArray { reader in elements.append(try reader.tree(key: key, cap: cap)) }
            return .array(elements)
        case .string:
            return .string(try decodeString(maxScalars: cap(key)).0)
        case .number:
            return .number(try number() ?? 0)
        case .bool:
            return .bool(try readBool())
        case .null:
            try readNull()
            return .null
        }
    }

    /// Only whitespace may follow the document.
    mutating func finish() throws {
        skipWhitespace()
        guard index == count else { throw StrictJSONFailure.syntax }
    }

    // MARK: Scanning

    private mutating func skipWhitespace() {
        while index < count {
            let c = base[index]
            guard c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 else { return }
            index += 1
        }
    }

    private mutating func readBool() throws -> Bool {
        if matchLiteral("true") { return true }
        if matchLiteral("false") { return false }
        throw StrictJSONFailure.syntax
    }

    private mutating func readNull() throws {
        guard matchLiteral("null") else { throw StrictJSONFailure.syntax }
    }

    private mutating func matchLiteral(_ literal: StaticString) -> Bool {
        let length = literal.utf8CodeUnitCount
        guard index + length <= count, memcmp(base + index, literal.utf8Start, length) == 0 else { return false }
        index += length
        return true
    }

    /// RFC 8259 number grammar: `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?`.
    private mutating func scanNumber() throws {
        func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
        if index < count, base[index] == 0x2D { index += 1 }
        guard index < count else { throw StrictJSONFailure.syntax }
        if base[index] == 0x30 {
            index += 1
        } else if base[index] >= 0x31, base[index] <= 0x39 {
            while index < count, isDigit(base[index]) { index += 1 }
        } else {
            throw StrictJSONFailure.syntax
        }
        if index < count, base[index] == 0x2E {
            index += 1
            let start = index
            while index < count, isDigit(base[index]) { index += 1 }
            guard index > start else { throw StrictJSONFailure.syntax }
        }
        if index < count, base[index] == 0x65 || base[index] == 0x45 {
            index += 1
            if index < count, base[index] == 0x2B || base[index] == 0x2D { index += 1 }
            let start = index
            while index < count, isDigit(base[index]) { index += 1 }
            guard index > start else { throw StrictJSONFailure.syntax }
        }
    }

    /// `index` at the opening quote; on return just past the closing quote. The text is not decoded: `memchr` jumps
    /// from quote to quote, and a quote preceded by an odd number of backslashes belongs to the text.
    private mutating func skipString() throws {
        let open = index
        var from = index + 1
        let raw = UnsafeRawPointer(base)
        while from < count {
            guard let found = memchr(raw + from, 0x22, count - from) else { throw StrictJSONFailure.syntax }
            let quote = raw.distance(to: UnsafeRawPointer(found))
            var k = quote - 1
            while k > open, base[k] == 0x5C { k -= 1 }
            if (quote - 1 - k) % 2 == 0 {
                index = quote + 1
                return
            }
            from = quote + 1
        }
        throw StrictJSONFailure.syntax
    }

    /// `index` at the opening quote. Decodes escapes (`\uXXXX` with surrogate pairs; a lone surrogate becomes U+FFFD)
    /// and keeps at most `maxScalars` Unicode scalars; the rest is scanned, not kept.
    private mutating func decodeString(maxScalars: Int) throws -> (String, Bool) {
        index += 1
        var out = String.UnicodeScalarView()
        var kept = 0
        var cut = false
        func keep(_ scalar: Unicode.Scalar) {
            if kept < maxScalars {
                out.append(scalar)
                kept += 1
            } else {
                cut = true
            }
        }
        while true {
            let start = index
            while index < count, base[index] != 0x22, base[index] != 0x5C { index += 1 }
            guard index < count else { throw StrictJSONFailure.syntax }
            if index > start {
                if kept < maxScalars {
                    let chunk = String(decoding: UnsafeBufferPointer(start: base + start, count: index - start), as: UTF8.self)
                    for scalar in chunk.unicodeScalars {
                        guard kept < maxScalars else {
                            cut = true
                            break
                        }
                        out.append(scalar)
                        kept += 1
                    }
                } else {
                    cut = true
                }
            }
            if base[index] == 0x22 {
                index += 1
                break
            }
            index += 1
            guard index < count else { throw StrictJSONFailure.syntax }
            let escape = base[index]
            index += 1
            switch escape {
            case 0x22: keep("\"")
            case 0x5C: keep("\\")
            case 0x2F: keep("/")
            case 0x62: keep("\u{08}")
            case 0x66: keep("\u{0C}")
            case 0x6E: keep("\n")
            case 0x72: keep("\r")
            case 0x74: keep("\t")
            case 0x75: keep(try unicodeEscape())
            default: throw StrictJSONFailure.syntax
            }
        }
        return (String(out), cut)
    }

    /// After `\u`: four hex digits, combined with a following `\uDC00`-`\uDFFF` when they are a high surrogate.
    private mutating func unicodeEscape() throws -> Unicode.Scalar {
        let replacement: Unicode.Scalar = "\u{FFFD}"
        let unit = try hex4()
        if unit >= 0xD800, unit <= 0xDBFF {
            guard index + 1 < count, base[index] == 0x5C, base[index + 1] == 0x75 else { return replacement }
            let save = index
            index += 2
            let low = try hex4()
            guard low >= 0xDC00, low <= 0xDFFF else {
                index = save
                return replacement
            }
            return Unicode.Scalar(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)) ?? replacement
        }
        if unit >= 0xDC00, unit <= 0xDFFF { return replacement }
        return Unicode.Scalar(unit) ?? replacement
    }

    private mutating func hex4() throws -> UInt32 {
        guard index + 4 <= count else { throw StrictJSONFailure.syntax }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let c = base[index]
            let digit: UInt32
            switch c {
            case 0x30...0x39: digit = UInt32(c - 0x30)
            case 0x41...0x46: digit = UInt32(c - 0x41 + 10)
            case 0x61...0x66: digit = UInt32(c - 0x61 + 10)
            default: throw StrictJSONFailure.syntax
            }
            value = value << 4 | digit
            index += 1
        }
        return value
    }
}

extension JSONValue {
    /// A non-empty string, or nil.
    var nonEmptyString: String? {
        guard let text = stringValue, !text.isEmpty else { return nil }
        return text
    }

    /// Whether the value is "set" for the status rules: present and not null, false, an empty string or an empty
    /// object.
    var isSet: Bool {
        switch self {
        case .null: return false
        case .bool(let value): return value
        case .string(let text): return !text.isEmpty
        case .object(let members): return !members.isEmpty
        case .array(let elements): return !elements.isEmpty
        case .number: return true
        }
    }
}
