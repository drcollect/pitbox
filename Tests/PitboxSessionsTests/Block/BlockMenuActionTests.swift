import AppKit
import Foundation
import Testing
@testable import PitboxSessions
import PitboxKit

/// The status menu's block actions (`PitboxBlock+Menu.swift`): Hide text, Pit all done and All back on track reach the
/// block's own paths. Fakes only.
@MainActor
@Suite("The block's menu actions", .serialized)
struct BlockMenuActionTests {
    init() {
        CodeTileLog.enabled = false
        CodeLog.enabled = false
    }

    @Test func hideTextFollowsTheHeadersButton() {
        let h = TileHarness()
        let block = PitboxBlock(model: h.model)
        var heard: [Bool] = []
        block.onHideTextChanged = { heard.append($0) }
        #expect(!block.hideText)
        block.setHideText(true)
        block.setHideText(true)
        #expect(block.hideText && h.model.snapshot.header.hideText)
        block.setHideText(false)
        #expect(heard == [true, false], "one flip per change, none for a repeat")
    }

    @Test func pitAllDoneCountsAndActsLikeTheHeader() async {
        let h = TileHarness()
        let block = PitboxBlock(model: h.model)
        h.set([tileSession("local_done", "Done", state: .done), tileSession("local_work", "Work", state: .working)])
        #expect(block.pitAllDoneCount == 1)
        block.pitAllDone()
        for _ in 0..<50 where h.parker.parkAllCalls.isEmpty { await Task.yield() }
        #expect(h.parker.parkAllCalls == [["local_done"]])
    }

    @Test func allBackOnTrackRestoresEveryWindowInThePit() {
        let h = TileHarness()
        let block = PitboxBlock(model: h.model)
        h.set([tileSession("local_a", "A"), tileSession("local_b", "B"), tileSession("local_c", "C"),
               tileSession("local_d", "D")])
        h.parker.statuses["local_a"] = CodeWindowStatus(place: .parked(since: tileNow))
        h.parker.statuses["local_b"] = CodeWindowStatus(place: .parked(since: tileNow), busy: .restoring)
        h.parker.statuses["local_c"] = CodeWindowStatus(place: .parkedNotMatched)
        h.parker.statuses["local_d"] = CodeWindowStatus(place: .minimized)
        h.parker.statuses["local_e"] = CodeWindowStatus(place: .parked(since: tileNow))   // under another focus
        #expect(block.inThePitCount == 2)
        #expect(block.allBackOnTrack() == 2)
        #expect(h.parker.performed.map { $0.0 } == [.restore, .restore])
        #expect(h.parker.performed.map { $0.1 } == ["local_a", "local_e"])
    }
}
