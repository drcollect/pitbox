import Foundation
import Testing
@testable import PitboxSessions
import PitboxKit

@Suite("Strict JSON")
struct StrictJSONTests {
    func tree(_ text: String, cap: Int = 4096) throws -> JSONValue {
        try withBytes(text) { bytes in
            try StrictJSONReader.read(bytes) { reader in try reader.tree(key: nil, cap: { _ in cap }) }
        }
    }

    func failure(_ text: String) -> StrictJSONFailure? {
        do {
            _ = try tree(text)
            return nil
        } catch let failure as StrictJSONFailure {
            return failure
        } catch {
            return .syntax
        }
    }

    @Test func readsObjectsArraysAndScalars() throws {
        let value = try tree(#" { "a": [1, -2.5e3, true, false, null], "b": {"c": "d\né😀"} } "#)
        #expect(value["a"]?.arrayValue?.count == 5)
        #expect(value["a"]?[1]?.doubleValue == -2500)
        #expect(value["a"]?[2]?.boolValue == true)
        #expect(value["a"]?[4]?.isNull == true)
        #expect(value["b"]?["c"]?.stringValue == "d\n\u{e9}\u{1F600}")
    }

    @Test func aDuplicatedKeyFailsTheDocumentAtAnyDepth() {
        #expect(failure(#"{"a":1,"a":2}"#) == .duplicateKey)
        #expect(failure(#"{"x":{"a":1,"b":{"c":1,"c":2}}}"#) == .duplicateKey)
        // The same key spelled with an escape is the same key.
        #expect(failure(#"{"a":1,"a":2}"#) == .duplicateKey)
        #expect(failure(#"{"list":[{"k":1},{"k":2}]}"#) == nil)
    }

    @Test func skippedValuesAreStillCheckedForDuplicates() {
        let text = #"{"keep":"x","skip":{"deep":[{"z":1,"z":2}]}}"#
        let result: Result<String?, Error> = Result {
            try withBytes(text) { bytes in
                try StrictJSONReader.read(bytes) { reader -> String? in
                    var kept: String?
                    try reader.readObject { r, key in
                        if key == "keep" { kept = try r.string(max: 10) } else { try r.skipValue() }
                    }
                    return kept
                }
            }
        }
        #expect(throws: StrictJSONFailure.duplicateKey) { try result.get() }
    }

    @Test func nestingStopsAt64() {
        let deep64 = String(repeating: "[", count: 63) + "{}" + String(repeating: "]", count: 63)
        let deep65 = String(repeating: "[", count: 64) + "{}" + String(repeating: "]", count: 64)
        #expect(failure("{\"a\":\(deep64.dropFirst().dropLast())}") == nil)
        #expect(failure(deep64) == nil)
        #expect(failure(deep65) == .tooDeep)
    }

    @Test func stringsAreCutWhileDecoding() throws {
        let long = String(repeating: "ab", count: 5000)
        let value = try tree("{\"t\":\"\(long)\"}", cap: 512)
        #expect(value["t"]?.stringValue?.count == 512)
        let pair = try tree(#"{"t":"😀😀"}"#, cap: 1)
        #expect(pair["t"]?.stringValue == "\u{1F600}")
        let lone = try tree(#"{"t":"\ud83dx"}"#)
        #expect(lone["t"]?.stringValue == "\u{FFFD}x")
    }

    @Test func badSyntaxFails() {
        for text in [#"{"a":1,}"#, #"{"a":01}"#, #"{"a":1.}"#, #"{"a":.5}"#, #"{"a":"x"} trailing"#, #"{"a" 1}"#,
                     #"{"a":tru}"#, #"{"a":"\x"}"#, #"{"a":"unterminated}"#, "", "{", #"["a",]"#, #"{"a":-}"#] {
            #expect(failure(text) != nil, "\(text)")
        }
        #expect(failure(#"{"a":-0.5e-3,"b":0,"c":1E+2}"#) == nil)
    }

    @Test func aVeryLongKeyFails() {
        let key = String(repeating: "k", count: StrictJSONReader.maxKeyScalars + 1)
        #expect(failure("{\"\(key)\":1}") == .longKey)
    }
}

@Suite("Careful files")
struct CarefulFilesTests {
    @Test func readsARegularFileOfTheUser() throws {
        let tree = FixtureTree()
        try tree.write("hello", to: tree.root.appendingPathComponent("a/b/file.json"))
        let path = try #require(CarefulPath(root: tree.root.path, components: ["a", "b", "file.json"]))
        let read = try CarefulFiles.read(path, owner: getuid(), maxBytes: 100).get()
        #expect(String(decoding: read.0, as: UTF8.self) == "hello")
        #expect(read.1.size == 5)
        // Unchanged: no data the second time.
        let again = try CarefulFiles.readIfChanged(path, owner: getuid(), maxBytes: 100, known: read.1).get()
        #expect(again.0 == nil)
    }

    @Test func aLinkIsRefusedNotFollowed() throws {
        let tree = FixtureTree()
        let target = tree.root.appendingPathComponent("target.json")
        try tree.write(secretWord, to: target)
        let link = tree.root.appendingPathComponent("dir/link.json")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let path = try #require(CarefulPath(root: tree.root.path, components: ["dir", "link.json"]))
        #expect(throws: CarefulReadFailure.link) { try CarefulFiles.read(path, owner: getuid(), maxBytes: 100).get() }
        // A linked folder on the way is refused too.
        let realFolder = tree.root.appendingPathComponent("real")
        try tree.write("x", to: realFolder.appendingPathComponent("f.json"))
        try FileManager.default.createSymbolicLink(at: tree.root.appendingPathComponent("linked"), withDestinationURL: realFolder)
        let through = try #require(CarefulPath(root: tree.root.path, components: ["linked", "f.json"]))
        let failure = CarefulFiles.read(through, owner: getuid(), maxBytes: 100)
        #expect(failure.isFailure(.link) || failure.isFailure(.notDirectory))
    }

    @Test func aFIFOIsRefusedWithoutWaiting() throws {
        let tree = FixtureTree()
        let fifo = tree.root.appendingPathComponent("pipe.json")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let path = try #require(CarefulPath(root: tree.root.path, components: ["pipe.json"]))
        #expect(throws: CarefulReadFailure.notRegular) { try CarefulFiles.read(path, owner: getuid(), maxBytes: 100).get() }
    }

    @Test func anotherOwnerAndOversizeAreRefused() throws {
        let tree = FixtureTree()
        try tree.write(String(repeating: "x", count: ClaudeSessionFile.maxBytes + 1), to: tree.root.appendingPathComponent("big.json"))
        let path = try #require(CarefulPath(root: tree.root.path, components: ["big.json"]))
        #expect(throws: CarefulReadFailure.tooLarge) {
            try CarefulFiles.read(path, owner: getuid(), maxBytes: ClaudeSessionFile.maxBytes).get()
        }
        #expect(throws: CarefulReadFailure.notOwned) { try CarefulFiles.read(path, owner: getuid() + 1, maxBytes: 10).get() }
    }

    @Test func pathsAreBuiltOnlyFromPlainNames() {
        #expect(CarefulPath(root: "/tmp", components: ["a", "b"]) != nil)
        #expect(CarefulPath(root: "/tmp", components: ["a/b"]) == nil)
        #expect(CarefulPath(root: "/tmp", components: [".."]) == nil)
        #expect(CarefulPath(root: "/tmp", components: [""]) == nil)
        #expect(CarefulPath(root: "relative", components: ["a"]) == nil)
        #expect(CarefulPath(root: "/tmp", components: ["a\u{0}b"]) == nil)
    }

    @Test func listsFolderEntriesWithTheirKinds() throws {
        let tree = FixtureTree()
        try tree.write("x", to: tree.root.appendingPathComponent("l/file.json"))
        try FileManager.default.createDirectory(at: tree.root.appendingPathComponent("l/sub"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: tree.root.appendingPathComponent("l/link"),
                                                   withDestinationURL: tree.root.appendingPathComponent("l/sub"))
        let path = try #require(CarefulPath(root: tree.root.path, components: ["l"]))
        let entries = try CarefulFiles.list(path, owner: getuid(), limit: 10).get()
        let kinds = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.kind) })
        #expect(kinds["file.json"] == .file && kinds["sub"] == .directory && kinds["link"] == .link)
    }
}

extension Result where Failure == CarefulReadFailure {
    func isFailure(_ expected: CarefulReadFailure) -> Bool {
        if case .failure(let failure) = self { return failure == expected }
        return false
    }
}
