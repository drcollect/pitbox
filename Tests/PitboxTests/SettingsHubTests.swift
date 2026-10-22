import Foundation
import Testing
@testable import Pitbox
import PitboxKit
import PitboxSessions

/// The app's one source of truth for the settings: the box is set before anyone is told, every change is
/// handed out once, a late watcher report never undoes a newer write, a hand edit arrives.
@MainActor
@Suite("Settings hub", .serialized)
struct SettingsHubTests {
    @Test func aWriteIsInTheBoxBeforeAnyoneHearsOfIt() throws {
        let folder = ScratchFolder("hub-write")
        let hub = SettingsHub.load(url: folder.file("settings.json"))
        var heard: [(CodeSettings, CodeSettings, CodeSettings)] = []
        hub.onChange = { old, new in heard.append((old, new, hub.box.value)) }
        _ = try hub.write(.warningsStuck(false)).get()
        #expect(heard.count == 1)
        #expect(heard.first?.0.warnings.stuck == true && heard.first?.1.warnings.stuck == false)
        #expect(heard.first?.2.warnings.stuck == false, "the box already holds the new settings when the listener runs")
        #expect(hub.current.warnings.stuck == false)
        // The same value again: the file is rewritten, nobody is told twice.
        _ = try hub.write(.warningsStuck(false)).get()
        #expect(heard.count == 1)
        // A late watcher report re-reads the file: what the app wrote stays.
        hub.fileChanged()
        #expect(heard.count == 1 && hub.current.warnings.stuck == false)
    }

    /// A write made by the listener while it is told of a change (docking off flushing a held `folded`) is in the box at
    /// once and handed out right after the listener returns: the listener never ends on a value older than its own.
    @Test func aWriteFromInsideTheListenerIsHandedOutAfterItReturns() throws {
        let folder = ScratchFolder("hub-nested")
        let hub = SettingsHub.load(url: folder.file("settings.json"))
        var heard: [(old: Bool, new: Bool)] = []
        var finishedWith: [Bool] = []
        hub.onChange = { old, new in
            heard.append((old.folded, new.folded))
            if new.dock.enabled == false, new.folded {
                let before = heard.count
                _ = hub.write(.folded(false))   // nested: the box changes now, the listener hears of it later
                #expect(hub.current.folded == false && heard.count == before, "not handed out while the listener runs")
            }
            finishedWith.append(new.folded)
        }
        _ = try hub.write(.folded(true)).get()
        _ = try hub.write(.dockEnabled(false)).get()
        #expect(heard.map(\.new) == [true, true, false])
        #expect(heard.last?.old == true, "in order: the nested change follows the one it came from")
        #expect(finishedWith.last == false && hub.current.folded == false)
        #expect(CodeSettings.read(at: folder.file("settings.json"))?.folded == false)
    }

    @Test func aFailedWriteChangesNothing() throws {
        let folder = ScratchFolder("hub-fail")
        let url = folder.file("settings.json")
        let hub = SettingsHub.load(url: url)
        var heard = 0
        hub.onChange = { _, _ in heard += 1 }
        try folder.write(#"{"chime":"#, to: "settings.json")
        guard case .failure(.unreadable) = hub.write(.chime(true)) else {
            Issue.record("a broken file is never written")
            return
        }
        hub.fileChanged()
        #expect(heard == 0 && !hub.current.chime, "a broken file keeps the settings in force")
    }

    @Test func aHandEditArrivesThroughTheOneWatcher() async throws {
        let folder = ScratchFolder("hub-watch")
        let url = folder.file("settings.json")
        let hub = SettingsHub.load(url: url)
        var heard: [CodeSettings] = []
        hub.onChange = { _, new in heard.append(new) }
        hub.start(debounce: 0.05)
        defer { hub.stop() }
        try await Task.sleep(nanoseconds: 200_000_000)
        try folder.write(#"{"topGap":120,"keepAboveWindows":false}"#, to: "settings.json")
        #expect(await eventually(15) { heard.last?.topGap == 120 })
        #expect(hub.current.topGap == 120 && !hub.current.keepAboveWindows)
        // The app writes; the watcher was told, so the write is not handed out a second time.
        let count = heard.count
        _ = try hub.write(.bottomGap(40)).get()
        #expect(heard.count == count + 1)
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(heard.count == count + 1)
    }
}
