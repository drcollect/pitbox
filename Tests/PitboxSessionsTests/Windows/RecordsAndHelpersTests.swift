import CoreGraphics
import Foundation
import Testing
@testable import PitboxSessions

@Suite("code-monitors.json, links, geometry")
struct RecordsAndHelpersTests {
    init() { CodeTileLog.enabled = false }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cm-records-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func record(_ id: String, at seconds: Double = 1_792_000_000) -> CodeParkedRecord {
        CodeParkedRecord(profile: "A", sessionID: id, pid: 501, windowNumber: 11, frame: CGRect(x: 10, y: 20, width: 900, height: 700),
                         displayID: 1, parkedAt: Date(timeIntervalSince1970: seconds))
    }

    // MARK: Records

    @Test func recordsRoundTripPrivatelyAndAtomically() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = CodeParkedRecordStore(url: dir.appendingPathComponent("code-monitors.json"))
        #expect(store.load().isEmpty)
        #expect(store.save([record("local_a"), record("local_b", at: 1_792_000_100)]))
        #expect(store.load() == [record("local_a"), record("local_b", at: 1_792_000_100)])
        let mode = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(store.save([record("local_c")]))
        #expect(store.load().map(\.sessionID) == ["local_c"])
        // No temporary file is left behind.
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names == ["code-monitors.json"])
        // Ids, numbers and frames only.
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any]
        let entry = (object?["parked"] as? [[String: Any]])?.first
        #expect(Set(entry?.keys.map { $0 } ?? []) == ["profile", "sessionId", "pid", "windowNumber", "frame", "displayID", "parkedAt"])
    }

    @Test func recordsAreReadTolerantly() {
        let text = #"""
        {"version": 1, "unknown": true, "parked": [
          {"profile": "A", "sessionId": "local_good", "pid": 501, "windowNumber": 11,
           "frame": {"x": 1, "y": 2, "w": 300, "h": 200}, "displayID": 1, "parkedAt": 1792000000, "extra": "ignored"},
          {"profile": "A", "sessionId": "local_good", "pid": 501, "windowNumber": 12,
           "frame": {"x": 1, "y": 2, "w": 300, "h": 200}, "displayID": 1, "parkedAt": 1792000500},
          {"profile": "A", "sessionId": "not-a-session", "pid": 501, "windowNumber": 11,
           "frame": {"x": 1, "y": 2, "w": 300, "h": 200}, "parkedAt": 1},
          {"profile": "A", "sessionId": "local_neg", "pid": -4, "windowNumber": 11,
           "frame": {"x": 1, "y": 2, "w": 300, "h": 200}, "parkedAt": 1},
          {"profile": "A", "sessionId": "local_noframe", "pid": 501, "windowNumber": 11, "parkedAt": 1},
          {"profile": "A", "sessionId": "local_zero", "pid": 501, "windowNumber": 11,
           "frame": {"x": 1, "y": 2, "w": 0, "h": 200}, "parkedAt": 1},
          "garbage", 7
        ]}
        """#
        let records = CodeParkedRecordStore.decode(Data(text.utf8))
        #expect(records.count == 1)
        #expect(records.first?.windowNumber == 12)   // the later of two entries for one session
        #expect(records.first?.displayID == 1)
        #expect(CodeParkedRecordStore.decode(Data("not json".utf8)).isEmpty)
        #expect(CodeParkedRecordStore.decode(Data(#"{"parked": 3}"#.utf8)).isEmpty)
    }

    @Test func aLinkOrAHugeFileIsNeverRead() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("elsewhere.json")
        try CodeParkedRecordStore.encode([record("local_a")]).write(to: real)
        let path = dir.appendingPathComponent("code-monitors.json")
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: real)
        #expect(CodeParkedRecordStore(url: path).load().isEmpty)
        try FileManager.default.removeItem(at: path)
        try Data(repeating: 0x20, count: CodeParkedRecordStore.maxBytes + 1).write(to: path)
        #expect(CodeParkedRecordStore(url: path).load().isEmpty)
    }

    // MARK: Links

    @Test func sessionIDsAreCheckedBeforeAnyLinkIsBuilt() {
        #expect(CodeDeepLink.isValidSessionID("local_abc-DEF-123"))
        #expect(CodeDeepLink.isValidSessionID("local_" + String(repeating: "a", count: 64)))
        #expect(!CodeDeepLink.isValidSessionID("local_" + String(repeating: "a", count: 65)))
        #expect(!CodeDeepLink.isValidSessionID("local_"))
        #expect(!CodeDeepLink.isValidSessionID("remote_abc"))
        #expect(!CodeDeepLink.isValidSessionID("local_a&b=c"))
        #expect(!CodeDeepLink.isValidSessionID("local_a/../b"))
        #expect(!CodeDeepLink.isValidSessionID("local_ab c"))
        #expect(!CodeDeepLink.isValidSessionID("local_é"))
        #expect(CodeDeepLink.continueURL(sessionID: "local_abc")?.absoluteString == "claude://code/continue?session=local_abc")
        #expect(CodeDeepLink.continueURL(sessionID: "local_a?x=1") == nil)
        #expect(CodeDeepLink.shareLink(sessionID: "local_abc") == "claude://claude.ai/epitaxy/local_abc")
        #expect(CodeDeepLink.shareLink(sessionID: "x") == nil)
    }

    // MARK: Restore geometry

    @Test func restoredFramesStayInsideTheVisibleFrameAndOutOfTheStrip() {
        let display = CodeDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 5120, height: 1440),
                                  visibleFrame: CGRect(x: 0, y: 30, width: 5120, height: 1312))
        let right = CGRect(x: 4096, y: 30, width: 1024, height: 1312)
        let area = CodeRestoreGeometry.usableArea(of: display, stripRects: [right])
        #expect(area == CGRect(x: 0, y: 30, width: 4096, height: 1312))
        // A strip on the left edge.
        let left = CGRect(x: 0, y: 30, width: 1024, height: 1312)
        #expect(CodeRestoreGeometry.usableArea(of: display, stripRects: [left]) == CGRect(x: 1024, y: 30, width: 4096, height: 1312))
        // Moved, not shrunk, when it fits; shrunk only when it must.
        #expect(CodeRestoreGeometry.clamp(CGRect(x: 3800, y: 100, width: 900, height: 700), into: area) == CGRect(x: 3196, y: 100, width: 900, height: 700))
        #expect(CodeRestoreGeometry.clamp(CGRect(x: -50, y: 0, width: 900, height: 700), into: area) == CGRect(x: 0, y: 30, width: 900, height: 700))
        #expect(CodeRestoreGeometry.clamp(CGRect(x: 10, y: 40, width: 6000, height: 2000), into: area) == area)
        // Untouched inside.
        let inside = CGRect(x: 200, y: 120, width: 900, height: 700)
        #expect(CodeRestoreGeometry.clamp(inside, into: area) == inside)
    }

    @Test func theDisplayIsTheParkedOneWhileItIsConnected() {
        let main = CodeDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), visibleFrame: CGRect(x: 0, y: 30, width: 2560, height: 1380))
        let other = CodeDisplay(id: 2, frame: CGRect(x: 2560, y: 0, width: 1920, height: 1080), visibleFrame: CGRect(x: 2560, y: 0, width: 1920, height: 1080))
        let frame = CGRect(x: 2700, y: 100, width: 800, height: 600)
        #expect(CodeRestoreGeometry.display(for: frame, preferredID: 1, displays: [main, other])?.id == 1)
        #expect(CodeRestoreGeometry.display(for: frame, preferredID: 9, displays: [main, other])?.id == 2)
        #expect(CodeRestoreGeometry.display(for: CGRect(x: 9000, y: 0, width: 10, height: 10), preferredID: nil, displays: [main, other])?.id == 1)
        #expect(CodeRestoreGeometry.displayID(for: frame, displays: [main, other]) == 2)
    }
}
