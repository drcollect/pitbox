import Darwin
import Foundation
import PitboxKit

/// The one-time hint under the header: the first time a window goes into the pit, one line says what that means, and
/// never again. Whether it was shown is remembered in `block-state.json` in the app-support folder
/// (`{"pitHintShown": true}`), read with the state files' care and written atomically; other keys there are kept. With
/// no file (`url` nil, tests and previews) it is remembered for this run only.
@MainActor
final class CodePitHint {
    /// The words.
    static let text = "In the pit: the window is minimized, the session keeps running. Click it to go back on track."
    /// How long the line stays once shown.
    static let duration: TimeInterval = 30
    static let key = "pitHintShown"

    private let url: URL?
    private(set) var wasShown: Bool
    /// When the line goes away (nil: not showing).
    private(set) var showingUntil: Date?
    /// The first look's time: a window that went into the pit before it (parked before a restart) is no new pit stop.
    private var armedAt: Date?

    init(url: URL?) {
        self.url = url
        guard let url else {
            wasShown = false
            return
        }
        switch CodeStateFiles.readObject(at: url, owner: getuid(), maxBytes: CodeTuning.settingsReadMax) {
        case .success(let object): wasShown = object[Self.key]?.boolValue ?? false
        case .failure(.missing): wasShown = false
        case .failure(let failure):
            // An unreadable file: say nothing rather than repeat the hint on every launch.
            CodeTileLog.info("pit hint state unreadable (\(failure.label))")
            wasShown = true
        }
    }

    /// Called on every rebuild with when each window now in the pit went in (`CodeWindowPlace.parked(since:)`): true
    /// while the line shows at `now`.
    func update(parkedSince: [Date], now: Date) -> Bool {
        let armedAt = self.armedAt ?? now
        self.armedAt = armedAt
        if let until = showingUntil {
            if until > now { return true }
            showingUntil = nil
        }
        guard !wasShown, parkedSince.contains(where: { $0 >= armedAt }) else { return false }
        wasShown = true
        showingUntil = now.addingTimeInterval(Self.duration)
        remember()
        CodeTileLog.info("pit hint shown")
        return true
    }

    private func remember() {
        guard let url else { return }
        var object: [String: JSONValue] = [:]
        switch CodeStateFiles.readObject(at: url, owner: getuid(), maxBytes: CodeTuning.settingsReadMax) {
        case .success(let read): object = read
        case .failure(.missing): break
        case .failure(let failure):
            CodeTileLog.info("pit hint state not written (\(failure.label))")
            return
        }
        object[Self.key] = .bool(true)
        guard let data = CodeStateFiles.serialize(object, pretty: true) else { return }
        do {
            try CodeStateFiles.writeAtomically(data, to: url)
        } catch {
            CodeTileLog.info("pit hint state not written (\((error as? CodeStateFiles.WriteFailure)?.label ?? "error"))")
        }
    }
}
