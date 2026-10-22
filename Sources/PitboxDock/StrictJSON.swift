import Foundation
import PitboxKit

/// A strict JSON reader for one dock line (docs/DOCK_PROTOCOL.md "Framing"): RFC 8259 only (no comments, no trailing
/// commas, no NaN or infinities, no leading zeros, no unescaped control characters, no lone surrogates), valid UTF-8,
/// nesting at most `maxDepth`, and a duplicated key anywhere is its own failure (the line is dropped, not obeyed with
/// either value). Foundation's reader keeps the last duplicate silently and accepts more than RFC 8259, hence this one.
enum StrictJSON {
    enum Failure: Error, Equatable {
        /// Not UTF-8.
        case notUTF8
        /// Not JSON by RFC 8259 (or trailing text after the value).
        case malformed
        /// Objects and arrays nested deeper than allowed.
        case tooDeep
        /// The same key twice in one object.
        case duplicateKey
    }

    /// Parses one complete JSON text.
    static func parse(_ bytes: [UInt8], maxDepth: Int = DockProtocol.maxNesting) throws -> JSONValue {
        guard String(validating: bytes, as: UTF8.self) != nil else { throw Failure.notUTF8 }
        var parser = Parser(bytes: bytes, maxDepth: maxDepth)
        parser.skipWhitespace()
        let value = try parser.value(depth: 0)
        parser.skipWhitespace()
        guard parser.atEnd else { throw Failure.malformed }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        let maxDepth: Int
        var index = 0

        init(bytes: [UInt8], maxDepth: Int) {
            self.bytes = bytes
            self.maxDepth = maxDepth
        }

        var atEnd: Bool { index >= bytes.count }

        func peek() -> UInt8? { index < bytes.count ? bytes[index] : nil }

        mutating func skipWhitespace() {
            while let byte = peek(), byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D { index += 1 }
        }

        mutating func expect(_ byte: UInt8) throws {
            guard peek() == byte else { throw Failure.malformed }
            index += 1
        }

        mutating func value(depth: Int) throws -> JSONValue {
            guard let byte = peek() else { throw Failure.malformed }
            switch byte {
            case UInt8(ascii: "{"): return try object(depth: depth + 1)
            case UInt8(ascii: "["): return try array(depth: depth + 1)
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try number())
            default: throw Failure.malformed
            }
        }

        mutating func literal(_ word: String) throws {
            for byte in word.utf8 { try expect(byte) }
        }

        mutating func object(depth: Int) throws -> JSONValue {
            guard depth <= maxDepth else { throw Failure.tooDeep }
            try expect(UInt8(ascii: "{"))
            var members: [String: JSONValue] = [:]
            skipWhitespace()
            if peek() == UInt8(ascii: "}") { index += 1; return .object(members) }
            while true {
                skipWhitespace()
                guard peek() == UInt8(ascii: "\"") else { throw Failure.malformed }
                let key = try string()
                skipWhitespace()
                try expect(UInt8(ascii: ":"))
                skipWhitespace()
                let member = try value(depth: depth)
                guard members[key] == nil else { throw Failure.duplicateKey }
                members[key] = member
                skipWhitespace()
                guard let next = peek() else { throw Failure.malformed }
                index += 1
                if next == UInt8(ascii: "}") { return .object(members) }
                guard next == UInt8(ascii: ",") else { throw Failure.malformed }
            }
        }

        mutating func array(depth: Int) throws -> JSONValue {
            guard depth <= maxDepth else { throw Failure.tooDeep }
            try expect(UInt8(ascii: "["))
            var elements: [JSONValue] = []
            skipWhitespace()
            if peek() == UInt8(ascii: "]") { index += 1; return .array(elements) }
            while true {
                skipWhitespace()
                elements.append(try value(depth: depth))
                skipWhitespace()
                guard let next = peek() else { throw Failure.malformed }
                index += 1
                if next == UInt8(ascii: "]") { return .array(elements) }
                guard next == UInt8(ascii: ",") else { throw Failure.malformed }
            }
        }

        mutating func string() throws -> String {
            try expect(UInt8(ascii: "\""))
            var scalars = String.UnicodeScalarView()
            var run: [UInt8] = []
            func flush() {
                if !run.isEmpty {
                    scalars.append(contentsOf: String(decoding: run, as: UTF8.self).unicodeScalars)
                    run.removeAll(keepingCapacity: true)
                }
            }
            while true {
                guard let byte = peek() else { throw Failure.malformed }
                index += 1
                switch byte {
                case UInt8(ascii: "\""):
                    flush()
                    return String(scalars)
                case UInt8(ascii: "\\"):
                    flush()
                    scalars.append(try escape())
                case 0x00..<0x20:
                    throw Failure.malformed
                default:
                    run.append(byte)
                }
            }
        }

