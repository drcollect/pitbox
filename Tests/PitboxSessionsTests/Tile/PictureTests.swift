import AppKit
import Foundation
import PitboxKit
import Testing
@testable import PitboxSessions

/// Renders the block as PNGs over a stand-in for the block's glass (the block draws no card), when `PITBOX_TEST_OUT` is
/// set: `PITBOX_TEST_OUT=<dir> scripts/test.sh --filter renderPictures`.
@MainActor
@Suite("Block pictures")
struct PictureTests {
    init() { CodeTileLog.enabled = false }

    struct Case {
        var name: String
        var size = CGSize(width: 992, height: 474)
        var dark = true
        var redacted = false
        var prepare: (TileHarness) -> Void
        var after: (TileHarness, CodeMonitorsTileView) -> Void = { _, _ in }
    }

    // MARK: Scenes

    static let todos = CodeSessionTodos(items: [.init(text: "K1 Swift engine", status: .completed), .init(text: "K2 models", status: .completed),
                                                .init(text: "K3 app wiring", status: .inProgress), .init(text: "K4 menu", status: .pending),
                                                .init(text: "Code review", status: .pending), .init(text: "Full test run", status: .pending)])

    static func fetch() -> CodeOfferEntry {
        tileOffer("scp 'alex@buildbox:/home/alex/drafts/recipe-import-notes.md' ~/Downloads/", session: 3,
                  commandClass: .fetchFile,
                  fetch: FetchFileRequest(alias: "buildbox", replyUser: "alex", remotePath: "/home/alex/drafts/recipe-import-notes.md",
                                          destinationName: nil))
    }

    /// Four large monitors: working with "Now", needs you (glow), done with a Fetch offer, review ready with a risky one.
    static func four(_ h: TileHarness) {
        h.set([
            tileSession("local_s1", "Weather app · forecast refactor", index: 1, state: .working, nickname: "quiet fern",
                        tldr: "Forecast workflow: K1 engine and K3 wiring done.", now: "subagent: K3 app wiring", todos: todos,
                        minutesAgo: 0.5),
            tileSession("local_s2", "Docs site · link checker", index: 2, state: .needsYou, nickname: "silver moss",
                        tldr: "Broken links listed for 3 sections; tests green.",
                        ask: "Fix the broken links now, or list them in an issue first?", model: "claude-sonnet-5-5", minutesAgo: 12),
            tileSession("local_s3", "Recipe box · import", index: 3, state: .done, nickname: "happy stream",
                        tldr: "Import notes written; checked against the sample file.", offers: [fetch()], place: .ssh,
                        sshHost: "buildbox", cwd: "/home/buildbox/projects/recipe-box"),
            tileSession("local_s4", "Toy Cube · print settings", index: 4, state: .reviewReady, nickname: "tc print",
                        tldr: "Slicer profile cleaned up; a cache clear is suggested.",
                        offers: [tileOffer("rm -rf ~/Library/Caches/com.toycube.slicer", session: 4, commandClass: .risky)],
                        model: "claude-sonnet-5-5", minutesAgo: 9),
        ])
        h.parker.statuses["local_s2"] = CodeWindowStatus(place: .parked(since: tileNow.addingTimeInterval(-12 * 60)))
        h.parker.statuses["local_s3"] = CodeWindowStatus(place: .parked(since: tileNow.addingTimeInterval(-3 * 60)))
    }

    static let headlines = ["Photo sorter · dedupe", "Chess clock · timer bug", "Garden planner · sync", "Trail map · offline cache",
                            "Toy Cube · checkout tests", "Habit tracker · streaks", "Plant log · token setup", "Music tagger · cleanup",
                            "Note app · quick add", "Bike log · weekly charts", "Reading list · focus modes", "Snippet box · history", "Travel planner · layout"]
    static let tldrs = ["Duplicates merged on a copy; originals kept.", "Matched 214 of 220 photos; 6 left for you.",
                        "Turn stopped: the SSH connection dropped.", "Cache built and verified.", "Test plan written for the checkout.",
                        "Streak counter built; 120 tests green.", "Token stored in the Keychain.", "Tags cleaned for 3 albums.",
                        "Parser handles relative dates.", "Charts read from rides.json.", "Two focus modes placed.",
                        "Concealed items skipped.", "Two-column layout at 657 pt."]
    static let states: [CodeSessionState] = [.working, .done, .problem, .done, .reviewReady, .working, .needsYou, .done,
                                             .maybeNeedsYou, .quietUnfinished, .doneNoSummary, .unknown, .done]

