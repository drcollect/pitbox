import Darwin
import Foundation
import Testing
@testable import PitboxSessions
import PitboxKit

/// The one-time scan on generated fixtures. Every byte is invented here; the
/// large fixtures are written to a temporary folder and removed at the end.
@Suite("Dashboard scan", .serialized)
struct TranscriptMarkerScanTests {
    init() { CodeLog.enabled = false }

    static let at = fixtureNow.addingTimeInterval(-86_400)

    /// About 1 MB of ordinary transcript lines without any marker: commands, their output, replies.
    static func fillerBlock(_ seed: Int = 0) -> Data {
        var text = ""
        var n = 0
        while text.utf8.count < 1 << 20 {
            let id = "toolu_f\(seed)_\(n)"
            text += SeamLine.bash("swift test --filter Part\(n)", description: "run part \(n)", id: id, uuid: "fu\(seed)x\(n)",
                                  at: at) + "\n"
            text += SeamLine.result(id, uuid: "fr\(seed)x\(n)", at: at,
                                    content: String(repeating: "test output line \(n) ok\n", count: 120)) + "\n"
            text += Line.text("Part \(n) passed; moving on to the next one.", uuid: "ft\(seed)x\(n)", at: at) + "\n"
            n += 1
        }
        return Data(text.utf8)
    }

