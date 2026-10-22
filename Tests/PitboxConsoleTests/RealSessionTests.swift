import AppKit
import Foundation
import Testing
@testable import PitboxConsole

/// The same code path as the app, without fakes: a real `PTYProcess` behind a real `ConsoleTerminalView`, read back
/// from the emulator's buffer. Nothing is shown on screen.
/// Keeps the temp folder alive as long as the manager is used.
@MainActor
struct RealHarness {
    let manager: TerminalSessionManager
    let dir: TempDir
}

@MainActor
struct RealSessionTests {
    /// A manager wired like the console host does it, but with private files and a fixed environment.
    private func realManager(settingsJSON: String? = nil) -> RealHarness {
        let dir = TempDir()
        let settings = testSettings(settingsJSON)
        var environment = TerminalEnvironment.live
        environment.parent = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": NSTemporaryDirectory()]
        let manager = TerminalSessionManager(TerminalSessionManager.Dependencies(
            settings: settings, environment: environment, launcher: { spec, size in try PTYProcess(spec: spec, size: size) },
            stateFile: nil, clock: SystemClock(), performLink: { _ in }, setClipboard: { _ in }, isDarkAppearance: { true },
            mode: .terminal))
        manager.setContentSize(CGSize(width: 800, height: 480))
        return RealHarness(manager: manager, dir: dir)
    }

