import AppKit
import CoreGraphics
import PitboxSessions
import PitboxShell

/// The Ready list's view of the person and the screen: HID idle time, the session lock and display sleep, whether a
/// session's pop-out is the front window, whether Claude is the front app, the chime, and Say it. Window numbers and
/// pids only: no titles, no Screen Recording.
enum ReadyPresence {
    /// The Ready list's environment. Say it asks `gate` before it speaks: alone it answers at once, docked the dock
    /// link's speech pause decides (`DockWiring.speechGate`).
    @MainActor
    static func live(parker: CodeWindowParker, engine: CodeSessionsEngine, voice: SpokenLine,
                     gate: SpeechGate = .alone) -> CodeReadyEnvironment {
        var ready = CodeReadyEnvironment()
        ready.idleSeconds = { PresenceProbe.hidIdleSeconds() }
        ready.screenLocked = { away() }
        ready.canSpeakNow = { !away() }
        ready.isKeyWindow = { [weak parker] sessionID in
            guard let desk = parker?.deskWindows[sessionID] else { return false }
            return isFrontWindow(desk, frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                 windows: onScreenWindows())
        }
        ready.claudeIsFrontmost = { [weak engine] in
            guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return false }
            return engine?.runningProcesses.contains { $0.pid == pid } ?? false
        }
        ready.chime = { CodeFinishChime.play() }
        ready.speech = speech(voice: voice, gate: gate)
        return ready
    }

    /// Say it's three steps: `gate.begin` (nothing is said unless it answers true), the phrase in the system voice,
    /// `gate.end` (also when `begin` said no: the dock link then has nothing to end).
    @MainActor
    static func speech(voice: SpokenLine?, gate: SpeechGate) -> CodeOwnSpeech {
        CodeOwnSpeech(beginOwnSpeech: gate.begin,
                      speak: { [weak voice] phrase in await voice?.speak(phrase) },
                      endOwnSpeech: gate.end)
    }

    /// The screen is locked or the main display sleeps: away for the recap, and no sound.
    static func away() -> Bool {
        PresenceProbe.screenLocked() || CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    /// The window server's on-screen list, front to back (numbers, owners and layers are all that is read).
    static func onScreenWindows() -> [[String: Any]] {
        (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    }

    /// True when `desk`'s app is the front app and its frontmost normal-layer window is `desk`'s window. Pure.
    static func isFrontWindow(_ desk: CodeDeskWindow, frontmostPID: pid_t?, windows: [[String: Any]]) -> Bool {
        guard frontmostPID == desk.pid,
              let front = windows.first(where: {
                  ($0[kCGWindowOwnerPID as String] as? pid_t) == desk.pid && ($0[kCGWindowLayer as String] as? Int) == 0
              }) else { return false }
        return (front[kCGWindowNumber as String] as? CGWindowID) == desk.windowNumber
    }
}
