import CoreGraphics
import Foundation
import PitboxKit

/// What the guest tells the host: its area, its counts, its mirrored drop claims, and the speech pause.
extension DockGuest {
    // MARK: Area

    /// The guest's panel after it applied a layout (`area`): its frame (AppKit global points), whether the rail shows,
    /// whether it is on screen. `seq` is the `place` it answers (default: the latest). Sent only while docked; the same
    /// report for the same `place` goes out once. Call it from the panel's area callback and once after each `onPlace`
    /// (an unchanged frame does not call the panel's callback), except while the panel shows alone at the edge.
    public func sendArea(frame: CGRect, folded: Bool, visible: Bool, seq: Int? = nil) {
        guard let session, handshake != nil, let place else { return }
        guard [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height].allSatisfy(\.isFinite),
              frame.width > 0, frame.height > 0 else { return }
        let report = AreaReport(seq: seq ?? place.seq, frame: frame, folded: folded, visible: visible)
        guard report != lastArea else { return }
        lastArea = report
        session.send(.area(seq: report.seq, frame: frame, folded: folded, visible: visible))
    }

    // MARK: Attention

    /// The counts on the rail (`attention`, feature `attention`): at most one message a second, the newest counts win,
    /// unchanged counts are not sent again. Kept while alone and sent when a host docks.
    public func sendAttention(needsYou: Int, finished: Int, running: Int) {
        let limit = DockWire.maxCount
        attentionLatest = AttentionCounts(needsYou: min(max(needsYou, 0), limit), finished: min(max(finished, 0), limit),
                                          running: min(max(running, 0), limit))
        flushAttention()
    }

    func flushAttention() {
        guard let session, let handshake, handshake.features.contains(.attention), let latest = attentionLatest,
              latest != attentionSent else { return }
        let now = clock.now()
        if let at = attentionSentAt, now - at < DockProtocol.attentionInterval - DockSession.epsilon {
            guard attentionTimer == nil else { return }
            attentionTimer = clock.after(at + DockProtocol.attentionInterval - now, on: .main) { [weak self] in
                MainActor.assumeIsolated {
                    self?.attentionTimer = nil
                    self?.flushAttention()
                }
            }
            return
        }
        attentionSent = latest
        attentionSentAt = now
        session.send(.attention(needsYou: latest.needsYou, finished: latest.finished, running: latest.running))
    }

    // MARK: Drop claims (feature guard.claims)

    /// Mirrors a drop claim of the guest's own registry to the host's guard: "leave this window alone for a moment".
    public func claim(pid: pid_t, windowNumber: UInt32) {
        guard pid > 0, claimsInUse else { return }
        session?.send(.claim(pid: pid, windowNumber: windowNumber))
    }

    /// Mirrors the end of a claim: parked (minimized) or not (the host's guard looks at the window again).
    public func release(pid: pid_t, windowNumber: UInt32, parked: Bool) {
        guard pid > 0, claimsInUse else { return }
        session?.send(.release(pid: pid, windowNumber: windowNumber, parked: parked))
    }

    /// Mirrors the left button going up during a drag.
    public func mouseUp() {
        guard claimsInUse else { return }
        session?.send(.mouseUp)
    }

    private var claimsInUse: Bool { session != nil && handshake?.features.contains(.guardClaims) == true }

    // MARK: Speech (feature speech)

    /// Asks the host to pause its listening before the guest speaks. Alone (no listed host app runs, or docking is
    /// off) the answer is `ok` at once. Docked: `speech.begin`, then the host's `ok` or `no`; no answer within
    /// `speechAnswerWait` is `no` (and a late `ok` is undone with `speech.end` at once). After an `ok` the app calls
    /// `endSpeech()` when the phrase ended; `speech.end` goes out at the latest `speechEndBackstop` after the `ok`.
    public func requestSpeech() async -> SpeechAnswer {
        guard let session, let handshake else {
            if !configuration.enabled || !listedHostRunning() { return .ok }
            return .no(.notDocked)
        }
        guard handshake.features.contains(.speech) else { return .no(.unsupported) }
        if case .hostNotResponding = state { return .no(.hostNotResponding) }
        guard pendingSpeech == nil else { return .no(.busy) }
        if activeSpeechID != nil { endSpeech() }
        let id = nextSpeechID
        nextSpeechID += 1
        session.send(.speechBegin(id: id))
        return await withCheckedContinuation { continuation in
            pendingSpeech = (id: id, continuation: continuation)
            speechAnswerTimer = clock.after(Self.speechAnswerWait, on: .main) { [weak self] in
                MainActor.assumeIsolated { self?.speechTimedOut(id) }
            }
        }
    }

    /// The phrase after an `ok` ended: `speech.end` (the host resumes listening). Nothing to do otherwise.
    public func endSpeech() {
        guard let id = activeSpeechID else { return }
        activeSpeechID = nil
        speechEndTimer?.cancel()
        speechEndTimer = nil
        session?.send(.speechEnd(id: id))
    }

    func speechOK(_ id: Int) {
        if let pending = pendingSpeech, pending.id == id {
            pendingSpeech = nil
            speechAnswerTimer?.cancel()
            speechAnswerTimer = nil
            activeSpeechID = id
            speechEndTimer = clock.after(Self.speechEndBackstop, on: .main) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.activeSpeechID == id else { return }
                    Log.info("dock: speech end sent by the backstop", "dock")
                    self.endSpeech()
                }
            }
            pending.continuation.resume(returning: .ok)
        } else if abandonedSpeech.remove(id) != nil {
            // The host paused for a request the guest already gave up on: let it resume at once.
            session?.send(.speechEnd(id: id))
        }
    }

    func speechNo(_ id: Int, why: DockSpeechNoReason) {
        if let pending = pendingSpeech, pending.id == id {
            pendingSpeech = nil
            speechAnswerTimer?.cancel()
            speechAnswerTimer = nil
            pending.continuation.resume(returning: .no(.host(why)))
        } else {
            abandonedSpeech.remove(id)
        }
    }

    private func speechTimedOut(_ id: Int) {
        guard let pending = pendingSpeech, pending.id == id else { return }
        pendingSpeech = nil
        speechAnswerTimer = nil
        abandonedSpeech.insert(id)
        Log.info("dock: no speech answer within \(Self.speechAnswerWait) s, not speaking", "dock")
        pending.continuation.resume(returning: .no(.timeout))
    }

    func answerPendingSpeech(_ answer: SpeechAnswer) {
        guard let pending = pendingSpeech else { return }
        pendingSpeech = nil
        speechAnswerTimer?.cancel()
        speechAnswerTimer = nil
        pending.continuation.resume(returning: answer)
    }
}