    @Test(.timeLimit(.minutes(1))) func echoAppearsInTheTerminalBuffer() async throws {
        let h = realManager(settingsJSON: #"{"onExit":"keep","shell":"/bin/sh","presets":[{"id":"e","name":"Echo","argv":["/bin/echo","hello from the pty"]}]}"#)
        let manager = h.manager
        let preset = try #require(manager.presetsForMenu().first { $0.id == "e" })
        let session = try #require(manager.newSession(preset: preset))
        #expect(await waitUntil(15) { session.hasExited })
        let text = screenText(session.view)
        #expect(text.contains("hello from the pty"), "\(text)")
        #expect(text.contains("Process exited"), "the restart hint follows the last output: \(text)")
        if case .exited(let status) = session.state { #expect(status == .exited(0)) } else { Issue.record("not exited: \(session.state)") }
        manager.shutdown()
        withExtendedLifetime(h.dir) {}
    }

    @Test(.timeLimit(.minutes(1))) func aShellCommandRunsThroughTheSamePath() async throws {
        let h = realManager(settingsJSON: #"{"onExit":"keep","shell":"/bin/sh","presets":[{"id":"c","name":"Cmd","script":"printf 'A%sB' \"$TERM_PROGRAM\"; printf ' cols=%s' \"$(stty size | cut -d' ' -f2)\"; exit 7"}]}"#)
        let manager = h.manager
        let preset = try #require(manager.presetsForMenu().first { $0.id == "c" })
        let session = try #require(manager.newSession(preset: preset))
        #expect(await waitUntil(15) { session.hasExited })
        let text = screenText(session.view)
        #expect(text.contains("APitboxB"), "TERM_PROGRAM reached the child: \(text)")
        #expect(text.contains("cols=\(session.view.terminal.cols)"), "the child saw the terminal's real width: \(text)")
        #expect(session.state == .exited(.exited(7)) && text.contains("Process exited with status 7"))
        manager.shutdown()
        withExtendedLifetime(h.dir) {}
    }

    @Test(.timeLimit(.minutes(1))) func typingIntoAnInteractiveLoginShellWorks() async throws {
        let h = realManager(settingsJSON: #"{"shell":"/bin/sh","onExit":"keep"}"#)
        let manager = h.manager
        let session = try #require(manager.selectedSession ?? manager.newSession())
        // A plain login sh: wait for it to run (prompt), then type like the keyboard would.
        try await Task.sleep(nanoseconds: 600_000_000)
        session.view.send(txt: "echo typed-$((6*7))\r")
        #expect(await waitUntil(10) { screenText(session.view).contains("typed-42") }, "\(screenText(session.view))")
        session.view.send(txt: "exit\r")
        #expect(await waitUntil(10) { session.hasExited || !manager.sessions.contains { $0 === session } }, "a clean exit closes the tab")
        manager.shutdown()
        withExtendedLifetime(h.dir) {}
    }

    @Test(.timeLimit(.minutes(1))) func closingATabHangsUpItsShellAndLeavesNoZombie() async throws {
        let h = realManager(settingsJSON: #"{"shell":"/bin/sh","onExit":"keep"}"#)
        let manager = h.manager
        let session = try #require(manager.newSession())
        let pid = try #require(session.pid)
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(ProcessInspector.exists(pid))
        manager.closeNow(session.id)
        #expect(await waitUntil(10) { !ProcessInspector.exists(pid) }, "the shell is gone and reaped")
        manager.shutdown()
        withExtendedLifetime(h.dir) {}
    }

    @Test(.timeLimit(.minutes(1))) func aTerminalViewResizeReachesTheRealProgram() async throws {
        // The program is exec'ed (as presets do), so it is the foreground process of the session and gets SIGWINCH.
        let script = #"exec perl -e '$SIG{WINCH} = sub { my $s = `stty size`; chomp $s; print "SIZE=$s\n" }; print "ready\n"; while (1) { sleep 1 }'"#
        let object: [String: Any] = ["shell": "/bin/sh", "onExit": "keep", "presets": [["id": "w", "name": "W", "script": script]]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        let h = realManager(settingsJSON: json)
        let manager = h.manager
        let preset = try #require(manager.presetsForMenu().first { $0.id == "w" })
        let session = try #require(manager.newSession(preset: preset))
        #expect(await waitUntil(15) { screenText(session.view).contains("ready") }, "\(screenText(session.view))")
        manager.setContentSize(CGSize(width: 1000, height: 600))
        let expected = "SIZE=\(session.view.terminal.rows) \(session.view.terminal.cols)"
        #expect(await waitUntil(10) { screenText(session.view).contains(expected) }, "expected \(expected) in: \(screenText(session.view))")
        manager.shutdown()
        withExtendedLifetime(h.dir) {}
    }
}


/// Real full-screen programs through the real path: alternate screen, cursor addressing, keys in, exit status out.
@MainActor
struct RealTUITests {
    private func manager(_ presets: String) -> (TerminalSessionManager, TempDir) {
        let dir = TempDir()
        let settings = testSettings("{\"onExit\":\"keep\",\"shell\":\"/bin/sh\",\"presets\":\(presets)}")
        var environment = TerminalEnvironment.live
        environment.parent = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": NSTemporaryDirectory()]
        let manager = TerminalSessionManager(TerminalSessionManager.Dependencies(
            settings: settings, environment: environment, launcher: { spec, size in try PTYProcess(spec: spec, size: size) },
            stateFile: nil, clock: SystemClock(), performLink: { _ in }, setClipboard: { _ in }, isDarkAppearance: { true },
            mode: .terminal))
        manager.setContentSize(CGSize(width: 800, height: 480))
        return (manager, dir)
    }

    private func rows(_ view: ConsoleTerminalView, _ count: Int) -> [String] {
        (0..<count).compactMap { view.terminal.getLine(row: $0)?.translateToString(trimRight: true) }
    }

    @Test(.timeLimit(.minutes(1))) func topDrawsItsScreenAndQuits() async throws {
        let (manager, dir) = manager(#"[{"id":"t","name":"T","argv":["top","-o","cpu"]}]"#)
        let session = try #require(manager.newSession(preset: manager.presetsForMenu().first { $0.id == "t" }))
        #expect(await waitUntil(20) { self.rows(session.view, 3).joined().contains("Processes:") }, "\(rows(session.view, 5))")
        #expect(session.view.terminal.isCurrentBufferAlternate, "top runs on the alternate screen")
        session.view.send(txt: "q")
        #expect(await waitUntil(20) { session.hasExited })
        #expect(session.state == .exited(.exited(0)))
        #expect(!session.view.terminal.isCurrentBufferAlternate, "the screen is restored for the hint")
        manager.shutdown()
        withExtendedLifetime(dir) {}
    }

    @Test(.timeLimit(.minutes(1))) func vimTakesTypedTextIncludingWideCharactersAndQuits() async throws {
        let (manager, dir) = manager(#"[{"id":"v","name":"V","argv":["vim","-u","NONE","-N"]}]"#)
        let session = try #require(manager.newSession(preset: manager.presetsForMenu().first { $0.id == "v" }))
        #expect(await waitUntil(20) { session.view.terminal.isCurrentBufferAlternate && self.rows(session.view, 3).joined().contains("~") })
        session.view.send(txt: "ihello vim \u{65E5}\u{672C}")
        session.view.send([0x1b])
        #expect(await waitUntil(20) { self.rows(session.view, 1).joined().contains("hello vim") }, "\(rows(session.view, 3))")
        let terminal = try #require(session.view.terminal)
        #expect(terminal.getCharacter(col: 10, row: 0) == "日" && terminal.getCharacter(col: 12, row: 0) == "本", "wide characters typed through the whole path")
        session.view.send(txt: ":q!\r")
        #expect(await waitUntil(20) { session.hasExited })
        #expect(session.state == .exited(.exited(0)))
        manager.shutdown()
        withExtendedLifetime(dir) {}
    }
}
