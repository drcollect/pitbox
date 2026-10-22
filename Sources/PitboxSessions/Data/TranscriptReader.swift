import Darwin
import Foundation

/// One line of a transcript as read: its entry (nil when the line could not be read: bad JSON by the strict rules, or
/// longer than `TranscriptReader.maxLineBytes`), where it starts and how many bytes it has (newline not counted).
struct TranscriptLine: Equatable, Sendable {
    var entry: TranscriptEntry?
    var offset: Int64
    var length: Int

    /// The offset just past this line's newline.
    var end: Int64 { offset + Int64(length) + 1 }
}

/// Where reading a transcript stands: the file's identity and size at the last read, the next byte to read
/// (the start of an unfinished last line, or the end of the file), and whether the bytes from there on still belong to a
/// line whose start was not read (they are dropped up to the next newline).
struct TranscriptCursor: Equatable, Sendable {
    var identity: FileIdentity
    var nextOffset: Int64
    var dropUntilNewline = false
}

/// The result of one transcript read.
struct TranscriptRead: Equatable, Sendable {
    /// Why a read started over from a fresh tail.
    enum FreshReason: String, Equatable, Sendable {
        /// Nothing was read before.
        case first
        /// A new inode (the file was replaced): offers are dropped.
        case replaced
        /// Smaller than before (the file was cut): offers are dropped.
        case cut
        /// More was appended than a tail holds: read the end again instead of everything since.
        case gap
    }

    enum Kind: Equatable, Sendable {
        case fresh(FreshReason)
        case appended
        case unchanged
    }

    var kind: Kind
    /// The lines read, in file order.
    var lines: [TranscriptLine]
    var cursor: TranscriptCursor
    /// Fresh reads only: the window holds the user entry that started the latest turn, or the whole file.
    var holdsTurnStart: Bool
    /// Fresh reads only: the window reached the start of the file.
    var reachedFileStart: Bool
}

/// Reads the end of a transcript: the last 256 KB, grown in 256 KB steps up to 2 MB until the window holds the
/// user entry that started the latest turn; afterwards only what was appended (a new inode, a smaller size or a
/// jump of more than 2 MB starts over from a fresh tail). A line cut by the window's start is dropped, and so is an
/// unfinished last line (it is read whole next time). Files are opened through `CarefulFiles` (no link followed, regular
/// files of the user only); lines are read in 1 MB chunks, memory stays at the window plus at most one long line.
enum TranscriptReader {
    static let tailStep = 256 * 1024
    static let tailLimit = 2 * 1024 * 1024
    /// Longer lines (huge tool results) are skipped as they stream by and count as unreadable.
    static let maxLineBytes = 8 * 1024 * 1024
    static let chunkBytes = 1 << 20

    /// Reads `path` from `cursor` on, or a fresh tail when there is no cursor or it no longer fits the file. With
    /// `digestFacts`, lines are parsed for the turn digest too (`TranscriptEntry.parse(_:digestFacts:)`). `reaches`
    /// makes a fresh tail grow further (still at most 2 MB) until it is true of the window's lines as well (the
    /// digest's reach); nil keeps the latest turn's rule alone.
    static func read(_ path: CarefulPath, owner: uid_t, cursor: TranscriptCursor?, digestFacts: Bool = false,
                     reaches: (([TranscriptLine]) -> Bool)? = nil) -> Result<TranscriptRead, CarefulReadFailure> {
        let outcome = CarefulFiles.withFile(path, owner: owner) { fd, identity -> TranscriptRead? in
            func fresh(_ reason: TranscriptRead.FreshReason) -> TranscriptRead? {
                freshTail(fd: fd, identity: identity, reason: reason, digestFacts: digestFacts, reaches: reaches)
            }
            guard let cursor else { return fresh(.first) }
            if !cursor.identity.isSameFile(as: identity) { return fresh(.replaced) }
            if identity.size < cursor.identity.size { return fresh(.cut) }
            if identity.size == cursor.identity.size, identity.modified == cursor.identity.modified {
                var same = cursor
                same.identity = identity
                return TranscriptRead(kind: .unchanged, lines: [], cursor: same, holdsTurnStart: false, reachedFileStart: false)
            }
            if identity.size - cursor.nextOffset > Int64(tailLimit) { return fresh(.gap) }
            guard let scanned = scan(fd: fd, from: cursor.nextOffset, to: identity.size, dropping: cursor.dropUntilNewline,
                                     reachesEnd: true, digestFacts: digestFacts) else { return nil }
            let next = TranscriptCursor(identity: identity, nextOffset: scanned.next, dropUntilNewline: scanned.dropping)
            return TranscriptRead(kind: .appended, lines: scanned.lines, cursor: next, holdsTurnStart: false,
                                  reachedFileStart: false)
        }
        switch outcome {
        case .failure(let failure): return .failure(failure)
        case .success(let read): return read.map { .success($0) } ?? .failure(.unreadable)
        }
    }

    /// Whether `entry` starts a turn: a user entry that is not a tool result, outside subagent side chains.
    static func startsTurn(_ entry: TranscriptEntry?) -> Bool {
        guard let entry else { return false }
        return entry.kind == .user && !entry.isToolResult && !entry.isSidechain
    }

    // MARK: Internals

