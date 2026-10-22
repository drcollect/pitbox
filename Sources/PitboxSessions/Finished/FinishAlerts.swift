import AppKit
import Foundation
import PitboxKit

/// On-device speech for "Say it", from the composition root (the package imports PitboxKit only): the phrase is
/// spoken in the on-device system voice, never through a cloud voice that would send the text off the Mac.
public struct CodeOwnSpeech {
    /// Pauses a docked host's listener and returns true once it reports paused; false: nothing is said, and
    /// `endOwnSpeech` follows at once to undo a pause begin asked for before giving up.
    public var beginOwnSpeech: @MainActor () async -> Bool
    /// Speaks `phrase` as plain text (never SSML) in the on-device system voice for en-US
    /// (the app's on-device voice) and returns when the synthesizer reports finished.
    public var speak: @MainActor (_ phrase: String) async -> Void
    /// Resumes a docked host's listener; called `CodeTuning.speechResumeDelay` (0.5 s) after the phrase ended, or at
    /// once when `beginOwnSpeech` returned false.
    public var endOwnSpeech: @MainActor () -> Void

    public init(beginOwnSpeech: @escaping @MainActor () async -> Bool, speak: @escaping @MainActor (String) async -> Void,
                endOwnSpeech: @escaping @MainActor () -> Void) {
        self.beginOwnSpeech = beginOwnSpeech; self.speak = speak; self.endOwnSpeech = endOwnSpeech
    }
}

/// The finish chime: the system sound "Hero", not "Glass", so it is not taken for a meeting reminder.
public enum CodeFinishChime {
    public static let soundName = "Hero"

    /// Plays the chime (the composition root passes this as `CodeReadyEnvironment.chime`).
    @MainActor public static func play() {
        NSSound(named: soundName)?.play()
    }
}

/// The chime and "Say it" when work finishes, both off by default. Main thread.
///
/// - A finish alerts once: a live mark (`CodeFinishedMark.silent` false), open, with an item. Under the user's eyes it
///   does not: a desk pop-out whose window is the key window of the frontmost app with input in the last 60 s gets no
///   item and no sound (its record is closed); a main-window session while Claude is frontmost with recent input keeps
///   its card, without a sound (the app cannot tell which session the main window shows).
/// - Finishes within `alertGather` make one alert ("3 Code sessions are done"); later ones within `alertCoalesce` (20 s)
///   of an alert join it silently; at most one phrase per `sayMinInterval` (30 s).
/// - Never while the screen is locked or the displays sleep (`canSpeakNow`), while a docked host's conversation or
///   dictation holds the audio (`beginOwnSpeech` answers false), or while the user is away (idle past
///   `recapAfterMinutes`): skipped, not queued; the item waits in Ready.
/// - Speaking is three steps: `beginOwnSpeech` (nothing is said unless it reports the listener paused), the phrase,
///   `endOwnSpeech` 0.5 s after it ended. One phrase at a time.
@MainActor
final class CodeFinishAlerts {
    /// Finishes this close together become one alert with their count.
    static let alertGather: TimeInterval = 1.5

    private let environment: CodeReadyEnvironment
    private let memory: CodeMemoryStore
    private var settings: CodeSettings
    /// "<session id>:<reply uuid>" of every finish looked at in this run.
    private var handled: Set<String> = []
    private var pending: [String] = []
    private var gathering = false
    private var lastAlertAt: Date?
    private var lastPhraseAt: Date?
    private var speaking = false

    /// The bezel pulses green 3 times at a live finish: the block's monitor.
    var onFinishPulse: ((String) -> Void)?
    /// Wake words a dock host announced (its `hello`, docs/DOCK_PROTOCOL.md §5.3): never said, like `neverSay`. Empty
    /// alone.
    var hostWakeWords: Set<String> = []

    /// What the spoken line never says: the settings file's `neverSay` and the host's wake words.
    var neverSay: [String] { settings.neverSay + hostWakeWords.sorted() }

    init(environment: CodeReadyEnvironment, memory: CodeMemoryStore, settings: CodeSettings) {
        self.environment = environment
        self.memory = memory
        self.settings = settings
    }

    func update(settings: CodeSettings) { self.settings = settings }

