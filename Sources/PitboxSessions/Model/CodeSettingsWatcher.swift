import Darwin
import Foundation
import PitboxKit

/// Hand edits of the settings file apply at once: kernel events on the file and its folder
/// (`CodeFileWatcher`: written in place, replaced by a rename, created or deleted), coalesced for `debounce` seconds,
/// then the file is read again with the careful rules (`CodeStateFiles.readObject`, as `CodeSettings.loadOrCreate`).
/// A file that fails the read (broken JSON, a duplicated key, a link, another owner, too large) or went missing keeps
/// the last good settings and logs a label only; a readable file is decoded key by key (a wrong value gives that key's
/// default). A change reaches `onChange` on the main thread (the composition root hands it to `PitboxBlock.update`,
/// the desk tags, drag-to-park and the engine); unchanged settings are not handed out again. Nothing runs while the
/// file does not change. Thread-safe: `current` may be read from any thread (the engine's `settings` closure).
///
/// ```swift
/// let watcher = CodeSettingsWatcher(initial: CodeSettings.loadOrCreate()) { settings in block.update(settings: settings) }
/// watcher.start()                                          // quit: watcher.stop()
/// let environment = CodeSessionsEnvironment.live(settings: { watcher.current })
/// ```
public final class CodeSettingsWatcher: @unchecked Sendable {
    /// The file watched (`Paths.settingsFile`).
    public let url: URL
    private let debounce: TimeInterval
    private let owner: uid_t
    private let onChange: @MainActor (CodeSettings) -> Void
    private let queue = DispatchQueue(label: "pitbox.code.settings-watch", qos: .utility)
    private let lock = NSLock()
    private var settings: CodeSettings
    private var watcher: CodeFileWatcher?
    private var pending: DispatchWorkItem?
    private var running = false
    private var lastFailure: String?

    /// - Parameters:
    ///   - url: the settings file.
    ///   - initial: the settings read at launch (`CodeSettings.loadOrCreate`), the last good ones until a change.
    ///   - debounce: how long a burst of events is coalesced (an editor's save is several).
    ///   - onChange: called on the main thread with the settings after each change that reads well.
    public init(url: URL = CodeSettings.fileURL, initial: CodeSettings, debounce: TimeInterval = 0.25,
                owner: uid_t = getuid(), onChange: @escaping @MainActor (CodeSettings) -> Void) {
        self.url = url
        self.settings = initial
        self.debounce = debounce
        self.owner = owner
        self.onChange = onChange
    }

    deinit {
        let watcher = self.watcher
        queue.async { watcher?.stop() }
    }

    /// The last good settings.
    public var current: CodeSettings { lock.withLock { settings } }

    /// Starts watching (idempotent). The file is read again once now, so an edit between launch and `start` counts.
    public func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            watcher = CodeFileWatcher(file: url.path, queue: queue) { [weak self] in self?.changed() }
            reload()
        }
    }

    /// Stops watching; `current` keeps the last good settings.
    public func stop() {
        queue.async { [self] in
            running = false
            pending?.cancel()
            pending = nil
            watcher?.stop()
            watcher = nil
        }
    }

    /// The app wrote `settings` itself (`CodeSettings.apply`): they become the last good settings, so the watcher's next
    /// read compares the file with what the app wrote. A hand edit right after an app write that puts a key back is then
    /// still reported, and the app's own write is not handed out again.
    public func noteWritten(_ settings: CodeSettings) {
        lock.withLock { self.settings = settings }
    }

    /// Reads the file now (tests; a menu write that already returned the new settings needs no call).
    public func reloadNow() {
        queue.async { [self] in reload() }
    }

    /// Runs `done` on the watcher's queue after the work queued so far (tests).
    func flush(then done: @escaping @Sendable () -> Void) {
        queue.async { done() }
    }

    private func changed() {
        guard running else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            self.pending = nil
            self.reload()
        }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    private func reload() {
        let fresh: CodeSettings
        switch CodeStateFiles.readObject(at: url, owner: owner, maxBytes: CodeTuning.settingsReadMax) {
        case .success(let object):
            fresh = CodeSettings.decode(object: object)
            lastFailure = nil
        case .failure(let failure):
            if lastFailure != failure.label {
                lastFailure = failure.label
                Log.warn("settings: unreadable (\(failure.label)), keeping the last good ones", "code")
            }
            return
        }
        let changed: Bool = lock.withLock {
            guard fresh != settings else { return false }
            settings = fresh
            return true
        }
        guard changed else { return }
        Log.info("settings: changed on disk, applied", "code")
        let onChange = self.onChange
        DispatchQueue.main.async { MainActor.assumeIsolated { onChange(fresh) } }
    }
}
