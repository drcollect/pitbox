import AppKit
import Carbon.HIToolbox
import PitboxKit

/// Global hotkeys through Carbon `RegisterEventHotKey`: no Accessibility or Input Monitoring permission needed, and
/// the keystroke is consumed (the frontmost app never sees it). Each shortcut has an id; registering an id again
/// replaces it. When the keyboard layout changes, every shortcut is re-registered for the new key codes, and one that
/// failed before is tried again.
///
/// Carbon hot keys are shared by default: a plain registration succeeds even when another app holds the same keys, and
/// then both apps fire. With `exclusiveCheck: true` the manager first asks Carbon for an exclusive registration of the
/// keys (`kEventHotKeyExclusive`) and releases it at once: a refusal (`eventHotKeyExistsErr`) means another app holds
/// them, and the shortcut is not registered ("taken by another app", `Registration.isTakenByAnotherApp`) instead of
/// sharing silently. Free keys are then registered the plain way, as without the check.
///
/// ```swift
/// let hotkeys = HotkeyManager()
/// hotkeys.register(id: "park", spec: settings.hotkeys.park, exclusiveCheck: true) { parker.parkFrontmost() }
/// hotkeys.register(id: "fold", spec: settings.hotkeys.fold, exclusiveCheck: true) { block.toggleFold() }
/// ```
@MainActor
public final class HotkeyManager {
    /// The outcome of registering one shortcut.
    public struct Registration: Equatable, Sendable {
        public let id: String
        /// The shortcut string as given (for example "ctrl+opt+p").
        public let spec: String
        public let result: Result<KeyCombo, HotkeyError>
        /// Set when an enabled macOS shortcut uses the same keys (macOS wins; the hotkey will not fire).
        public let warning: String?

        public var combo: KeyCombo? { try? result.get() }

        /// True when the exclusive check found the keys held by another app (the shortcut is not registered).
        public var isTakenByAnotherApp: Bool {
            if case .failure(let error) = result { return error.isTakenByAnotherApp }
            return false
        }
    }

    /// Called after any registration changed (refresh menus).
    public var onRegistrationsChanged: (() -> Void)?

    /// Current registrations by id (including failed ones, with their error).
    public private(set) var registrations: [String: Registration] = [:]

    private struct Entry {
        let id: String
        let spec: String
        let combo: KeyCombo
        let keyCode: UInt32
        let exclusiveCheck: Bool
        let action: () -> Void
    }

    /// What a failed registration needs to be tried again.
    private struct Failed {
        let action: () -> Void
        let exclusiveCheck: Bool
    }

    private let carbon = CarbonHotKeys()
    private var entries: [UInt32: Entry] = [:]
    /// The action of each registration that failed, so a layout change (or `retryFailed()`) can try it again.
    private var failedActions: [String: Failed] = [:]
    private var nextCarbonID: UInt32 = 1
    private let layoutProvider: @MainActor () -> KeyboardLayoutMap
    private var layout: KeyboardLayoutMap
    private var layoutObserver: NSObjectProtocol?

