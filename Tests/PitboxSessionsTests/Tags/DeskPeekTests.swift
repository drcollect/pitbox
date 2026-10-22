import AppKit
import Foundation
import PitboxKit
import Testing
@testable import PitboxSessions

/// The desk peek's content and the log lines of desk tags.
@MainActor
@Suite("desk tags: desk peek and logs")
struct DeskPeekTests {
    init() { DeskTagLog.enabled = false }

    func model(_ session: CodeSessionSnapshot, hidden: Bool = false) -> DeskPeekModel {
        DeskPeekBuilder.model(.init(session: session, textHidden: hidden, now: tileNow, clock: tagClock,
                                    homeDirectory: "/Users/alex"))
    }

    static func rich() -> CodeSessionSnapshot {
        var session = tagSession("local_t1", "Weather app · forecast refactor", state: .working,
                                 offers: [tileOffer("swift test --filter Tags", number: 1),
                                          tileOffer("rm -rf .build", number: 2, commandClass: .risky)],
                                 earlierOffers: [tileOffer("make lab", number: 1, reply: "earlier")],
                                 warnings: [TagContentTests.stuck],
                                 dashboard: TagPanelTests.dashboard,
                                 eta: CodeETA(kind: .stated, at: tileNow.addingTimeInterval(1200), statedZone: "Europe/Lisbon"),
                                 progress: CodeProgress(source: .backgroundTasks, unit: .agents, done: 4, total: 6),
                                 workStartedAt: tileNow.addingTimeInterval(-34 * 60),
                                 results: [CodeResult(kind: .preview, origin: .replyLink, url: URL(string: "http://localhost:5173/"),
                                                      label: "localhost:5173"),
                                           CodeResult(kind: .document, origin: .handedOver, path: "/Users/alex/x/notes.md",
                                                      label: "notes.md"),
                                           CodeResult(kind: .mentionedPath, origin: .replyText, path: "/tmp/elsewhere.md",
                                                      label: "elsewhere.md")])
        session.now = "running: swift test"
        session.tldr = "K1 engine and K3 wiring done; K4 menu next."
        session.otherLinkCount = 2
        return session
    }

    @Test func richPeekContent() {
        let m = model(Self.rich())
        #expect(m.title == "Weather app · forecast refactor")
        #expect(m.detailLines.first == "this Mac · ~/my project")
        #expect(m.now == "Now: running: swift test")
        let started = tagClock.string(tileNow.addingTimeInterval(-34 * 60))
        let eta = tagClock.string(tileNow.addingTimeInterval(1200))
        #expect(m.runLine == "Started \(started) · running 34 min · ETA \(eta), as stated in its reply · 4 of 6 agents done")
        #expect(m.zoneNote?.hasPrefix("(stated as ") == true, "stated in Europe/Lisbon, shown in UTC here")
        #expect(m.progress == 4.0 / 6.0)
        #expect(!m.late)
        #expect(m.warnings == ["Looks stuck: 4 commands failed in a row · last exit 1"])
        #expect(m.tldr == "K1 engine and K3 wiring done; K4 menu next.")
        #expect(m.results.map(\.title) == ["↗ Open preview · localhost:5173", "▤ Open notes.md"])
        #expect(m.results.allSatisfy { $0.needsArming })
        #expect(m.resultNotes == ["Named in the reply: /tmp/elsewhere.md", "2 other links in the reply (open them from the session)"])
        #expect(m.dashboard?.title == "▦ Open dashboard · since \(tagClock.string(tileNow.addingTimeInterval(-3600))) · updated \(tagClock.string(tileNow.addingTimeInterval(-600)))")
        #expect(m.dashboard?.needsArming == true)
        #expect(m.commands.map(\.button.title) == ["Review…", "Review…"], "Run is off by default")
        #expect(m.commands.map(\.chip) == ["Not flagged", "Risky"])
        #expect(m.commands[1].risky)
        #expect(m.earlierCommands.count == 1)
        #expect(m.earlierCommands.first?.note == "from an earlier reply (\(tagClock.string(tileNow)))")
        #expect(m.footer.map(\.action) == [.park, .copyLink])
        #expect(!m.footer.contains { $0.needsArming })
    }

    @Test func lateEstimateAndSSHLines() {
        var late = Self.rich()
        late.eta = CodeETA(kind: .stated, at: tileNow.addingTimeInterval(-6 * 60), isLate: true)
        let m = model(late)
        #expect(m.late)
        #expect(m.runLine?.contains("(passed 6 min ago)") == true)
        var estimate = Self.rich()
        estimate.eta = CodeETA(kind: .estimate, at: tileNow.addingTimeInterval(540), minutesLeft: 9)
        #expect(model(estimate).runLine?.hasSuffix("≈ 9 min left (estimate from 4 of 6 agents done)") == true)
        var ssh = tagSession("local_s", "fleet build", state: .working, place: .ssh, sshHost: "buildbox")
        ssh.now = "agent: dashboard-builder"
        ssh.lastActivity = tileNow.addingTimeInterval(-120)
        ssh.cwd = "/home/buildbox/projects/recipe-box"
        let remote = model(ssh)
        #expect(remote.detailLines.first == "buildbox · /home/buildbox/projects/recipe-box")
        #expect(remote.now == "Now: agent: dashboard-builder (as of \(tagClock.string(tileNow.addingTimeInterval(-120))))")
    }

