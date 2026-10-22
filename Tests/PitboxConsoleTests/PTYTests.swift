import Darwin
import Foundation
import Testing
@testable import PitboxConsole

/// Keeps the main thread busy so the pty backlog grows (a slow consumer). A plain function: `Thread.sleep` is refused in
/// async code.
func blockTheMainThread(for seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

/// Runs a real process on a real pty and records what the terminal side sees.
@MainActor
final class ProcessProbe {
    let process: PTYProcess
    private(set) var output: [UInt8] = []
    private(set) var exit: ProcessExit?
    private(set) var outputCountAtExit: Int?
    var text: String { String(decoding: output, as: UTF8.self) }

    init(_ argv: [String], executable: String = "/bin/sh", env: [String] = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "TERM=xterm-256color"],
         cwd: String = "/tmp", size: TerminalSize = TerminalSize(cols: 100, rows: 30, pixelWidth: 800, pixelHeight: 600)) throws {
        let spec = LaunchSpec(executable: executable, argv: argv, env: env, cwd: cwd, presetID: "test", kind: .program, shellName: "sh")
        process = try PTYProcess(spec: spec, size: size)
        process.onOutput = { [unowned self] bytes in output += bytes }
        process.onExit = { [unowned self] status in exit = status; outputCountAtExit = output.count }
    }

    func waitForText(_ needle: String, timeout: TimeInterval = 8) async -> Bool {
        await waitUntil(timeout) { self.text.contains(needle) }
    }

    func waitForExit(timeout: TimeInterval = 8) async -> ProcessExit? {
        _ = await waitUntil(timeout) { self.exit != nil }
        return exit
    }
}

@MainActor
struct PTYSmokeTests {
    @Test(.timeLimit(.minutes(1))) func echoRunsAndItsOutputArrivesBeforeTheExit() async throws {
        let probe = try ProcessProbe(["echo", "hello", "world"], executable: "/bin/echo")
        #expect(await probe.waitForExit() == .exited(0))
        #expect(probe.text == "hello world\r\n", "the tty turns \\n into \\r\\n: \(probe.text.debugDescription)")
        #expect(probe.outputCountAtExit == probe.output.count, "all output is delivered before onExit")
        #expect(!ProcessInspector.exists(probe.process.pid), "the child was reaped: no zombie")
        #expect(!probe.process.isRunning)
    }