        mutating func escape() throws -> Unicode.Scalar {
            guard let byte = peek() else { throw Failure.malformed }
            index += 1
            switch byte {
            case UInt8(ascii: "\""): return "\""
            case UInt8(ascii: "\\"): return "\\"
            case UInt8(ascii: "/"): return "/"
            case UInt8(ascii: "b"): return "\u{08}"
            case UInt8(ascii: "f"): return "\u{0C}"
            case UInt8(ascii: "n"): return "\n"
            case UInt8(ascii: "r"): return "\r"
            case UInt8(ascii: "t"): return "\t"
            case UInt8(ascii: "u"):
                let first = try hex4()
                if (0xD800...0xDBFF).contains(first) {
                    // A high surrogate must be followed by an escaped low one.
                    guard peek() == UInt8(ascii: "\\") else { throw Failure.malformed }
                    index += 1
                    guard peek() == UInt8(ascii: "u") else { throw Failure.malformed }
                    index += 1
                    let second = try hex4()
                    guard (0xDC00...0xDFFF).contains(second) else { throw Failure.malformed }
                    let value = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                    guard let scalar = Unicode.Scalar(value) else { throw Failure.malformed }
                    return scalar
                }
                guard !(0xDC00...0xDFFF).contains(first), let scalar = Unicode.Scalar(first) else { throw Failure.malformed }
                return scalar
            default:
                throw Failure.malformed
            }
        }

        mutating func hex4() throws -> UInt32 {
            var value: UInt32 = 0
            for _ in 0..<4 {
                guard let byte = peek() else { throw Failure.malformed }
                index += 1
                let digit: UInt32
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a") + 10)
                case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A") + 10)
                default: throw Failure.malformed
                }
                value = value << 4 | digit
            }
            return value
        }

        mutating func number() throws -> Double {
            let start = index
            if peek() == UInt8(ascii: "-") { index += 1 }
            guard let first = peek(), isDigit(first) else { throw Failure.malformed }
            index += 1
            if first == UInt8(ascii: "0") {
                if let next = peek(), isDigit(next) { throw Failure.malformed }
            } else {
                while let next = peek(), isDigit(next) { index += 1 }
            }
            if peek() == UInt8(ascii: ".") {
                index += 1
                guard let next = peek(), isDigit(next) else { throw Failure.malformed }
                while let next = peek(), isDigit(next) { index += 1 }
            }
            if let marker = peek(), marker == UInt8(ascii: "e") || marker == UInt8(ascii: "E") {
                index += 1
                if let sign = peek(), sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") { index += 1 }
                guard let next = peek(), isDigit(next) else { throw Failure.malformed }
                while let next = peek(), isDigit(next) { index += 1 }
            }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            guard let value = Double(text), value.isFinite else { throw Failure.malformed }
            return value
        }

        func isDigit(_ byte: UInt8) -> Bool { byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") }
    }
}

/// Writes dock lines: compact JSON, keys sorted (stable output for logs and tests), whole numbers without a fraction.
enum DockJSONWriter {
    static func line(_ value: JSONValue) -> Data {
        var text = ""
        write(value, into: &text)
        text.append("\n")
        return Data(text.utf8)
    }

    static func text(_ value: JSONValue) -> String {
        var text = ""
        write(value, into: &text)
        return text
    }

    private static func write(_ value: JSONValue, into text: inout String) {
        switch value {
        case .null: text += "null"
        case .bool(let flag): text += flag ? "true" : "false"
        case .number(let number): text += format(number)
        case .string(let string): writeString(string, into: &text)
        case .array(let elements):
            text += "["
            for (offset, element) in elements.enumerated() {
                if offset > 0 { text += "," }
                write(element, into: &text)
            }
            text += "]"
        case .object(let members):
            text += "{"
            for (offset, key) in members.keys.sorted().enumerated() {
                if offset > 0 { text += "," }
                writeString(key, into: &text)
                text += ":"
                write(members[key] ?? .null, into: &text)
            }
            text += "}"
        }
    }

    /// Whole numbers within ±2^53 as integers; other finite numbers in Swift's shortest round-trip form (valid JSON);
    /// a non-finite number (never produced by the encoders) as 0.
    static func format(_ number: Double) -> String {
        guard number.isFinite else { return "0" }
        if number == number.rounded(), abs(number) <= 9_007_199_254_740_992 { return String(Int64(number)) }
        return "\(number)"
    }

    private static func writeString(_ string: String, into text: inout String) {
        text += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": text += "\\\""
            case "\\": text += "\\\\"
            case "\n": text += "\\n"
            case "\r": text += "\\r"
            case "\t": text += "\\t"
            case "\u{08}": text += "\\b"
            case "\u{0C}": text += "\\f"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F || scalar.value == 0x2028 || scalar.value == 0x2029 {
                    text += String(format: "\\u%04x", scalar.value)
                } else {
                    text.unicodeScalars.append(scalar)
                }
            }
        }
        text += "\""
    }
}
