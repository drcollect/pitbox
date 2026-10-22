import Foundation
import os
import PitboxKit
import PitboxSessions

/// The settings in force, readable from any thread (the session engine reads them on its own queue). Only `SettingsHub`
/// changes them.
final class SettingsBox: @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<CodeSettings>

    init(_ settings: CodeSettings) { lock = OSAllocatedUnfairLock(initialState: settings) }

    /// The settings in force now.
    var value: CodeSettings { lock.withLock { $0 } }

    fileprivate func set(_ settings: CodeSettings) { lock.withLock { $0 = settings } }
}

/// The app's one source of truth for `settings.json`: one watcher on the file, one box holding the settings
/// in force, and one way in for both directions.
///
/// - **The app writes** (`write`): `CodeSettings.apply` (the careful read-change-write), then the result goes into the
///   box BEFORE anyone is told, so the engine's settings closure (`box.value`) already reads it when the block reloads
///   the engine; the watcher is told what the app wrote (`noteWritten`), so it reports only edits made after it.
/// - **The file changes** (`CodeSettingsWatcher`, kernel events, 0.25 s debounce): the watcher's report is only a
///   trigger; the hub reads the file again here, on the main thread, so a late report can never undo a newer write.
/// - Every change is deduplicated against the box and handed out once, as (old, new), on the main thread, in order. A
///   write made by the listener while it is being told of a change (docking turned off flushes a held `folded`) goes
///   into the box at once and is handed out right after the listener returns, so no listener ever finishes applying a
///   value older than one it already caused.
@MainActor
final class SettingsHub {
    /// The file (`Paths.settingsFile`; tests use a scratch one).
    let url: URL
    /// The settings in force (the engine's environment reads it from its queue).
    let box: SettingsBox
    /// Called on the main thread after the settings in force changed, with the old and the new ones.
    var onChange: ((_ old: CodeSettings, _ new: CodeSettings) -> Void)?
    private var watcher: CodeSettingsWatcher?
    /// The settings last handed to `onChange` (the box may be ahead while a notification runs).
    private var handedOut: CodeSettings
    /// True while `onChange` runs.
    private var notifying = false

    /// - Parameter initial: the settings read at launch (`CodeSettings.loadOrCreate`).
    init(url: URL = CodeSettings.fileURL, initial: CodeSettings) {
        self.url = url
        box = SettingsBox(initial)
        handedOut = initial
    }

    /// Reads the file (writing the defaults once when it is missing) and makes the hub over it.
    static func load(url: URL = CodeSettings.fileURL) -> SettingsHub {
        SettingsHub(url: url, initial: CodeSettings.loadOrCreate(at: url))
    }

    /// The settings in force.
    var current: CodeSettings { box.value }

    /// Starts watching the file (idempotent; the file is read again once now).
    func start(debounce: TimeInterval = 0.25) {
        guard watcher == nil else { return }
        let watcher = CodeSettingsWatcher(url: url, initial: box.value, debounce: debounce) { [weak self] _ in
            self?.fileChanged()
        }
        self.watcher = watcher
        watcher.start()
    }

    /// Stops watching (quit); the box keeps the settings in force.
    func stop() {
        watcher?.stop()
        watcher = nil
    }

    /// Writes one change through the careful writer; on success the box and every listener have the result before this
    /// returns, except for a write made from inside `onChange`: the listener hears of it right after it returns.
    @discardableResult
    func write(_ change: CodeSettings.MenuChange) -> Result<CodeSettings, CodeSettings.WriteFailure> {
        let result = CodeSettings.apply(change, at: url)
        if case .success(let fresh) = result {
            watcher?.noteWritten(fresh)
            accept(fresh)
        }
        return result
    }

    /// The watcher saw the file change: read it again now; a file that fails the read keeps the settings in force.
    func fileChanged() {
        guard let fresh = CodeSettings.read(at: url) else { return }
        accept(fresh)
    }

    /// New settings: into the box, then out to the listener, once per change and in order. A change accepted while the
    /// listener runs is handed out by the running loop once the listener returns.
    private func accept(_ fresh: CodeSettings) {
        guard fresh != box.value else { return }
        box.set(fresh)
        guard !notifying else { return }
        notifying = true
        defer { notifying = false }
        while box.value != handedOut {
            let old = handedOut
            let new = box.value
            handedOut = new
            onChange?(old, new)
        }
    }
}
