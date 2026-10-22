import AppKit
import Foundation
import PitboxKit
import Testing
@testable import PitboxSessions

/// Delays the view asked for, run by the test.
@MainActor
final class TileDelays {
    private(set) var items: [(seconds: TimeInterval, item: DispatchWorkItem)] = []

    func install(on view: CodeMonitorsTileView) {
        view.delay = { [weak self] seconds, work in
            let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
            self?.items.append((seconds, item))
            return item
        }
    }

    /// Runs the latest pending delay of `seconds`.
    func fire(_ seconds: TimeInterval) {
        guard let entry = items.last(where: { abs($0.seconds - seconds) < 0.001 && !$0.item.isCancelled }) else {
            Issue.record("no pending \(seconds) s delay")
            return
        }
        entry.item.perform()
    }

    func requested(_ seconds: TimeInterval) -> Bool { items.contains { abs($0.seconds - seconds) < 0.001 } }
}

@MainActor
@Suite("Block view")
struct TileViewTests {
    init() { CodeTileLog.enabled = false }

    private func click(_ view: NSView, at point: CGPoint) {
        let window = view.window
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else {
            Issue.record("could not make mouse events")
            return
        }
        view.mouseDown(with: down)
        view.mouseUp(with: up)
    }

    private func centre(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

    private func four(_ h: TileHarness, offers: [String: [CodeOfferEntry]] = [:]) {
        h.set((1...4).map { n in
            tileSession("local_s\(n)", "Session \(n)", index: n, state: n == 2 ? .needsYou : .done,
                        tldr: "Summary \(n)", ask: n == 2 ? "Pick A or B?" : nil, offers: offers["local_s\(n)"] ?? [])
        })
    }

    @Test func aClickOnAScreenParksOrRestores() throws {
        let h = TileHarness()
        four(h)
        h.parker.statuses["local_s2"] = CodeWindowStatus(place: .parked(since: tileNow))
        let (view, window) = makeTileView(h)
        defer { window.close() }
        let first = try #require(view.folder.monitorView("local_s1"))
        click(first, at: centre(first.layoutInfo.screen))
        let second = try #require(view.folder.monitorView("local_s2"))
        click(second, at: centre(second.layoutInfo.screen))
        #expect(h.parker.performed.map(\.0) == [.park, .restore])
        #expect(h.parker.performed.map(\.1) == ["local_s1", "local_s2"])
        // A press that ends elsewhere does nothing.
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: first.convert(centre(first.layoutInfo.screen), to: nil),
                                      modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                      eventNumber: 0, clickCount: 1, pressure: 1)
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: first.convert(CGPoint(x: -50, y: -50), to: nil), modifierFlags: [],
                                    timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        if let down, let up { first.mouseDown(with: down); first.mouseUp(with: up) }
        #expect(h.parker.performed.count == 2)
    }

    @Test func theOfferLineOpensTheSheetBesideItsMonitor() throws {
        let h = TileHarness()
        let entry = tileOffer("open ~/Downloads/report.pdf", session: 1)
        four(h, offers: ["local_s1": [entry]])
        let (view, window) = makeTileView(h)
        defer { window.close() }
        let monitor = try #require(view.folder.monitorView("local_s1"))
        let offer = try #require(monitor.layoutInfo.offer)
        #expect(monitor.layoutInfo.screen.contains(offer))
        click(monitor, at: centre(offer))
        let sheet = try #require(h.presenter.presented.first)
        #expect(sheet.offer.id == entry.id)
        #expect(sheet.anchor == monitor.convert(monitor.bounds, to: nil))
        // The offer click never parks.
        #expect(h.parker.performed.isEmpty)
    }