    private static func freshTail(fd: Int32, identity: FileIdentity, reason: TranscriptRead.FreshReason, digestFacts: Bool,
                                  reaches: (([TranscriptLine]) -> Bool)?) -> TranscriptRead? {
        let size = identity.size
        var lines: [TranscriptLine] = []
        var span = Int64(tailStep)
        // The start of the earliest line already parsed; nil while no complete line has been found.
        var parsedFrom: Int64?
        var next = size
        var dropping = false
        while true {
            let from = max(0, size - span)
            if let boundary = parsedFrom {
                if from < boundary {
                    guard let earlier = scan(fd: fd, from: from, to: boundary, dropping: from > 0, reachesEnd: false,
                                             digestFacts: digestFacts) else { return nil }
                    lines.insert(contentsOf: earlier.lines, at: 0)
                    if let first = earlier.firstLineStart { parsedFrom = first }
                }
            } else {
                guard let window = scan(fd: fd, from: from, to: size, dropping: from > 0, reachesEnd: true,
                                        digestFacts: digestFacts) else { return nil }
                lines = window.lines
                next = window.next
                dropping = window.dropping
                parsedFrom = window.firstLineStart
            }
            let reachedStart = from == 0
            let holds = reachedStart || lines.contains { startsTurn($0.entry) }
            let farEnough = reachedStart || (holds && (reaches?(lines) ?? true))
            if farEnough || span >= Int64(tailLimit) {
                return TranscriptRead(kind: .fresh(reason), lines: lines,
                                      cursor: TranscriptCursor(identity: identity, nextOffset: next, dropUntilNewline: dropping),
                                      holdsTurnStart: holds, reachedFileStart: reachedStart)
            }
            span = min(span + Int64(tailStep), Int64(tailLimit))
        }
    }

    /// The complete lines in `[from, to)`. With `dropping`, the bytes up to the first newline are dropped (they belong to
    /// a line that started earlier). With `reachesEnd`, bytes after the last newline are an unfinished line: `next` is
    /// its start (it is read whole next time), or the end when it is being dropped. `firstLineStart` is where the first
    /// complete line (after any dropped bytes) begins; nil when no newline was found while dropping.
    private static func scan(fd: Int32, from: Int64, to: Int64, dropping startDropping: Bool, reachesEnd: Bool,
                             digestFacts: Bool) -> (lines: [TranscriptLine], next: Int64, dropping: Bool, firstLineStart: Int64?)? {
        var lines: [TranscriptLine] = []
        var pending: [UInt8] = []
        var dropping = startDropping
        var position = from
        var lineStart = from
        var firstLineStart: Int64? = startDropping ? nil : from

        func emit(_ bytes: UnsafeRawBufferPointer, start: Int64) {
            if isBlank(bytes) { return }
            lines.append(TranscriptLine(entry: TranscriptEntry.parse(bytes, digestFacts: digestFacts), offset: start,
                                        length: bytes.count))
        }

        while position < to {
            let want = Int(min(Int64(chunkBytes), to - position))
            guard let chunk = CarefulFiles.readRange(fd: fd, from: position, count: want) else { return nil }
            if chunk.isEmpty { break }
            chunk.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var index = 0
                while index < chunk.count {
                    guard let found = memchr(base + index, 0x0A, chunk.count - index) else {
                        let rest = chunk.count - index
                        if !dropping {
                            if pending.count + rest > maxLineBytes {
                                // Too long to hold: counted once as unreadable, then dropped up to its newline.
                                lines.append(TranscriptLine(entry: nil, offset: lineStart, length: pending.count + rest))
                                pending = []
                                dropping = true
                            } else {
                                pending.append(contentsOf: UnsafeRawBufferPointer(start: base + index, count: rest))
                            }
                        }
                        index = chunk.count
                        break
                    }
                    let newline = base.distance(to: found)
                    let length = newline - index
                    let nextStart = position + Int64(newline + 1)
                    if dropping {
                        dropping = false
                        pending = []
                        if firstLineStart == nil { firstLineStart = nextStart }
                    } else if pending.isEmpty {
                        if length > maxLineBytes {
                            lines.append(TranscriptLine(entry: nil, offset: lineStart, length: length))
                        } else {
                            emit(UnsafeRawBufferPointer(start: base + index, count: length), start: lineStart)
                        }
                    } else if pending.count + length > maxLineBytes {
                        lines.append(TranscriptLine(entry: nil, offset: lineStart, length: pending.count + length))
                        pending = []
                    } else {
                        pending.append(contentsOf: UnsafeRawBufferPointer(start: base + index, count: length))
                        pending.withUnsafeBytes { emit($0, start: lineStart) }
                        pending = []
                    }
                    lineStart = nextStart
                    index = newline + 1
                }
            }
            position += Int64(chunk.count)
        }
        if !reachesEnd { return (lines, position, false, firstLineStart) }
        if dropping { return (lines, position, true, firstLineStart) }
        return (lines, pending.isEmpty ? position : lineStart, false, firstLineStart)
    }

    private static func isBlank(_ bytes: UnsafeRawBufferPointer) -> Bool {
        for byte in bytes where byte != 0x20 && byte != 0x09 && byte != 0x0D { return false }
        return true
    }
}
