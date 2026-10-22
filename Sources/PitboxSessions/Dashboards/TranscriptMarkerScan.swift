import Darwin
import Foundation
import PitboxKit

/// The one-time dashboard scan of a whole transcript (a link posted long ago is seldom in the tail): it reads from the
/// end backwards in `Limits.chunk` reads, looking for the configured sites' markers (`CodeDashboardSite.key`, such as
/// `dash.example.com/dash/`) and `"dashboard-builder"`. The partial line at each read's edge is kept and joined with
/// the next read, up to `Limits.lineMax`; a longer line is skipped whole. A line holding a marker is parsed strictly
/// (nesting at most 64, `TranscriptEntry`) and counts only as an assistant entry's text block, or an Agent call whose
/// `input.subagent_type` is "dashboard-builder" (its prompt); the same bytes in user text, a task notice or a tool
/// result never count. It stops once it has the newest link and the newest builder call, at the file's start, after
/// `Limits.maxBytes` or `Limits.maxSeconds`, or when cancelled (checked before every read). Memory stays at one read,
/// one carried partial line and one joined line. Pure: the reader, the clock and the cancel flag are injected.
enum TranscriptMarkerScan {
    struct Limits: Equatable, Sendable {
        var maxBytes = CodeTuning.dashboardScanMax
        var maxSeconds = CodeTuning.dashboardScanSeconds
        var lineMax = CodeTuning.dashboardLineMax
        var chunk = 1 << 20
    }

    /// Why the scan ended (a label: safe to log).
    enum Stop: String, Equatable, Sendable {
        /// The newest link and the newest builder call were both found.
        case complete
        case startOfFile = "start-of-file"
        case byteLimit = "byte-limit"
        case timeLimit = "time-limit"
        case cancelled
        case unreadable
    }

    struct Result: Equatable, Sendable {
        /// The newest link of the session's own writing, and the newest `dashboard-builder` call.
        var link: DashboardSighting?
        var builderFound = false
        var builderAt: Date?
        var bytesRead = 0
        var stop: Stop = .startOfFile
        /// Lines that held a marker and were parsed; lines skipped for being longer than `lineMax`.
        var linesParsed = 0
        var linesSkipped = 0
        /// The most bytes held at once (the read, the carried partial line and a joined line).
        var peakBytes = 0
    }

    static let builderMarker: [UInt8] = Array("\"dashboard-builder\"".utf8)

    /// Scans a file of `size` bytes. `read(offset, count)` returns exactly `count` bytes from `offset` (nil, or fewer,
    /// is a read error); `clock` is a monotonic clock in seconds.
    static func run(size: Int64, sites: CodeDashboardSites, limits: Limits = Limits(), read: (Int64, Int) -> [UInt8]?,
                    clock: () -> TimeInterval, isCancelled: () -> Bool) -> Result {
        var result = Result()
        let started = clock()
        var end = size
        var carry: [UInt8] = []
        var skipping = false
        while end > 0 {
            if isCancelled() { return finish(&result, .cancelled) }
            if clock() - started > limits.maxSeconds { return finish(&result, .timeLimit) }
            if result.bytesRead >= limits.maxBytes { return finish(&result, .byteLimit) }
            let count = Int(min(Int64(max(1, limits.chunk)), end))
            let start = end - Int64(count)
            guard let bytes = read(start, count), bytes.count == count else { return finish(&result, .unreadable) }
            result.bytesRead += count
            result.peakBytes = max(result.peakBytes, bytes.count + carry.count)
            bytes.withUnsafeBufferPointer { b in
                guard let first = b.firstIndex(of: 0x0A) else {
                    // The middle of a line that is longer than this read.
                    if !skipping {
                        if carry.count + count > limits.lineMax {
                            skipping = true
                            carry = []
                            result.linesSkipped += 1
                        } else {
                            carry = bytes + carry
                        }
                    }
                    return
                }
                let last = b.lastIndex(of: 0x0A) ?? first
                // The line that runs from after this read's last newline into the carried bytes: the newest here.
                if skipping {
                    skipping = false
                } else if (count - last - 1) + carry.count <= limits.lineMax {
                    let line = Array(b[(last + 1)...]) + carry
                    result.peakBytes = max(result.peakBytes, bytes.count + carry.count + line.count)
                    examine(line, sites: sites, into: &result)
                } else {
                    result.linesSkipped += 1
                }
                // Lines wholly inside this read, newest first.
                if last > first { examineRegion(b, from: first + 1, to: last, sites: sites, into: &result) }
                // The part before the first newline ends a line that starts earlier.
                carry = Array(b[..<first])
                if carry.count > limits.lineMax {
                    carry = []
                    skipping = true
                    result.linesSkipped += 1
                }
            }
            end = start
            if result.link != nil, result.builderFound { return finish(&result, .complete) }
        }
        if !skipping, !carry.isEmpty, result.link == nil || !result.builderFound { examine(carry, sites: sites, into: &result) }
        return finish(&result, result.link != nil && result.builderFound ? .complete : .startOfFile)
    }