    @Test func hideTextKeepsHeadlineStateAndButtons() {
        let m = model(Self.rich(), hidden: true)
        #expect(m.title == "Weather app · forecast refactor")
        #expect(m.textHidden)
        #expect(m.now == nil && m.tldr == nil && m.ask == nil && m.steps.isEmpty && m.todos.isEmpty)
        #expect(m.runLine == "Running 34 min")
        #expect(m.zoneNote == nil)
        #expect(m.results.map(\.title) == ["↗ Open preview", "▤ Open file"])
        #expect(m.resultNotes == ["2 other links in the reply (open them from the session)"])
        #expect(m.dashboard?.title == "▦ Open dashboard")
        #expect(m.commands.map(\.preview) == ["hidden", "hidden"])
        #expect(m.detailLines.count == 1, "no folder")
    }

    @Test func peekViewDrawsNoSessionTextWithHideText() throws {
        let view = DeskPeekView(model: model(Self.rich(), hidden: true), frame: CGRect(x: 0, y: 0, width: 360, height: 500))
        view.drawnTexts = []
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let drawn = (view.drawnTexts ?? []).joined(separator: "\n")
        #expect(!drawn.contains("swift test") && !drawn.contains("notes.md") && !drawn.contains("K1 engine"))
        #expect(drawn.contains("Pit") && drawn.contains("Copy link"))
    }

    @Test func peekHeightIsBounded() {
        var session = Self.rich()
        session.offers = (1...8).map { tileOffer("echo \($0)", number: $0) }
        session.steps = (0..<5).map { CodeSessionStep(words: "step \($0)", at: tileNow.addingTimeInterval(-Double($0) * 60)) }
        let peek = DeskPeekPanel(sessionID: session.id, model: model(session))
        let size = peek.size(maxHeight: 560)
        #expect(size.width == 360)
        #expect(size.height <= 560)
        peek.panel.setFrame(CGRect(origin: .zero, size: size), display: false)
        if peek.view.maxScrollOffset > 0 {
            peek.view.scroll(to: .commands)
            #expect(peek.view.scrollOffset > 0, "opened at the commands")
        }
    }

    @Test func logsHoldNoSessionText() throws {
        final class Lines: @unchecked Sendable {
            let lock = NSLock()
            var all: [String] = []
            func add(_ line: String) { lock.withLock { all.append(line) } }
        }
        let lines = Lines()
        let token = DeskTagLog.observe { lines.add($0) }
        defer { DeskTagLog.stopObserving(token) }
        let h = TagHarness(lab: DeskTagLabOptions(enabled: true))
        h.start()
        let secret = "Recipe box · secret-plan"
        var session = Self.rich()
        session.headline = secret
        h.desk([session])
        h.click("local_t1")
        h.button.down = true
        h.move(to: CGRect(x: 500, y: 300, width: 900, height: 700))
        h.button.down = false
        h.advance(1)
        h.controller.peek.map { _ in h.controller.closePeek() }
        h.controller.logLabCost()
        let all = lines.all.joined(separator: "\n")
        #expect(all.contains("tag shown session=#1 kind=offer"))
        #expect(all.contains("desktag lab note kind=moved button=down"))
        #expect(all.contains("desktag lab cost per_min"))
        for forbidden in [secret, "secret-plan", "swift test", "localhost:5173", "notes.md", "polar-shore", "local_t1",
                          "reply-1", "earlier", tagClock.string(tileNow.addingTimeInterval(1200)), "/Users/alex"] {
            #expect(!all.contains(forbidden), "log holds \(forbidden)")
        }
    }

    @Test func labOptionsFromTheEnvironment() {
        #expect(DeskTagLabOptions.from(environment: [:]) == DeskTagLabOptions())
        let options = DeskTagLabOptions.from(environment: ["PITBOX_DESKTAG_LAB": "1", "PITBOX_DESKTAG_COVER": "floating",
                                                        "PITBOX_DESKTAG_INSET": "48"])
        #expect(options == DeskTagLabOptions(enabled: true, coverMode: .floating, rightInset: 48))
        let bad = DeskTagLabOptions.from(environment: ["PITBOX_DESKTAG_LAB": "yes", "PITBOX_DESKTAG_COVER": "x", "PITBOX_DESKTAG_INSET": "900"])
        #expect(bad == DeskTagLabOptions())
        #expect(DeskTagFeasibility.current == .untested, "tags wait for the window-ordering check")
        #expect(DeskTagCoverMode.current == .orderedAbove)
    }

    @Test func labInsetAndCoverOverrides() {
        let h = TagHarness(feasibility: .untested, lab: DeskTagLabOptions(enabled: true, coverMode: .floating, rightInset: 60))
        #expect(h.controller.coverMode == .floating)
        #expect(h.controller.rightInset == 60)
        h.server.frontToBack = [tagWindow()]
        h.start()
        h.desk([TagControllerTests.offerSession()])
        #expect(h.quartzFrame("local_t1")?.maxX == tagWindowBounds.maxX - 60)
        let plain = TagHarness(lab: DeskTagLabOptions(enabled: false, coverMode: .floating, rightInset: 60))
        #expect(plain.controller.coverMode == .orderedAbove, "overrides only in the lab")
        #expect(plain.controller.rightInset == CodeTuning.tagRightInset)
    }

    @Test func labOrderAndClickChecks() throws {
        final class Lines: @unchecked Sendable {
            let lock = NSLock()
            var all: [String] = []
            func add(_ line: String) { lock.withLock { all.append(line) } }
        }
        let lines = Lines()
        let token = DeskTagLog.observe { lines.add($0) }
        defer { DeskTagLog.stopObserving(token) }
        let h = TagHarness(lab: DeskTagLabOptions(enabled: true))
        h.ax.focused[tagPID] = tagWindowNumber
        h.start()
        h.desk([TagControllerTests.offerSession()])
        h.click("local_t1")
        h.advance(0.4)
        #expect(lines.all.contains("desktag lab click session=#1 own_active=0 claude_front=1 focus_kept=1"))
    }
}
