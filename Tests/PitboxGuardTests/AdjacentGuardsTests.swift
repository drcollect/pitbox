import CoreGraphics
import PitboxKit
import Testing
@testable import PitboxGuard

// docs/DOCK_PROTOCOL.md §7: a window over the host's part takes at most two short hops, both toward the window side;
// one over the block's part only takes one; fold and unfold are never fights. Scenario frames are written for a layout
// at the right edge and mirrored for one at the left (`DockLayout.place`). Window ids: 1 maximized, 2 straddling,
// 3 dragged into the host's part, 4 dragged into the block, 5 beside the docked area, 7 dragged into the space a fold
// frees, 8 zoomed while folded.

private func start(_ layout: DockLayout, width: CGFloat) -> CGRect {
    layout.place(CGRect(x: layout.visible.minX + 10, y: layout.visible.minY + 100, width: width, height: 500))
}

private func straddling(_ layout: DockLayout) -> CGRect {
    let block = layout.atRight.block.rect
    return layout.place(CGRect(x: block.minX - 200, y: layout.visible.minY + 120, width: block.width + 400,
                               height: 500))
}

private func inHostsPart(_ layout: DockLayout) -> CGRect {
    layout.place(CGRect(x: layout.atRight.host.rect.minX + 20, y: layout.visible.minY + 140, width: 380, height: 500))
}

private func inBlock(_ layout: DockLayout) -> CGRect {
    layout.place(CGRect(x: layout.atRight.block.rect.minX + 60, y: layout.visible.minY + 160, width: 380, height: 500))
}

private func besideDockedArea(_ layout: DockLayout) -> CGRect {
    let visible = layout.visible, block = layout.atRight.block.rect
    return layout.place(CGRect(x: visible.minX, y: visible.minY + 80, width: block.minX - visible.minX, height: 600))
}

/// In the space between the unfolded block's window side and the rail: free while folded.
private func inFreedSpace(_ layout: DockLayout) -> CGRect {
    layout.place(CGRect(x: layout.atRight.block.rect.minX + 50, y: layout.visible.minY + 200, width: 360, height: 500))
}

@Suite("Two guards side by side: the host's strip and Pitbox's block")
struct AdjacentGuardsTests {
    @Test(arguments: DockLayout.all, GuardSide.allCases)
    func everyWindowEndsOutsideBothRegionsInAtMostTwoHops(layout: DockLayout, first: GuardSide) {
        #expect(layout.hostMidpointAgreesWithEdge, "the edge rule models the host's midpoint rule")
        let sim = DockedSimulation(layout, windows: [FakeWindow(1, start(layout, width: 380)),
                                                     FakeWindow(3, start(layout, width: 380)),
                                                     FakeWindow(4, pid: Fixture.chrome, start(layout, width: 380))],
                                   first: first)
        sim.run(until: 1)
        #expect(sim.hops.isEmpty, "every window starts clear of both regions")

        var counts: [Int] = []
        func settle(_ name: String, _ id: Int, since mark: Int) {
            sim.run(for: 3)
            let hops = sim.hops(of: id, since: mark)
            counts.append(hops.count)
            #expect(sim.hops[mark...].allSatisfy { $0.window == id }, "\(name): no other window moved")
            #expect((1...2).contains(hops.count), "\(name): at most two hops, got \(hops.count)")
            #expect(hops.allSatisfy(layout.isTowardWindowSide), "\(name): every hop toward the window side")
            #expect(sim.frame(id).map(layout.isClear) == true, "\(name): ends outside both regions, \(hops)")
        }

        var mark = sim.hops.count
        sim.appChanges(1, to: layout.visible)                       // the app zooms it: no click, no user action
        settle("maximized", 1, since: mark)

        mark = sim.hops.count
        sim.provider.add(FakeWindow(2, pid: Fixture.chrome, straddling(layout)))
        sim.notify(2)                                               // AXWindowCreated
        settle("straddling both regions", 2, since: mark)

        mark = sim.hops.count
        sim.drag(3, to: inHostsPart(layout))
        settle("dragged into the host's part", 3, since: mark)

        mark = sim.hops.count
        sim.drag(4, to: inBlock(layout))
        settle("dragged into the block", 4, since: mark)

        // Measured: the guard that looks first decides whether a window over both parts takes one hop or two. A window
        // dropped in the host's part always takes two (the host's guard puts it at its inner edge, inside the block);
        // one dropped in the block only takes one.
        #expect(counts == (first == .host ? [2, 2, 2, 1] : [1, 1, 2, 1]))
        #expect(sim.cooldowns == 0, "no window on a fight cooldown")
        #expect(sim.foughtLines == 0)
        for id in DockedSimulation.panelIDs {
            #expect(sim.hops(of: id).isEmpty, "the accessory apps' windows are never moved (window \(id))")
        }
    }

