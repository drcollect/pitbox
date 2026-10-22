import AppKit
import Foundation
import PitboxKit
import Testing
@testable import PitboxSessions

/// Renders the block with buckets as PNGs over a stand-in for the block's glass (`PictureTests.picture`), when
/// `PITBOX_TEST_OUT` is set: `PITBOX_TEST_OUT=<dir> scripts/test.sh --filter renderBucketPictures`.
/// Scenes: three buckets of 2, 7 and 13 monitors (large, medium, small with pages) and a folded one, the 3 × 10 block,
/// light, rename in progress, a drag in progress, slim rows, Delete's question, the marks slot, a narrow block, and the
/// plain look with Unsorted alone.
@MainActor
@Suite("Bucket pictures")
struct BucketPictureTests {
    init() { CodeTileLog.enabled = false }

    struct Case {
        var name: String
        var size = CGSize(width: 992, height: 1180)
        var dark = true
        var settings = CodeSettings()
        var prepare: @MainActor (BucketHarness) -> Void = { BucketPictureTests.scene($0) }
        var after: @MainActor (BucketHarness, CodeMonitorsTileView) -> Void = { _, _ in }
    }

    static let todos = CodeSessionTodos(items: [.init(text: "K1 Swift engine", status: .completed), .init(text: "K2 models", status: .completed),
                                                .init(text: "K3 app wiring", status: .inProgress), .init(text: "Code review", status: .pending)])

    static let toyThings = ["product page", "checkout tests", "print settings", "shop sandbox", "cart badge", "copy for the box",
                            "photo shoot list", "shipping rates", "FAQ draft", "returns policy", "gift cards", "newsletter", "price list"]

    /// Unsorted (2), Side projects (7), Toy Cube (13, page 1 of 2; Needs you on page 2) and Other projects (3, folded).
    @discardableResult
    static func scene(_ h: BucketHarness, fold: Bool = true) -> [String] {
        let ids = h.makeBuckets(["Side projects", "Toy Cube", "Other projects"])
        var sessions: [CodeSessionSnapshot] = [
            tileSession("local_u1", "Weather app · forecast refactor", index: 1, state: .working, nickname: "quiet fern",
                        tldr: "Forecast workflow: K1 engine and K3 wiring done.", now: "subagent: K3 app wiring", todos: todos,
                        minutesAgo: 0.5),
            tileSession("local_u2", "Docs site · link checker", index: 2, state: .needsYou, nickname: "silver moss",
                        tldr: "Broken links listed for 3 sections; tests green.",
                        ask: "Fix the broken links now, or list them in an issue first?", model: "claude-sonnet-5-5", minutesAgo: 12),
        ]
        let headlines = PictureTests.headlines, tldrs = PictureTests.tldrs
        let sideStates: [CodeSessionState] = [.done, .working, .reviewReady, .done, .problem, .working, .done]
        for n in 0..<7 {
            sessions.append(tileSession("local_c\(n + 1)", headlines[n], index: 10 + n, state: sideStates[n],
                                        nickname: ["quiet fjord", "copper dune", "north gale"][n % 3], tldr: tldrs[n],
                                        now: sideStates[n] == .working ? "running: npm test" : nil,
                                        offers: n == 2 ? [tileOffer("open ~/Documents/Photos/duplicates.csv", session: 10 + n)] : [],
                                        minutesAgo: Double(4 + n * 6)))
        }
        for n in 0..<13 {
            let state: CodeSessionState = n == 12 ? .needsYou : (n % 4 == 1 ? .working : (n % 5 == 3 ? .reviewReady : .done))
            sessions.append(tileSession("local_t\(n + 1)", "Toy Cube · " + toyThings[n], index: 30 + n, state: state,
                                        tldr: "Draft ready for a look.", now: state == .working ? "Edit copy.md" : nil,
                                        offers: n == 4 ? [tileOffer("npm run build", session: 30 + n)] : [], minutesAgo: Double(2 + n * 3)))
        }
        for n in 0..<3 {
            var session = tileSession("local_o\(n + 1)", ["Photo sorter · dedupe", "Chess clock · timer bug", "Garden planner · sync"][n],
                                      index: 50 + n, state: [.working, .done, .problem][n])
            if n == 0 { session.warnings = [CodeWarning(kind: .silence, since: tileNow)] }
            if n == 1 {
                session.unread = true
                session.finished = CodeFinishedMark(replyUUID: "r-o2", at: tileNow, ranSeconds: 1260)
            }
            sessions.append(session)
        }
        h.set(sessions)
        for n in 1...7 { h.model.moveSession("local_c\(n)", toBucket: ids[0]) }
        for n in 1...13 { h.model.moveSession("local_t\(n)", toBucket: ids[1]) }
        for n in 1...3 { h.model.moveSession("local_o\(n)", toBucket: ids[2]) }
        for id in ["local_u2", "local_c1", "local_c3", "local_c4", "local_t1", "local_t3", "local_t6", "local_o2"] {
            h.parker.statuses[id] = CodeWindowStatus(place: .parked(since: tileNow.addingTimeInterval(-9 * 60)))
        }
        if fold { h.model.toggleFolded(ids[2]) }
        return ids
    }

