import CoreGraphics
import Foundation
import Testing
@testable import Pitbox
import PitboxSessions

/// Whether a session's pop-out is the front window: window numbers, owners and layers only (no titles).
@Suite("Ready presence")
struct ReadyPresenceTests {
    static func window(_ number: CGWindowID, pid: pid_t, layer: Int = 0) -> [String: Any] {
        [kCGWindowNumber as String: number, kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: layer]
    }

    @Test func theFrontWindowIsTheFrontAppsFirstNormalWindow() {
        let desk = CodeDeskWindow(pid: 501, windowNumber: 42)
        let list = [Self.window(7, pid: 900, layer: 25), Self.window(9, pid: 501, layer: 3), Self.window(42, pid: 501),
                    Self.window(43, pid: 501)]
        #expect(ReadyPresence.isFrontWindow(desk, frontmostPID: 501, windows: list))
        #expect(!ReadyPresence.isFrontWindow(desk, frontmostPID: 777, windows: list), "another app is in front")
        #expect(!ReadyPresence.isFrontWindow(desk, frontmostPID: nil, windows: list))
        let behind = [Self.window(43, pid: 501), Self.window(42, pid: 501)]
        #expect(!ReadyPresence.isFrontWindow(desk, frontmostPID: 501, windows: behind), "another window of Claude is in front")
        #expect(!ReadyPresence.isFrontWindow(desk, frontmostPID: 501, windows: []))
    }
}
