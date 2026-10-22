import Foundation

/// What `ssh -G <alias>` printed for the alias: the effective settings after the user's
/// config, read from its `key value` lines. Only run when no file has a `Match` block; it never connects.
struct SSHResolution: Equatable, Sendable {
    var hostName: String?
    /// The user ssh logs in as when none is given (the config's `User`, else the local account).
    var user: String?
    var proxyJump: String?
    var proxyCommand: String?
    /// `KnownHostsCommand` also runs a program of the user's when connecting, like a proxy command.
    var knownHostsCommand: String?

    init(hostName: String? = nil, user: String? = nil, proxyJump: String? = nil, proxyCommand: String? = nil,
         knownHostsCommand: String? = nil) {
        self.hostName = hostName; self.user = user; self.proxyJump = proxyJump; self.proxyCommand = proxyCommand
        self.knownHostsCommand = knownHostsCommand
    }

    /// Parses `ssh -G` output: lowercase keys, one space, the value. Keys it does not use are ignored; `none` means
    /// unset. The first line of a key wins (ssh prints each once).
    init(output: String) {
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            guard let space = line.firstIndex(of: " ") else { continue }
            let key = String(line[line.startIndex..<space]).lowercased()
            let value = String(line[line.index(after: space)...]).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, value.lowercased() != "none", values[key] == nil else { continue }
            values[key] = value
        }
        self.init(hostName: values["hostname"], user: values["user"], proxyJump: values["proxyjump"],
                  proxyCommand: values["proxycommand"], knownHostsCommand: values["knownhostscommand"])
    }

    /// The line for the sheet: "through <jump>", "your config runs a proxy command", and a known-hosts command when
    /// there is one; nil when the alias connects directly.
    var proxyNote: String? {
        var notes: [String] = []
        if let jump = proxyJump {
            let printable = jump.count <= 120 && jump.unicodeScalars.allSatisfy { $0.isASCII && $0.value >= 0x20 && $0.value < 0x7F }
            notes.append(printable ? "through \(jump)" : "through a jump host")
        }
        if proxyCommand != nil { notes.append("your config runs a proxy command") }
        if knownHostsCommand != nil { notes.append("your config runs a known-hosts command") }
        return notes.isEmpty ? nil : notes.joined(separator: "; ")
    }
}

/// Looks an alias up the way `ssh -G <alias>` does; nil when that failed or timed out. Injected in tests.
typealias SSHResolver = @Sendable (_ alias: String) async -> SSHResolution?
