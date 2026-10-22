import Foundation

/// A token bucket: `capacity` tokens, refilled at `rate` per second up to `capacity`; each line takes one. The dock's
/// line rate rule (docs/DOCK_PROTOCOL.md "Framing"): a receiver that finds the bucket empty treats the line as a
/// violation, and a sender paces itself with a smaller bucket so it never comes near the receiver's.
struct TokenBucket {
    let capacity: Double
    let rate: Double
    private(set) var tokens: Double
    private var updated: TimeInterval?

    init(capacity: Int, perSecond rate: Int) {
        self.capacity = Double(capacity)
        self.rate = Double(rate)
        tokens = Double(capacity)
    }

    /// Adds the tokens earned since the last call (time never runs backwards here: an earlier `now` adds nothing).
    private mutating func refill(_ now: TimeInterval) {
        guard let last = updated else {
            updated = now
            return
        }
        guard now > last else { return }
        tokens = min(capacity, tokens + (now - last) * rate)
        updated = now
    }

    /// Takes a token if there is one.
    mutating func take(at now: TimeInterval) -> Bool {
        refill(now)
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }

    /// When the next token is there (now, if one is).
    mutating func nextToken(after now: TimeInterval) -> TimeInterval {
        refill(now)
        return tokens >= 1 ? now : now + (1 - tokens) / rate
    }
}

/// Splits the byte stream of one connection into lines and enforces the framing limits: at most
/// `DockProtocol.maxLineBytes` bytes before the newline (a longer line is a violation as soon as it is seen, without
/// waiting for its end), and at most `DockProtocol.maxLinesPerSecond` lines a second (a bucket of 50, refilled at 50 a
/// second). Blank lines carry nothing but count against the rate.
struct DockLineFramer {
    enum Output: Equatable {
        case line([UInt8])
        case violation(String)
    }

    private var pending: [UInt8] = []
    private var bucket = TokenBucket(capacity: DockProtocol.maxLinesPerSecond, perSecond: DockProtocol.maxLinesPerSecond)
    private(set) var failed = false
    private(set) var blankLines = 0

    /// Feeds bytes read at `now`; returns the complete lines in order, ending with a violation if one occurred (after
    /// which the framer takes nothing more).
    mutating func feed(_ bytes: UnsafeRawBufferPointer, at now: TimeInterval) -> [Output] {
        guard !failed else { return [] }
        var out: [Output] = []
        for byte in bytes {
            if byte == 0x0A {
                guard bucket.take(at: now) else {
                    failed = true
                    out.append(.violation("rate"))
                    return out
                }
                var line = pending
                pending.removeAll(keepingCapacity: true)
                if line.last == 0x0D { line.removeLast() }
                if line.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) {
                    blankLines += 1
                    continue
                }
                out.append(.line(line))
            } else {
                pending.append(byte)
                if pending.count > DockProtocol.maxLineBytes {
                    failed = true
                    pending.removeAll()
                    out.append(.violation("line too long"))
                    return out
                }
            }
        }
        return out
    }

    /// Feeds bytes from an array (tests).
    mutating func feed(_ bytes: [UInt8], at now: TimeInterval) -> [Output] {
        bytes.withUnsafeBytes { feed($0, at: now) }
    }

    /// Bytes of an unfinished line held.
    var pendingCount: Int { pending.count }
}