    /// `layout` supplies the keyboard layout (injectable for tests).
    public init(layout: @escaping @MainActor () -> KeyboardLayoutMap = { KeyboardLayoutMap.current() }) {
        self.layoutProvider = layout
        self.layout = layout()
        carbon.onFire = { [weak self] id in self?.fire(carbonID: id) }
        layoutObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil,
            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyboardLayoutChanged() }
        }
    }

    deinit {
        if let layoutObserver { DistributedNotificationCenter.default().removeObserver(layoutObserver) }
    }

    /// Registers (or replaces) the shortcut `id`; `action` runs on the main thread when it is pressed. Returns the
    /// parsed combo or why it could not be registered (the failure is also kept in `registrations`).
    ///
    /// `exclusiveCheck`: first find out whether another app already holds the keys (an exclusive Carbon registration,
    /// released at once). If it does, the shortcut is not registered and fails with
    /// `.registrationFailed(eventHotKeyExistsErr)` ("already taken by another app"); `retryFailed()` or a layout change
    /// tries again. Without it the keys are registered as before, shared with any other holder.
    @discardableResult
    public func register(id: String, spec: String, exclusiveCheck: Bool = false,
                         action: @escaping () -> Void) -> Result<KeyCombo, HotkeyError> {
        let result = registerQuietly(id: id, spec: spec, exclusiveCheck: exclusiveCheck, action: action)
        onRegistrationsChanged?()
        return result
    }

    /// Tries every failed registration again that may succeed now (keys another app held, a key missing on the layout),
    /// for example when the status menu opens. Calls `onRegistrationsChanged` once when something was tried.
    public func retryFailed() {
        let retry = registrations.values.filter { Self.aLayoutMayFix($0.result) }
            .compactMap { registration in failedActions[registration.id].map { (registration.id, registration.spec, $0) } }
        guard !retry.isEmpty else { return }
        for (id, spec, failed) in retry {
            _ = registerQuietly(id: id, spec: spec, exclusiveCheck: failed.exclusiveCheck, action: failed.action)
        }
        onRegistrationsChanged?()
    }

    /// Removes the shortcut `id` (and its recorded result).
    public func unregister(id: String) {
        removeEntry(id: id)
        registrations[id] = nil
        failedActions[id] = nil
        onRegistrationsChanged?()
    }

    /// Removes every shortcut this manager registered.
    public func unregisterAll() {
        for carbonID in entries.keys { carbon.unregister(carbonID) }
        entries = [:]
        registrations = [:]
        failedActions = [:]
        onRegistrationsChanged?()
    }

    /// The combo registered for `id`, if registration succeeded.
    public func combo(for id: String) -> KeyCombo? { registrations[id]?.combo }

    // MARK: Private

    private func registerQuietly(id: String, spec: String, exclusiveCheck: Bool,
                                 action: @escaping () -> Void) -> Result<KeyCombo, HotkeyError> {
        removeEntry(id: id)
        let result = resolve(id: id, spec: spec).flatMap { combo, keyCode -> Result<KeyCombo, HotkeyError> in
            if exclusiveCheck {
                let probe = carbon.probeExclusive(keyCode: keyCode, modifiers: combo.carbonModifiers)
                if probe == OSStatus(eventHotKeyExistsErr) { return .failure(.registrationFailed(probe)) }
                if probe != noErr { Log.warn("hotkey \(id): exclusive check returned \(probe)", "shell") }
            }
            let carbonID = nextCarbonID
            nextCarbonID &+= 1
            let status = carbon.register(carbonID, keyCode: keyCode, modifiers: combo.carbonModifiers)
            guard status == noErr else { return .failure(.registrationFailed(status)) }
            entries[carbonID] = Entry(id: id, spec: spec, combo: combo, keyCode: keyCode, exclusiveCheck: exclusiveCheck,
                                      action: action)
            return .success(combo)
        }
        var warning: String?
        switch result {
        case .success(let combo):
            if let code = combo.keyCode(in: layout), let name = SystemShortcuts.conflict(keyCode: code, modifiers: combo.modifiers) {
                warning = "\(combo) is also the macOS shortcut “\(name)”, which takes precedence"
                Log.warn("hotkey \(id): \(warning ?? "")", "shell")
            }
            Log.info("hotkey \(id) = \(combo) (\(spec)) on \(layout.name)", "shell")
        case .failure(let error):
            Log.warn("hotkey \(id) '\(spec)' not registered: \(error)", "shell")
        }
        registrations[id] = Registration(id: id, spec: spec, result: result, warning: warning)
        failedActions[id] = result.isFailure ? Failed(action: action, exclusiveCheck: exclusiveCheck) : nil
        return result
    }

    private func resolve(id: String, spec: String) -> Result<(KeyCombo, UInt32), HotkeyError> {
        KeyCombo.parse(spec).flatMap { combo in
            if let other = entries.values.first(where: { $0.combo == combo && $0.id != id }) {
                return .failure(.duplicate(other.id))
            }
            guard let code = combo.keyCode(in: layout) else {
                if case .character(let c) = combo.key { return .failure(.notOnKeyboard(c)) }
                return .failure(.missingKey)
            }
            return .success((combo, code))
        }
    }

    private func removeEntry(id: String) {
        for (carbonID, entry) in entries where entry.id == id {
            carbon.unregister(carbonID)
            entries[carbonID] = nil
        }
    }

    private func fire(carbonID: UInt32) {
        guard let entry = entries[carbonID] else { return }
        entry.action()
    }

    /// Key codes of character keys depend on the layout: re-register everything that moved, and try the shortcuts that
    /// failed again (a key missing on the old layout may exist on the new one). Called by the input-source observer.
    func keyboardLayoutChanged() {
        let newLayout = layoutProvider()
        guard newLayout != layout else { return }
        layout = newLayout
        let current = entries.values.map { ($0.id, $0.spec, Failed(action: $0.action, exclusiveCheck: $0.exclusiveCheck)) }
        let failed = registrations.values.filter { Self.aLayoutMayFix($0.result) }
            .compactMap { registration in failedActions[registration.id].map { (registration.id, registration.spec, $0) } }
        for (id, spec, entry) in current + failed {
            _ = registerQuietly(id: id, spec: spec, exclusiveCheck: entry.exclusiveCheck, action: entry.action)
        }
        onRegistrationsChanged?()
    }

    /// Whether a failed registration may succeed on another layout (a missing key, or Carbon refusing the old key
    /// code). Spelling mistakes, reserved and duplicate combos fail on every layout, so they are not retried.
    static func aLayoutMayFix(_ result: Result<KeyCombo, HotkeyError>) -> Bool {
        guard case .failure(let error) = result else { return false }
        switch error {
        case .notOnKeyboard, .missingKey, .registrationFailed: return true
        default: return false
        }
    }
}