    /// A file of `blocks` filler blocks with `lines` placed after the block of the same index (`-1`: before all).
    static func writeFixture(_ url: URL, blocks: Int, lines: [Int: [String]]) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let filler = fillerBlock()
        if let first = lines[-1] { try handle.write(contentsOf: Data((first.joined(separator: "\n") + "\n").utf8)) }
        for block in 0..<blocks {
            try handle.write(contentsOf: filler)
            if let extra = lines[block] { try handle.write(contentsOf: Data((extra.joined(separator: "\n") + "\n").utf8)) }
        }
    }

    /// Runs the scan the way the scanner does (careful open, `pread`), returning its result.
    static func scanFile(_ url: URL, limits: TranscriptMarkerScan.Limits = .init(),
                         cancelAfterReads: Int? = nil) throws -> (TranscriptMarkerScan.Result, Double, Double) {
        let path = try #require(CarefulPath(root: url.deletingLastPathComponent().path, components: [url.lastPathComponent]))
        var reads = 0
        let wall = MonotonicClock.now()
        let cpu = threadCPUSeconds()
        let outcome = CarefulFiles.withFile(path, owner: getuid()) { fd, identity in
            TranscriptMarkerScan.run(size: identity.size, sites: .test, limits: limits, read: { offset, count in
                reads += 1
                return CarefulFiles.readRange(fd: fd, from: offset, count: count)
            }, clock: { MonotonicClock.now() }, isCancelled: { cancelAfterReads.map { reads >= $0 } ?? false })
        }
        guard case .success(let result) = outcome else { throw ScanFailure.unreadable }
        return (result, MonotonicClock.now() - wall, threadCPUSeconds() - cpu)
    }

    enum ScanFailure: Error { case unreadable }

    static func threadCPUSeconds() -> Double {
        var spec = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &spec)
        return Double(spec.tv_sec) + Double(spec.tv_nsec) / 1e9
    }

    static let link = "https://dash.example.com/dash/polar-shore/"

    static func builderCall(at date: Date, prompt: String = "Update the board with the new tasks") -> String {
        SeamLine.agent("dashboard-builder", id: "toolu_db", uuid: "db1", at: date, prompt: prompt)
    }

    // MARK: Small fixtures (small reads exercise the same edges)

    func scanText(_ text: String, chunk: Int = 4096, lineMax: Int = 1 << 20) -> TranscriptMarkerScan.Result {
        let bytes = Array(text.utf8)
        var limits = TranscriptMarkerScan.Limits()
        limits.chunk = chunk
        limits.lineMax = lineMax
        return TranscriptMarkerScan.run(size: Int64(bytes.count), sites: .test, limits: limits, read: { offset, count in
            Array(bytes[Int(offset)..<Int(offset) + count])
        }, clock: { 0 }, isCancelled: { false })
    }

    @Test func onlyAssistantTextAndBuilderPromptsCount() {
        let decoys = [
            Line.user("The user pasted \(Self.link)", uuid: "u1", at: Self.at),
            SeamLine.result("toolu_x", uuid: "r1", at: Self.at, content: "curl says \(Self.link)"),
            SeamLine.noticeTurn(noticeText(taskID: "agent1x") + " \(Self.link)", uuid: "n1", at: Self.at),
            Line.text("A subagent's own words \(Self.link)", uuid: "s1", at: Self.at, sidechain: true),
            SeamLine.agent("general-purpose", id: "toolu_g", uuid: "g1", at: Self.at, prompt: "Mention \(Self.link)"),
        ]
        let none = scanText(decoys.joined(separator: "\n") + "\n")
        #expect(none.link == nil && !none.builderFound && none.stop == .startOfFile && none.linesParsed == 5)
        let older = Line.text("Board: https://dash.example.com/dash/amber-reef/", uuid: "a0", at: Self.at)
        let newer = Line.text("Board moved: \(Self.link)", uuid: "a1", at: Self.at.addingTimeInterval(60))
        let builder = Self.builderCall(at: Self.at.addingTimeInterval(120))
        let found = scanText(([older, newer, builder] + decoys).joined(separator: "\n") + "\n")
        #expect(found.link == DashboardSighting(handle: "polar-shore", site: CodeDashboardSite.test.key, at: Self.at.addingTimeInterval(60)), "the newest link")
        #expect(found.builderFound && found.builderAt == Self.at.addingTimeInterval(120) && found.stop == .complete)
        let inPrompt = scanText(Self.builderCall(at: Self.at, prompt: "Rebuild \(Self.link) now") + "\n")
        #expect(inPrompt.link?.handle == "polar-shore" && inPrompt.builderFound)
    }

    @Test func aLinkSplitAcrossAReadBoundaryIsFound() {
        let head = Line.text(String(repeating: "y", count: 5000), uuid: "p1", at: Self.at)
        let line = Line.text("Board: \(Self.link)", uuid: "a1", at: Self.at)
        // A newer line of growing length moves the 4 KB read edge from after the link line, through it (the marker
        // straddling the edge on some steps), to before it.
        var cut = 0
        for length in stride(from: 3000, through: 4200, by: 23) {
            let tail = Line.text(String(repeating: "x", count: length), uuid: "f1", at: Self.at)
            let text = head + "\n" + line + "\n" + tail + "\n"
            let edge = text.utf8.count - 4096
            let start = head.utf8.count + 1
            if edge > start, edge < start + line.utf8.count { cut += 1 }
            #expect(scanText(text, chunk: 4096).link?.handle == "polar-shore", "length \(length)")
        }
        #expect(cut >= 5, "the edge cut the link line \(cut) times")
    }

    @Test func aLineLongerThanTheLimitIsSkippedWhole() {
        let older = Line.text("Board: https://dash.example.com/dash/amber-reef/", uuid: "a0", at: Self.at)
        let huge = Line.text("Board: \(Self.link) " + String(repeating: "z", count: 20_000), uuid: "a1", at: Self.at)
        let result = scanText([older, huge, "{\"type\":\"system\"}"].joined(separator: "\n") + "\n", chunk: 4096, lineMax: 8192)
        #expect(result.link?.handle == "amber-reef", "the long line's link is never read")
        #expect(result.linesSkipped >= 1 && result.peakBytes <= 4096 + 8192 + 8192)
        // At the file's start too.
        let first = scanText(huge + "\n" + older + "\n", chunk: 4096, lineMax: 8192)
        #expect(first.link?.handle == "amber-reef")
        // With the real limits: a 2 MB line holding the marker is skipped, the 1 MB reads stay bounded.
        let twoMegabytes = Line.text("Board: \(Self.link) " + String(repeating: "z", count: 2 << 20), uuid: "a2", at: Self.at)
        let bytes = Array(([older, twoMegabytes, "{\"type\":\"system\"}"].joined(separator: "\n") + "\n").utf8)
        let real = TranscriptMarkerScan.run(size: Int64(bytes.count), sites: .test, read: { offset, count in
            Array(bytes[Int(offset)..<Int(offset) + count])
        }, clock: { 0 }, isCancelled: { false })
        #expect(real.link?.handle == "amber-reef" && real.linesSkipped == 1)
        #expect(real.peakBytes <= 3 << 20)
    }

    @Test func scanLogsHoldLabelsAndNumbersOnly() throws {
        let lines = Shared<[String]>([])
        let token = CodeLog.observe { line in lines.value.append(line) }
        defer { CodeLog.stopObserving(token) }
        let folder = SeamFolder("dash-scan-log")
        let url = folder.file("t.jsonl")
        try Data((Line.text("\(secretWord) board \(Self.link)", uuid: "a1", at: Self.at) + "\n").utf8).write(to: url)
        let memory = ProgressMemory(clock: ManualClock(fixtureNow))
        let path = try #require(CarefulPath(root: folder.url.path, components: ["t.jsonl"]))
        DashboardScanner.scan(sessionID: sessionA, index: 7, transcript: path, owner: getuid(), memory: memory.store, sites: .test,
                              ticket: DashboardScanTicket(), limits: .init(), wallClock: { fixtureNow })
        let deriver = DashboardDeriver(sites: .test, scanner: RecordingScanner())
        _ = derived(deriver, deriveInput(progressSnapshot(index: 7), digest: digestOf([Line.user("x", uuid: "u1", at: Self.at)]),
                                         now: fixtureNow, memory: memory.store, transcript: path))
        #expect(lines.value.contains { $0.hasPrefix("INFO dashboard scan session=#7 bytes=") && $0.contains("found=yes") })
        #expect(lines.value.contains("INFO dashboard found session=#7 source=scan"))
        for line in lines.value {
            for marker in [secretWord, "polar", "dash.example", "example.com", sessionA, folder.url.path] {
                #expect(!line.contains(marker), "\(line)")
            }
        }
    }

    @Test func itStopsAtTheByteAndTimeLimitsAndWhenCancelled() {
        let filler = [UInt8](Self.fillerBlock())
        let reader: (Int64, Int) -> [UInt8]? = { _, count in Array(filler.prefix(count)) }
        let size = Int64(200 << 20)
        let bytes = TranscriptMarkerScan.run(size: size, sites: .test, read: reader, clock: { 0 }, isCancelled: { false })
        #expect(bytes.stop == .byteLimit && bytes.bytesRead == CodeTuning.dashboardScanMax)
        // A slow reader: the fake clock moves 1.5 s per read; at 60 s it stops.
        var fakeNow = 0.0
        let slow = TranscriptMarkerScan.run(size: size, sites: .test, read: { offset, count in
            fakeNow += 1.5
            return reader(offset, count)
        }, clock: { fakeNow }, isCancelled: { false })
        #expect(slow.stop == .timeLimit && slow.bytesRead == 41 << 20)
        var reads = 0
        let cancelled = TranscriptMarkerScan.run(size: size, sites: .test, read: { offset, count in
            reads += 1
            return reader(offset, count)
        }, clock: { 0 }, isCancelled: { reads >= 3 })
        #expect(cancelled.stop == .cancelled && cancelled.bytesRead == 3 << 20)
        #expect(TranscriptMarkerScan.run(size: size, sites: .test, read: { _, _ in nil }, clock: { 0 }, isCancelled: { false }).stop == .unreadable)
    }

    // MARK: Large fixtures

    @Test func aLinkNinetyMegabytesBackAndANewerBuilderCallAreBothFound() throws {
        let folder = SeamFolder("dash-scan-90")
        let url = folder.file("fixture.jsonl")
        let linkLine = Line.text("Fleet dashboard: \(Self.link)", uuid: "al", at: Self.at)
        let builder = Self.builderCall(at: Self.at.addingTimeInterval(3600))
        try Self.writeFixture(url, blocks: 92, lines: [1: [linkLine], 88: [builder]])
        let (result, seconds, _) = try Self.scanFile(url)
        #expect(result.link == DashboardSighting(handle: "polar-shore", site: CodeDashboardSite.test.key, at: Self.at))
        #expect(result.builderAt == Self.at.addingTimeInterval(3600) && result.stop == .complete)
        #expect(result.bytesRead >= 90 << 20 && result.bytesRead <= 92 << 20)
        #expect(seconds < 30)
    }

    @Test func c20TheCostOfAFullReadOfAHundredMegabytesAndOfCancelling() throws {
        let folder = SeamFolder("dash-scan-100")
        let url = folder.file("fixture.jsonl")
        // Every 10 MB the bytes appear where they never count: pasted by the user, in a tool's output, in a notice
        // (real transcripts held 231 such places in 30 days); they are parsed and dropped.
        let decoys = [
            Line.user("Pasted \(Self.link)", uuid: "du", at: Self.at),
            SeamLine.result("toolu_d", uuid: "dr", at: Self.at, content: "\"dashboard-builder\" wrote \(Self.link)"),
            SeamLine.noticeTurn(noticeText(taskID: "agentd") + " \(Self.link)", uuid: "dn", at: Self.at),
        ]
        var placed: [Int: [String]] = [-1: [Line.user("Start", uuid: "u1", at: Self.at)]]
        for block in stride(from: 9, to: 100, by: 10) { placed[block] = decoys }
        try Self.writeFixture(url, blocks: 100, lines: placed)
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let (full, seconds, cpu) = try Self.scanFile(url)
        #expect(full.link == nil && !full.builderFound && full.stop == .startOfFile && full.bytesRead == size)
        #expect(full.linesParsed == 30)
        #expect(full.peakBytes <= 3 << 20, "one read, one carried line and one joined line")
        #expect(seconds < 30)
        let (cancelled, cancelSeconds, _) = try Self.scanFile(url, cancelAfterReads: 10)
        #expect(cancelled.stop == .cancelled && cancelled.bytesRead == 10 << 20)

        // The scanner writes its "not found" mark, so the scan never repeats.
        let memory = ProgressMemory(clock: ManualClock(fixtureNow))
        let path = try #require(CarefulPath(root: folder.url.path, components: ["fixture.jsonl"]))
        DashboardScanner.scan(sessionID: sessionA, index: 3, transcript: path, owner: getuid(), memory: memory.store, sites: .test,
                              ticket: DashboardScanTicket(), limits: .init(), wallClock: { fixtureNow })
        let mark: DashboardScanRecord = try #require(memory.store.read(.dashboardScan, session: sessionA))
        #expect(mark.found == false && mark.bytes == size && mark.handle == nil && mark.at == fixtureNow)
        // A cancelled scan writes nothing.
        let ticket = DashboardScanTicket()
        ticket.cancel()
        DashboardScanner.scan(sessionID: sessionB, index: 4, transcript: path, owner: getuid(), memory: memory.store, sites: .test,
                              ticket: ticket, limits: .init(), wallClock: { fixtureNow })
        #expect((memory.store.read(.dashboardScan, session: sessionB) as DashboardScanRecord?) == nil && ticket.isFinished)

        if let out = ProcessInfo.processInfo.environment["PITBOX_TEST_OUT"] {
            let report = """
            C20 dashboard scan, generated fixture (no real transcript)
            file bytes: \(size)
            full read (no link): bytes=\(full.bytesRead) wall_s=\(String(format: "%.3f", seconds)) cpu_s=\(String(format: "%.3f", cpu)) \
            peak_buffer_bytes=\(full.peakBytes) lines_parsed=\(full.linesParsed) stop=\(full.stop.rawValue)
            cancelled after 10 reads: bytes=\(cancelled.bytesRead) wall_s=\(String(format: "%.3f", cancelSeconds))
            """
            try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
            try? Data(report.utf8).write(to: URL(fileURLWithPath: out).appendingPathComponent("c20-dashboard-scan.txt"))
        }
    }
}
