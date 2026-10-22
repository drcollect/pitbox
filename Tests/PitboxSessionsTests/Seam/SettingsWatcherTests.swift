import Darwin
import Foundation
import Testing
@testable import PitboxSessions
import PitboxKit

/// Hand edits of the settings file apply at once: the watcher reads the file again after
/// kernel events, with the careful rules; a broken edit or a missing file keeps the last good settings.
@Suite("Settings watcher", .serialized)
struct SettingsWatcherTests {
    /// A watcher over `url` whose changes land in `changes`.
    static func watcher(_ url: URL, initial: CodeSettings = CodeSettings(),
                        changes: Shared<[CodeSettings]>) -> CodeSettingsWatcher {
        CodeSettingsWatcher(url: url, initial: initial, debounce: 0.05) { settings in changes.value.append(settings) }
    }

    /// Writes `text` in place (an editor that truncates and writes), 0600.
    static func writeInPlace(_ text: String, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        let bytes = Array(text.utf8)
        guard write(fd, bytes, bytes.count) == bytes.count else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Replaces the file by a rename (how most editors and the app's own writer save).
    static func replaceAtomically(_ text: String, at url: URL) throws {
        try CodeStateFiles.writeAtomically(Data(text.utf8), to: url)
    }

    /// Waits until the watcher's queue has run what was queued so far.
    static func settle(_ watcher: CodeSettingsWatcher) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in watcher.flush { done.resume() } }
    }

    @Test func handEditsApplyAtOnceInPlaceOrByRename() async throws {
        let folder = SeamFolder("settings-watch")
        let url = folder.file("settings.json")
        try Self.writeInPlace(#"{"chime":false}"#, to: url)
        let changes = Shared<[CodeSettings]>([])
        let watcher = Self.watcher(url, changes: changes)
        watcher.start()
        defer { watcher.stop() }
        await Self.settle(watcher)
        #expect(changes.value.isEmpty, "the file as at launch: nothing new")

        // The watcher's own state first, then the main-thread delivery: under a full parallel run other suites can hold
        // the main thread for seconds, so the deadlines are generous.
        try Self.writeInPlace(#"{"chime":true,"columns":1}"#, to: url)
        #expect(await eventually(15) { watcher.current.chime })
        #expect(await eventually(15) { changes.value.last?.chime == true })
        #expect(watcher.current.chime && watcher.current.columns == 1)

        try Self.replaceAtomically(#"{"chime":true,"columns":1,"edge":"left"}"#, at: url)
        #expect(await eventually(15) { watcher.current.edge == .left }, "a replaced file is watched again")
        #expect(await eventually(15) { changes.value.last?.edge == .left })

        // And again after the replace: the new file is the one watched.
        try Self.writeInPlace(#"{"chime":false,"edge":"left"}"#, to: url)
        #expect(await eventually(15) { !watcher.current.chime })
        #expect(await eventually(15) { changes.value.last?.chime == false })
        #expect(changes.value.count == 3, "one change per edit, a burst coalesced")
    }

    @Test func aBrokenEditOrAMissingFileKeepsTheLastGoodSettings() async throws {
        let folder = SeamFolder("settings-broken")
        let url = folder.file("settings.json")
        try Self.writeInPlace(#"{"sayIt":true}"#, to: url)
        let changes = Shared<[CodeSettings]>([])
        let watcher = Self.watcher(url, changes: changes)
        watcher.start()
        defer { watcher.stop() }
        #expect(await eventually { changes.value.last?.sayIt == true }, "an edit before start counts")

        try Self.writeInPlace(#"{"sayIt":false,"#, to: url)           // half a save
        try await Task.sleep(nanoseconds: 300_000_000)
        await Self.settle(watcher)
        #expect(watcher.current.sayIt && changes.value.count == 1, "broken JSON: the last good settings stay")

        try Self.writeInPlace(#"{"sayIt":false,"sayIt":true}"#, to: url)   // a duplicated key fails the careful read
        try await Task.sleep(nanoseconds: 300_000_000)
        await Self.settle(watcher)
        #expect(watcher.current.sayIt && changes.value.count == 1)

        try FileManager.default.removeItem(at: url)
        try await Task.sleep(nanoseconds: 300_000_000)
        await Self.settle(watcher)
        #expect(watcher.current.sayIt && changes.value.count == 1, "a missing file is no reason to reset")

        try Self.writeInPlace(#"{"sayIt":false}"#, to: url)           // the file comes back
        #expect(await eventually { changes.value.last?.sayIt == false })
    }

    @Test func aLinkIsNeverFollowed() async throws {
        let folder = SeamFolder("settings-link")
        let url = folder.file("settings.json")
        let target = folder.file("elsewhere.json")
        try Self.writeInPlace(#"{"chime":true}"#, to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        let changes = Shared<[CodeSettings]>([])
        let watcher = Self.watcher(url, changes: changes)
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(nanoseconds: 300_000_000)
        await Self.settle(watcher)
        #expect(changes.value.isEmpty && !watcher.current.chime)
    }

    @Test func stoppedItHearsNothing() async throws {
        let folder = SeamFolder("settings-stop")
        let url = folder.file("settings.json")
        try Self.writeInPlace("{}", to: url)
        let changes = Shared<[CodeSettings]>([])
        let watcher = Self.watcher(url, changes: changes)
        watcher.start()
        await Self.settle(watcher)
        watcher.stop()
        await Self.settle(watcher)
        try Self.writeInPlace(#"{"chime":true}"#, to: url)
        try await Task.sleep(nanoseconds: 300_000_000)
        await Self.settle(watcher)
        #expect(changes.value.isEmpty && !watcher.current.chime)
    }

    @MainActor
    @Test func theBlockFollowsAWatchedEdit() async throws {
        let folder = SeamFolder("settings-block")
        let url = folder.file("settings.json")
        try Self.writeInPlace(#"{"look":"monitors"}"#, to: url)
        let h = TileHarness()
        let block = PitboxBlock(model: h.model)
        let watcher = CodeSettingsWatcher(url: url, initial: CodeSettings.loadOrCreate(at: url), debounce: 0.05) { settings in
            block.update(settings: settings)
        }
        watcher.start()
        defer { watcher.stop() }
        h.set([tileSession("local_a", "A")])
        #expect(h.model.snapshot.look == .monitors)
        try Self.writeInPlace(#"{"look":"rows"}"#, to: url)
        #expect(await eventually { h.model.snapshot.look == .rows }, "the monitors redraw as slim rows at once")
        #expect(block.settings.look == .rows)
    }
}