    /// The marks slot in use: the unread dot and the ▦ pill on a few monitors.
    static func marks(_ h: BucketHarness) {
        h.model.itemDecorators = [{ session, item in
            if ["local_u1", "local_c2", "local_t2"].contains(session.id) {
                item.marks.append(CodeMonitorMark(id: "dashboard", place: .footPill, text: "▦ Dashboard", short: "▦", fill: 0xF58AC4,
                                                  ink: 0x2A0B1C, label: "Open the dashboard", opens: true))
            }
            if ["local_u2", "local_c3", "local_t5"].contains(session.id) {
                item.marks.append(CodeMonitorMark(id: nil, place: .cornerDot, text: "", short: "", fill: 0xFFFFFF, ink: 0,
                                                  label: "New since you looked", opens: false))
            }
        }]
        scene(h)
    }

    static var rows: CodeSettings {
        var settings = CodeSettings()
        settings.look = .rows
        return settings
    }

    static var cases: [Case] {
        [
            Case(name: "buckets-dark"),
            Case(name: "buckets-3x10-dark", size: CGSize(width: 992, height: 798)),
            Case(name: "buckets-light", dark: false),
            Case(name: "buckets-page2-dark", size: CGSize(width: 992, height: 798), after: { _, view in
                let toy = view.snapshot.sections[2].id
                view.otherFolders[toy]?.show(page: 1)
                view.scroll(to: view.maxScrollOffset)
            }),
            Case(name: "buckets-rename-dark", size: CGSize(width: 992, height: 798), after: { _, view in
                view.startNewBucket()
                view.renaming?.field.stringValue = "Toy Cu"
            }),
            Case(name: "buckets-drag-dark", size: CGSize(width: 992, height: 798), after: { _, view in
                guard let monitor = view.monitorView("local_u1"), let sideBucket = view.snapshot.sections.dropFirst().first?.id,
                      let body = view.otherFolders[sideBucket] else { return }
                let start = CGPoint(x: monitor.bounds.midX, y: monitor.bounds.midY)
                let target = view.convert(CGPoint(x: body.bounds.maxX - 290, y: 120), from: body)
                if let down = bucketMouse(.leftMouseDown, at: start, in: monitor),
                   let move = bucketMouse(.leftMouseDragged, in: monitor, windowPoint: view.convert(target, to: nil)) {
                    monitor.mouseDown(with: down)
                    monitor.mouseDragged(with: move)
                }
            }),
            Case(name: "buckets-rows-dark", settings: rows),
            Case(name: "buckets-rows-light", dark: false, settings: rows),
            Case(name: "buckets-delete-dark", size: CGSize(width: 992, height: 798), after: { _, view in
                let sideBucket = view.snapshot.sections[1].id
                if let header = view.bucketHeaders[sideBucket] { view.headerPart(sideBucket, .delete, header: header) }
            }),
            Case(name: "buckets-marks-dark", prepare: { BucketPictureTests.marks($0) }),
            Case(name: "buckets-narrow-dark", size: CGSize(width: 322, height: 1300)),
            Case(name: "buckets-two-columns-dark", size: CGSize(width: 657, height: 1300)),
            Case(name: "buckets-flat-dark", size: CGSize(width: 992, height: 474), prepare: { h in
                h.set(bucketSessions("s", 3, states: [2: .needsYou]))
                h.parker.statuses["local_s1"] = CodeWindowStatus(place: .parked(since: tileNow.addingTimeInterval(-600)))
            }),
            Case(name: "buckets-empty-buckets-dark", size: CGSize(width: 992, height: 474), prepare: { h in
                h.makeBuckets(["Side projects", "Toy Cube"])
                h.set([])
            }),
        ]
    }

    @Test func renderBucketPictures() throws {
        let out = ProcessInfo.processInfo.environment["PITBOX_TEST_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        for item in Self.cases {
            let h = BucketHarness(settings: item.settings)
            item.prepare(h)
            let (view, window) = makeBucketTileView(h, size: item.size)
            view.testsRenderUnredacted = true
            item.after(h, view)
            let png = try #require(PictureTests.picture(of: view, size: item.size, dark: item.dark), "\(item.name)")
            #expect(png.count > 2000)
            if let out {
                try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                try png.write(to: out.appendingPathComponent("\(item.name).png"))
            }
            view.endTransientBucketUI()
            window.close()
        }
    }
}