    /// The sessions after a publication with how each is followed: new live finishes alert.
    func observe(_ sessions: [CodeSessionSnapshot], followed: CodeFollowedSet) {
        let recentInput = (environment.idleSeconds() ?? .infinity) < CodeTuning.lookingInputWindow
        for session in sessions {
            guard let follow = followed.kind(of: session.id), let mark = session.finished, mark.isOpen, mark.hasItem,
                  !mark.silent, handled.insert(session.id + ":" + mark.replyUUID).inserted else { continue }
            switch follow {
            case .desk where recentInput && environment.isKeyWindow(session.id):
                CodeFinishedRecords.close(mark.replyUUID, session: session.id, memory: memory)
                CodeTileLog.info("finished session=#\(session.index) alert=none reason=looking")
                continue
            case .recentUsed, .recentOwn:
                if recentInput && environment.claudeIsFrontmost() {
                    CodeTileLog.info("finished session=#\(session.index) alert=none reason=claude-in-front")
                    continue
                }
            case .desk, .parked:
                break
            }
            if !follow.isRecent { onFinishPulse?(session.id) }
            pending.append(session.headline)
            CodeTileLog.info("finished session=#\(session.index) ran_s=\(Int(mark.ranSeconds.rounded())) alert=pending")
        }
        guard !pending.isEmpty, !gathering else { return }
        gathering = true
        environment.schedule(Self.alertGather) { [weak self] in self?.fire() }
    }

    /// One alert for the finishes gathered.
    func fire() {
        gathering = false
        let headlines = pending
        pending = []
        guard !headlines.isEmpty else { return }
        let now = environment.clock()
        if let last = lastAlertAt, now.timeIntervalSince(last) < CodeTuning.alertCoalesce {
            CodeTileLog.info("finish alert joined count=\(headlines.count)")
            return
        }
        guard settings.chime || settings.sayIt else { return }
        if let reason = quietReason() {
            CodeTileLog.info("finish alert skipped reason=\(reason) count=\(headlines.count)")
            return
        }
        lastAlertAt = now
        if settings.chime, let chime = environment.chime {
            chime()
            CodeTileLog.info("finish alert=chime count=\(headlines.count)")
        }
        guard settings.sayIt else { return }
        if let last = lastPhraseAt, now.timeIntervalSince(last) < CodeTuning.sayMinInterval {
            CodeTileLog.info("finish phrase skipped reason=interval")
            return
        }
        lastPhraseAt = now
        say(CodeSpokenPhrase.finished(headlines: headlines, sayHeadlines: settings.sayHeadlines, neverSay: neverSay))
    }

    /// The recap's read-out: counts only, same voice and conditions.
    func sayRecap(_ recap: CodeAwayRecap.Recap) {
        guard settings.sayIt, quietReason() == nil,
              let phrase = CodeSpokenPhrase.recap(finished: recap.count(.finished), waiting: recap.count(.waiting),
                                                  running: recap.count(.running)) else { return }
        let now = environment.clock()
        if let last = lastPhraseAt, now.timeIntervalSince(last) < CodeTuning.sayMinInterval { return }
        lastPhraseAt = now
        say(phrase)
    }

    /// Why no sound may play now, nil when it may (labels for the log).
    private func quietReason() -> String? {
        if !environment.canSpeakNow() { return "busy" }
        if environment.screenLocked() { return "locked" }
        if let idle = environment.idleSeconds(), idle >= TimeInterval(settings.recapAfterMinutes) * 60 { return "away" }
        return nil
    }

    /// The three steps of speaking.
    private func say(_ phrase: String) {
        guard let speech = environment.speech, !speaking else { return }
        speaking = true
        let schedule = environment.schedule
        Task { @MainActor [weak self] in
            guard await speech.beginOwnSpeech() else {
                // begin may have asked for the pause before giving up: undo it, or the host's listener stays paused.
                speech.endOwnSpeech()
                self?.speaking = false
                CodeTileLog.info("finish phrase skipped reason=listener")
                return
            }
            await speech.speak(phrase)
            CodeTileLog.info("finish alert=voice")
            // The listener paused: it resumes whatever happens to this object meanwhile.
            schedule(CodeTuning.speechResumeDelay) {
                speech.endOwnSpeech()
                self?.speaking = false
            }
        }
    }
}
