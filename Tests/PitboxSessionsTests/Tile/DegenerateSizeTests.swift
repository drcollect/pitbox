import AppKit
import Foundation
import PitboxKit
import Testing
@testable import PitboxSessions

/// The block at degenerate sizes. The block once crashed the app on its first layout:
/// SwiftUI hosted it at width 0, `insetBy` returned `CGRect.null` (an infinite origin), ∞ − ∞ gave NaN, and `Int(NaN)`
/// trapped in `placeLarge`. Every layout must stay finite and nothing may trap, whatever size AppKit hands over.
@MainActor
@Suite("Degenerate sizes")
struct DegenerateSizeTests {
    init() { CodeTileLog.enabled = false }

    static let oddSizes: [CGSize] = [.zero, CGSize(width: 1, height: 1), CGSize(width: 0, height: 474), CGSize(width: 992, height: 0),
                                     CGSize(width: 2, height: 600), CGSize(width: 600, height: 2), CGSize(width: 40, height: 474)]

    static let oddBounds: [CGRect] = oddSizes.map { CGRect(origin: .zero, size: $0) } + [
        CGRect(x: 0, y: 0, width: -40, height: 100), .null, .infinite,
        CGRect(x: 0, y: 0, width: CGFloat.nan, height: 100), CGRect(x: CGFloat.infinity, y: 0, width: 100, height: 100),
    ]

    /// A session that fills every slot: nickname, TL;DR, Ask, Now, an offer, results and a warning.
    func busySession(_ id: String, index: Int) -> CodeSessionSnapshot {
        var s = tileSession(id, "Ship the Code monitors build", index: index, state: .working,
                            tldr: "Built, signed and staged; the install waits for a restart.", ask: "Shall I install it now?",
                            now: "running: swift test", offers: [tileOffer("ls -la", session: index)])
        s.results = [CodeResult(kind: .document, origin: .written, path: "/x/report.md", label: "report.md")]
        s.otherLinkCount = 1
        s.warnings = [CodeWarning(kind: .failedInARow, since: tileNow.addingTimeInterval(-600), failures: 4, lastExitCode: 1)]
        return s
    }

    func item(_ s: CodeSessionSnapshot, hidden: Bool = false) -> CodeMonitorItem {
        CodeMonitorBuilder.item(s, position: 1, total: 1, inputs: CodeMonitorBuilder.Inputs(
            sessions: [s], statuses: [:], runs: CodeOfferRunBook(), hideText: hidden, showText: [:], showsProfiles: true,
            homeDirectory: "/Users/alex", now: tileNow))
    }

    func rects(_ l: CodeMonitorLayout) -> [CGRect] {
        [l.bezel, l.screen, l.content, l.led, l.neck, l.base, l.headline, l.spinner]
            + [l.profileLabel, l.nickname, l.chip, l.tldr, l.now, l.ask, l.offer, l.pip, l.compact, l.progress, l.status,
               l.stripe, l.warning, l.run, l.runBar].compactMap { $0 } + l.marks
    }

    @Test func everyMonitorLayoutStaysFiniteAtOddBounds() {
        let items = [item(busySession("local_d1", index: 1)), item(busySession("local_d2", index: 2), hidden: true)]
        for bounds in Self.oddBounds {
            for built in items {
                for size in [CodeMonitorSize.large, .medium, .small] {
                    let layout = CodeMonitorLayout.compute(built, size: size, bounds: bounds, showsProfile: true)
                    let finite = rects(layout).allSatisfy { $0.isFiniteRect }
                    #expect(finite, "\(size) at \(bounds)")
                    #expect(layout.headlineLines >= 1 && layout.tldrLines >= 0 && layout.askLines >= 0)
                }
                let row = CodeMonitorLayout.computeRow(built, bounds: bounds, showsProfile: true)
                let rowFinite = rects(row).allSatisfy { $0.isFiniteRect }
                #expect(rowFinite, "row at \(bounds)")
            }
        }
    }

    @Test func theGridStaysSaneAtOddWidths() {
        for width in [0, -50, 1, CGFloat.nan, CGFloat.infinity, -CGFloat.infinity] {
            for count in [1, 4, 9, 30] {
                let grid = CodeMonitorGrid.layout(count: count, width: width, stripColumn: 322, rows: false)
                #expect(grid.columns >= 1 && grid.pages >= 1 && grid.height.isFinite, "count \(count) at width \(width)")
                let rows = CodeMonitorGrid.layout(count: count, width: width, stripColumn: 322, rows: true)
                #expect(rows.pages >= 1 && rows.height.isFinite)
            }
            #expect(CodeMonitorGrid.stripColumn(tileWidth: width, stripWidth: CGFloat.nan).isFinite)
            #expect(CodeMonitorGrid.stripColumn(tileWidth: width, stripWidth: 1500).isFinite)
        }
    }

    @Test func theHelpersNeverReturnNullOrTrap() {
        // The AppKit behaviour the helpers guard against: an inset wider than the rect gives `null`, origin at infinity.
        #expect(CGRect(x: 0, y: 0, width: 1, height: 1).insetBy(dx: 8, dy: 0).isNull)
        #expect(CGRect(x: 10, y: 20, width: 1, height: 30).finiteInset(dx: 8, dy: 0) == CGRect(x: 10.5, y: 20, width: 0, height: 30))
        #expect(CGRect(x: 0, y: 0, width: 100, height: 50).finiteInset(dx: 8, dy: 4) == CGRect(x: 8, y: 4, width: 84, height: 42))
        #expect(CGRect.null.finiteInset(dx: 4, dy: 4) == .zero && CGRect.infinite.finiteOrZero == .zero)
        #expect(LayoutCount.floor(.nan) == 0 && LayoutCount.ceil(.infinity) == 0 && LayoutCount.nearest(-.infinity) == 0)
        #expect(LayoutCount.floor(2.9) == 2 && LayoutCount.ceil(2.1) == 3 && LayoutCount.nearest(2.5) == 3)
        #expect(LayoutCount.floor(1e12) == 10_000 && LayoutCount.floor(-1e12) == -10_000)
    }

    /// The crash path itself: a populated block view resized to odd sizes (bucket layout, folder view, monitor views).
    @Test func theTileSurvivesOddFrameSizes() {
        for count in [1, 3, 7] {
            let harness = TileHarness()
            harness.set((1...count).map { busySession("local_d\($0)", index: $0) })
            let (view, window) = makeTileView(harness)
            for size in Self.oddSizes + [CGSize(width: 992, height: 474)] {
                view.setFrameSize(size)
                view.layoutSubtreeIfNeeded()
                view.refresh()
            }
            window.close()
        }
    }
}
