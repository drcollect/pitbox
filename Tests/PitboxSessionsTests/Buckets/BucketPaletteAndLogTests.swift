import AppKit
import Foundation
import PitboxKit
import Testing
@testable import PitboxSessions

/// The palette passes 3:1 against the block's glass, badge words are readable on their pills, no bucket name or session
/// text reaches a log line, and a mark in the marks slot that opens something arms first.
@MainActor
@Suite("Buckets: colours, logs and marks")
struct BucketPaletteAndLogTests {
    init() { CodeTileLog.enabled = false }

    typealias Contrast = PaletteTests

    @Test func everyBucketColourStandsOutOnTheGlassInBothAppearances() {
        for color in CodeBucketColor.allCases {
            #expect(Contrast.contrast(color.dark, Contrast.darkGlass) >= 3, "\(color) dark")
            #expect(Contrast.contrast(color.light, Contrast.lightGlass) >= 3, "\(color) light")
        }
        #expect(CodeBucketColor.allCases.map(\.title) == ["Violet", "Amber", "Teal", "Red", "Green", "Blue", "Pink", "Grey"])
    }

    @Test func badgeWordsReadOnTheirPills() {
        let pills = [CodeBucketBadgeColors.needYou, CodeBucketBadgeColors.commands, CodeBucketBadgeColors.files,
                     CodeBucketBadgeColors.finished, CodeBucketBadgeColors.warnings]
        for pill in pills { #expect(Contrast.contrast(pill.ink, pill.fill) >= 4.5, "#\(String(pill.fill, radix: 16))") }
        #expect(Contrast.contrast(CodeBucketHeaderView.dangerInk, CodeBucketHeaderView.dangerFill) >= 4.5)
        // A slim row's words on its fill.
        for text in [CodeMonitorPalette.headline, CodeMonitorPalette.dim, CodeMonitorPalette.cyan] {
            #expect(Contrast.contrast(text, CodeMonitorView.rowFill) >= 4.5, "#\(String(text, radix: 16))")
        }
    }

    @Test func noBucketNameOrSessionTextReachesALogLine() throws {
        CodeTileLog.startRecording()
        let folder = BucketTestFolder()
        defer { folder.cleanUp() }
        try folder.write("{ broken QQBROKEN")
        let h = BucketHarness(store: bucketStore(folder))
        let ids = h.makeBuckets(["QQBUCKET one", "QQBUCKET two"])
        h.set([tileSession("local_qq1", "QQTITLE one", index: 1), tileSession("local_qq2", "QQTITLE two", index: 2)])
        h.model.moveSession("local_qq2", toBucket: ids[0])
        h.model.renameBucket(ids[1], to: "QQBUCKET renamed")
        h.model.setBucketColor(ids[1], .pink)
        h.model.toggleFolded(ids[1])
        h.model.deleteBucket(ids[1])
        let (view, window) = makeBucketTileView(h)
        defer { window.close() }
        view.startNewBucket()
        view.renaming?.field.stringValue = "QQBUCKET typed"
        view.finishRename(commit: true)
        let monitor = try #require(view.monitorView("local_qq1"))
        let header = try #require(view.bucketHeaders[ids[0]])
        let start = bucketCentre(monitor.layoutInfo.screen)
        monitor.mouseDown(with: try #require(bucketMouse(.leftMouseDown, at: start, in: monitor)))
        monitor.mouseDragged(with: try #require(bucketMouse(.leftMouseDragged, in: monitor,
                                                            windowPoint: header.convert(bucketCentre(header.bounds), to: nil))))
        monitor.mouseUp(with: try #require(bucketMouse(.leftMouseUp, in: monitor,
                                                       windowPoint: header.convert(bucketCentre(header.bounds), to: nil))))
        h.model.buckets.flush()
        let lines = CodeTileLog.recorded
        #expect(lines.contains { $0.hasPrefix("bucket created buckets=") })
        #expect(lines.contains { $0.hasPrefix("buckets file unreadable size=") && $0.contains("reason=") })
        #expect(lines.contains { $0.hasPrefix("monitor drag dropped session=#1 on=bucket") })
        for line in lines { #expect(!line.contains("QQ"), "\(line)") }
        // The broken file's copy keeps its name: no session text or bucket name in it.
        #expect(FileManager.default.fileExists(atPath: folder.corrupt.path))
    }

    // MARK: The marks slot (the unread dot, the ▦ pill)

    private static let pill = CodeMonitorMark(id: "dashboard", place: .footPill, text: "▦ Dashboard", short: "▦", fill: 0xF58AC4,
                                              ink: 0x2A0B1C, label: "Open the dashboard", opens: true)

    /// A large monitor of one session, outside the block, with its clock and pointer under the test's control.
    private func monitor(marks: [CodeMonitorMark] = [], clock: @escaping () -> TimeInterval,
                         pointer: @escaping () -> CGPoint?) -> (CodeMonitorView, BucketCalls<CodeMonitorView.Target>) {
        let session = tileSession("local_m1", "Marked", index: 1)
        let inputs = CodeMonitorBuilder.Inputs(sessions: [session], statuses: ["local_m1": CodeWindowStatus(place: .onDesk)],
                                               runs: CodeOfferRunBook(), hideText: false, showText: ["A": true], showsProfiles: false,
                                               homeDirectory: "/Users/alex", now: tileNow)
        var item = CodeMonitorBuilder.item(session, position: 1, total: 1, inputs: inputs)
        item.marks = marks
        let view = CodeMonitorView(item: item, size: .large, showsProfile: false, frame: CGRect(x: 0, y: 0, width: 323, height: 219))
        view.clock = clock
        view.pointerProbe = pointer
        let clicks = BucketCalls<CodeMonitorView.Target>()
        view.onClick = { _, target in clicks.calls.append(target) }
        return (view, clicks)
    }

    private func withPill(_ view: CodeMonitorView) {
        var item = view.item
        item.marks = [Self.pill]
        view.configure(item: item, size: view.size, showsProfile: view.showsProfile)
    }

    @Test func aMarkThatOpensSomethingCountsOnly08SecondsAfterItAppeared() throws {
        var now: TimeInterval = 100
        let (view, clicks) = monitor(clock: { now }, pointer: { nil })
        withPill(view)
        let rect = try #require(view.layoutInfo.marks.first)
        #expect(rect != .zero && rect.minX < view.layoutInfo.led.minX)
        now = 100.5
        bucketClick(view, at: bucketCentre(rect))
        #expect(clicks.calls.isEmpty)
        now = 100.9
        bucketClick(view, at: bucketCentre(rect))
        #expect(clicks.calls == [.mark(0)])
    }

    @Test func aMarkThatAppearedUnderThePointerSwallowsTheFirstPress() throws {
        var now: TimeInterval = 100
        var pointer: CGPoint?
        let (view, clicks) = monitor(clock: { now }, pointer: { pointer })
        let probe = CodeMonitorLayout.compute({ var item = view.item; item.marks = [Self.pill]; return item }(), size: .large,
                                              bounds: view.bounds, showsProfile: false)
        let rect = try #require(probe.marks.first)
        pointer = bucketCentre(rect)
        withPill(view)
        now = 103
        bucketClick(view, at: bucketCentre(rect))
        #expect(clicks.calls.isEmpty)
        bucketClick(view, at: bucketCentre(rect))
        #expect(clicks.calls == [.mark(0)])
    }

    @Test func aDotThatOpensNothingIsNoTargetAndItsMonitorStillClicks() throws {
        let dot = CodeMonitorMark(id: nil, place: .cornerDot, text: "", short: "", fill: 0xFFFFFF, ink: 0, label: "New", opens: false)
        let (view, clicks) = monitor(marks: [dot], clock: { 0 }, pointer: { nil })
        let rect = try #require(view.layoutInfo.marks.first)
        #expect(rect.size == CGSize(width: 11, height: 11) && rect.origin == view.layoutInfo.bezel.origin)
        bucketClick(view, at: CGPoint(x: rect.maxX - 2, y: rect.maxY - 2))
        #expect(clicks.calls == [.screen])
        #expect(view.accessibilityLabel()?.contains("New") == true)
    }
}