    static func many(_ h: TileHarness, count: Int, profiles: [CodeProfile] = [.a]) {
        h.set((0..<count).map { index in
            let state = states[index % states.count]
            return tileSession("local_m\(index)", headlines[index % headlines.count], index: index + 1,
                               profile: profiles[index % profiles.count], state: state,
                               nickname: ["quiet fjord", "copper dune", "north gale", "amber reef"][index % 4],
                               tldr: tldrs[index % tldrs.count], ask: state == .needsYou ? "Which key name should it use?" : nil,
                               now: state == .working ? "running: npm test" : nil,
                               offers: index == 4 ? [tileOffer("open ~/Documents/Photos/duplicates.csv", session: index + 1)] : [],
                               minutesAgo: Double(3 + index * 7), quiet: index == 7)
        })
        for index in stride(from: 1, to: count, by: 3) {
            h.parker.statuses["local_m\(index)"] = CodeWindowStatus(place: .parked(since: tileNow.addingTimeInterval(-Double(index) * 240)))
        }
        if count > 6 { h.parker.statuses["local_m6"] = CodeWindowStatus(place: .otherSpace) }
        if count > 2 { h.parker.statuses["local_m2"] = CodeWindowStatus(place: .onDesk, busy: .restoring) }
    }

    /// Offer lines: a run in progress, finished ok and failed, a blocked block, several commands.
    static func offers(_ h: TileHarness) {
        let running = tileOffer("swift test --parallel", session: 1)
        let ok = tileOffer("security add-generic-password -U -a \"$USER\" -s TOYCUBE_SHOP_KEY -w", session: 2)
        let failed = tileOffer("npm run build", session: 3, commandClass: .risky)
        h.set([
            tileSession("local_o1", "Weather app · tests", index: 1, state: .done, tldr: "Running the suite as you asked.", offers: [running]),
            tileSession("local_o2", "Plant log · token setup", index: 2, state: .done, tldr: "Store the shop key in your Keychain.", offers: [ok]),
            tileSession("local_o3", "Docs site · build", index: 3, state: .reviewReady, tldr: "Build script updated.", offers: [failed]),
            tileSession("local_o4", "reply with odd text", index: 4, state: .done, tldr: "Here is the command.",
                        offers: [tileOffer("echo ok\u{202E} ; ls", session: 4, commandClass: .blocked, block: .b1)]),
        ])
        for (entry, id) in [(running, "local_o1"), (ok, "local_o2"), (failed, "local_o3")] {
            h.model.openSheet(entry.id, sessionID: id, anchor: .zero)
        }
        let events = h.presenter.presented.map(\.events)
        events[0](.started(runID: UUID()))
        let okRun = UUID()
        events[1](.started(runID: okRun))
        events[1](.finished(runID: okRun, exitStatus: 0, seconds: 3))
        let failRun = UUID()
        events[2](.started(runID: failRun))
        events[2](.finished(runID: failRun, exitStatus: 1, seconds: 12))
    }

