import CoreGraphics
import Foundation
import Testing
@testable import PitboxSessions

/// The window observer on fakes: one observer per Claude copy, reads by window
/// number after notifications, coalescing, follow-up reads, the backstop pass, idle cost, several clients.
@MainActor
@Suite("desk tags: window observer")
struct ObserverTests {
    final class Recorder {
        var events: [CodeWindowObserverEvent] = []
        var windows: [CodeWindowState] {
            events.flatMap { event -> [CodeWindowState] in
                if case .windows(let states) = event { return states }
                return []
            }
        }
    }

    struct Rig {
        let timeline = TagTimeline()
        let ax = FakeTagAX()
        let server = FakeTagServer()
        let button = FakeTagButton()
        let observer: CodeWindowObserver
        let recorder = Recorder()
        let client: Int

        @MainActor
        init() {
            let timeline = self.timeline
            observer = CodeWindowObserver(queue: FakeTagQueue(timeline), ax: ax, server: server, button: button,
                                          uptime: { timeline.now }, deliverToMain: { work in work() })
            let recorder = self.recorder
            client = observer.addClient { recorder.events.append($0) }
            server.windows[tagWindowNumber] = tagWindow()
            server.windows[502] = tagWindow(502, bounds: CGRect(x: 100, y: 100, width: 800, height: 600))
        }

        @MainActor
        func want(_ windows: Set<CodeWindowKey>, backstop: Bool = true, frontToBack: Bool = false, notes: Bool = false) {
            observer.setInterest(CodeWindowInterest(pids: Set(windows.map(\.pid)), windows: windows, backstop: backstop,
                                                    frontToBack: frontToBack, notes: notes), for: client)
            timeline.drain()
        }
    }

    let key = CodeWindowKey(pid: tagPID, number: tagWindowNumber)

    @Test func idleObservesNothingAndRunsNoTimer() {
        let rig = Rig()
        rig.timeline.drain()
        #expect(rig.ax.observeCalls.isEmpty)
        #expect(rig.timeline.pendingTimers == 0)
        #expect(!rig.observer.core.isBackstopArmed)
    }

    @Test func watchingObservesTheCopyAndReadsTheWindowOnce() {
        let rig = Rig()
        rig.want([key])
        #expect(rig.ax.observeCalls == [tagPID])
        #expect(rig.ax.watchCalls == [key], "destroyed is registered on the window itself")
        #expect(rig.recorder.windows.map(\.reason) == [.watched])
        #expect(rig.recorder.windows.first?.window == tagWindow())
        #expect(rig.ax.fullScreenReads == 1)
    }

    @Test func aMoveReadsTheWindowServerByNumberAndDeliversTheChange() {
        let rig = Rig()
        rig.want([key])
        rig.recorder.events = []
        let reads = rig.server.reads
        rig.server.windows[tagWindowNumber]?.bounds.origin.x = 350
        rig.ax.post(.moved, pid: tagPID)
        rig.timeline.drain()
        #expect(rig.server.reads == reads + 1)
        #expect(rig.recorder.windows.count == 1)
        #expect(rig.recorder.windows.first?.window?.bounds.minX == 350)
        #expect(rig.recorder.windows.first?.notifications == [.moved])
        // An unchanged read delivers nothing (Claude's main window moving, say).
        rig.recorder.events = []
        rig.ax.post(.moved, pid: tagPID)
        rig.timeline.advance(by: 0.05)
        #expect(rig.recorder.windows.isEmpty)
    }

    @Test func notificationsCoalesceToOneReadPer16ms() {
        let rig = Rig()
        rig.want([key])
        let reads = rig.server.reads
        for step in 1...10 {
            rig.server.windows[tagWindowNumber]?.bounds.origin.x = 300 + CGFloat(step)
            rig.ax.post(.moved, pid: tagPID)
            rig.timeline.drain()
        }
        // The first at once, the rest wait for the end of the 16 ms.
        #expect(rig.server.reads == reads + 1)
        rig.timeline.advance(by: 0.016)
        #expect(rig.server.reads == reads + 2)
        #expect(rig.recorder.windows.last?.window?.bounds.minX == 310, "the latest bounds win")
        rig.timeline.advance(by: 0.1)
        #expect(rig.server.reads == reads + 2)
    }

