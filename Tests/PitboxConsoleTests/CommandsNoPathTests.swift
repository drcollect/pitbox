import AppKit
import Foundation
import PitboxKit
import Testing
@testable import PitboxConsole

/// "No other way in" and "no command text in logs" (docs/THREAT_MODEL.md): the module's public surface has no method
/// that starts a command tab or types into a session, and every flow writes labels and numbers only.
@MainActor
struct CommandsNoPathTests {
    private var sourceFiles: [URL] {
        // <package>/Tests/PitboxConsoleTests/<this file>: up three folders, then Sources/PitboxConsole.
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let sources = root.appendingPathComponent("Sources/PitboxConsole")
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }

    /// Every `public` or `open` declaration of the module, as "file: line".
    private func publicDeclarations() throws -> [String] {
        var found: [String] = []
        for file in sourceFiles {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//") else { continue }
                let declares = ["public ", "open "].contains { trimmed.hasPrefix($0) }
                    || [" public func ", " public var ", " public init", " public static ", " public subscript", " open func ",
                        " open var ", " open class "].contains { trimmed.contains($0) }
                guard declares else { continue }
                found.append("\(file.lastPathComponent): \(trimmed)")
            }
        }
        return found
    }

    @Test func nothingPublicStartsACommandTabOrTypesIntoASession() throws {
        let declarations = try publicDeclarations()
        #expect(!declarations.isEmpty)
        let forbidden = ["startCommand", "typeInto", "sendPaste", "write(", "openCommandTab", "openServerTab", "spawn", "launch",
                         "consume", "runOrType", "fetchPressed", "send(", "paste"]
        for declaration in declarations {
            for word in forbidden {
                #expect(!declaration.contains(word), "public API reaches the run path: \(declaration)")
            }
        }
        // The command sheet's whole public surface: show it (an offer, or a result fetch), tell it about
        // staleness, close it, reveal a finished run.
        let sheet = declarations.filter { $0.hasPrefix("CommandSheetController") }.map { $0.components(separatedBy: ": ").dropFirst().joined() }
        #expect(!sheet.isEmpty)
        for line in sheet {
            let allowed = ["public final class CommandSheetController", "public weak var anchorWindow", "public var anchorFrame",
                           "public convenience init(console",
                           "public func present(", "public func presentFetch(", "public func offerWentStale(",
                           "public func offerWasSuperseded(", "public func dismissSheet(", "public func revealRun("]
            #expect(allowed.contains { line.hasPrefix($0) }, "unexpected public API: \(line)")
        }
        // The console host's whole public surface: make it and its view, settings, the hooks, focus, shut down, counts,
        // and selecting the tab of a Run. Nothing else is public in its files: a new public way in fails here.
        let console = declarations.filter { $0.hasPrefix("ConsoleHost") || $0.hasPrefix("ConsoleCommandHooks") }
            .map { $0.components(separatedBy: ": ").dropFirst().joined() }
        #expect(!console.isEmpty)
        for line in console {
            let allowed = ["public final class ConsoleHost", "public convenience init(settings", "public var commandHooks",
                           "public func makeView()", "public func update(settings", "public func focus()", "public func shutdown()",
                           "public var sessionCount", "public var busySessionCount", "public func selectCommandTab(runID",
                           "public var runningCommandCount",
                           "public struct ConsoleCommandHooks", "public var consoleVisible", "public var revealAndHoldConsole",
                           "public var releaseConsoleHold", "public init(consoleVisible"]
            #expect(allowed.contains { line.hasPrefix($0) }, "unexpected public API: \(line)")
        }
        // The console's settings: only the look is public (font, size, appearance). What its own tabs run (shell,
        // presets) stays internal: making it public is a decision this test must be changed for.
        let settings = declarations.filter { $0.hasPrefix("TerminalSettings.swift") }.map { $0.components(separatedBy: ": ").dropFirst().joined() }
        #expect(!settings.isEmpty)
        for line in settings {
            let allowed = ["public enum TerminalAppearance", "public struct TerminalSettings", "public var fontName",
                           "public var fontSize", "public var appearance", "public static let standard",
                           "public static let fontSizeRange"]
            #expect(allowed.contains { line.hasPrefix($0) }, "unexpected public API: \(line)")
        }
        // Pitbox's own additions, each allowed deliberately. The drawer: its view, height, state and hold, the hooks it
        // installs, and the block's hide. The run policy: the value and its mapping from the settings. The sandbox: the
        // policy the app builds and the append-only store of what hosts announced. None of them starts, types or stops
        // anything.
        let p3: [(file: String, allowed: [String])] = [
            ("ConsoleDrawer.swift", ["public final class ConsoleDrawer", "public enum State", "public static let heldHeight",
                                     "public static let barHeight", "public var view", "public private(set) var state",
                                     "public private(set) var isHeld", "public var onHeightChanged", "public var height",
                                     "public init(console", "public var commandHooks", "public func blockHidden()"]),
            ("CommandRunPolicy.swift", ["public enum CommandRunPolicy", "public init(settingsValue"]),
            ("CommandSandbox.swift", ["public enum CommandSandbox", "public struct Policy", "public var announcedFolders",
                                      "public var announcedSocketFolders", "public var denyFolders", "public var allowSocketFolders",
                                      "public init(announcedFolders", "public static var standard"]),
            ("SandboxMemory.swift", ["public final class SandboxMemory", "public convenience init()", "public var folders",
                                     "public var socketFolders", "public func remember(folders", "public func reload()",
                                     "public func folders(adding", "public func socketFolders(adding"]),
            ("ConsoleDrawerView.swift", []),
            ("CommandHelperLocator.swift", []),
        ]
        for (file, allowed) in p3 {
            let lines = declarations.filter { $0.hasPrefix(file + ":") }.map { $0.components(separatedBy: ": ").dropFirst().joined() }
            #expect(lines.isEmpty == allowed.isEmpty, "\(file): its public surface is what this test lists")
            for line in lines {
                #expect(allowed.contains { line.hasPrefix($0) }, "unexpected public API: \(file): \(line)")
            }
        }
        // The console host's new input is the sandbox policy, read per spawn: it can only add denies to the fixed rules.
        #expect(declarations.contains { $0 == "ConsoleHost.swift: public convenience init(settings: TerminalSettings = .standard," })
    }

    /// The drawer's whole public surface, driven: its hooks, its bar, the block's hide. It shows and folds the console;
    /// it never starts a command tab, a shell or a server tab, and never writes into a session.
    @Test func theDrawerStartsNothing() throws {
        let h = DrawerHarness()
        let hooks = h.drawer.commandHooks
        _ = hooks.consoleVisible()
        var answers: [Bool] = []
        hooks.revealAndHoldConsole { answers.append($0) }
        h.clock.advance(by: 1)
        hooks.releaseConsoleHold()
        h.drawer.blockHidden()
        h.drawer.barClicked()
        h.drawerView.bar.onClick?()
        _ = h.drawerView.bar.accessibilityPerformPress()
        h.drawer.onHeightChanged?(312)
        #expect(answers == [true], "the reveal answers, and that is all it does")
        #expect(h.commands.specs.isEmpty && h.launcher.processes.isEmpty, "nothing was spawned")
        #expect(h.console.sessionCount == 0, "no tab was opened")
    }

    /// With `commands: copyOnly` nothing can start a Run tab, whatever is clicked or called on the sheet.
    @Test func copyOnlyCanStartNoRunTab() async throws {
        let h = SheetHarness(assess: { text, _ in SheetFixtures.notFlagged(text) })
        h.runPolicy = .copyOnly
        await h.present(SheetFixtures.offer("echo hi", facts: SheetFixtures.facts(cwd: h.folder.path)))
        h.advance(10)
        for button in h.view?.armedControls ?? [] where button !== h.view?.typeButton { h.click(button) }
        h.controller.runOrType(.run)
        _ = h.controller.refuseRunWhenOff()
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(!h.host.requests.contains { $0.role == .run }, "no Run request reached the console")
        #expect(h.sheet?.state.consumed != true)
        h.controller.dismissSheet()
    }

    @Test func theSheetIsTheOnlyProtocolEntryAndItOnlyShowsTheSheet() async throws {
        let h = SheetHarness(assess: { text, _ in SheetFixtures.notFlagged(text) })
        let presenter: CommandOfferPresenting = h.controller
        var events: [CommandOfferEvent] = []
        presenter.present(SheetFixtures.offer("echo hi", facts: SheetFixtures.facts(cwd: h.folder.path)), anchor: .zero,
                          freshness: h.freshness) { events.append($0) }
        _ = await waitUntil(5) { h.sheet?.state.assessmentReady == true }
        h.advance(60)
        presenter.offerWasSuperseded(CommandOffer.ID(sessionIndex: 3, replyUUID: "reply-uuid-1", number: 1),
                                     supersession: .init(newerReplies: 1, latestAt: Date(), sessionIsWorking: false))
        presenter.revealRun(UUID())
        presenter.offerWentStale(CommandOffer.ID(sessionIndex: 3, replyUUID: "reply-uuid-1", number: 1))
        presenter.dismissSheet()
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(h.host.requests.isEmpty, "nothing reaches the console without a click on the sheet")
        #expect(events == [.cancelled])
    }

    /// A log value is made only by the typed builders: the one initializer that takes text is private, and nothing
    /// else in the module spells one out.
    @Test func logValuesHaveNoFreeTextInitializer() throws {
        let file = try #require(sourceFiles.first { $0.lastPathComponent == "CommandLog.swift" })
        let text = try String(contentsOf: file, encoding: .utf8)
        let initializers = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && $0.contains("init(") }
        #expect(initializers.contains("private init(text: String) { self.text = text }"))
        // Every initializer whose parameters take a String is private.
        for line in initializers {
            guard let open = line.range(of: "init("), let close = line[open.upperBound...].firstIndex(of: ")") else { continue }
            guard line[open.upperBound..<close].contains(": String") else { continue }
            #expect(line.hasPrefix("private init("), "a log value initializer that takes text: \(line)")
        }
        for other in sourceFiles where other.lastPathComponent != "CommandLog.swift" {
            let source = try String(contentsOf: other, encoding: .utf8)
            #expect(!source.contains("CommandLogValue(text"), "\(other.lastPathComponent) builds a log value from text")
        }
    }

    @Test func logsHoldLabelsAndNumbersOnly() async throws {
        var lines: [String] = []
        let lock = NSLock()
        let recorder = CommandLog.addRecorder { category, line in lock.withLock { lines.append("[\(category)] \(line)") } }
        defer { CommandLog.removeRecorder(recorder) }
        let secret = "SERVICE_TOKEN"
        let text = "security add-generic-password -U -a \"$USER\" -s \(secret) -w\nrm -rf ~/x"
        let headline = "very private client headline"

        // The sheet: open, copy, a risky run, a refusal, a stale offer.
        let h = SheetHarness(assess: { text, _ in CommandsSheetTests.risky(text) })
        let project = h.folder.subfolder("client-project")
        await h.present(SheetFixtures.offer(text, facts: SheetFixtures.facts(cwd: project.path), headline: headline,
                                            asked: "the secret plan", caption: "run this privately"))
        h.advance(1)
        h.click(try #require(h.view?.copyButton))
        h.tickAll()
        h.controller.reachedEnd()
        h.advance(2.1)
        h.click(try #require(h.view?.runButton))
        _ = await waitUntil(5) { h.host.requests.count == 1 }
        let other = SheetHarness(assess: { text, _ in SheetFixtures.notFlagged(text) })
        await other.present(SheetFixtures.offer(text, facts: SheetFixtures.facts(cwd: project.path), headline: headline))
        other.controller.offerWentStale(CommandOffer.ID(sessionIndex: 3, replyUUID: "reply-uuid-1", number: 1))
        other.controller.dismissSheet()

        // The console: a real command tab through the helper, a Type tab, Stop.
        let real = CommandConsoleHarness(realHelper: true)
        real.start(try real.request("print -r -- \(secret); exit 2", headline: headline))
        _ = await waitUntil(10) { real.events.count == 2 }
        let fake = CommandConsoleHarness()
        fake.start(try fake.request("echo \(secret)", role: .typeIntoTerminal, headline: headline))
        fake.commands.processes.first?.emit("\u{1b}[?2004h")
        fake.start(try fake.request("sleep 9 # \(secret)", headline: headline))
        fake.view.selectedCommandBar?.onStop?()

        let all = lock.withLock { lines }
        #expect(all.contains { $0.contains("sheet opened offer=#3.1") })
        #expect(all.contains { $0.hasPrefix("[terminal] command tab finished") })
        let forbidden = [secret, "rm -rf", "security", headline, "client-project", project.path, h.folder.path, "secret plan",
                         "privately", real.home.path, "print -r"]
        for line in all {
            for word in forbidden { #expect(!line.contains(word), "a log line carries text it must not") }
            // Every field is key=value with a label (letters, digits, - and #, .) or a number.
            for field in line.split(separator: " ").dropFirst() where field.contains("=") {
                let value = field.split(separator: "=", maxSplits: 1).last.map(String.init) ?? ""
                #expect(value.allSatisfy { $0.isLetter || $0.isNumber || "-#.".contains($0) }, "a value that is not a label")
            }
        }
    }
}