    static var cases: [Case] {
        [
            Case(name: "code-monitors-4-large-dark", prepare: four),
            Case(name: "code-monitors-4-large-light", dark: false, prepare: four),
            Case(name: "code-monitors-6-medium-dark", prepare: { many($0, count: 6) }),
            Case(name: "code-monitors-9-medium-light", dark: false, prepare: { many($0, count: 9) }),
            Case(name: "code-monitors-9-medium-scrolled-dark", prepare: { many($0, count: 9) },
                 after: { _, view in view.scroll(to: view.maxScrollOffset) }),
            Case(name: "code-monitors-9-medium-3x10-dark", size: CGSize(width: 992, height: 798), prepare: { many($0, count: 9) }),
            Case(name: "code-monitors-13-small-page1-dark", prepare: { many($0, count: 13) }),
            Case(name: "code-monitors-13-small-page2-dark", prepare: { many($0, count: 13) },
                 after: { _, view in view.folder.show(page: 1) }),
            Case(name: "code-monitors-offer-lines-dark", prepare: offers),
            Case(name: "code-monitors-peek-dark", prepare: four, after: { _, view in view.openPeek("local_s2") }),
            Case(name: "code-monitors-peek-commands-light", dark: false, prepare: four, after: { _, view in view.openPeek("local_s4") }),
            Case(name: "code-monitors-hide-text-dark", prepare: { h in four(h); h.model.toggleHideText() }),
            Case(name: "code-monitors-profiles-dark", prepare: { h in h.source.runningProfiles = [.a, .b, .c]; many(h, count: 4, profiles: [.a, .b, .c]) }),
            Case(name: "code-monitors-profiles-medium-light", dark: false,
                 prepare: { h in h.source.runningProfiles = [.a, .b]; many(h, count: 7, profiles: [.a, .b]) }),
            Case(name: "code-monitors-wide-1248-dark", size: CGSize(width: 1248, height: 474), prepare: { many($0, count: 8) }),
            Case(name: "code-monitors-banner-dark", prepare: { h in
                h.source.banner = "Claude's session files changed (Claude 2.43). Showing titles only."
                many(h, count: 3)
            }),
            Case(name: "code-monitors-empty-dark", prepare: { $0.set([]) }),
            Case(name: "code-monitors-empty-light", dark: false, prepare: { h in h.source.runningProfiles = []; h.set([]) }),
            Case(name: "code-monitors-snapshot-redacted-dark", redacted: true, prepare: four),
        ]
    }

    @Test func renderPictures() throws {
        let out = ProcessInfo.processInfo.environment["PITBOX_TEST_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        for item in Self.cases {
            let h = TileHarness()
            item.prepare(h)
            let (view, window) = makeTileView(h, size: item.size)
            view.testsRenderUnredacted = !item.redacted
            view.folder.reduceMotion = { false }
            item.after(h, view)
            let png = try #require(Self.picture(of: view, size: item.size, dark: item.dark), "\(item.name)")
            #expect(png.count > 2000)
            if let out {
                try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                try png.write(to: out.appendingPathComponent("\(item.name).png"))
            }
            window.close()
        }
    }

    /// 2x PNG: a backdrop, a soft gradient and the block's glass tint, then the block through `cacheDisplay`. No card:
    /// the block draws no background of its own.
    static func picture(of view: NSView, size: CGSize, dark: Bool) -> Data? {
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let margin: CGFloat = 16
        let total = CGSize(width: size.width + 2 * margin, height: size.height + 2 * margin)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(total.width * 2), pixelsHigh: Int(total.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let viewRep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = total
        viewRep.size = size
        view.cacheDisplay(in: view.bounds, to: viewRep)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let backdrop = dark ? NSColor(srgbRed: 0.11, green: 0.11, blue: 0.118, alpha: 1) : NSColor(srgbRed: 0.949, green: 0.949, blue: 0.969, alpha: 1)
        backdrop.setFill()
        CGRect(origin: .zero, size: total).fill()
        let tint = dark ? NSColor(srgbRed: 0.16, green: 0.2, blue: 0.3, alpha: 1) : NSColor(srgbRed: 0.86, green: 0.9, blue: 0.97, alpha: 1)
        NSGradient(starting: tint, ending: backdrop)?.draw(in: CGRect(origin: .zero, size: total), angle: -35)
        PitboxTheme.glassTint.color(dark: dark).setFill()
        CGRect(origin: .zero, size: total).fill(using: .sourceOver)
        viewRep.draw(in: CGRect(x: margin, y: margin, width: size.width, height: size.height), from: .zero, operation: .sourceOver,
                     fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
