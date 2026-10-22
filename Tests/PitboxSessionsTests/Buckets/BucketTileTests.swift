import AppKit
import Foundation
import PitboxKit
import Testing
@testable import PitboxSessions

/// Buckets in the block: when headers show, the header words and badges, where desk windows show, "+ New bucket" and
/// the name field, the colour menu, fold, Delete's question, the limit, the broken-file note and "Show monitor".
@MainActor
@Suite("Buckets: in the block")
struct BucketTileTests {
    init() { CodeTileLog.enabled = false }

    // MARK: Headers and words

    @Test func withUnsortedAloneTheTileLooksAsBeforeAndTheFirstBucketBringsTheHeaders() throws {
        let h = BucketHarness()
        h.set(bucketSessions("s", 3))
        let (view, window) = makeBucketTileView(h)
        defer { window.close() }
        #expect(!h.model.snapshot.bucketMode && view.bucketHeaders.isEmpty)
        #expect(view.folder.frame.minY == 0)
        let id = try #require(h.model.createBucket())
        #expect(h.model.snapshot.bucketMode)
        #expect(Set(view.bucketHeaders.keys) == [CodeBucket.unsortedID, id])
        // Unsorted's header first, then its monitors, then the new bucket's header and its drop hint.
        let unsorted = try #require(view.bucketHeaders[CodeBucket.unsortedID]), made = try #require(view.bucketHeaders[id])
        #expect(unsorted.frame.minY == 0 && view.folder.frame.minY == unsorted.frame.maxY + CodeBucketLayout.headerToBody)
        #expect(made.frame.minY > view.folder.frame.maxY)
        let empty = try #require(view.otherFolders[id])
        #expect(empty.showsEmptyHint && empty.frame.height == 48)
        // Deleting the last bucket goes back to the plain look.
        h.model.deleteBucket(id)
        #expect(view.bucketHeaders.isEmpty && view.folder.frame.minY == 0)
    }

    /// Buckets come first: the stack puts every bucket first and the Ready list after the last.
    @Test func bucketsComeFirstAndTheReadyListFollowsTheLastBucket() throws {
        let specs: [(id: String, folded: Bool, bodyHeight: CGFloat)] = [("u", false, 100), ("c", true, 0), ("d", false, 48)]
        let stack = CodeBucketLayout.stack(width: 300, readyHeight: 80, flat: false, buckets: specs)
        #expect(stack.placed.map(\.id) == ["u", "c", "d"])
        #expect(stack.placed.first?.header?.minY == 0)
        let lastEnd = try #require(stack.placed.last?.area.maxY)
        #expect(stack.readyY == lastEnd + CodeBucketLayout.aboveReady && stack.height == stack.readyY + 80)

        // No Ready items: no gap and no list height.
        let bare = CodeBucketLayout.stack(width: 300, readyHeight: 0, flat: false, buckets: specs)
        #expect(bare.placed == stack.placed && bare.readyY == lastEnd && bare.height == lastEnd)

        // Unsorted alone (no headers): its body at the top, the list right under it.
        let flat = CodeBucketLayout.stack(width: 300, readyHeight: 80, flat: true, buckets: [specs[0]])
        #expect(flat.placed.first?.body?.minY == 0 && flat.placed.first?.header == nil)
        #expect(flat.readyY == 100 && flat.height == 180)
    }

    /// A new bucket above the Ready list moves it, and the list hears of it (its open buttons re-arm); a layout that
    /// moves nothing says nothing.
    @Test func aBucketAboveTheReadyListMovesItAndTellsIt() throws {
        let h = BucketHarness()
        h.set(bucketSessions("s", 3))
        let (view, window) = makeBucketTileView(h)
        defer { window.close() }
        let band = MovingBand()
        view.readyAccessory = band
        let before = band.frame.minY
        #expect(band.moves == 0 && before > 0)
        _ = try #require(h.model.createBucket())
        #expect(band.frame.minY > before && band.moves == 1)
        view.layoutContent()
        #expect(band.moves == 1)
    }