    @Test func severalOffersOpenThePeeksList() throws {
        let h = TileHarness()
        four(h, offers: ["local_s3": [tileOffer("a", session: 3, number: 1, total: 2), tileOffer("b", session: 3, number: 2, total: 2)]])
        let (view, window) = makeTileView(h)
        defer { window.close() }
        let monitor = try #require(view.folder.monitorView("local_s3"))
        click(monitor, at: centre(try #require(monitor.layoutInfo.offer)))
        #expect(view.peekFor == "local_s3")
        #expect(h.presenter.presented.isEmpty)
        #expect(view.peekView?.item.peek.offers.count == 2)
    }

    @Test func restingOnAMonitorOpensItsPeekAndLeavingClosesIt() throws {
        let h = TileHarness()
        four(h)
        let (view, window) = makeTileView(h)
        defer { window.close() }
        let delays = TileDelays()
        delays.install(on: view)
        var pointer: CGPoint?
        view.pointerProbe = { pointer }
        let monitor = try #require(view.folder.monitorView("local_s2"))
        monitor.setHovered(true)
        #expect(delays.requested(CodeMonitorsTileView.dwellDelay))
        #expect(view.peekView == nil)
        delays.fire(CodeMonitorsTileView.dwellDelay)
        let peek = try #require(view.peekView)
        // Two strip columns from the hovered (middle) column toward the side with room, at most 450 pt tall at the
        // monitor's row, under the header.
        #expect(peek.frame.width == 657)
        #expect(abs(peek.frame.minX - view.content.convert(monitor.bounds, from: monitor).minX) < 1)
        #expect(peek.frame.minY == 0 && peek.frame.height == 450)
        #expect(view.convert(peek.bounds, from: peek).minY == CodeMonitorsTileView.headerHeight)
        // Leaving: 0.25 s later it closes, unless the pointer is on the panel.
        monitor.setHovered(false)
        pointer = CGPoint(x: peek.frame.midX, y: peek.frame.midY)
        delays.fire(CodeMonitorsTileView.closeDelay)
        #expect(view.peekView != nil)
        peek.onHover?(false)
        pointer = CGPoint(x: 5, y: view.bounds.maxY - 5)
        delays.fire(CodeMonitorsTileView.closeDelay)
        #expect(view.peekView == nil)
    }

    @Test func aRightColumnMonitorsPeekGrowsLeft() throws {
        let h = TileHarness()
        four(h)
        let (view, window) = makeTileView(h)
        defer { window.close() }
        let right = try #require(view.folder.monitorView("local_s3"))
        view.openPeek("local_s3")
        let peek = try #require(view.peekView)
        #expect(abs(peek.frame.maxX - view.content.convert(right.bounds, from: right).maxX) < 1)
        // The glow of a monitor under the panel is held back (it would bleed out around it).
        #expect(view.folder.monitorView("local_s2")?.suppressGlow == true)
        view.closePeek()
        #expect(view.folder.monitorView("local_s2")?.suppressGlow == false)
    }

    @Test func peekButtonsReviewCopyAndMoveTheWindow() throws {
        let h = TileHarness()
        let entry = tileOffer("make test", session: 1)
        four(h, offers: ["local_s1": [entry]])
        let (view, window) = makeTileView(h)
        defer { window.close() }
        view.openPeek("local_s1")
        let peek = try #require(view.peekView)
        let review = try #require(peek.visibleButtons().first { $0.action == .review(entry.id) })
        // "Review…" (Run is off by default; "▶ Run…" with it on) only opens the sheet.
        #expect(review.title == "Review…")
        click(peek, at: centre(review.rect))
        #expect(h.presenter.presented.map(\.offer.id) == [entry.id])
        #expect(h.parker.performed.isEmpty)
        peek.press(.copy(entry.id))
        #expect(h.pasteboard.copies.last?.privately == true)
        peek.press(.copyLink)
        #expect(h.pasteboard.copies.last?.text == "claude://claude.ai/epitaxy/local_s1")
        let park = try #require(peek.footerButtons.first)
        #expect(park.title == "Pit")
        click(peek, at: centre(park.rect))
        #expect(h.parker.performed.map(\.0) == [.park])
        #expect(view.peekView == nil)
        // The sheet was asked once; nothing else reached it.
        #expect(h.presenter.presented.count == 1)
    }

    @Test func theHeaderSwitchesHideTextAndParksAllDone() async throws {
        let h = TileHarness()
        four(h)
        let (view, window) = makeTileView(h)
        defer { window.close() }
        let buttons = view.headerButtons()
        let hide = try #require(buttons.first { $0.kind == .hideText })
        #expect(hide.title == "Hide text")
        click(view, at: centre(hide.rect))
        #expect(h.model.hideText)
        #expect(view.headerButtons().first { $0.kind == .hideText }?.title == "Show text")
        let parkAll = try #require(view.headerButtons().first { $0.kind == .parkAllDone })
        #expect(parkAll.title == "Pit all done (3)" && parkAll.enabled)
        click(view, at: centre(parkAll.rect))
        for _ in 0..<50 where h.parker.parkAllCalls.isEmpty { await Task.yield() }
        #expect(h.parker.parkAllCalls.first?.count == 3)
        // Nothing done on the desk: the button is off.
        h.set([tileSession("local_w", "Working", state: .working)])
        #expect(view.headerButtons().first { $0.kind == .parkAllDone }?.enabled == false)
    }

    @Test func pagesTurnWithTheDots() throws {
        let h = TileHarness()
        h.set((1...13).map { tileSession("local_p\($0)", "Pop-out \($0)", index: $0) })
        let (view, window) = makeTileView(h)
        defer { window.close() }
        #expect(view.folder.grid.size == .small && view.folder.grid.pages == 2)
        #expect(view.folder.monitorViews.count == 12)
        let dot = try #require(view.folder.controls().first { $0.control == .dot(1) })
        click(view.folder, at: centre(dot.rect))
        #expect(view.folder.page == 1)
        #expect(Array(view.folder.monitorViews.keys) == ["local_p13"])
    }

    @Test func aTallFolderScrollsUnderTheHeaderAndHandsTheWheelOnAtTheEnd() throws {
        let h = TileHarness()
        h.set((1...9).map { tileSession("local_m\($0)", "Medium \($0)", index: $0) })
        let (view, window) = makeTileView(h)
        defer { window.close() }
        // Nine medium monitors are 3 × 150 + 2 × 12 = 474 pt; under the 24 pt header there are 450.
        #expect(view.folder.grid.size == .medium && view.folder.frame.height == 474)
        #expect(view.maxScrollOffset == 24)
        view.openPeek("local_m1")
        func wheel(_ dy: Int32) throws -> NSEvent {
            let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0))
            return try #require(NSEvent(cgEvent: cg))
        }
        view.content.scrollWheel(with: try wheel(-30))
        #expect(view.scrollOffset == 24)
        #expect(view.folder.frame.minY == -24)
        // Scrolling closes a peek (it would no longer sit on its monitor).
        #expect(view.peekView == nil)
        // A short folder does not scroll.
        h.set((1...4).map { tileSession("local_l\($0)", "Large \($0)", index: $0) })
        #expect(view.maxScrollOffset == 0 && view.scrollOffset == 0)
    }