// MARK: - Carbon plumbing

private let hotKeySignature: OSType = 0x5042_484B // 'PBHK'
private let probeSignature: OSType = 0x5042_5850 // 'PBXP'

/// Owns the Carbon event handler and hotkey refs; cleans up when released.
private final class CarbonHotKeys {
    var onFire: ((UInt32) -> Void)?
    private var handler: EventHandlerRef?
    private var refs: [UInt32: EventHotKeyRef] = [:]

    func register(_ id: UInt32, keyCode: UInt32, modifiers: UInt32) -> OSStatus {
        if handler == nil {
            let status = installHandler()
            guard status == noErr else { return status }
        }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: hotKeySignature, id: id),
                                         GetEventDispatcherTarget(), 0, &ref)
        if status == noErr, let ref { refs[id] = ref }
        return status
    }

    func unregister(_ id: UInt32) {
        guard let ref = refs.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(ref)
    }

    /// Asks for an exclusive registration of the keys and releases it at once. `eventHotKeyExistsErr` means another
    /// registration holds them (another app's, or one of this process). Needs no event handler: the keys are held for
    /// microseconds and never fire.
    func probeExclusive(keyCode: UInt32, modifiers: UInt32) -> OSStatus {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: probeSignature, id: 0),
                                         GetEventDispatcherTarget(), OptionBits(kEventHotKeyExclusive), &ref)
        if status == noErr, let ref { UnregisterEventHotKey(ref) }
        return status
    }

    private func installHandler() -> OSStatus {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        return InstallEventHandler(GetEventDispatcherTarget(), carbonHotKeyCallback, 1, &spec,
                                   Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    fileprivate func deliver(_ id: UInt32) { onFire?(id) }

    deinit {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}

/// Carbon delivers hotkey events on the main thread's event loop.
private func carbonHotKeyCallback(_ next: EventHandlerCallRef?, _ event: EventRef?,
                                  _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr, hotKeyID.signature == hotKeySignature else { return OSStatus(eventNotHandledErr) }
    let box = Unmanaged<CarbonHotKeys>.fromOpaque(userData).takeUnretainedValue()
    let id = hotKeyID.id
    MainActor.assumeIsolated { box.deliver(id) }
    return noErr
}

private extension Result {
    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}
