import CoreGraphics
import Foundation
import PitboxKit
import Testing
@testable import PitboxDock

/// The link invariant (docs/DOCK_PROTOCOL.md §11, "What the link can never do"): no message reaches the run
/// sheet, the console, the parker, an opener, the settings writer or anything that runs, types, opens, parks, restores
/// or reads back. PitboxDock imports none of those modules and names none of those things; its messages carry no
/// session content; the guest's callbacks carry plain values; its public surface is exactly the list below.
@Suite struct LinkInvariantTests {
    private struct SourceFile {
        let name: String
        let text: String
        /// The text without comments and without the contents of string literals (so words in messages and docs do
        /// not count, and code does).
        let code: String
    }

    private static func sources() throws -> [SourceFile] {
        // <package>/Tests/PitboxDockTests/<this file>: up three folders, then Sources/PitboxDock.
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let folder = root.appendingPathComponent("Sources/PitboxDock")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".swift") }.sorted()
        return try names.map { name in
            let text = try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
            return SourceFile(name: name, text: text, code: stripCommentsAndStrings(text))
        }
    }

    /// Drops `//` comments, `/* */` comments and the insides of string literals (simple and raw `#"…"#` ones).
    private static func stripCommentsAndStrings(_ text: String) -> String {
        var out = ""
        var index = text.startIndex
        func peek(_ offset: Int) -> Character? {
            guard let at = text.index(index, offsetBy: offset, limitedBy: text.endIndex), at < text.endIndex else { return nil }
            return text[at]
        }
        while index < text.endIndex {
            let char = text[index]
            if char == "/", peek(1) == "/" {
                while index < text.endIndex, text[index] != "\n" { index = text.index(after: index) }
                continue
            }
            if char == "/", peek(1) == "*" {
                index = text.index(index, offsetBy: 2)
                while index < text.endIndex, !(text[index] == "*" && peek(1) == "/") { index = text.index(after: index) }
                index = text.index(index, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
                continue
            }
            if char == "\"" || (char == "#" && peek(1) == "\"") {
                let raw = char == "#"
                if raw { index = text.index(after: index) }
                let triple = peek(1) == "\"" && peek(2) == "\""
                index = text.index(index, offsetBy: triple ? 3 : 1)
                out += "\"\""
                while index < text.endIndex {
                    let current = text[index]
                    if !raw, current == "\\" {
                        index = text.index(index, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
                        continue
                    }
                    if current == "\"" {
                        if triple {
                            if peek(1) == "\"", peek(2) == "\"" {
                                index = text.index(index, offsetBy: 3)
                                if raw, index < text.endIndex, text[index] == "#" { index = text.index(after: index) }
                                break
                            }
                        } else if !raw || peek(1) == "#" {
                            index = text.index(index, offsetBy: raw ? 2 : 1)
                            break
                        }
                    }
                    index = text.index(after: index)
                }
                continue
            }
            out.append(char)
            index = text.index(after: index)
        }
        return out
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return ["bad pattern \(pattern)"] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    // MARK: Modules and references

    @Test func pitboxDockImportsNothingThatRunsOrShowsSessions() throws {
        let files = try Self.sources()
        #expect(files.count >= 10, "the scan sees the module's files")
        let allowed: Set<String> = ["Foundation", "Darwin", "CoreGraphics", "AppKit", "PitboxKit"]
        for file in files {
            for line in file.code.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("import ") || trimmed.hasPrefix("@testable import ") || trimmed.contains(" import ") else { continue }
                let module = trimmed.split(separator: " ").last.map(String.init) ?? ""
                #expect(allowed.contains(module), "\(file.name) imports \(module)")
            }
            for module in ["PitboxConsole", "PitboxSessions", "PitboxShell", "PitboxGuard", "SwiftTerm", "WebKit"] {
                #expect(Self.matches("\\bimport\\s+\(module)\\b", in: file.code).isEmpty, "\(file.name) imports \(module)")
            }
        }
    }

    @Test func pitboxDockNamesNothingThatRunsTypesOpensParksOrWritesSettings() throws {
        let forbidden: [(pattern: String, what: String)] = [
            ("CommandSheet|CommandOffer|CommandSpawn|CommandSandbox|CommandRunPolicy|runOrType", "the run sheet and the run path"),
            ("Console(Host|Drawer|Seam|CommandHooks)|Terminal(Session|Process)|PTYProcess", "the console"),
            ("SandboxMemory", "the sandbox memory (the app passes announced folders on)"),
            ("Parker|parkFrontmost|DragToPark|DeskTag|WindowGuard|WindowDropClaims|lookAgain", "parking and the window guard"),
            ("\\brestore", "restoring windows"),
            ("SettingsWriter|CodeSettings|SettingsChange|settings\\.json|settingsFile", "the settings writer"),
            ("\\.open\\(|openApplication|launchApplication|openURL|NSWorkspace\\.shared\\.(open|launch)", "an opener"),
            ("\\bProcess\\b|NSTask|posix_spawn|\\bexec[lv]p?e?\\(|\\bfork\\(|\\bsystem\\(|popen|NSAppleScript", "starting processes"),
            ("AXUIElement|CGEvent(Post|Create)|CGEvent\\(|NSPasteboard|insertText|typeText|keyDown", "typing, pressing or the clipboard"),
            ("URLSession|NSURLConnection|WKWebView|CFSocket|Network\\.", "the network"),
            ("\\.write\\(to:|createFile|removeItem|moveItem|copyItem|FileHandle\\(forWriting", "writing files"),
            ("transcript|headline|tldr|TL;DR|sessionText|ReadyItem|CodeSession", "session content"),
            ("killpg|\\braise\\(|pthread_kill|sigqueue|Darwin\\.kill|\\bsignal\\(|sigaction", "sending signals"),
            ("(?<![A-Za-z_.])open\\(|fopen|\\bcreat\\(|openat|\\btruncate|ftruncate|\\blink\\(|symlink\\(|rmdir|removefile",
             "opening, creating or deleting files"),
        ]
        for file in try Self.sources() {
            for (pattern, what) in forbidden {
                let hits = Self.matches(pattern, in: file.code)
                #expect(hits.isEmpty, "\(file.name) reaches \(what): \(hits)")
            }
            // The few calls that touch the file system or another process, each pinned: the listener's own socket and
            // folder, and the liveness probe of the host's pid (signal 0 sends nothing).
            let pinned: [(pattern: String, allowed: Set<String>)] = [
                ("\\bunlink\\([^)]*\\)", ["unlink(socketPath)", "unlink(temporary)"]),
                ("\\brename\\([^)]*\\)", ["rename(temporary, socketPath)"]),
                ("\\bchmod\\([^)]*\\)", ["chmod(temporary, 0o600)", "chmod(folder, 0o700)"]),
                ("\\bmkdir\\([^)]*\\)", ["mkdir(folder, 0o700)"]),
                ("\\bkill\\([^)]*\\)", ["kill(host.pid, 0)"]),
            ]
            for (pattern, allowed) in pinned {
                for call in Self.matches(pattern, in: file.code) {
                    #expect(allowed.contains(call), "\(file.name): \(call)")
                }
            }
        }
    }

    // MARK: Messages

    /// A compile-time pin: a new host message must be added here, with what it may do.
    private func effect(of message: HostMessage) -> String {
        switch message {
        case .hello: return "handshake: version, features, the host's name, wake words, private folders"
        case .place: return "geometry"
        case .appearance: return "look"
        case .focus: return "focus key"
        case .speechOK, .speechNo: return "speech answer"
        case .fold: return "fold"
        case .ping, .pong, .bye: return "link"
        }
    }

    /// A compile-time pin of the guest's messages.
    private func content(of message: GuestMessage) -> String {
        switch message {
        case .hello, .busy, .ping, .pong, .bye: return "protocol words"
        case .area: return "a frame and flags"
        case .claim, .release, .mouseUp: return "a pid and a window number"
        case .attention: return "counts"
        case .speechBegin, .speechEnd: return "a number"
        }
    }

    @Test func theGuestsLinesCarryNoSessionContent() throws {
        let samples: [GuestMessage] = [
            DockGuestHello(build: "1.0.0", features: DockFeature.all).message, .busy,
            .area(seq: 1, frame: CGRect(x: 1, y: 2, width: 3, height: 4), folded: true, visible: false),
            .claim(pid: 1, windowNumber: 2), .release(pid: 1, windowNumber: 2, parked: false), .mouseUp,
            .attention(needsYou: 1, finished: 2, running: 3), .speechBegin(id: 1), .speechEnd(id: 1),
            .ping, .pong,
        ] + DockByeReason.allCases.map(GuestMessage.bye)
        var words: Set<String> = ["hello", "busy", "area", "claim", "release", "mouseUp", "attention", "speech.begin",
                                  "speech.end", "ping", "pong", "bye", "guest", AppIdentity.displayName, "1.0.0"]
        words.formUnion(DockFeature.allCases.map(\.rawValue))
        words.formUnion(DockByeReason.allCases.map(\.rawValue))
        for message in samples {
            #expect(!content(of: message).isEmpty)
            let value = try StrictJSON.parse(Array(DockWire.encode(message).dropLast()))
            for text in strings(in: value) {
                #expect(words.contains(text), "a guest line carries \(text.debugDescription)")
            }
        }
        let hostSamples: [HostMessage] = [FakeHost.hello(), .place(FakeHost.place()), .appearance(.system),
                                          .focus(.all), .speechOK(id: 1), .speechNo(id: 1, why: .talk), .fold(true),
                                          .ping, .pong, .bye(.quit)]
        for message in hostSamples { #expect(!effect(of: message).isEmpty) }
    }

    private func strings(in value: JSONValue) -> [String] {
        switch value {
        case .string(let text): return [text]
        case .array(let list): return list.flatMap(strings(in:))
        case .object(let members): return members.values.flatMap(strings(in:))
        default: return []
        }
    }

    @Test func theGuestDispatchesHostMessagesOnlyToItsPlainCallbacks() throws {
        let guest = try #require(try Self.sources().first { $0.name == "DockGuest.swift" })
        let start = try #require(guest.code.range(of: "private func handle(_ message: HostMessage)"))
        let rest = guest.code[start.upperBound...]
        let end = try #require(rest.range(of: "\n    }\n"))
        let body = String(rest[..<end.lowerBound])
        let calls = Set(Self.matches("[A-Za-z_][A-Za-z0-9_]*\\??\\(", in: body).map { $0.replacingOccurrences(of: "?", with: "") })
        let allowed: Set<String> = ["applyPlace(", "onAppearance(", "onFocus(", "onFold(", "speechOK(", "speechNo(",
                                    "place(", "appearance(", "focus(", "fold(", "let(", "speechNo(", "bye("]
        #expect(!calls.isEmpty)
        for call in calls { #expect(allowed.contains(call), "the dispatch calls \(call)") }
    }

    // MARK: Callbacks carry plain values

    @Test func theGuestsCallbacksTakePlainValuesOnly() throws {
        let guest = try #require(try Self.sources().first { $0.name == "DockGuest.swift" })
        let callbacks = guest.text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("public var on") }
        #expect(callbacks.count == 8, "a new callback is a decision this test must be changed for")
        let allowedTypes: Set<String> = ["DockGuestState", "HostPlace", "DockAppearance", "DockFocus", "Bool", "String",
                                         "HostPrivateFolders", "Void"]
        for callback in callbacks {
            guard let colon = callback.firstIndex(of: ":") else { continue }
            let type = String(callback[callback.index(after: colon)...])
            for name in Self.matches("[A-Z][A-Za-z0-9]*", in: type) {
                #expect(allowedTypes.contains(name), "\(callback): \(name) is not a plain value of the link")
            }
        }
    }

    /// No reference type anywhere inside the values the callbacks and the state carry.
    @Test func theCarriedValuesHoldNoObjects() {
        let place = FakeHost.place()
        let values: [Any] = [
            place, DockAppearance(scheme: .dark, backdrop: .solid), DockFocus.named("Acme"),
            HostPrivateFolders(folders: ["/a"], socketFolders: ["/b"]),
            DockGuestState.docked(place, DockFeature.all), DockGuestState.hostNotResponding(place, [.speech]),
            DockGuestState.refused(.version(ours: 1...1, theirs: 2...2)), DockGuestState.refused(.notListed(bundleID: "a.b")),
            SpeechAnswer.no(.host(.talk)), DockWarning.hostWithoutDockSupport, ["hey host"],
        ]
        func check(_ value: Any, path: String) {
            let mirror = Mirror(reflecting: value)
            #expect(mirror.displayStyle != .class, "\(path) is an object")
            for child in mirror.children { check(child.value, path: path + "." + (child.label ?? "?")) }
        }
        for value in values { check(value, path: "\(type(of: value))") }
    }

    // MARK: The public surface, pinned

    @Test func thePublicSurfaceIsExactlyThis() throws {
        var found: [String] = []
        for file in try Self.sources() {
            for line in file.text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//") else { continue }
                let declares = ["public ", "open "].contains { trimmed.hasPrefix($0) }
                    || [" public func ", " public var ", " public init", " public static ", " public subscript",
                        " public let ", " open func ", " open var ", " open class ", " public enum ", " public struct ",
                        " public final class ", " public private(set) var "].contains { trimmed.contains($0) }
                guard declares else { continue }
                let head = trimmed.components(separatedBy: " {").first ?? trimmed
                found.append("\(file.name): \(head)")
            }
        }
        let expected = Set(Self.publicSurface)
        let actual = Set(found)
        for extra in actual.subtracting(expected).sorted() { Issue.record("new public API: \(extra)") }
        for missing in expected.subtracting(actual).sorted() { Issue.record("public API gone: \(missing)") }
        #expect(found.sorted() == Self.publicSurface.sorted(), "the same declarations, as often")
    }

    /// Every public declaration of PitboxDock (file: declaration head). A change here is a decision about what the app
    /// can reach through the dock module; it must keep the invariant above.
    static let publicSurface: [String] = [
        "DockGuest+Send.swift: public func claim(pid: pid_t, windowNumber: UInt32)",
        "DockGuest+Send.swift: public func endSpeech()",
        "DockGuest+Send.swift: public func mouseUp()",
        "DockGuest+Send.swift: public func release(pid: pid_t, windowNumber: UInt32, parked: Bool)",
        "DockGuest+Send.swift: public func requestSpeech() async -> SpeechAnswer",
        "DockGuest+Send.swift: public func sendArea(frame: CGRect, folded: Bool, visible: Bool, seq: Int? = nil)",
        "DockGuest+Send.swift: public func sendAttention(needsYou: Int, finished: Int, running: Int)",
        "DockGuest.swift: public convenience init(listener: DockListener, configuration: Configuration)",
        "DockGuest.swift: public final class DockGuest",
        "DockGuest.swift: public func bye(_ why: DockByeReason)",
        "DockGuest.swift: public func setEnabled(_ enabled: Bool)",
        "DockGuest.swift: public func setHosts(_ hosts: [String])",
        "DockGuest.swift: public func start()",
        "DockGuest.swift: public func stop()",
        "DockGuest.swift: public init(enabled: Bool = true, hosts: [String] = [], build: String = \"0\", features: Set<DockFeature> = DockFeature.all)",
        "DockGuest.swift: public private(set) var configuration: Configuration",
        "DockGuest.swift: public private(set) var hostName: String?",
        "DockGuest.swift: public private(set) var state: DockGuestState = .alone",
        "DockGuest.swift: public private(set) var warning: DockWarning?",
        "DockGuest.swift: public static let noConnectionWait: TimeInterval = 5",
        "DockGuest.swift: public static let speechAnswerWait: TimeInterval = 2",
        "DockGuest.swift: public static let speechEndBackstop: TimeInterval = 60",
        "DockGuest.swift: public static let startWait: TimeInterval = 1",
        "DockGuest.swift: public struct Configuration: Equatable, Sendable",
        "DockGuest.swift: public var build: String",
        "DockGuest.swift: public var enabled: Bool",
        "DockGuest.swift: public var features: Set<DockFeature>",
        "DockGuest.swift: public var features: Set<DockFeature>",
        "DockGuest.swift: public var hosts: [String]",
        "DockGuest.swift: public var isConnected: Bool",
        "DockGuest.swift: public var onAppearance: ((DockAppearance) -> Void)?",
        "DockGuest.swift: public var onFocus: ((DockFocus) -> Void)?",
        "DockGuest.swift: public var onFold: ((Bool) -> Void)?",
        "DockGuest.swift: public var onHostAnnouncement: ((HostPrivateFolders) -> Void)?",
        "DockGuest.swift: public var onHostPrivateFolders: ((HostPrivateFolders) -> Void)?",
        "DockGuest.swift: public var onHostWakeWords: (([String]) -> Void)?",
        "DockGuest.swift: public var onPlace: ((HostPlace?) -> Void)?",
        "DockGuest.swift: public var onStateChanged: ((DockGuestState) -> Void)?",
        "DockGuest.swift: public var statusLine: String?",
        "DockGuestState.swift: public enum DockGuestState: Equatable, Sendable",
        "DockGuestState.swift: public enum DockWarning: Equatable, Sendable",
        "DockGuestState.swift: public enum SpeechAnswer: Equatable, Sendable",
        "DockGuestState.swift: public enum SpeechRefusal: Equatable, Sendable",
        "DockGuestState.swift: public var isDocked: Bool",
        "DockGuestState.swift: public var place: HostPlace?",
        "DockListener.swift: public convenience init(socketPath: String = Paths.dockSocketPath)",
        "DockListener.swift: public enum DockListenerError: Error, Equatable, Sendable",
        "DockListener.swift: public final class DockListener: @unchecked Sendable",
        "DockListener.swift: public func bind(configuration: DockGuest.Configuration) throws",
        "DockListener.swift: public func stop()",
        "DockListener.swift: public let socketPath: String",
        "DockListener.swift: public var isBound: Bool",
        "DockMessages.swift: public enum Backdrop: String, Sendable, CaseIterable",
        "DockMessages.swift: public enum DockFocus: Equatable, Sendable",
        "DockMessages.swift: public enum Level: String, Sendable, CaseIterable",
        "DockMessages.swift: public enum Scheme: String, Sendable, CaseIterable",
        "DockMessages.swift: public init(folders: [String] = [], socketFolders: [String] = [])",
        "DockMessages.swift: public init(scheme: Scheme = .system, backdrop: Backdrop = .glass)",
        "DockMessages.swift: public init(seq: Int, displayID: UInt32, displayUUID: String? = nil, edge: Edge, host: CGRect, visible: Bool = true,",
        "DockMessages.swift: public init(width: Double, gutter: Double = 12, padding: Double = 16, row: Double = 69)",
        "DockMessages.swift: public static let system = DockAppearance()",
        "DockMessages.swift: public struct Cell: Equatable, Sendable",
        "DockMessages.swift: public struct DockAppearance: Equatable, Sendable",
        "DockMessages.swift: public struct HostPlace: Equatable, Sendable",
        "DockMessages.swift: public struct HostPrivateFolders: Equatable, Sendable",
        "DockMessages.swift: public var backdrop: Backdrop",
        "DockMessages.swift: public var cell: Cell",
        "DockMessages.swift: public var displayID: UInt32",
        "DockMessages.swift: public var displayUUID: String?",
        "DockMessages.swift: public var edge: Edge",
        "DockMessages.swift: public var folders: [String]",
        "DockMessages.swift: public var gutter: Double",
        "DockMessages.swift: public var host: CGRect",
        "DockMessages.swift: public var isEmpty: Bool",
        "DockMessages.swift: public var key: String",
        "DockMessages.swift: public var level: Level",
        "DockMessages.swift: public var live: Bool",
        "DockMessages.swift: public var maxWidth: Double",
        "DockMessages.swift: public var padding: Double",
        "DockMessages.swift: public var row: Double",
        "DockMessages.swift: public var scheme: Scheme",
        "DockMessages.swift: public var seq: Int",
        "DockMessages.swift: public var socketFolders: [String]",
        "DockMessages.swift: public var visible: Bool",
        "DockMessages.swift: public var width: Double",
        "DockPeer.swift: public enum DockRefusal: Error, Equatable, Sendable",
        "DockPeer.swift: public func menuLine(hostName: String? = nil) -> String",
        "DockProtocol.swift: public enum DockByeReason: String, CaseIterable, Sendable",
        "DockProtocol.swift: public enum DockFeature: String, CaseIterable, Sendable",
        "DockProtocol.swift: public enum DockProtocol",
        "DockProtocol.swift: public enum DockSpeechNoReason: String, CaseIterable, Sendable",
        "DockProtocol.swift: public static let attentionInterval: TimeInterval = 1",
        "DockProtocol.swift: public static let handshakeTimeout: TimeInterval = 2",
        "DockProtocol.swift: public static let majors: ClosedRange<Int> = 1...1",
        "DockProtocol.swift: public static let maxLineBytes = 16 * 1024",
        "DockProtocol.swift: public static let maxLinesPerSecond = 50",
        "DockProtocol.swift: public static let maxLivePlacesPerSecond = 30",
        "DockProtocol.swift: public static let maxNesting = 8",
        "DockProtocol.swift: public static let minor = 0",
        "DockProtocol.swift: public static let notRespondingAfter: TimeInterval = 15",
        "DockProtocol.swift: public static let pingAfter: TimeInterval = 5",
        "DockProtocol.swift: public static var all: Set<DockFeature>",
        "DockProtocol.swift: public static var versionText: String",
    ]
}
