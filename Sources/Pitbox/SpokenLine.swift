import AVFoundation
import Foundation

/// The block's spoken line ("… is done", "Say it"): the Mac's on-device system voice, plain text, never
/// a cloud voice. `speak` returns when the synthesizer reports the end (or a cancel), so whoever paused a listener for it
/// resumes only afterwards; a phrase that never reports back is ended after `maxSeconds`, so nothing waits on it for
/// ever. Alone nothing of a host listens, so the app speaks directly (`beginOwnSpeech` answers true at once).
@MainActor
final class SpokenLine: NSObject, AVSpeechSynthesizerDelegate {
    /// The longest a phrase may take before it counts as finished (a short headline takes 2-4 s).
    static let maxSeconds: TimeInterval = 15

    private let synthesizer = AVSpeechSynthesizer()
    private var finish: CheckedContinuation<Void, Never>?
    /// The utterance `finish` waits for: a late callback of an earlier one never ends a newer phrase.
    private var current: ObjectIdentifier?
    private var generation = 0

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Speaks `phrase` in the en-US system voice and returns when it has been said (or stopped, or timed out).
    func speak(_ phrase: String) async {
        synthesizer.stopSpeaking(at: .immediate)
        end(nil)
        generation &+= 1
        let mine = generation
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            finish = continuation
            let utterance = AVSpeechUtterance(string: phrase)
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            current = ObjectIdentifier(utterance)
            synthesizer.speak(utterance)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.maxSeconds * 1_000_000_000))
                guard let self, self.generation == mine else { return }
                self.synthesizer.stopSpeaking(at: .immediate)
                self.end(nil)
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.end(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.end(id) }
    }

    /// Ends the waiting phrase: any phrase for nil (a new phrase, the time limit), else only the utterance named.
    private func end(_ utterance: ObjectIdentifier?) {
        if let utterance, utterance != current { return }
        let continuation = finish
        finish = nil
        current = nil
        continuation?.resume()
    }
}
