import Foundation
import PitboxKit
import Testing
@testable import PitboxDock

private func parse(_ text: String) throws -> JSONValue { try StrictJSON.parse(Array(text.utf8)) }

private func failure(_ text: String) -> StrictJSON.Failure? {
    do {
        _ = try StrictJSON.parse(Array(text.utf8))
        return nil
    } catch let failure as StrictJSON.Failure {
        return failure
    } catch {
        return nil
    }
}

private func nested(_ depth: Int) -> String {
    // depth 1 is the top object alone.
    var text = "{\"t\":\"ping\",\"x\":"
    for _ in 1..<depth { text += "[" }
    text += "0"
    for _ in 1..<depth { text += "]" }
    return text + "}"
}

@Suite struct StrictJSONTests {
    @Test func readsEveryKindOfValue() throws {
        let value = try parse(#" { "t" : "place", "n": -12.5e1, "z": 0, "b": true, "f": false, "x": null, "a": [1, "two", {}], "o": {"k": []} } "#)
        #expect(value["t"]?.stringValue == "place")
        #expect(value["n"]?.doubleValue == -125)
        #expect(value["z"]?.intValue == 0)
        #expect(value["b"]?.boolValue == true)
        #expect(value["f"]?.boolValue == false)
        #expect(value["x"]?.isNull == true)
        #expect(value["a"]?.arrayValue?.count == 3)
        #expect(value["o"]?["k"]?.arrayValue == [])
    }

    @Test func stringsWithEscapesAndSurrogatePairs() throws {
        let value = try parse(#"{"s":"a\"b\\c\/d\b\f\n\r\t\u00e9\ud83d\ude00é"}"#)
        #expect(value["s"]?.stringValue == "a\"b\\c/d\u{08}\u{0C}\n\r\té😀é")
    }

    @Test func nestingUpToEightIsFineNineIsTooDeep() throws {
        #expect(throws: Never.self) { try parse(nested(8)) }
        #expect(failure(nested(9)) == .tooDeep)
        #expect(failure(String(repeating: "[", count: 500) + String(repeating: "]", count: 500)) == .tooDeep,
                "deep input fails early instead of recursing far")
    }

    @Test func aDuplicatedKeyAnywhereIsItsOwnFailure() {
        #expect(failure(#"{"t":"place","t":"ping"}"#) == .duplicateKey)
        #expect(failure(#"{"t":"place","host":{"x":1,"x":2}}"#) == .duplicateKey)
        #expect(failure(#"{"t":"place","a":[{"k":1,"k":1}]}"#) == .duplicateKey)
        // Escapes that spell the same key are the same key.
        #expect(failure(#"{"t":"a","\u0074":"b"}"#) == .duplicateKey)
    }

    @Test(arguments: [
        "", " ", "{", "}", "{\"t\":}", "{\"t\":\"a\",}", "{'t':'a'}", "{\"t\":\"a\"} x", "{\"t\":\"a\"}{}",
        "{\"n\":01}", "{\"n\":1.}", "{\"n\":.5}", "{\"n\":+1}", "{\"n\":1e}", "{\"n\":NaN}", "{\"n\":Infinity}",
        "{\"n\":1e999}", "{\"s\":\"tab\there\"}", "{\"s\":\"\\x41\"}", "{\"s\":\"\\ud800\"}", "{\"s\":\"\\udc00\"}",
        "{\"s\":\"\\ud800\\u0041\"}", "{\"s\":\"\\u12\"}", "{\"s\":\"open}", "[1,2", "tru", "nul", "{\"t\" \"a\"}",
        "{\"t\":\"a\" // comment\n}", "/* c */ {}",
    ])
    func malformedTextFails(_ text: String) {
        #expect(failure(text) == .malformed, "\(text.debugDescription)")
    }

    @Test func invalidUTF8Fails() {
        #expect(throws: StrictJSON.Failure.notUTF8) { try StrictJSON.parse([0x7B, 0x22, 0xFF, 0x22, 0x3A, 0x31, 0x7D]) }
        #expect(throws: StrictJSON.Failure.notUTF8) { try StrictJSON.parse([0x7B, 0xC3, 0x7D]) }
        // An overlong encoding of "/".
        #expect(throws: StrictJSON.Failure.notUTF8) { try StrictJSON.parse([0x22, 0xC0, 0xAF, 0x22]) }
    }

    @Test func theWriterIsReadBackExactly() throws {
        let value: JSONValue = ["t": "area", "seq": 12, "frame": ["x": -0.5, "y": 98, "w": 631, "h": 1312.25],
                                "s": "quote \" backslash \\ newline \n nul \u{0} é 😀 \u{2028}", "list": [true, false, nil]]
        let text = DockJSONWriter.text(value)
        #expect(!text.contains("\n"), "one line, whatever the strings hold")
        #expect(try parse(text) == value)
        #expect(DockJSONWriter.line(["t": "ping"]) == Data("{\"t\":\"ping\"}\n".utf8))
        #expect(DockJSONWriter.format(12) == "12")
        #expect(DockJSONWriter.format(301.4) == "301.4")
        #expect(DockJSONWriter.format(-3) == "-3")
        #expect(DockJSONWriter.format(.nan) == "0")
        #expect(DockJSONWriter.text(["b": 1, "a": 2]) == #"{"a":2,"b":1}"#, "keys sorted")
    }
}