    @Test func moveWithTheButtonDownCarriesTheButton() {
        let rig = Rig()
        rig.want([key])
        rig.button.down = true
        rig.server.windows[tagWindowNumber]?.bounds.origin.y = 260
        rig.ax.post(.moved, pid: tagPID)
        rig.timeline.drain()
        #expect(rig.recorder.windows.last?.buttonDown == true)
        #expect(rig.recorder.windows.last?.key == key)
    }

    @Test func miniaturizeIsReadAgainAfterTheDockAnimation() {
        let rig = Rig()
        rig.want([key])
        rig.recorder.events = []
        rig.ax.post(.miniaturized, pid: tagPID)
        rig.timeline.drain()
        #expect(rig.recorder.events.contains(.app(tagPID, .miniaturized)))
        #expect(rig.recorder.windows.isEmpty, "still on screen while the window animates")
        rig.server.windows[tagWindowNumber]?.isOnScreen = false
        rig.timeline.advance(by: 0.3)
        let state = rig.recorder.windows.last
        #expect(state?.window?.isOnScreen == false)
        #expect(state?.notifications == [.miniaturized])
    }

    @Test func destroyedReadsThatWindowAtOnce() {
        let rig = Rig()
        rig.want([key])
        rig.recorder.events = []
        rig.server.windows[tagWindowNumber] = nil
        rig.ax.post(.destroyed, pid: tagPID, number: tagWindowNumber)
        rig.timeline.drain()
        #expect(rig.recorder.windows.count == 1)
        #expect(rig.recorder.windows.first?.window == nil)
    }

    @Test func fullScreenIsReadOnceAResizeSettles() {
        let rig = Rig()
        rig.want([key])
        let before = rig.ax.fullScreenReads
        rig.ax.fullScreen[key] = true
        for _ in 0..<5 {
            rig.ax.post(.resized, pid: tagPID)
            rig.timeline.advance(by: 0.1)
        }
        #expect(rig.ax.fullScreenReads == before, "not during the resize")
        rig.timeline.advance(by: 0.3)
        #expect(rig.ax.fullScreenReads == before + 1)
        #expect(rig.recorder.events.contains(.fullScreen(key, true)))
    }

    @Test func appEventsGoToTheClients() {
        let rig = Rig()
        rig.want([key])
        for note in [CodeWindowNotification.appActivated, .appDeactivated, .appHidden, .appShown, .focusedWindowChanged,
                     .mainWindowChanged] {
            rig.ax.post(note, pid: tagPID)
        }
        rig.timeline.drain()
        let apps = rig.recorder.events.compactMap { event -> CodeWindowNotification? in
            if case .app(_, let note) = event { return note }
            return nil
        }
        #expect(apps == [.appActivated, .appDeactivated, .appHidden, .appShown, .focusedWindowChanged, .mainWindowChanged])
    }

    @Test func backstopRunsOnlyWhileWatched() {
        let rig = Rig()
        rig.want([key])
        #expect(rig.observer.core.isBackstopArmed)
        let reads = rig.server.reads
        rig.timeline.advance(by: 3.05)
        #expect(rig.server.reads == reads + 3, "one read per watched window per second")
        rig.server.windows[tagWindowNumber]?.isOnScreen = false   // a missed notification
        rig.timeline.advance(by: 1)
        #expect(rig.recorder.windows.last?.reason == .backstop)
        rig.want([])
        #expect(!rig.observer.core.isBackstopArmed)
        #expect(rig.ax.unobserveCalls == [tagPID])
        #expect(rig.ax.unwatchCalls == [key])
        let after = rig.server.reads
        rig.timeline.advance(by: 5)
        #expect(rig.server.reads == after, "nothing watched: no reads, no timer")
        #expect(rig.timeline.pendingTimers == 0)
    }

