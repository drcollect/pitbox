import AppKit
import Darwin
import Foundation
import PitboxKit
import Testing
@testable import PitboxConsole

/// The command sheet, over fakes: no window on screen, a manual clock, a private pasteboard, the classifier's answers
/// supplied by each test.
@MainActor
struct CommandsSheetTests {
    static let keychain = #"security add-generic-password -U -a "$USER" -s SERVICE_TOKEN -w"#

    static func risky(_ text: String) -> CommandAssessment {
        var a = SheetFixtures.notFlagged(text, programs: ["rm", "swift"])
        a.commandClass = .risky
        a.flags = [SheetFixtures.flag(.r2, "Deletes files and folders; not to the Trash: build", "rm -rf build", in: text, line: 1),
                   SheetFixtures.flag(.r18, "Runs code from the folder that is not shown here", "swift build", in: text, line: 2)]
        return a
    }

    // MARK: Opening

    @Test func theSheetNeverTakesTheKeyboardAndHasNoDefaultButton() async throws {
        let h = SheetHarness(assess: { text, _ in SheetFixtures.notFlagged(text) })
        await h.present(SheetFixtures.offer("echo hi", facts: SheetFixtures.facts(cwd: h.folder.path)))
        let panel = try #require(h.sheet?.panel)
        #expect(!panel.canBecomeKey && !panel.canBecomeMain)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.defaultButtonCell == nil)
        #expect(panel.animationBehavior == .none)
        h.advance(5)
        // Return, Enter, Space and Escape sent at it never reach a button.
        for (code, characters) in [(UInt16(36), "\r"), (UInt16(76), "\u{3}"), (UInt16(49), " "), (UInt16(53), "\u{1b}")] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                      windowNumber: panel.windowNumber, context: nil, characters: characters,
                                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            panel.sendEvent(event)
            #expect(!panel.performKeyEquivalent(with: event))
        }
        #expect(h.host.requests.isEmpty)
        #expect(h.sheet != nil, "Escape did not close it either")
        let view = try #require(h.view)
        for button in view.armedControls + [view.cancelButton, view.closeButton] {
            #expect(!button.acceptsFirstResponder)
        }
    }

    @Test func theSheetClassifiesTheTextItselfWithTheBoundFolder() async throws {
        var seenFolders: [String?] = []
        let h = SheetHarness(assess: { text, context in
            seenFolders.append(context.runFolder)
            return Self.risky(text)
        })
        await h.present(SheetFixtures.offer("rm -rf build\nswift build", facts: SheetFixtures.facts(cwd: h.folder.path)))
        let model = try #require(h.model)
        #expect(model.isRisky, "the sheet's own reading decides, whatever the caller thought")
        #expect(model.run.title == "Yes, run this risky command")
        #expect(model.redLines.count == 2)
        #expect(seenFolders.allSatisfy { $0 == h.folder.path })
    }

    @Test func aMissingSessionFolderRunsInHomeAndSaysSo() async throws {
        let h = SheetHarness(assess: { text, _ in SheetFixtures.notFlagged(text) })
        await h.present(SheetFixtures.offer("ls", facts: SheetFixtures.facts(cwd: "/nonexistent/project")))
        let state = try #require(h.sheet?.state)
        #expect(state.folder.path == h.folder.path && state.folder.isHomeFallback)
        let lines = h.model?.rows.first { $0.label == "Folder" }?.lines ?? []
        #expect(lines.contains { $0.contains(.warning("the session's folder doesn't exist here: runs in ~")) })
    }

    // MARK: Arming and the press

    @Test func runCountsOnlyAPressThatBeganAfterArming() async throws {
        let h = SheetHarness(assess: { text, _ in SheetFixtures.notFlagged(text) })
        await h.present(SheetFixtures.offer("echo hi", facts: SheetFixtures.facts(cwd: h.folder.path)))
        let run = try #require(h.view?.runButton)
        #expect(h.model?.run.state == .on)
        h.advance(0.5)
        h.click(run)
        #expect(!run.isArmed)
        h.advance(0.5)
        run.pointerExited()
        // A press that began before arming and ended after it still does not count.
        run.pointerEntered()
        h.now -= 0.4
        run.beginPress()
        h.now += 0.4
        run.endPress(inside: true)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(h.host.requests.isEmpty)
        // A press that ends outside does nothing.
        run.pointerExited()
        run.pointerEntered()
        run.beginPress()
        run.endPress(inside: false)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(h.host.requests.isEmpty)
        h.click(run)
        #expect(await waitUntil(5) { h.host.requests.count == 1 })
        let request = try #require(h.host.requests.first)
        #expect(request.role == .run)
        #expect(request.descriptor.text == "echo hi")
        #expect(request.descriptor.shellPath == "/bin/zsh")
        #expect(request.descriptor.shellArguments == ["-f", "-i", "-o", "interactivecomments", "-o", "nobanghist", "-c"])
        #expect(request.descriptor.path == CommandExecutionDescriptor.cleanPath)
        #expect(request.descriptor.machine == .thisMac)
        #expect(!request.descriptor.environmentNames.contains("SSH_AUTH_SOCK"))
        #expect(request.folder.path == h.folder.path)
        #expect(h.sheet == nil, "the sheet closed")
        #expect(h.events == [.started(runID: request.runID)], "no cancelled after a run")
    }

    @Test func runIsNeverArmedUnderAPointerThatRestedOnItBeforeArming() async throws {
        let h = SheetHarness(assess: { text, _ in SheetFixtures.notFlagged(text) })
        await h.present(SheetFixtures.offer("echo hi", facts: SheetFixtures.facts(cwd: h.folder.path)))
        let run = try #require(h.view?.runButton)
        run.pointerEntered()   // the pointer is on Run before it arms
        h.advance(2)
        run.beginPress()
        run.endPress(inside: true)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(h.host.requests.isEmpty, "inert until the pointer left and came back")
        run.pointerExited()
        h.click(run)
        #expect(await waitUntil(5) { h.host.requests.count == 1 })
    }

    @Test func doubleClicksControlClicksAndDisabledButtonsStartNothing() async throws {
        let h = SheetHarness(assess: { text, _ in SheetFixtures.notFlagged(text) })
        await h.present(SheetFixtures.offer("echo hi", facts: SheetFixtures.facts(cwd: h.folder.path)))
        let run = try #require(h.view?.runButton)
        let panel = try #require(h.sheet?.panel)
        h.advance(1)
        run.pointerEntered()
        for (count, modifiers) in [(2, NSEvent.ModifierFlags()), (1, NSEvent.ModifierFlags.control)] {
            let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                                       windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: count,
                                                       pressure: 1))
            run.mouseDown(with: down)
            #expect(run.pressBegan == nil)
        }
        let right = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        run.rightMouseDown(with: right)
        #expect(run.pressBegan == nil)
        run.isEnabled = false
        run.beginPress()
        run.endPress(inside: true)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(h.host.requests.isEmpty)
    }

    @Test func runOffersNoAccessibilityPressAndSaysHowToRunIt() async throws {
        let h = SheetHarness(assess: { text, _ in SheetFixtures.notFlagged(text) })
        await h.present(SheetFixtures.offer("echo hi", facts: SheetFixtures.facts(cwd: h.folder.path)))
        let view = try #require(h.view)
        h.advance(2)
        for button in [view.runButton, view.typeButton, view.copyButton, view.fetchButton] {
            #expect(!button.isAccessibilitySelectorAllowed(#selector(NSView.accessibilityPerformPress)))
            #expect(!button.accessibilityPerformPress())
        }
        #expect(view.runButton.accessibilityHelp() == "click to run")
        #expect(view.cancelButton.isAccessibilitySelectorAllowed(#selector(NSView.accessibilityPerformPress)))
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(h.host.requests.isEmpty)
    }

    @Test func armingStartsAgainOnMovesCoversWakeAndContentChanges() async throws {
        let h = SheetHarness(assess: { text, _ in SheetFixtures.notFlagged(text) })
        await h.present(SheetFixtures.offer("echo hi", facts: SheetFixtures.facts(cwd: h.folder.path)))
        let view = try #require(h.view)
        let run = view.runButton
        // The panel's own notifications are posted for real; the system-wide ones (wake, unlock, displays) go
        // straight to the handler their observers call, so parallel tests' sheets are not disturbed.
        let triggers: [(String, () -> Void)] = [
            ("move", { NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: h.sheet?.panel) }),
            ("resize", { NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: h.sheet?.panel) }),
            ("cover", { NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: h.sheet?.panel) }),
            ("wake, unlock, displays", { h.controller.environmentChanged(reassess: true) }),
            ("content", { h.controller.toggle(.howItRuns) }),
        ]
        for (label, trigger) in triggers {
            h.advance(5)
            run.pointerExited()
            run.pointerEntered()
            run.beginPress()   // a press in progress when the sheet re-arms is dropped
            trigger()
            #expect(run.pressBegan == nil, "\(label): the pending press was dropped")
            run.pointerExited()
            run.pointerEntered()
            #expect(!run.isArmed, "\(label): re-armed")
            h.advance(0.81)
            run.pointerExited()
            run.pointerEntered()
            #expect(run.isArmed, "\(label): armed again after 0.8 s")
        }
        #expect(h.host.requests.isEmpty)
    }

    @Test func armingCountsOnlyWhileTheSheetIsFullyVisible() async throws {
        let h = SheetHarness(assess: { text, _ in SheetFixtures.notFlagged(text) })
        await h.present(SheetFixtures.offer("echo hi", facts: SheetFixtures.facts(cwd: h.folder.path)))
        let run = try #require(h.view?.runButton)
        h.advance(2)
        h.visible = false
        h.click(run)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(h.host.requests.isEmpty, "covered: nothing starts")
        #expect(h.model?.message?.text == "The sheet must be fully visible to run anything; look again.")
        h.visible = true
        run.pointerExited()
        h.click(run)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(h.host.requests.isEmpty, "it re-armed when it was found covered")
        h.advance(0.9)
        run.pointerExited()
        h.click(run)
        #expect(await waitUntil(5) { h.host.requests.count == 1 })
    }

    @Test func riskyNeedsEveryTickTwoSecondsAfterTheLastAndTheScrollToTheEnd() async throws {
        let h = SheetHarness(assess: { text, _ in Self.risky(text) })
        h.screen = CGRect(x: 0, y: 0, width: 2_560, height: 420)   // a short screen: the body scrolls
        let text = "rm -rf build\nswift build\n" + (1...30).map { "echo line \($0)" }.joined(separator: "\n")
        await h.present(SheetFixtures.offer(text, facts: SheetFixtures.facts(cwd: h.folder.path)))
        let view = try #require(h.view)
        h.advance(1)
        let run = view.runButton
        #expect(view.runButton.style == .danger)
        #expect(h.model?.run.state == .off("Tick each red line first."))
        h.tickAll()
        #expect(h.model?.redLines.allSatisfy(\.ticked) == true)
        #expect(h.model?.run.state == .off("Scroll to the end of the command first."))
        // Scroll the body to the bottom: the end of the command area comes into view.
        let clip = view.scroll.contentView
        clip.scroll(to: CGPoint(x: 0, y: max(0, view.body.frame.height - clip.bounds.height)))
        view.scroll.reflectScrolledClipView(clip)
        #expect(await waitUntil(2) { h.model?.run.state == .on })
        h.advance(1.5)
        h.click(run)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(h.host.requests.isEmpty, "1.5 s after the last tick is too soon")
        h.advance(0.6)
        run.pointerExited()
        h.click(run)
        #expect(await waitUntil(5) { h.host.requests.count == 1 })
    }

    @Test func untickingSwitchesRunOffAgain() async throws {
        let h = SheetHarness(assess: { text, _ in Self.risky(text) })
        await h.present(SheetFixtures.offer("rm -rf build\nswift build", facts: SheetFixtures.facts(cwd: h.folder.path)))
        h.advance(1)
        h.tickAll()
        let key = try #require(h.model?.redLines.first?.key)
        h.advance(1)
        h.controller.toggleTick(key)
        #expect(h.model?.run.state.isOn == false)
    }

    // MARK: Click-time checks

    @Test func aStaleOfferStartsNothingAndCopyStillWorks() async throws {
        let h = SheetHarness(assess: { text, _ in SheetFixtures.notFlagged(text) })
        let offer = SheetFixtures.offer("echo hi", facts: SheetFixtures.facts(cwd: h.folder.path))
        await h.present(offer)
        h.controller.offerWentStale(offer.id)
        let model = try #require(h.model)
        #expect(model.run.state == .off("The session has moved on: this is from an older reply."))
        #expect(model.type.state.isOn == false)
        #expect(model.copy.state == .on)
        #expect(model.message?.text == "The session has moved on: this is from an older reply.")
        h.advance(1)
        h.click(try #require(h.view?.copyButton))
        #expect(h.events == [.copied])
    }

    @Test func theClickTimeCheckDecides() async throws {
        let h = SheetHarness(assess: { text, _ in SheetFixtures.notFlagged(text) })
        await h.present(SheetFixtures.offer("echo hi", facts: SheetFixtures.facts(cwd: h.folder.path)))
        let run = try #require(h.view?.runButton)
        h.advance(1)
        h.freshness.answer = .unknown
        h.click(run)
        #expect(await waitUntil(5) { h.model?.message?.text == "Couldn't check the session; try again." })
        #expect(h.host.requests.isEmpty)
        h.freshness.answer = .stale
        h.advance(1)
        run.pointerExited()
        h.click(run)
        #expect(await waitUntil(5) { h.sheet?.state.stale == true })
        #expect(h.host.requests.isEmpty)
        #expect(h.freshness.calls == 2)
    }

    @Test func aSlowSessionCheckCountsAsUnknown() async throws {
        let h = SheetHarness(assess: { text, _ in SheetFixtures.notFlagged(text) })
        await h.present(SheetFixtures.offer("echo hi", facts: SheetFixtures.facts(cwd: h.folder.path)))
        h.freshness.delay = 1
        h.advance(1)
        h.click(try #require(h.view?.runButton))
        #expect(await waitUntil(5) { h.model?.message?.text == "Couldn't check the session; try again." })
        #expect(h.host.requests.isEmpty)
    }

    @Test func supersededAtTheClickAddsR22AndRunsOnlyAfterItsTick() async throws {
        let h = SheetHarness(assess: { text, _ in SheetFixtures.notFlagged(text) })
        await h.present(SheetFixtures.offer("echo hi", facts: SheetFixtures.facts(cwd: h.folder.path)))
        let s = CommandOffer.Supersession(newerReplies: 1, latestAt: Date(timeIntervalSince1970: 1_760_966_400),
                                          replies: [.init(at: Date(timeIntervalSince1970: 1_760_966_400), origin: .human, head: "thanks!")],
                                          sessionIsWorking: false)
        h.freshness.answer = .superseded(s)
        let run = try #require(h.view?.runButton)
        h.advance(1)
        h.click(run)
        #expect(await waitUntil(5) { h.model?.redLines.contains { $0.key == "R22" } == true })
        #expect(h.host.requests.isEmpty, "nothing started")
        #expect(h.model?.isRisky == true)
        #expect(h.model?.message?.text == "The session has moved on since you opened this. Tick the new line to run it anyway.")
        let r22 = try #require(h.model?.redLines.first { $0.key == "R22" })
        #expect(r22.words.hasPrefix("The session has moved on since this command (1 newer reply, latest "))
        #expect(r22.words.hasSuffix("The command text is unchanged; what it runs against may not be."))
        h.advance(1)
        h.tickAll()
        h.advance(1)
        run.pointerExited()
        h.click(run)
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(h.host.requests.isEmpty, "2 s after the tick")
        h.advance(1.1)
        run.pointerExited()
        h.click(run)
        #expect(await waitUntil(5) { h.host.requests.count == 1 }, "the same facts under a ticked R22: it runs")
    }

    @Test func newFactsAtTheClickResetTheR22Tick() async throws {
        let first = CommandOffer.Supersession(newerReplies: 1, latestAt: Date(timeIntervalSince1970: 1_760_966_400), sessionIsWorking: false)
        let h = SheetHarness(assess: { text, _ in SheetFixtures.notFlagged(text) })
        await h.present(SheetFixtures.offer("echo hi", facts: SheetFixtures.facts(cwd: h.folder.path), supersession: first))
        h.advance(1)
        h.tickAll()
        h.advance(2.1)
        let second = CommandOffer.Supersession(newerReplies: 2, latestAt: Date(timeIntervalSince1970: 1_760_967_000), sessionIsWorking: true)
        h.freshness.answer = .superseded(second)
        let run = try #require(h.view?.runButton)
        h.click(run)
        #expect(await waitUntil(5) { h.sheet?.state.supersession == second })
        #expect(h.host.requests.isEmpty)
        #expect(h.sheet?.state.ticked.contains("R22") == false)
    }

    @Test func r22WordsFollowWhatFollowedTheReply() {
        let at = Date(timeIntervalSince1970: 1_760_966_400)
        let clock = CommandTimeFormat.clock(at)
        let tail = "The command text is unchanged; what it runs against may not be."
        let message = CommandOffer.Supersession(newerReplies: 0, latestAt: at, unansweredMessageHead: "wait", sessionIsWorking: true)
        #expect(CommandSheetModel.r22Words(message) == "You sent the session a new message after this command (\(clock)); it has not replied yet. " + tail)
        let replies = CommandOffer.Supersession(newerReplies: 2, newerBackgroundUpdates: 1, latestAt: at, sessionIsWorking: false)
        #expect(CommandSheetModel.r22Words(replies) == "The session has moved on since this command (3 newer replies, latest \(clock)). " + tail)
        let working = CommandOffer.Supersession(newerReplies: 0, latestAt: at, sessionIsWorking: true)
        #expect(CommandSheetModel.r22Words(working) == "The session is working on a newer turn right now (since \(clock)); its reply is not in yet. " + tail)
        #expect(CommandSheetModel.r22SaysWorking(working))
        #expect(!CommandSheetModel.r22Words(nil).contains("Read its newest reply first"))
        let facts = CommandOffer.Supersession(newerReplies: 1, latestAt: at, sessionIsWorking: false, readWebSince: true,
                                              filesChangedSince: ["release.sh", "a.swift", "b.swift", "c.swift"], filesChangedCount: 9,
                                              backgroundTasksFinishedSince: 2)
        #expect(CommandSheetModel.sinceLine(facts) == "Since then: read web pages · edited 9 files (release.sh, a.swift, b.swift, …) · 2 background tasks finished")
    }

    @Test func aSupersededOfferOpensWithR22AndTheNewerRepliesClosed() async throws {
        let s = CommandOffer.Supersession(newerReplies: 1, latestAt: Date(timeIntervalSince1970: 1_760_966_400),
                                          replies: [.init(at: Date(timeIntervalSince1970: 1_760_966_400), origin: .taskNotification,
                                                          head: "Background task finished.")],
                                          sessionIsWorking: true, readWebSince: true)
        let h = SheetHarness(assess: { text, _ in SheetFixtures.notFlagged(text) })
        await h.present(SheetFixtures.offer("echo hi", facts: SheetFixtures.facts(cwd: h.folder.path), supersession: s))
        let model = try #require(h.model)
        #expect(model.isRisky && model.redLines.map(\.key) == ["R22"])
        #expect(model.notes.first == "The session read web pages since this command's reply")
        #expect(model.notes.contains("The session is working on a newer turn right now."))
        let replies = try #require(model.sections.first { $0.disclosure == .newerReplies })
        #expect(!replies.isOpen, "closed by default")
        #expect(replies.caption == "session text: it does not vouch for the command")
        #expect(replies.lines.first?.first == .dim("\(CommandTimeFormat.clock(Date(timeIntervalSince1970: 1_760_966_400))) · started by a background task: "))
    }

    @Test func offerWasSupersededSwitchesRunOffAndReArms() async throws {
        let h = SheetHarness(assess: { text, _ in SheetFixtures.notFlagged(text) })
        let offer = SheetFixtures.offer("echo hi", facts: SheetFixtures.facts(cwd: h.folder.path))
        await h.present(offer)
        h.advance(3)
        #expect(h.model?.run.state == .on)
        h.controller.offerWasSuperseded(offer.id, supersession: .init(newerReplies: 1, latestAt: Date(), sessionIsWorking: false))
        #expect(h.model?.run.state.isOn == false)
        #expect(h.model?.copy.state == .on, "Copy keeps working")
        #expect(h.model?.message?.text == "The session has moved on since you opened this. Tick the new line to run it anyway.")
        #expect(h.view?.runButton.isArmed == false)
    }

    @Test func aFolderSwappedAfterOpeningStartsNothing() async throws {
        let h = SheetHarness(assess: { text, _ in SheetFixtures.notFlagged(text) })
        let project = h.folder.subfolder("project")
        await h.present(SheetFixtures.offer("touch x", facts: SheetFixtures.facts(cwd: project.path)))
        try FileManager.default.moveItem(at: project, to: h.folder.url.appendingPathComponent("moved"))
        h.folder.subfolder("project")
        h.advance(1)
        h.click(try #require(h.view?.runButton))
        #expect(await waitUntil(5) { h.model?.message?.text == "the folder changed after you looked; review again" })
        #expect(h.host.requests.isEmpty)
    }

    @Test func filesThatChangedSinceOpeningNeedAReview() async throws {
        let target = "/Users/tester/out.txt"
        var withFacts = false
        let h = SheetHarness(assess: { text, context in
            var a = SheetFixtures.notFlagged(text, programs: ["echo"])
            a.localTargets = [target]
            if context.pathFacts[target] == .file {
                withFacts = true
                a.commandClass = .risky
                a.flags = [CommandFlag(rule: .r21, words: "Replaces out.txt", line: 1, utf16Range: 8..<20)]
            }
            return a
        })
        await h.present(SheetFixtures.offer("echo x > ~/out.txt", facts: SheetFixtures.facts(cwd: h.folder.path)))
        #expect(h.model?.redLines.isEmpty == true, "the target does not exist yet")
        #expect(h.factLookups.first == [target])
        h.facts[target] = .file   // created after the sheet opened
        h.advance(1)
        h.click(try #require(h.view?.runButton))
        #expect(await waitUntil(5) { h.model?.redLines.count == 1 })
        #expect(withFacts)
        #expect(h.host.requests.isEmpty, "a new red line: nothing started")
        #expect(h.model?.message?.text == "What this command touches changed since you looked; review it again.")
    }

    @Test func runWaitsForTheSecondPass() async throws {
        let h = SheetHarness(assess: { text, _ in
            var a = SheetFixtures.notFlagged(text)
            a.localTargets = ["/Users/tester/x"]
            return a
        })
        h.controller.lookUpFacts = { paths in
            try? await Task.sleep(nanoseconds: 300_000_000)
            return paths.reduce(into: [:]) { $0[$1] = .missing }
        }
        h.controller.present(SheetFixtures.offer("echo > ~/x", facts: SheetFixtures.facts(cwd: h.folder.path)),
                             anchor: .zero, freshness: h.freshness) { _ in }
        #expect(h.model?.run.state == .off("Checking the files this command writes…"))
        #expect(await waitUntil(5) { h.sheet?.state.assessmentReady == true })
        #expect(h.model?.run.state == .on)
    }

    // MARK: Classes and buttons

    @Test func copyMarksThePasteboardConcealedAndTransient() async throws {
        let h = SheetHarness(assess: { text, _ in SheetFixtures.notFlagged(text) })
        await h.present(SheetFixtures.offer(Self.keychain, facts: SheetFixtures.facts(cwd: h.folder.path)))
        h.advance(1)
        h.click(try #require(h.view?.copyButton))
        #expect(h.pasteboard.string(forType: .string) == Self.keychain)
        let types = h.pasteboard.types ?? []
        #expect(types.contains(CommandPasteboard.concealedType) && types.contains(CommandPasteboard.transientType))
        #expect(h.events == [.copied])
        #expect(h.model?.copy.title == "Copied")
        h.advance(2.1)
        h.controller.refresh()
        #expect(h.model?.copy.title == "Copy")
        #expect(h.sheet != nil, "the sheet stays open")
    }

    @Test func copyIsArmedLikeEverythingElse() async throws {
        let h = SheetHarness(assess: { text, _ in SheetFixtures.notFlagged(text) })
        await h.present(SheetFixtures.offer("echo hi", facts: SheetFixtures.facts(cwd: h.folder.path)))
        h.advance(0.3)
        h.click(try #require(h.view?.copyButton))
        #expect(h.events.isEmpty, "the double click that opened the sheet cannot land on Copy")
    }

    @Test func hiddenCharactersBlockAndOnlyCopyCleanedIsOffered() async throws {
        let text = "echo \"a\u{202E}b\" &&\u{00A0}ls"
        let h = SheetHarness(assess: { text, _ in
            var a = SheetFixtures.notFlagged(text)
            a.commandClass = .blocked
            a.flags = [CommandFlag(rule: .b1, words: "Hidden or deceptive characters", line: 1, utf16Range: 0..<0)]
            return a
        })
        await h.present(SheetFixtures.offer(text, facts: SheetFixtures.facts(cwd: h.folder.path)))
        let model = try #require(h.model)
        #expect(!model.run.state.isShown && !model.type.state.isShown)
        #expect(!model.copy.state.isShown)
        #expect(model.copyCleaned.state == .on)
        #expect(model.cleaned?.text == "echo \"ab\" &&ls" && model.cleaned?.removed == 2)
        h.advance(1)
        h.click(try #require(h.view?.copyCleanedButton))
        #expect(h.pasteboard.string(forType: .string) == "echo \"ab\" &&ls")
        #expect(h.pasteboard.types?.contains(CommandPasteboard.transientType) == true)
        let area = try #require(h.view?.commandArea)
        #expect(area.content.attributed.string.contains("⟨U+202E⟩") && area.content.attributed.string.contains("⟨U+00A0⟩"))
    }

    @Test func blockReasonsDecideAboutCopy() async throws {
        for (rule, copy) in [(CommandRule.b2, CommandSheetModel.ButtonState.off("This text can't be copied as it is.")),
                             (.b3, .on), (.b4, .on), (.b5, .off("This text can't be copied as it is.")), (.b6, .on)] {
            let h = SheetHarness(assess: { text, _ in
                var a = SheetFixtures.notFlagged(text)
                a.commandClass = .blocked
                a.flags = [CommandFlag(rule: rule, words: "blocked", line: 1, utf16Range: 0..<0)]
                return a
            })
            await h.present(SheetFixtures.offer("x", facts: SheetFixtures.facts(cwd: h.folder.path)))
            #expect(h.model?.copy.state == copy, "\(rule.rawValue)")
            #expect(h.model?.run.state.isShown == false, "\(rule.rawValue)")
        }
    }

    @Test func aPartlyReadReplyIsCopyOnly() async throws {
        let h = SheetHarness(assess: { text, _ in SheetFixtures.notFlagged(text) })
        await h.present(SheetFixtures.offer("echo hi", facts: SheetFixtures.facts(cwd: h.folder.path), complete: false))
        let model = try #require(h.model)
        #expect(!model.run.state.isShown && !model.type.state.isShown)
        #expect(model.copy.state == .on)
        #expect(model.checkText == "Pitbox couldn't read the whole reply. Copy only.")
    }

    @Test func needsEditingOffersTypeButNotRun() async throws {
        let h = SheetHarness(assess: { text, _ in
            var a = SheetFixtures.notFlagged(text)
            a.commandClass = .needsEditing
            a.placeholder = "<server>"
            return a
        })
        await h.present(SheetFixtures.offer("ssh <server>", facts: SheetFixtures.facts(cwd: h.folder.path)))
        let model = try #require(h.model)
        #expect(!model.run.state.isShown)
        #expect(model.type.state == .on)
        #expect(model.checkText?.contains("fill in <server> first") == true)
    }

    @Test func serverCommandsOfferCopyAndATerminalOnTheExactAlias() async throws {
        let h = SheetHarness(assess: { text, _ in
            var a = SheetFixtures.notFlagged(text)
            a.commandClass = .otherMachine
            a.machine = .remote(host: "buildbox")
            return a
        })
        h.exactAliases = ["buildbox"]
        await h.present(SheetFixtures.offer("ssh buildbox 'uptime'", facts: SheetFixtures.facts(place: .ssh, alias: "buildbox")))
        #expect(await waitUntil(5) { h.model?.server.state == .on })
        let model = try #require(h.model)
        #expect(!model.run.state.isShown && !model.type.state.isShown)
        #expect(model.server.title == "Open a terminal on buildbox")
        h.advance(1)
        h.click(try #require(h.view?.serverButton))
        #expect(h.host.serverAliases == ["buildbox"])
        #expect(h.host.requests.isEmpty)
        #expect(h.sheet != nil, "the sheet stays, so Copy can follow")
    }

    @Test func aServerThatIsNotAnExactAliasGetsNoTerminal() async throws {
        let h = SheetHarness(assess: { text, _ in
            var a = SheetFixtures.notFlagged(text)
            a.commandClass = .otherMachine
            a.machine = .remote(host: "c0nductor")
            return a
        })
        await h.present(SheetFixtures.offer("ssh c0nductor 'uptime'", facts: SheetFixtures.facts(place: .ssh, alias: "buildbox")))
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(h.model?.server.state == .off("That server isn't an exact entry in your SSH config."))
    }

    @Test func anUnclearMachineNeedsTheUsersPick() async throws {
        let h = SheetHarness(assess: { text, _ in
            var a = SheetFixtures.notFlagged(text)
            a.commandClass = .unclearMachine
            a.machine = .unclear
            return a
        })
        h.exactAliases = ["buildbox"]
        await h.present(SheetFixtures.offer("tail -n 5 /var/log/x", facts: SheetFixtures.facts(place: .ssh, alias: "buildbox")))
        h.advance(1)
        var model = try #require(h.model)
        #expect(model.showsMachinePicker)
        #expect(model.run.state == .off("Pick This Mac or The server first."))
        #expect(model.type.state.isOn == false)
        let view = try #require(h.view)
        h.click(view.thisMacChip)
        model = try #require(h.model)
        #expect(model.machinePick == .thisMac && model.run.state == .on)
        #expect(view.runButton.isArmed == false, "picking re-arms")
        h.advance(1)
        h.click(view.serverChip)
        model = try #require(h.model)
        #expect(!model.run.state.isShown, "The server: the server buttons")
        #expect(model.server.state.isShown)
    }

    @Test func aHiddenTerminalSwitchesRunAndTypeOffWithTheReason() async throws {
        let h = SheetHarness(assess: { text, _ in SheetFixtures.notFlagged(text) })
        h.host.blocker = ConsoleHost.consoleHiddenReason
        await h.present(SheetFixtures.offer("echo hi", facts: SheetFixtures.facts(cwd: h.folder.path)))
        let model = try #require(h.model)
        #expect(model.run.state == .off(ConsoleHost.consoleHiddenReason))
        #expect(model.type.state == .off(ConsoleHost.consoleHiddenReason))
        #expect(model.copy.state == .on)
        #expect(model.message?.text == ConsoleHost.consoleHiddenReason)
    }

    @Test func aRefusalFromTheTerminalKeepsTheSheetSayingWhy() async throws {
        let h = SheetHarness(assess: { text, _ in SheetFixtures.notFlagged(text) })
        h.host.refuseWith = "3 commands are running. Wait for one to finish, or stop one."
        await h.present(SheetFixtures.offer("echo hi", facts: SheetFixtures.facts(cwd: h.folder.path)))
        h.advance(1)
        let run = try #require(h.view?.runButton)
        h.click(run)
        #expect(await waitUntil(5) { h.host.requests.count == 1 })
        #expect(h.sheet != nil)
        #expect(h.model?.message?.text == "3 commands are running. Wait for one to finish, or stop one.")
        #expect(h.model?.run.state.isOn == false, "one approval, one run: a new look needs a new sheet")
        h.advance(1)
        run.pointerExited()
        h.click(run)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(h.host.requests.count == 1)
    }

    @Test func typeUsesTheInteractiveCleanShellAndLoginTypeLeavesOutFullLineComments() async throws {
        let h = SheetHarness(assess: { text, _ in SheetFixtures.notFlagged(text) })
        await h.present(SheetFixtures.offer("# fetch it\necho one", facts: SheetFixtures.facts(cwd: h.folder.path)))
        h.advance(1)
        h.click(try #require(h.view?.typeButton))
        #expect(await waitUntil(5) { h.host.requests.count == 1 })
        let request = try #require(h.host.requests.first)
        #expect(request.role == .typeIntoTerminal)
        #expect(request.descriptor.kind == .typeIntoTerminal)
        #expect(request.descriptor.shellArguments == ["-f", "-i", "-o", "interactivecomments", "-o", "nobanghist"])
        #expect(request.typedText == "# fetch it\necho one", "the clean shell keeps comments as comments")

        let login = SheetHarness(assess: { text, _ in SheetFixtures.notFlagged(text) }, shell: .login)
        await login.present(SheetFixtures.offer("# fetch it\necho one", facts: SheetFixtures.facts(cwd: login.folder.path)))
        #expect(login.model?.notes.contains("Your startup files run first and can change what this command does.") == true)
        login.advance(1)
        login.click(try #require(login.view?.typeButton))
        #expect(await waitUntil(5) { login.host.requests.count == 1 })
        #expect(login.host.requests.first?.typedText == "echo one")
        #expect(login.host.requests.first?.descriptor.shellArguments == ["-l", "-i"])

        let trailing = SheetHarness(assess: { text, _ in SheetFixtures.notFlagged(text) }, shell: .login)
        await trailing.present(SheetFixtures.offer("echo one # two", facts: SheetFixtures.facts(cwd: trailing.folder.path)))
        #expect(trailing.model?.type.state == .off("your zsh has interactive comments off: use Copy"))
    }

    @Test func sshFamilyCommandsGetTheAgent() async throws {
        let h = SheetHarness(assess: { text, _ in SheetFixtures.notFlagged(text, programs: ["git"]) })
        await h.present(SheetFixtures.offer("git pull", facts: SheetFixtures.facts(cwd: h.folder.path)))
        h.advance(1)
        h.click(try #require(h.view?.runButton))
        #expect(await waitUntil(5) { h.host.requests.count == 1 })
        #expect(h.host.requests.first?.descriptor.environmentNames.contains("SSH_AUTH_SOCK") == true)
    }

    // MARK: Closing

    @Test func cancelDismissAndReplacingCloseAsCancel() async throws {
        let h = SheetHarness(assess: { text, _ in SheetFixtures.notFlagged(text) })
        await h.present(SheetFixtures.offer("echo one", facts: SheetFixtures.facts(cwd: h.folder.path)))
        h.click(try #require(h.view?.cancelButton), enter: false)   // Cancel works at once
        #expect(h.sheet == nil && h.events == [.cancelled])
        await h.present(SheetFixtures.offer("echo two", facts: SheetFixtures.facts(cwd: h.folder.path)))
        h.controller.dismissSheet()
        #expect(h.sheet == nil && h.events == [.cancelled, .cancelled])
        await h.present(SheetFixtures.offer("echo three", facts: SheetFixtures.facts(cwd: h.folder.path)))
        await h.present(SheetFixtures.offer("echo four", number: 2, total: 2))
        #expect(h.events == [.cancelled, .cancelled, .cancelled], "the replaced sheet closed as a Cancel")
        #expect(h.sheet?.state.offer?.text == "echo four")
    }

    @Test func anUntouchedSheetClosesAsACancel() async throws {
        let h = SheetHarness(assess: { text, _ in SheetFixtures.notFlagged(text) })
        await h.present(SheetFixtures.offer("echo one", facts: SheetFixtures.facts(cwd: h.folder.path)))
        h.sheet?.untouched = h.controller.schedule(after: 0.05) { [weak controller = h.controller] in controller?.close(reason: .timeout) }
        #expect(await waitUntil(5) { h.sheet == nil })
        #expect(h.events == [.cancelled])
        #expect(CommandSheetController.untouchedLimit == 600)
    }

    @Test func revealRunAsksTheTerminalAndNothingElse() {
        let h = SheetHarness(assess: { text, _ in SheetFixtures.notFlagged(text) })
        let id = UUID()
        h.controller.revealRun(id)
        #expect(h.host.revealed == [id])
        #expect(h.host.requests.isEmpty)
    }

    // MARK: Placement

    @Test func theSheetSitsBesideTheBlockNeverUnderThePointer() {
        let screen = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let block = CGRect(x: 1536, y: 0, width: 1024, height: 1440)
        let size = CGSize(width: 720, height: 600)
        let frame = CommandSheetPlacement.frame(size: size, anchor: CGRect(x: 1600, y: 700, width: 320, height: 220), block: block,
                                                screen: screen, pointer: CGPoint(x: 1700, y: 800))
        #expect(frame.maxX <= block.minX - CommandSheetPlacement.gap + 0.5, "left of a block on the right edge")
        #expect(!frame.contains(CGPoint(x: 1700, y: 800)))
        let under = CommandSheetPlacement.frame(size: size, anchor: CGRect(x: 1600, y: 700, width: 320, height: 220), block: block,
                                                screen: screen, pointer: CGPoint(x: 1200, y: 800))
        #expect(!under.insetBy(dx: -4, dy: -4).contains(CGPoint(x: 1200, y: 800)), "moved away from the pointer")
        let tall = CommandSheetPlacement.frame(size: CGSize(width: 720, height: 5_000), anchor: .zero, block: block, screen: screen, pointer: nil)
        #expect(tall.height <= screen.height * 0.8 + 0.5)
        #expect(CommandSheetController.width(for: "short", screen: screen) == 720)
        #expect(CommandSheetController.width(for: String(repeating: "x", count: 300), screen: screen) == 960)
    }

    /// The sheet sits on the block's window side: the side facing the rest of the screen, whichever edge the block is on,
    /// also with room on the far side; a docked area (`anchorFrame`) is the reference when given.
    @Test func theSheetSitsOnTheBlocksWindowSide() {
        let screen = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let size = CGSize(width: 720, height: 600)
        let anchor = CGRect(x: 100, y: 700, width: 300, height: 200)
        let leftEdge = CGRect(x: 0, y: 0, width: 640, height: 1440)
        let right = CommandSheetPlacement.frame(size: size, anchor: anchor, block: leftEdge, screen: screen, pointer: nil)
        #expect(right.minX == leftEdge.maxX + CommandSheetPlacement.gap, "right of a block on the left edge")
        // An inboard block in the left half with room on both sides: still towards the screen's middle.
        let inboard = CGRect(x: 900, y: 0, width: 300, height: 1440)
        let towardsMiddle = CommandSheetPlacement.frame(size: size, anchor: anchor, block: inboard, screen: screen, pointer: nil)
        #expect(towardsMiddle.minX == inboard.maxX + CommandSheetPlacement.gap)
        // Without a block, the anchor is the reference: one in the left half gets the sheet on its right.
        let byAnchor = CommandSheetPlacement.frame(size: size, anchor: anchor, block: nil, screen: screen, pointer: nil)
        #expect(byAnchor.minX == anchor.maxX + CommandSheetPlacement.gap)
        // No room on either side: the screen's left margin.
        let full = CGRect(x: 200, y: 0, width: 2200, height: 1440)
        #expect(CommandSheetPlacement.frame(size: size, anchor: anchor, block: full, screen: screen, pointer: nil).minX
                == screen.minX + CommandSheetPlacement.margin)
    }

    @Test func theSheetUsesTheAnchorFrameBeforeTheAnchorWindow() async throws {
        let h = SheetHarness(assess: { text, _ in SheetFixtures.notFlagged(text) })
        let window = NSWindow(contentRect: CGRect(x: 1_900, y: 0, width: 660, height: 1_400), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        h.controller.anchorWindow = window
        let docked = CGRect(x: 1_300, y: 0, width: 1_260, height: 1_400)
        h.controller.anchorFrame = { docked }
        await h.present(SheetFixtures.offer("echo hi", facts: SheetFixtures.facts(cwd: h.folder.path)))
        let frame = try #require(h.sheet?.placedFrame)
        #expect(frame.maxX <= docked.minX - CommandSheetPlacement.gap + 0.5, "beside the docked area, not the block's window")
        h.controller.dismissSheet()
        h.controller.anchorFrame = { nil }
        await h.present(SheetFixtures.offer("echo hi", facts: SheetFixtures.facts(cwd: h.folder.path)))
        let alone = try #require(h.sheet?.placedFrame)
        #expect(alone.maxX <= window.frame.minX - CommandSheetPlacement.gap + 0.5 && alone.maxX > docked.minX,
                "without an anchor frame: beside the window")
        h.controller.dismissSheet()
    }
}