    @Test func theHeaderSaysParkedOnYourDeskAndNeedsYou() throws {
        let h = BucketHarness()
        h.set(bucketSessions("s", 5, states: [2: .needsYou, 3: .problem]))
        h.parker.statuses["local_s1"] = CodeWindowStatus(place: .parked(since: tileNow))
        h.parker.statuses["local_s4"] = CodeWindowStatus(place: .closed)
        h.parker.parkedSessionIDs = ["local_s4"]
        let (view, window) = makeBucketTileView(h)
        defer { window.close() }
        let header = h.model.snapshot.header
        #expect(header.parked == 2 && header.onDesk == 3 && header.needYou == 1)
        #expect(view.headerWords().map(\.text) == ["2 in the pit", "3 on track", "1 needs you"])
        h.set(bucketSessions("s", 5, states: [2: .needsYou, 5: .needsYou]))
        #expect(view.headerWords().last?.text == "2 need you" && view.headerWords().last?.attention == true)
        // The header's buttons: Hide text, Park all done and + New bucket, left to right.
        #expect(view.headerButtons().map(\.kind) == [.newBucket, .parkAllDone, .hideText])
        #expect(view.headerButtons().first?.title == "+ New bucket")
    }

    @Test func bucketHeadersCountEveryPageWithWordsAndSigns() throws {
        let h = BucketHarness()
        let toy = try #require(h.makeBuckets(["Toy Cube"]).first)
        var sessions = bucketSessions("t", 13, states: [1: .working, 2: .maybeNeedsYou, 3: .quietUnfinished, 13: .needsYou])
        sessions[3].progress = CodeProgress(source: .backgroundTasks, unit: .agents, done: 2, total: 6, pendingBetweenTurns: true)
        sessions[4].offers = [tileOffer("make", session: 5), tileOffer("scp x", session: 5, number: 2, total: 2, commandClass: .fetchFile)]
        sessions[5].earlierOffers = [tileOffer("make again", session: 6)]
        sessions[6].results = [CodeResult(kind: .serverFile, origin: .handedOver, path: "/srv/x", label: "x")]
        sessions[7].unread = true
        sessions[7].finished = CodeFinishedMark(replyUUID: "r1", at: tileNow, ranSeconds: 600)
        sessions[8].unread = true   // news, but no finished turn
        sessions[12].warnings = [CodeWarning(kind: .silence, since: tileNow)]
        h.set(sessions)
        for n in 1...13 { h.model.moveSession("local_t\(n)", toBucket: toy) }
        let section = try #require(h.section(toy))
        #expect(section.counts == CodeBucketCounts(monitors: 13, running: 3, needYou: 1, commands: 2, files: 2, finishedNew: 1, warnings: 1))
        #expect(CodeBucketHeaderView.meta(section.counts) == "13 · 3 running")
        #expect(CodeBucketHeaderView.badges(section.counts).map(\.text) == ["1 needs you", "▶ 2", "⤓ 2", "✓ 1 new", "⚠ 1"])
        #expect(CodeBucketHeaderView.accessibilityLabel(section)
                    == "Bucket Toy Cube, 13 sessions, 3 running, 1 needs you, 2 commands, 2 files, 1 new, 1 warning")
        // Ready items can stand in for the snapshot's offers.
        h.model.readyCounts = { _ in CodeReadyCounts(commands: 1, files: 0) }
        h.model.rebuild()
        #expect(h.section(toy)?.counts.commands == 13 && h.section(toy)?.counts.files == 0)
        // A folded bucket keeps its badges.
        h.model.toggleFolded(toy)
        let (view, window) = makeBucketTileView(h)
        defer { window.close() }
        let header = try #require(view.bucketHeaders[toy])
        #expect(header.section.bucket.folded && !header.layoutInfo.badges.isEmpty)
        #expect(view.otherFolders[toy]?.isHidden == true)
        #expect(header.accessibilityLabel()?.hasSuffix("folded") == true)
    }

    // MARK: Desk windows

    @Test func deskWindowsLeaveTheBucketsOnlyOnceDeskTagsStandInForThem() {
        let h = BucketHarness()
        h.set(bucketSessions("s", 3))
        h.parker.statuses["local_s2"] = CodeWindowStatus(place: .parked(since: tileNow))
        h.parker.statuses["local_s3"] = CodeWindowStatus(place: .otherSpace)
        // No desk tags yet: every pop-out keeps its monitor.
        #expect(h.model.snapshot.monitors.map(\.id) == ["local_s1", "local_s2", "local_s3"])
        h.model.deskWindowsHaveTags = true
        // The default: desk windows show as desk tags and in Ready; parked ones and ones elsewhere keep monitors.
        #expect(h.model.snapshot.monitors.map(\.id) == ["local_s2", "local_s3"])
        #expect(h.model.snapshot.header.onDesk == 1 && h.model.snapshot.header.parked == 1)
        // A pop-out the window pass has not seen yet gets none (no flash before the first pass).
        h.source.sessions = bucketSessions("s", 4)
        #expect(!h.model.snapshot.monitors.contains { $0.id == "local_s4" })
        // The other way: desk windows keep their monitors.
        var settings = CodeSettings()
        settings.deskWindows = .monitors
        h.model.update(settings: settings)
        #expect(h.model.snapshot.monitors.count == 4)
    }

    // MARK: + New bucket and the name field

    @Test func newBucketOpensItsNameForTypingAndReturnKeepsIt() throws {
        let h = BucketHarness()
        h.set(bucketSessions("s", 2))
        let (view, window) = makeBucketTileView(h)
        defer { window.close() }
        let button = try #require(view.headerButtons().first { $0.kind == .newBucket })
        bucketClick(view, at: bucketCentre(button.rect))
        let state = try #require(view.renaming)
        #expect(state.isNew && state.field.stringValue == "New bucket")
        #expect(h.keyboard.calls == [true])
        #expect(state.field.superview === view.bucketHeaders[state.bucketID])
        // Typing drops B1 characters and line breaks, and stops at 32 characters.
        state.field.stringValue = "Toy\u{202E} Cube\n"
        state.field.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(state.field.stringValue == "Toy Cube")
        state.field.stringValue = String(repeating: "z", count: 40)
        state.field.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(state.field.stringValue.count == 32)
        state.field.stringValue = "  Toy Cube "
        #expect(state.field.control(state.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(view.renaming == nil && state.field.superview == nil)
        #expect(h.model.buckets.bucket(state.bucketID)?.name == "Toy Cube")
        #expect(h.keyboard.calls == [true, false])
    }

    @Test func escapeRemovesABucketJustMadeAndKeepsAnOldName() throws {
        let h = BucketHarness()
        let (view, window) = makeBucketTileView(h)
        defer { window.close() }
        view.startNewBucket()
        let fresh = try #require(view.renaming)
        fresh.field.stringValue = "Typed then dropped"
        #expect(fresh.field.control(fresh.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(h.model.buckets.buckets == [CodeBucket.unsorted])
        #expect(!h.model.snapshot.bucketMode)
        // A rename of an old bucket: Escape keeps the old name.
        let id = try #require(h.makeBuckets(["Acme"]).first)
        let header = try #require(view.bucketHeaders[id])
        bucketClick(header, at: bucketCentre(header.layoutInfo.name), clickCount: 2)
        let rename = try #require(view.renaming)
        #expect(!rename.isNew && rename.field.stringValue == "Acme")
        rename.field.stringValue = "Something else"
        _ = rename.field.control(rename.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        #expect(h.model.buckets.bucket(id)?.name == "Acme")
        #expect(view.renaming == nil)
    }

    @Test func aClickElsewhereKeepsWhatWasTypedAndASingleClickRenamesNothing() throws {
        let h = BucketHarness()
        let id = try #require(h.makeBuckets(["Acme"]).first)
        let (view, window) = makeBucketTileView(h)
        defer { window.close() }
        let header = try #require(view.bucketHeaders[id])
        bucketClick(header, at: bucketCentre(header.layoutInfo.name))
        #expect(view.renaming == nil)
        view.beginRename(id, isNew: false)
        let state = try #require(view.renaming)
        state.field.stringValue = "Acme room"
        let inside = try #require(bucketMouse(.leftMouseDown, at: CGPoint(x: 4, y: 4), in: state.field))
        view.renameSawClick(inside)
        #expect(view.renaming != nil)
        let elsewhere = try #require(bucketMouse(.leftMouseDown, at: CGPoint(x: 500, y: 300), in: view))
        view.renameSawClick(elsewhere)
        #expect(view.renaming == nil)
        #expect(h.model.buckets.bucket(id)?.name == "Acme room")
        // Unsorted's name never opens.
        view.beginRename(CodeBucket.unsortedID, isNew: false)
        #expect(view.renaming == nil)
        // The block hiding keeps the typed name too.
        view.beginRename(id, isNew: false)
        view.renaming?.field.stringValue = "Acme again"
        h.model.setStripVisible(false)
        #expect(view.renaming == nil && h.model.buckets.bucket(id)?.name == "Acme again")
    }

    // MARK: Colour, fold, delete

    @Test func theColourSquareOpensEightNamedColoursWithTheCurrentOneTicked() throws {
        let h = BucketHarness()
        let id = try #require(h.makeBuckets(["Toy Cube"]).first)
        let (view, window) = makeBucketTileView(h)
        defer { window.close() }
        var shown: NSMenu?
        view.menuPresenter = { menu, _, _ in shown = menu }
        let header = try #require(view.bucketHeaders[id])
        bucketClick(header, at: bucketCentre(header.layoutInfo.swatch))
        let menu = try #require(shown)
        #expect(menu.items.map(\.title) == ["Violet", "Amber", "Teal", "Red", "Green", "Blue", "Pink", "Grey"])
        #expect(menu.items.filter { $0.state == .on }.map(\.title) == ["Violet"])
        let amber = try #require(menu.items.first { $0.title == "Amber" })
        view.colorChosen(amber)
        #expect(h.model.buckets.bucket(id)?.color == .amber)
        #expect(view.bucketHeaders[id]?.section.bucket.color == .amber)
        // Unsorted can be recoloured too.
        let unsorted = try #require(view.bucketHeaders[CodeBucket.unsortedID])
        bucketClick(unsorted, at: bucketCentre(unsorted.layoutInfo.swatch))
        #expect(shown?.items.filter { $0.state == .on }.map(\.title) == ["Grey"])
    }

    @Test func foldFoldsToTheHeaderAndIsRemembered() throws {
        let folder = BucketTestFolder()
        defer { folder.cleanUp() }
        let h = BucketHarness(store: bucketStore(folder))
        let id = try #require(h.makeBuckets(["Acme"]).first)
        h.set(bucketSessions("s", 2))
        h.model.moveSession("local_s1", toBucket: id)
        let (view, window) = makeBucketTileView(h)
        defer { window.close() }
        let header = try #require(view.bucketHeaders[id])
        bucketClick(header, at: bucketCentre(header.layoutInfo.fold))
        #expect(h.model.buckets.bucket(id)?.folded == true)
        #expect(view.otherFolders[id]?.isHidden == true && view.monitorView("local_s1") == nil)
        h.model.buckets.flush()
        #expect(bucketStore(folder).bucket(id)?.folded == true)
        bucketClick(header, at: bucketCentre(header.layoutInfo.fold))
        #expect(view.monitorView("local_s1") != nil)
    }

    @Test func deleteAsksFirstAndMovesTheMonitorsToUnsorted() throws {
        let h = BucketHarness()
        let id = try #require(h.makeBuckets(["Toy Cube"]).first)
        h.set(bucketSessions("s", 4))
        for n in 1...3 { h.model.moveSession("local_s\(n)", toBucket: id) }
        let (view, window) = makeBucketTileView(h)
        defer { window.close() }
        let header = try #require(view.bucketHeaders[id])
        #expect(view.bucketHeaders[CodeBucket.unsortedID]?.layoutInfo.delete == nil)
        bucketClick(header, at: bucketCentre(try #require(header.layoutInfo.delete)))
        #expect(header.confirmingDelete)
        header.drawnTexts = []
        bucketRender(header)
        #expect(header.drawnTexts?.contains("Delete “Toy Cube”? 3 monitors move to Unsorted. No window is closed.") == true)
        #expect(header.drawnTexts?.contains("Keep") == true && header.drawnTexts?.contains("Delete") == true)
        #expect(CodeBucketHeaderView.deleteQuestion(name: "Solo", monitors: 1) == "Delete “Solo”? 1 monitor moves to Unsorted. No window is closed.")
        #expect(CodeBucketHeaderView.deleteQuestion(name: "Empty", monitors: 0) == "Delete “Empty”? No window is closed.")
        // Keep: nothing happens.
        bucketClick(header, at: bucketCentre(try #require(header.layoutInfo.keep)))
        #expect(!header.confirmingDelete && h.model.buckets.bucket(id) != nil)
        // Delete: the monitors move to Unsorted; no window is touched.
        bucketClick(header, at: bucketCentre(try #require(header.layoutInfo.delete)))
        bucketClick(header, at: bucketCentre(try #require(header.layoutInfo.confirm)))
        #expect(h.model.buckets.bucket(id) == nil)
        #expect(h.layout[CodeBucket.unsortedID] == ["local_s1", "local_s2", "local_s3", "local_s4"])
        #expect(h.parker.performed.isEmpty)
    }

    @Test func atTwentyBucketsNewBucketIsOffWithItsTooltip() throws {
        let h = BucketHarness()
        h.makeBuckets((1...19).map { "Bucket \($0)" })
        let (view, window) = makeBucketTileView(h)
        defer { window.close() }
        let button = try #require(view.headerButtons().first { $0.kind == .newBucket })
        #expect(!button.enabled && !h.model.snapshot.header.canCreateBucket)
        #expect(view.view(view, stringForToolTip: 0, point: bucketCentre(button.rect), userData: nil) == "20 buckets is the limit")
        bucketClick(view, at: bucketCentre(button.rect))
        #expect(h.model.buckets.buckets.count == 20 && view.renaming == nil)
    }

    @Test func aNarrowTileShortensNewBucketToAPlus() throws {
        let h = BucketHarness()
        h.set(bucketSessions("s", 2))
        let (view, window) = makeBucketTileView(h, size: CGSize(width: 322, height: 600))
        defer { window.close() }
        let button = try #require(view.headerButtons().first { $0.kind == .newBucket })
        #expect(button.title == "+" && button.enabled)
        #expect(view.view(view, stringForToolTip: 0, point: bucketCentre(button.rect), userData: nil) == "New bucket")
        #expect(view.accessibilityLabel(for: .newBucket) == "New bucket")
        // At the shipped width the words stay.
        let (wide, wideWindow) = makeBucketTileView(h)
        defer { wideWindow.close() }
        #expect(wide.headerButtons().first { $0.kind == .newBucket }?.title == "+ New bucket")
    }

    // MARK: The broken-file note, and Show monitor

    @Test func aBrokenFileShowsTheNoteUntilTheUsersNextChange() throws {
        let folder = BucketTestFolder()
        defer { folder.cleanUp() }
        try folder.write("{ not json")
        let h = BucketHarness(store: bucketStore(folder))
        let (view, window) = makeBucketTileView(h)
        defer { window.close() }
        #expect(view.bannerLines == ["Your buckets couldn't be read; a copy was kept."])
        #expect(view.content.frame.minY == CodeMonitorsTileView.headerHeight + CodeMonitorsTileView.bannerHeight)
        h.set(bucketSessions("s", 1))
        #expect(view.bannerLines.count == 1)
        h.model.createBucket()
        #expect(view.bannerLines.isEmpty)
    }

    @Test func showMonitorUnfoldsItsBucketTurnsItsPageAndScrollsToIt() throws {
        let h = BucketHarness()
        let ids = h.makeBuckets(["Acme", "Toy Cube"])
        h.set(bucketSessions("u", 4) + bucketSessions("t", 13))
        for n in 1...13 { h.model.moveSession("local_t\(n)", toBucket: ids[1]) }
        h.model.toggleFolded(ids[1])
        let (view, window) = makeBucketTileView(h, size: CGSize(width: 992, height: 474))
        defer { window.close() }
        #expect(view.monitorView("local_t13") == nil)
        h.model.revealMonitor("local_t13")
        #expect(h.model.buckets.bucket(ids[1])?.folded == false)
        #expect(view.otherFolders[ids[1]]?.page == 1 && h.model.page(of: ids[1]) == 1)
        let monitor = try #require(view.monitorView("local_t13"))
        let frame = view.content.convert(monitor.bounds, from: monitor)
        #expect(frame.minY >= 0 && frame.maxY <= view.content.bounds.height)
    }
}

/// A Ready-list stand-in that counts the block's `movedInStack()` calls.
@MainActor
private final class MovingBand: NSView, CodeTileAccessory {
    var moves = 0
    func accessoryHeight(forWidth width: CGFloat) -> CGFloat { 60 }
    func movedInStack() { moves += 1 }
}
