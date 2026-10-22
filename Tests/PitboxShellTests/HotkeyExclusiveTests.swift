import AppKit
import Carbon.HIToolbox
import Testing
@testable import PitboxShell

/// The exclusive check (a probe with an exclusive Carbon registration, released at once) with real Carbon
/// registrations, on hyper+F15 only (the other hotkey tests use F16-F18). Every registration is released in `defer`.
@Suite @MainActor struct HotkeyExclusiveTests {
    private static let hyper = UInt32(controlKey | optionKey | shiftKey | cmdKey)

    /// Holds hyper+F15 with a plain registration, the way another app would (Carbon refuses an exclusive registration
    /// over any existing one, in this process or another).
    private static func holdF15() -> EventHotKeyRef? {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(kVK_F15), hyper, EventHotKeyID(signature: 0x5054_4F54, id: 1),
                                         GetEventDispatcherTarget(), 0, &ref)
        return status == noErr ? ref : nil
    }

    /// An exclusive probe of hyper+F15: noErr when nothing holds it.
    private static func probeF15() -> OSStatus {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(kVK_F15), hyper, EventHotKeyID(signature: 0x5054_4F54, id: 2),
                                         GetEventDispatcherTarget(), OptionBits(kEventHotKeyExclusive), &ref)
        if status == noErr, let ref { UnregisterEventHotKey(ref) }
        return status
    }

    @Test func freeKeysAreRegisteredAfterTheCheck() throws {
        let manager = HotkeyManager(layout: { .ansi })
        defer { manager.unregisterAll() }
        try #require(Self.probeF15() == noErr, "hyper+F15 must be free for this test")
        let result = manager.register(id: "fold", spec: "hyper+f15", exclusiveCheck: true) {}
        #expect((try? result.get())?.key == .named(.f15))
        #expect(manager.registrations["fold"]?.isTakenByAnotherApp == false)
        // The manager now holds the keys (plainly): an exclusive probe is refused.
        #expect(Self.probeF15() == OSStatus(eventHotKeyExistsErr))
        // Re-registering the same id releases its own hold first, so the check does not see itself.
        #expect((try? manager.register(id: "fold", spec: "hyper+f15", exclusiveCheck: true) {}.get()) != nil)
        manager.unregister(id: "fold")
        #expect(Self.probeF15() == noErr, "released")
    }

    @Test func keysHeldElsewhereAreReportedTakenNotShared() throws {
        let manager = HotkeyManager(layout: { .ansi })
        defer { manager.unregisterAll() }
        var hold = Self.holdF15()
        defer { if let hold { UnregisterEventHotKey(hold) } }
        try #require(hold != nil)
        var changes = 0
        manager.onRegistrationsChanged = { changes += 1 }

        let result = manager.register(id: "park", spec: "hyper+f15", exclusiveCheck: true) {}
        guard case .failure(let error) = result else {
            Issue.record("a held key was registered")
            return
        }
        #expect(error == .registrationFailed(Int32(eventHotKeyExistsErr)))
        #expect(error.isTakenByAnotherApp)
        #expect(error.description == "already taken by another app")
        let registration = try #require(manager.registrations["park"])
        #expect(registration.isTakenByAnotherApp && registration.combo == nil)
        #expect(changes == 1)

        // Still held: a retry changes nothing but tries.
        manager.retryFailed()
        #expect(manager.registrations["park"]?.isTakenByAnotherApp == true)
        #expect(changes == 2)

        // The other holder lets go: the next retry (the menu opening) gets the keys.
        if let held = hold { UnregisterEventHotKey(held) }
        hold = nil
        manager.retryFailed()
        #expect(manager.combo(for: "park")?.key == .named(.f15))
        #expect(manager.registrations["park"]?.isTakenByAnotherApp == false)
        #expect(Self.probeF15() == OSStatus(eventHotKeyExistsErr), "now the manager holds them")
    }

    @Test func withoutTheCheckRegistrationIsAsBefore() {
        let manager = HotkeyManager(layout: { .ansi })
        defer { manager.unregisterAll() }
        let result = manager.register(id: "plain", spec: "hyper+f15") {}
        #expect((try? result.get()) != nil)
        #expect(manager.registrations["plain"]?.isTakenByAnotherApp == false)
    }

    @Test func retryLeavesFailuresNoRetryCanFixAlone() {
        let manager = HotkeyManager(layout: { .ansi })
        defer { manager.unregisterAll() }
        var changes = 0
        manager.onRegistrationsChanged = { changes += 1 }
        manager.register(id: "bad", spec: "ctrl+banana", exclusiveCheck: true) {}
        manager.register(id: "reserved", spec: "cmd+space", exclusiveCheck: true) {}
        #expect(changes == 2)
        manager.retryFailed()
        #expect(changes == 2, "spelling and reserved combos are not tried again")
        #expect(!HotkeyError.duplicate("x").isTakenByAnotherApp)
        #expect(!HotkeyError.registrationFailed(-50).isTakenByAnotherApp)
    }
}

@Suite struct PresenceProbeTests {
    @Test func idleTimeIsReadable() {
        let idle = PresenceProbe.hidIdleSeconds()
        #expect(!idle.isNaN)
        #expect(idle >= 0)
    }

    @Test func lockStateIsReadableAndFollowsTheRule() {
        let locked = PresenceProbe.screenLocked()
        #expect(locked == PresenceProbe.sessionLocked(CGSessionCopyCurrentDictionary() as? [String: Any]))
    }

    @Test func unknownCountsAsLocked() {
        #expect(PresenceProbe.sessionLocked(nil))
        #expect(PresenceProbe.sessionLocked(["kCGSSessionOnConsoleKey": false]))
        #expect(PresenceProbe.sessionLocked(["kCGSSessionOnConsoleKey": true, "CGSSessionScreenIsLocked": true]))
        #expect(PresenceProbe.sessionLocked(["CGSSessionScreenIsLocked": NSNumber(value: 1)]))
        #expect(!PresenceProbe.sessionLocked(["kCGSSessionOnConsoleKey": true]))
        #expect(!PresenceProbe.sessionLocked([:]), "the lock flag is absent while unlocked")
        #expect(!PresenceProbe.sessionLocked(["kCGSSessionOnConsoleKey": true, "CGSSessionScreenIsLocked": false]))
    }
}