    @Test func hidingTheStripClosesThePeek() throws {
        let h = TileHarness()
        four(h)
        let (view, window) = makeTileView(h)
        defer { window.close() }
        view.openPeek("local_s1")
        #expect(view.peekView != nil)
        h.model.setStripVisible(false)
        #expect(view.peekView == nil)
        h.model.setStripVisible(true)
        view.openPeek("local_s1")
        h.model.closeOverlays()   // `PitboxBlock.dismissOverlays()`: fold and hide close the peek
        #expect(view.peekView == nil)
    }

    @Test func theTileTellsTheModelWhenItIsVisible() {
        let h = TileHarness()
        let (_, window) = makeTileView(h)
        defer { window.close() }
        #expect(h.parker.active.last == true)
        #expect(h.source.stripVisible.last == true)
    }

    @Test func snapshotsShowOnlyTheRedactionCard() throws {
        let h = TileHarness()
        four(h)
        let size = CGSize(width: 992, height: 474)
        let (view, window) = makeTileView(h, size: size)
        defer { window.close() }
        view.appearance = NSAppearance(named: .darkAqua)
        view.openPeek("local_s2")
        func render(_ target: NSView) throws -> NSBitmapImageRep {
            let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            rep.size = size
            target.cacheDisplay(in: target.bounds, to: rep)
            return rep
        }
        let tile = try render(view)
        let card = CodeRedactionView(frame: CGRect(origin: .zero, size: size), dark: true)
        card.appearance = NSAppearance(named: .darkAqua)
        let expected = try render(card)
        #expect(tile.pixelsWide == expected.pixelsWide && tile.pixelsHigh == expected.pixelsHigh)
        var differing = 0
        for x in stride(from: 0, to: tile.pixelsWide, by: 7) {
            for y in stride(from: 0, to: tile.pixelsHigh, by: 7) where tile.colorAt(x: x, y: y) != expected.colorAt(x: x, y: y) {
                differing += 1
            }
        }
        #expect(differing == 0)
        // The cover is gone again afterwards.
        #expect(!view.subviews.contains { $0 is CodeRedactionView })
    }

    @Test func voiceOverLabelsHoldNoSessionText() throws {
        let h = TileHarness()
        h.set([tileSession("local_a", "Client deal ZQX", tldr: "price 4M ZQX", ask: "Approve ZQX?",
                           offers: [tileOffer("echo ZQX")])])
        let (view, window) = makeTileView(h)
        defer { window.close() }
        let monitor = try #require(view.folder.monitorView("local_a"))
        let label = monitor.accessibilityLabel() ?? ""
        #expect(label.hasPrefix("Code monitor 1 of 1"))
        #expect(label.contains("1 command offered"))
        #expect(!label.contains("ZQX") && !(monitor.accessibilityHelp() ?? "").contains("ZQX"))
        view.openPeek("local_a")
        let peekLabels = (view.peekView?.accessibilityChildren() ?? []).compactMap { ($0 as? NSAccessibilityElement)?.accessibilityLabel() }
        #expect(!peekLabels.isEmpty && peekLabels.allSatisfy { !$0.contains("ZQX") })
    }
}
