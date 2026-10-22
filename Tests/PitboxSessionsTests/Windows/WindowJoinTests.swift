import CoreGraphics
import Foundation
import Testing
@testable import PitboxSessions

@Suite("Window join (pure)")
struct WindowJoinTests {
    private func session(_ id: String, _ title: String, previous: [String] = [], hint: CGRect? = nil) -> CodeWindowSessionInput {
        CodeWindowSessionInput(id: id, index: 1, profile: .a, title: title, previousTitles: previous, hint: hint)
    }

    private func window(_ number: CGWindowID, _ title: String?, frame: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600))
        -> CodeJoinWindow {
        CodeJoinWindow(element: WindowsTestAX.element(number), title: title, frame: frame, minimized: false, number: number)
    }

    @Test func titlesMatchExactly() {
        let result = CodeWindowJoin.matchTitles(sessions: [session("local_a", "Alpha"), session("local_b", "Beta")],
                                                windows: [window(1, "Beta"), window(2, "Alpha")])
        #expect(result == ["local_a": 1, "local_b": 0])
    }

    @Test func aTitleThatIsTheStartOfAnotherNeverMatches() {
        // One title was the start of another ("(fork)"): only exact equality is safe.
        let fork = CodeWindowJoin.matchTitles(sessions: [session("local_a", "wake phrase build (fork)")],
                                              windows: [window(1, "wake phrase build")])
        #expect(fork.isEmpty)
        let plain = CodeWindowJoin.matchTitles(sessions: [session("local_a", "wake phrase build")],
                                               windows: [window(1, "wake phrase build (fork)")])
        #expect(plain.isEmpty)
    }

    @Test func previousTitlesMatchAfterTheCurrentOne() {
        let result = CodeWindowJoin.matchTitles(sessions: [session("local_a", "New name", previous: ["Old name", "Older"])],
                                                windows: [window(7, "Old name")])
        #expect(result == ["local_a": 0])
        // The current title wins over a previous one.
        let both = CodeWindowJoin.matchTitles(sessions: [session("local_a", "New name", previous: ["Old name"]),
                                                         session("local_b", "Old name")],
                                              windows: [window(7, "Old name"), window(8, "New name")])
        #expect(both == ["local_a": 1, "local_b": 0])
    }

    @Test func theMainWindowAndUntitledWindowsNeverMatch() {
        let result = CodeWindowJoin.matchTitles(sessions: [session("local_a", "Claude"), session("local_b", "")],
                                                windows: [window(1, "Claude"), window(2, ""), window(3, nil)])
        #expect(result.isEmpty)
    }

    @Test func twoWindowsWithOneTitleAreToldApartByTheHint() {
        let a = CGRect(x: 100, y: 100, width: 900, height: 700), b = CGRect(x: 1100, y: 100, width: 900, height: 700)
        let windows = [window(1, "Same", frame: a), window(2, "Same", frame: b)]
        #expect(CodeWindowJoin.matchTitles(sessions: [session("local_a", "Same", hint: b)], windows: windows) == ["local_a": 1])
        // Within a point counts as equal (Electron rounds).
        let nudged = CGRect(x: 1100.6, y: 99.5, width: 900, height: 700.4)
        #expect(CodeWindowJoin.matchTitles(sessions: [session("local_a", "Same", hint: nudged)], windows: windows) == ["local_a": 1])
        // No hint, or a hint matching neither: not matched (for both).
        #expect(CodeWindowJoin.matchTitles(sessions: [session("local_a", "Same")], windows: windows).isEmpty)
        let elsewhere = CGRect(x: 3000, y: 100, width: 900, height: 700)
        #expect(CodeWindowJoin.matchTitles(sessions: [session("local_a", "Same", hint: elsewhere)], windows: windows).isEmpty)
    }

    @Test func twoSessionsWithOneTitleAreToldApartByTheirHints() {
        let a = CGRect(x: 100, y: 100, width: 900, height: 700), b = CGRect(x: 1100, y: 100, width: 900, height: 700)
        let windows = [window(1, "Same", frame: a), window(2, "Same", frame: b)]
        let result = CodeWindowJoin.matchTitles(sessions: [session("local_a", "Same", hint: b), session("local_b", "Same", hint: a)],
                                                windows: windows)
        #expect(result == ["local_a": 1, "local_b": 0])
        // Both hints at one window (Zones placed them at identical rects): neither.
        let tied = CodeWindowJoin.matchTitles(sessions: [session("local_a", "Same", hint: a), session("local_b", "Same", hint: a)],
                                              windows: windows)
        #expect(tied.isEmpty)
    }

    @Test func windowsThatCouldNotBeToldApartAreNotHandedToAnOlderTitle() {
        let result = CodeWindowJoin.matchTitles(sessions: [session("local_a", "Same"), session("local_b", "Other", previous: ["Same"])],
                                                windows: [window(1, "Same"), window(2, "Same")])
        #expect(result.isEmpty)
    }

    @Test func aStaleHintDoesNotMatterWhenTheTitleIsUnique() {
        // session-popouts.json may not be rewritten when a window moves (unverified): the title decides.
        let stale = CGRect(x: 0, y: 0, width: 400, height: 300)
        let result = CodeWindowJoin.matchTitles(sessions: [session("local_a", "Alpha", hint: stale)],
                                                windows: [window(1, "Alpha", frame: CGRect(x: 900, y: 80, width: 1000, height: 800))])
        #expect(result == ["local_a": 0])
    }

    @Test func numbersComeFromAXElseFromUniqueEqualBounds() {
        let frame = CGRect(x: 100, y: 100, width: 900, height: 700)
        let server = [CodeServerWindow(number: 11, pid: 1, bounds: frame, layer: 0, isOnScreen: true),
                      CodeServerWindow(number: 12, pid: 1, bounds: CGRect(x: 1200, y: 100, width: 900, height: 700), layer: 0, isOnScreen: true)]
        #expect(CodeWindowJoin.resolveNumber(reported: 12, frame: frame, serverWindows: server) == 12)
        // `_AXUIElementGetWindow` missing: the bounds decide.
        #expect(CodeWindowJoin.resolveNumber(reported: nil, frame: frame, serverWindows: server) == 11)
        // A reported number of another process is not trusted.
        #expect(CodeWindowJoin.resolveNumber(reported: 99, frame: frame, serverWindows: server) == 11)
        // Two windows at identical rects: not matched.
        let twins = server + [CodeServerWindow(number: 13, pid: 1, bounds: frame, layer: 0, isOnScreen: true)]
        #expect(CodeWindowJoin.resolveNumber(reported: nil, frame: frame, serverWindows: twins) == nil)
    }

    @Test func eligibleWindowsAreNormalOrFloatingAndLargeEnough() {
        func w(layer: Int, _ width: CGFloat, _ height: CGFloat) -> CodeServerWindow {
            CodeServerWindow(number: 1, pid: 1, bounds: CGRect(x: 0, y: 0, width: width, height: height), layer: layer, isOnScreen: true)
        }
        #expect(CodeWindowJoin.isEligible(w(layer: 0, 160, 100)))
        #expect(CodeWindowJoin.isEligible(w(layer: 3, 900, 700)))      // an alwaysOnTop pop-out (floating level)
        #expect(!CodeWindowJoin.isEligible(w(layer: 0, 159, 300)))
        #expect(!CodeWindowJoin.isEligible(w(layer: 0, 300, 99)))
        #expect(!CodeWindowJoin.isEligible(w(layer: 8, 900, 700)))     // a pop-up menu or a panel
        #expect(!CodeWindowJoin.isEligible(w(layer: 25, 900, 700)))
    }
}