    @Test(arguments: DockLayout.all, GuardSide.allCases)
    func foldingAndUnfoldingThreeTimesInTenSecondsIsNoFight(layout: DockLayout, first: GuardSide) {
        let beside = besideDockedArea(layout)
        let sim = DockedSimulation(layout, windows: [FakeWindow(5, beside), FakeWindow(7, start(layout, width: 360)),
                                                     FakeWindow(8, pid: Fixture.chrome, start(layout, width: 380))],
                                   first: first)
        sim.run(until: 2)
        #expect(sim.hops.isEmpty)
        let begin = sim.now
        for cycle in 0..<3 {
            let foldAt = begin + Double(cycle) * 3
            sim.run(until: foldAt)
            sim.setBlock(layout.rail)                                   // − : fold to the rail
            #expect(sim.pitbox.causedByUser(sim.now), "a shown region resized is the user's doing")
            sim.run(for: 0.1)
            sim.drag(7, to: inFreedSpace(layout))                       // the user uses the space the fold freed
            sim.run(for: 0.2)
            #expect(sim.hops(of: 7).count == cycle, "dropped clear of the rail: nothing to correct")
            if cycle == 0 {
                let mark = sim.hops.count
                sim.appChanges(8, to: layout.visible)                   // an app zooms a window over the freed space
                sim.run(for: 1)
                let hops = sim.hops(of: 8, since: mark)
                #expect(hops.count == (first == .host ? 2 : 1) && hops.allSatisfy(layout.isTowardWindowSide),
                        "zoomed while folded: \(hops)")
                #expect(sim.frame(8).map { !Placement.overlaps($0, layout.host.rect)
                                            && !Placement.overlaps($0, layout.rail.rect) } == true)
            }
            sim.run(until: foldAt + 2.5)
            let mark = sim.hops.count
            sim.setBlock(layout.block)                                  // + : unfold
            #expect(sim.pitbox.causedByUser(sim.now))
            #expect(!sim.pitbox.recentUserAction(sim.now), "the last click is too long ago to be the reason")
            sim.run(until: foldAt + 3)
            let hops = sim.hops(of: 7, since: mark)
            #expect(hops.count == 1 && hops.allSatisfy { $0.side == .pitbox && layout.isTowardWindowSide($0) },
                    "unfold \(cycle + 1): one hop by the block's guard, \(hops)")
            #expect(sim.frame(7).map(layout.isClear) == true)
            if cycle == 0 {
                #expect(sim.hops(of: 8, since: mark).count == 1, "the zoomed window steps aside once")
            }
            #expect(sim.frame(8).map(layout.isClear) == true)
        }
        #expect(sim.now - begin <= 9, "three folds and unfolds within 10 s")
        #expect(sim.hops(of: 5).isEmpty, "the window beside the docked area is never touched")
        #expect(sim.frame(5) == beside)
        #expect(sim.cooldowns == 0, "no window on a fight cooldown")
        #expect(sim.foughtLines == 0)
        let record = sim.pitbox.fights.entries[7]
        #expect(record?.all.count == 3, "three corrections of the dragged window in 10 s")
        #expect(record?.hits.isEmpty == true, "none of them counted toward a fight")
        for id in DockedSimulation.panelIDs { #expect(sim.hops(of: id).isEmpty) }
    }

    /// The other half of the rule: a region appearing from nothing (a show after a hide, a launch) is not the user's
    /// doing, so an app that fights from the start is still caught.
    @Test(arguments: DockLayout.all)
    func aRegionAppearingFromNothingIsNotUserCaused(layout: DockLayout) {
        let sim = DockedSimulation(layout, windows: [FakeWindow(1, start(layout, width: 380))])
        sim.run(until: 2)
        sim.setBlock(nil)                                               // Pitbox hides
        #expect(!sim.pitbox.causedByUser(sim.now))
        sim.run(for: 2)
        sim.appChanges(1, to: layout.visible)                           // zoomed while the block is hidden
        sim.run(for: 2)
        #expect(sim.hops(of: 1).map(\.side) == [.host], "only the host's guard is guarding")
        #expect(sim.frame(1).map { Placement.overlaps($0, layout.block.rect) } == true, "now under the block's place")

        let mark = sim.hops.count
        sim.setBlock(layout.block)                                      // shown again
        #expect(!sim.pitbox.causedByUser(sim.now), "a region appearing from nothing is not the user's doing")
        sim.run(for: 2)
        let hops = sim.hops(of: 1, since: mark)
        #expect(hops.count == 1 && hops.allSatisfy { $0.side == .pitbox && layout.isTowardWindowSide($0) })
        #expect(sim.frame(1).map(layout.isClear) == true)
        #expect(sim.pitbox.fights.entries[1]?.hits.count == 1, "the correction counts toward a fight")
        #expect(sim.cooldowns == 0)

        sim.setBlock(layout.rail)                                       // a shown region resized: the user's doing
        #expect(sim.pitbox.causedByUser(sim.now))
        sim.run(for: 2)
        #expect(!sim.pitbox.causedByUser(sim.now), "for settleDelay + userActionWindow only")
    }

    /// The harness catches what push-by-edge prevents: with the direction the midpoint rule picks for a block whose
    /// middle lies on the host's side of the display's middle, the two guards bounce a window until they give up.
    @Test(arguments: [DockLayout.narrow, DockLayout.narrowLeft])
    func theMidpointRuleWouldBounceAWindowBetweenTheGuards(layout: DockLayout) {
        let block = layout.block
        #expect(layout.edge == .right ? block.rect.midX < layout.visible.midX : block.rect.midX > layout.visible.midX)
        var midpoint = block
        midpoint.edge = layout.edge == .right ? .left : .right
        let sim = DockedSimulation(layout, windows: [FakeWindow(1, start(layout, width: 380))])
        sim.setBlock(midpoint)
        sim.run(until: 2)
        sim.appChanges(1, to: layout.visible)
        sim.run(for: 10)
        let hops = sim.hops(of: 1)
        #expect(hops.count > 2, "bounced between the guards: \(hops.count) hops")
        #expect(!hops.allSatisfy(layout.isTowardWindowSide), "pushed both ways")
        #expect(sim.cooldowns > 0, "until a guard put it on a fight cooldown")
        #expect(sim.frame(1).map(layout.isClear) == false, "and left it under the docked area")
    }
}