    @Test(.timeLimit(.minutes(1))) func shellCommandReportsItsExitStatusAndTheTerminalEnvironment() async throws {
        let env = fixtureEnvironment(parent: ["PATH": "/usr/bin:/bin"]).variables(shell: "/bin/sh", preset: nil)
        let probe = try ProcessProbe(["sh", "-c", #"printf '%s|%s|%s|%s|%s' "$TERM" "$COLORTERM" "$TERM_PROGRAM" "$LANG" "$(pwd -P)"; exit 3"#], env: env, cwd: "/tmp")
        #expect(await probe.waitForExit() == .exited(3))
        #expect(probe.text == "xterm-256color|truecolor|Pitbox|en_US.UTF-8|/private/tmp", "\(probe.text)")
        #expect(!ProcessInspector.exists(probe.process.pid))
    }

    @Test(.timeLimit(.minutes(1))) func aSignalKilledProcessIsReportedAsSuch() async throws {
        let probe = try ProcessProbe(["sh", "-c", "kill -9 $$"])
        #expect(await probe.waitForExit() == .signaled(SIGKILL))
        #expect(!ProcessInspector.exists(probe.process.pid))
    }

    @Test(.timeLimit(.minutes(1))) func ctrlCReachesTheForegroundProcessThroughTheTty() async throws {
        let probe = try ProcessProbe(["sh", "-c", #"trap 'echo GOT_INT; exit 5' INT; echo ready; while :; do sleep 0.05; done"#])
        #expect(await probe.waitForText("ready"))
        probe.process.write([0x03])   // what the terminal sends for Ctrl-C
        #expect(await probe.waitForExit() == .exited(5))
        #expect(probe.text.contains("GOT_INT"), "\(probe.text)")
    }

    @Test(.timeLimit(.minutes(1))) func resizingTheTerminalSignalsTheProgramAndChangesItsSize() async throws {
        let probe = try ProcessProbe(["sh", "-c", #"trap 'echo WINCH $(stty size)' WINCH; echo ready $(stty size); while :; do sleep 0.05; done"#])
        #expect(await probe.waitForText("ready 30 100"), "\(probe.text)")
        probe.process.resize(cols: 120, rows: 40, pixelWidth: 960, pixelHeight: 800)
        #expect(await probe.waitForText("WINCH 40 120"), "SIGWINCH arrived and the size is right: \(probe.text)")
        probe.process.resize(cols: 120, rows: 40, pixelWidth: 960, pixelHeight: 800)   // same size: no second signal
        probe.process.terminate()
        _ = await probe.waitForExit()
        #expect(probe.text.components(separatedBy: "WINCH").count == 2)
    }

    @Test(.timeLimit(.minutes(1))) func terminateHangsUpTheSession() async throws {
        let probe = try ProcessProbe(["sh", "-c", "trap 'exit 7' HUP; echo ready; while :; do sleep 0.05; done"])
        #expect(await probe.waitForText("ready"))
        probe.process.terminate()
        #expect(await probe.waitForExit() == .exited(7), "the shell saw SIGHUP")
        #expect(!ProcessInspector.exists(probe.process.pid))
    }

    @Test(.timeLimit(.minutes(1))) func aProcessThatIgnoresHangupIsKilledAfterTheGracePeriod() async throws {
        let probe = try ProcessProbe(["sh", "-c", "trap '' HUP; echo ready; while :; do sleep 0.05; done"])
        #expect(await probe.waitForText("ready"))
        let started = Date()
        probe.process.terminate()
        #expect(await probe.waitForExit(timeout: 10) == .signaled(SIGKILL))
        #expect(Date().timeIntervalSince(started) >= 1.4, "SIGKILL only after the grace period")
        #expect(!ProcessInspector.exists(probe.process.pid))
    }

    @Test(.timeLimit(.minutes(1))) func hangUpDoesNotWait() async throws {
        let probe = try ProcessProbe(["sh", "-c", "trap 'exit 9' HUP; echo ready; while :; do sleep 0.05; done"])
        #expect(await probe.waitForText("ready"))
        probe.process.hangUp()   // what quitting the app does
        #expect(await probe.waitForExit() == .exited(9))
    }

    @Test(.timeLimit(.minutes(1))) func inspectReportsTheForegroundProgramAndTheFolder() async throws {
        let probe = try ProcessProbe(["sh", "-c", "exec sleep 30"], cwd: "/tmp")
        #expect(await waitUntil(5) { probe.process.inspect()?.name == "sleep" })
        let info = try #require(probe.process.inspect())
        #expect(info.pgid == probe.process.pid && info.isSessionLeader)
        #expect(info.cwd.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath().path)
        probe.process.terminate()
        #expect(await probe.waitForExit() != nil)
        #expect(probe.process.inspect() == nil, "nothing to inspect after the exit")
    }

    @Test(.timeLimit(.minutes(1))) func aLargeBurstOfOutputArrivesCompleteAndInOrder() async throws {
        // 3 MB without newlines (the tty rewrites \n): passes the 1 MB backpressure mark.
        let probe = try ProcessProbe(["sh", "-c", #"perl -e 'print "0123456789" x 300000'"#])
        #expect(await probe.waitForExit(timeout: 30) == .exited(0))
        #expect(probe.output.count == 3_000_000, "\(probe.output.count)")
        let expected = [UInt8](repeating: 0, count: 0)
        _ = expected
        var ordered = true
        for (index, byte) in probe.output.enumerated() where byte != UInt8(ascii: "0") + UInt8(index % 10) { ordered = false; break }
        #expect(ordered)
    }

    @Test(.timeLimit(.minutes(1))) func aSlowConsumerPausesTheChildWithoutLosingBytes() async throws {
        // 6 MB while the main thread is busy: the backlog passes the 1 MB mark, reading pauses, the child blocks in
        // write, and everything still arrives complete and in order once the main thread catches up.
        let probe = try ProcessProbe(["sh", "-c", #"perl -e 'print "0123456789" x 600000'"#])
        blockTheMainThread(for: 0.8)
        #expect(await probe.waitForExit(timeout: 40) == .exited(0))
        #expect(probe.output.count == 6_000_000, "\(probe.output.count)")
        var ordered = true
        for (index, byte) in probe.output.enumerated() where byte != UInt8(ascii: "0") + UInt8(index % 10) { ordered = false; break }
        #expect(ordered)
        #expect(!ProcessInspector.exists(probe.process.pid))
    }

    @Test(.timeLimit(.minutes(1))) func aProcessThatClosesItsTerminalStillEndsProperly() async throws {
        let probe = try ProcessProbe(["sh", "-c", "echo before; exec >&- 2>&- <&-; sleep 0.6; exit 4"])
        #expect(await probe.waitForText("before"))
        #expect(await probe.waitForExit(timeout: 10) == .exited(4), "the end of the output is not the end of the process")
        #expect(!ProcessInspector.exists(probe.process.pid))
    }

    @Test(.timeLimit(.minutes(1))) func terminateStillWorksAfterTheProcessClosedItsTerminal() async throws {
        let probe = try ProcessProbe(["sh", "-c", "echo before; exec >&- 2>&- <&-; sleep 30"])
        #expect(await probe.waitForText("before"))
        try await Task.sleep(nanoseconds: 300_000_000)
        probe.process.terminate()
        #expect(await probe.waitForExit(timeout: 10) == .signaled(SIGHUP))
        #expect(!ProcessInspector.exists(probe.process.pid))
    }

    @Test(.timeLimit(.minutes(1))) func endedProcessesIgnoreLateCalls() async throws {
        let probe = try ProcessProbe(["echo", "x"], executable: "/bin/echo")
        #expect(await probe.waitForExit() == .exited(0))
        probe.process.write([0x61])
        probe.process.resize(cols: 50, rows: 20, pixelWidth: 0, pixelHeight: 0)
        probe.process.terminate()
        probe.process.hangUp()
        #expect(probe.process.inspect() == nil && !probe.process.isRunning)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(probe.exit == .exited(0), "onExit fires once")
    }

    @Test(.timeLimit(.minutes(1))) func hugeInputIsWrittenInFullEvenWhenTheChildIsSlowToRead() async throws {
        // 300 KB is far more than the pty buffer: the write queue must wait for the child instead of dropping bytes.
        // Written only once the child says the tty is raw (see `PTYRawModeTests`); the child then waits before reading.
        let probe = try ProcessProbe(["sh", "-c", #"stty raw -echo; echo ready; sleep 0.3; head -c 300000 | wc -c; echo done"#])
        defer { probe.process.terminate() }
        #expect(await probe.waitForText("ready", timeout: 30))
        probe.process.write([UInt8](repeating: UInt8(ascii: "a"), count: 300_000))
        #expect(await probe.waitForExit(timeout: 30) == .exited(0))
        #expect(probe.text.contains("300000"), "\(probe.text)")
    }

    @Test(.timeLimit(.minutes(1))) func aMissingProgramIsAnErrorNotACrash() async throws {
        #expect(throws: PTYError.self) { _ = try ProcessProbe(["x"], executable: "/nonexistent/program") }
        #expect(throws: PTYError.self) { _ = try ProcessProbe(["x"], executable: "/etc/hosts") }
    }
}

/// Why `hugeInputIsWrittenInFullEvenWhenTheChildIsSlowToRead` waits for the child: input that reaches a canonical tty
/// (before `stty raw` ran) keeps only MAX_INPUT (1024) bytes of an unterminated line, so `head` would wait forever.
@MainActor
struct PTYRawModeTests {
    @Test(.timeLimit(.minutes(1))) func inputThatArrivesBeforeRawModeIsCutShort() async throws {
        let probe = try ProcessProbe(["sh", "-c", #"sleep 0.5; stty raw -echo; head -c 300000 | wc -c; echo done"#])
        defer { probe.process.terminate() }
        probe.process.write([UInt8](repeating: UInt8(ascii: "a"), count: 300_000))
        let exit = await probe.waitForExit(timeout: 2)
        #expect(exit == nil && !probe.text.contains("300000"), "all 300 KB reached head: \(String(describing: exit))")
        probe.process.terminate()
        #expect(await probe.waitForExit(timeout: 10) != nil, "the probe ends (head is hung up)")
    }
}

@MainActor
struct ChildHygieneTests {
    @Test(.timeLimit(.minutes(1))) func theChildInheritsNoDescriptorsAboveTwoAndNoIgnoredSignals() async throws {
        // A descriptor without close-on-exec, as the app's files or sockets might be.
        let plain = open("/dev/null", O_RDONLY)
        let leaked = fcntl(plain, F_DUPFD, 50)   // a high number, no close-on-exec
        close(plain)
        #expect(leaked >= 50)
        defer { close(leaked) }
        let oldPipe = signal(SIGPIPE, SIG_IGN)   // an app that ignores SIGPIPE must not pass that on
        defer { signal(SIGPIPE, oldPipe) }

        let script = #"for fd in $(ls /dev/fd); do echo "fd=$fd"; done; yes | head -1 > /dev/null; echo end"#
        let probe = try ProcessProbe(["sh", "-c", script])
        #expect(await probe.waitForExit() == .exited(0))
        let fds = probe.text.split(whereSeparator: \.isNewline).compactMap { line -> Int? in
            line.hasPrefix("fd=") ? Int(line.dropFirst(3)) : nil
        }
        #expect(!fds.contains(Int(leaked)), "the leaked descriptor \(leaked) must not reach the shell: \(fds)")
        #expect(fds.allSatisfy { $0 <= 4 }, "only the standard descriptors (and ls's own directory handles): \(fds)")
        #expect(!probe.text.contains("Broken pipe"), "SIGPIPE is back to its default in the child: \(probe.text)")
        #expect(probe.text.contains("end"))
    }

    @Test(.timeLimit(.minutes(1))) func theTerminalIsSetUpForUTF8LikeTerminalApp() async throws {
        let probe = try ProcessProbe(["sh", "-c", "stty -a"])
        #expect(await probe.waitForExit() == .exited(0))
        let words = probe.text.replacingOccurrences(of: "\r", with: " ").split(whereSeparator: { " \n;".contains($0) }).map(String.init)
        #expect(words.contains("iutf8"), "IUTF8 is on so backspace erases whole characters: \(probe.text)")
        #expect(words.contains("icanon") && words.contains("echo") && words.contains("isig"), "otherwise the system defaults: \(probe.text)")
        #expect(probe.text.contains("30 rows; 100 columns"), "and the size we asked for: \(probe.text)")
    }

    @Test(.timeLimit(.minutes(1))) func theChildLeadsItsOwnSessionWithThePtyAsControllingTerminal() async throws {
        let probe = try ProcessProbe(["sh", "-c", #"ps -o pid=,pgid=,tpgid=,tty= -p $$"#])
        #expect(await probe.waitForExit() == .exited(0))
        let fields = probe.text.split(whereSeparator: { $0 == " " || $0.isNewline }).map(String.init)
        #expect(fields.count == 4, "\(probe.text)")
        #expect(fields[0] == fields[1] && fields[1] == fields[2], "session leader, own group, and the tty's foreground group: \(fields)")
        #expect(fields[3].hasPrefix("ttys"), "controlling terminal is a pty: \(fields)")
    }
}