    private static func finish(_ result: inout Result, _ stop: Stop) -> Result {
        result.stop = stop
        return result
    }

    /// The complete lines in `b[from..<to]` that hold a marker, newest first.
    private static func examineRegion(_ b: UnsafeBufferPointer<UInt8>, from: Int, to: Int, sites: CodeDashboardSites,
                                      into result: inout Result) {
        guard let base = b.baseAddress, to > from else { return }
        var lines: [Range<Int>] = []
        var seenStarts = Set<Int>()
        for marker in sites.all.map(\.marker) + [builderMarker] {
            var at = from
            while at < to {
                let hit = marker.withUnsafeBytes { needle in memmem(base + at, to - at, needle.baseAddress, marker.count) }
                guard let hit else { break }
                let position = UnsafeRawPointer(base).distance(to: UnsafeRawPointer(hit))
                var lineStart = position
                while lineStart > from, b[lineStart - 1] != 0x0A { lineStart -= 1 }
                var lineEnd = position
                while lineEnd < to, b[lineEnd] != 0x0A { lineEnd += 1 }
                if seenStarts.insert(lineStart).inserted { lines.append(lineStart..<lineEnd) }
                at = lineEnd + 1
            }
        }
        for range in lines.sorted(by: { $0.lowerBound > $1.lowerBound }) {
            guard result.link == nil || !result.builderFound else { return }
            examine(UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(b)[range]), sites: sites, into: &result)
        }
    }

    private static func examine(_ line: [UInt8], sites: CodeDashboardSites, into result: inout Result) {
        line.withUnsafeBytes { examine($0, sites: sites, into: &result) }
    }

    /// One line: skipped without a marker; else parsed, and only the session's own writing counts.
    private static func examine(_ line: UnsafeRawBufferPointer, sites: CodeDashboardSites, into result: inout Result) {
        guard let base = line.baseAddress, line.count > 0 else { return }
        let holdsLink = DashboardLink.mayHoldLink(line, sites: sites)
        let holdsBuilder = builderMarker.withUnsafeBytes { memmem(base, line.count, $0.baseAddress, builderMarker.count) } != nil
        guard holdsLink || holdsBuilder else { return }
        result.linesParsed += 1
        guard let entry = TranscriptEntry.parse(line, digestFacts: true), entry.kind == .assistant, !entry.isSidechain
        else { return }
        for block in entry.blocks.reversed() {
            switch block {
            case .text(let text, _):
                if result.link == nil, let link = DashboardLink.newestLink(in: text, sites: sites) {
                    result.link = DashboardSighting(handle: link.handle, site: link.site.key, at: entry.timestamp)
                }
            case .toolUse(let tool):
                guard DashboardTracker.isBuilderCall(name: tool.name, subagentType: tool.input.subagentType) else { continue }
                if !result.builderFound {
                    result.builderFound = true
                    result.builderAt = entry.timestamp
                }
                if result.link == nil, let prompt = tool.input.prompt, let link = DashboardLink.newestLink(in: prompt, sites: sites) {
                    result.link = DashboardSighting(handle: link.handle, site: link.site.key, at: entry.timestamp)
                }
            default:
                continue
            }
        }
    }
}