    @Test func notReadyCopiesAreRetriedThenGivenUp() {
        let rig = Rig()
        rig.ax.observeAnswers[tagPID] = [.notReady, .notReady, nil]
        rig.want([key], backstop: false)
        #expect(rig.ax.observeCalls.count == 1)
        rig.timeline.advance(by: 0.5)
        #expect(rig.ax.observeCalls.count == 2)
        rig.timeline.advance(by: 1)
        #expect(rig.ax.observeCalls.count == 3)
        #expect(rig.observer.core.observedPIDs == [tagPID])
        #expect(rig.ax.watchCalls.contains(key), "the window is registered once the copy is observed")

        let other = Rig()
        other.ax.observeAnswers[tagPID] = Array(repeating: .notReady, count: 10)
        other.want([key], backstop: false)
        other.timeline.advance(by: 30)
        #expect(other.ax.observeCalls.count == 6, "five retries, then given up")
        #expect(other.timeline.pendingTimers == 0)
        other.observer.refreshAll()
        other.timeline.drain()
        #expect(other.ax.observeCalls.count == 7, "a refresh tries a given-up copy again")
    }

    @Test func withoutAccessibilityNothingIsObserved() {
        let rig = Rig()
        rig.ax.observeAnswers[tagPID] = [.apiDisabled]
        rig.want([key])
        #expect(rig.observer.core.observedPIDs.isEmpty)
        #expect(rig.recorder.events.contains(.trust(false)))
        rig.ax.post(.moved, pid: tagPID)
        rig.timeline.drain()
        #expect(!rig.recorder.events.contains { if case .app = $0 { return true } else { return false } })
    }

    @Test func refreshAllReadsEveryWatchedWindow() {
        let rig = Rig()
        let second = CodeWindowKey(pid: tagPID, number: 502)
        rig.want([key, second])
        rig.recorder.events = []
        rig.server.windows[tagWindowNumber]?.isOnScreen = false
        rig.server.windows[502]?.isOnScreen = false
        rig.observer.refreshAll()
        rig.timeline.drain()
        #expect(Set(rig.recorder.windows.map(\.key)) == [key, second])
        #expect(rig.recorder.windows.allSatisfy { $0.reason == .refresh })
    }

    @Test func frontToBackOnlyWhenAsked() {
        let rig = Rig()
        rig.want([key])
        rig.timeline.advance(by: 2)
        #expect(rig.server.listReads == 0)
        rig.want([key], frontToBack: true)
        #expect(rig.server.listReads == 1)
        rig.timeline.advance(by: 1)
        #expect(rig.server.listReads == 2, "with the backstop pass")
        rig.ax.post(.moved, pid: tagPID)
        rig.timeline.advance(by: 0.02)
        #expect(rig.server.listReads == 3, "after a notification's read")
    }

    @Test func labNotesCarryTheButtonAndTime() {
        let rig = Rig()
        rig.want([key], notes: true)
        rig.button.down = true
        rig.ax.post(.moved, pid: tagPID)
        rig.timeline.drain()
        #expect(rig.recorder.events.contains(.note(tagPID, .moved, buttonDown: true, at: rig.timeline.now)))
    }

    @Test func clientsShareOneObserver() {
        let rig = Rig()
        let second = Recorder()
        let other = rig.observer.addClient { second.events.append($0) }
        let drag = CodeWindowKey(pid: tagPID, number: 502)
        rig.want([key])
        rig.observer.setInterest(CodeWindowInterest(windows: [drag]), for: other)
        rig.timeline.drain()
        #expect(rig.observer.core.watchedKeys == [key, drag])
        #expect(rig.ax.observeCalls == [tagPID], "one observer per copy")
        rig.want([])
        #expect(rig.observer.core.watchedKeys == [drag], "the other client still watches its window")
        #expect(rig.ax.unobserveCalls.isEmpty)
        rig.observer.removeClient(other)
        rig.timeline.drain()
        #expect(rig.ax.unobserveCalls == [tagPID])
        #expect(!second.events.isEmpty, "every client gets the events")
    }
}
