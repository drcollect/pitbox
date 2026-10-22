import Foundation
import Testing
@testable import PitboxSessions
import PitboxKit

/// A source written before `recentSessions(within:)` existed: it never heard of it.
@MainActor
private final class OldSource: CodeSessionsSource {
    var sessions: [CodeSessionSnapshot] = []
    var runningProfiles: [CodeProfile] = []
    var banner: String?
    var onChange: (() -> Void)?
    func setWatched(_ sessionIDs: Set<String>) {}
    func setStripVisible(_ visible: Bool) {}
    func start() {}
    func stop() {}
}

@Suite("Model seam: derived fields")
struct ModelSeamTests {
    @Test @MainActor func aSourceWithoutRecentSessionsHasNone() {
        let source: CodeSessionsSource = OldSource()
        #expect(source.recentSessions(within: 6).isEmpty && source.runningProcesses.isEmpty)
    }

    @Test func aSnapshotMadeTheOldWayHasEmptyWaveTwoFields() {
        let snapshot = CodeSessionSnapshot(id: sessionA, index: 1, profile: .a, headline: "h", title: "h", place: .local,
                                           state: .done)
        #expect(snapshot.workStartedAt == nil && snapshot.replyUUID == nil && snapshot.progress == nil && snapshot.eta == nil)
        #expect(snapshot.results.isEmpty && snapshot.otherLinkCount == 0 && snapshot.warnings.isEmpty)
        #expect(snapshot.dashboard == nil && snapshot.earlierOffers.isEmpty && snapshot.finished == nil && !snapshot.unread)
    }

    @Test func theConstantsAreTheTablesOfA12() {
        #expect(CodeTuning.densityMediumFrom == 5 && CodeTuning.densitySmallFrom == 10)
        let perPage: [Int] = [CodeTuning.perPageLarge, CodeTuning.perPageMedium, CodeTuning.perPageSmall, CodeTuning.perPageRows]
        #expect(perPage == [4, 9, 12, 8])
        let rows: [Int] = [CodeTuning.rowsPerPageLarge, CodeTuning.rowsPerPageMedium, CodeTuning.rowsPerPageSmall,
                           CodeTuning.rowsPerPageRows]
        #expect(rows == [2, 3, 2, 8])
        let heights: [CGFloat] = [CodeTuning.largeHeight, CodeTuning.mediumHeight, CodeTuning.smallHeight, CodeTuning.rowHeight]
        #expect(heights == [219, 150, 104, 36])
        #expect(CodeTuning.maxBuckets == 20 && CodeTuning.bucketNameMax == 32)
        #expect(CodeTuning.readyVisibleCards == 3 && CodeTuning.readyVisibleCardsTall == 6 && CodeTuning.cardHeight == 60)
        #expect(CodeTuning.readyMaxItems == 40 && CodeTuning.followMax == 24 && CodeTuning.readyRecentHours == 6)
        #expect(CodeTuning.newerRepliesMax == 2 && CodeTuning.newerRepliesShown == 4 && CodeTuning.sshMidTurnSlack == 10)
        #expect(CodeTuning.dismissUndo == 5 && CodeTuning.resultRowLife == 600 && CodeTuning.openButtonArmDelay == 0.8)
        #expect(CodeTuning.tagRightInset == 24 && CodeTuning.tagPlaceCoalesce == 0.016 && CodeTuning.tagShowAfterDrag == 0.15)
        #expect(CodeTuning.workMaxAge == 12 * 3600 && CodeTuning.backgroundMaxAge == 6 * 3600 && CodeTuning.backgroundMaxPending == 64)
        #expect(CodeTuning.etaBeforeStatement == 1800 && CodeTuning.etaMaxAhead == 12 * 3600 && CodeTuning.etaKeepAfter == 7200)
        #expect(CodeTuning.etaValueWindow == 40 && CodeTuning.etaLabelLines == 3)
        #expect(CodeTuning.estimateMinDone == 1 && CodeTuning.estimateMinTotal == 3 && CodeTuning.estimateMinElapsed == 180
                && CodeTuning.estimateMax == 240 * 60)
        #expect(CodeTuning.finishedMinRun == 180 && CodeTuning.finishedSilentAtStart == 7200 && CodeTuning.lookingInputWindow == 60)
        #expect(CodeTuning.alertCoalesce == 20 && CodeTuning.sayMinInterval == 30 && CodeTuning.speechResumeDelay == 0.5)
        #expect(CodeTuning.recapAfterMinutes == 15 && CodeTuning.recapPollPresent == 30 && CodeTuning.recapPollAway == 2
                && CodeTuning.recapLife == 1800)
        #expect(CodeTuning.maxResults == 6 && CodeTuning.fileCandidatesMax == 6 && CodeTuning.fileCheckBudget == 0.05
                && CodeTuning.repoSearchDepth == 12)
        #expect(CodeTuning.stuckRunLength == 4 && CodeTuning.stuckSilence == 1800)
        #expect(CodeTuning.sameFileWindow == 1800 && CodeTuning.okSilenceSameFile == 7200)
        #expect(CodeTuning.dashboardScanMax == 128 * 1024 * 1024 && CodeTuning.dashboardScanSeconds == 60
                && CodeTuning.dashboardLineMax == 1024 * 1024)
        #expect(CodeTuning.dropArmDelay == 0.25 && CodeTuning.dropPollHz == 30)
        #expect(CodeTuning.memoryReadMax == 1024 * 1024 && CodeTuning.memoryWriteMax == 768 * 1024
                && CodeTuning.memoryPruneDays == 14 && CodeTuning.bucketsPruneDays == 30)
        // The claims registry in Core keeps the same numbers.
        #expect(CodeTuning.claimMaxHoldAfterMouseUp == WindowDropClaims.maxHoldAfterMouseUp)
        #expect(CodeTuning.claimMaxAge == WindowDropClaims.maxAge && CodeTuning.claimsMax == WindowDropClaims.maxClaims)
        #expect(CodeTuning.deriveBudget == 0.010 && CodeTuning.digestTurnsMax == 200 && CodeTuning.digestBytesMax == 2 << 20)
    }

    @Test func dashboardHandlesFollowTheGrammarAndTheAddressIsRebuilt() throws {
        for handle in ["polar-shore", "quiet-fjord-lane", "3f2a9c1b", "a", String(repeating: "a", count: 64)] {
            #expect(CodeDashboard.isValidHandle(handle), "\(handle)")
        }
        for handle in ["Polar-Shore", "-x", "x-", "a--b", "", String(repeating: "a", count: 65), "polar_shore", "pölar",
                       "polar shore", "../x", "polar.shore"] {
            #expect(!CodeDashboard.isValidHandle(handle), "\(handle)")
            #expect(CodeDashboard(handle: handle, site: .test, firstSeen: fixtureNow) == nil)
        }
        let dashboard = try #require(CodeDashboard(handle: "polar-shore", site: .test, firstSeen: fixtureNow,
                                                   lastBuilderCallAt: fixtureNow.addingTimeInterval(-60)))
        #expect(dashboard.url?.absoluteString == "https://dash.example.com/dash/polar-shore/")
        #expect(dashboard.lastBuilderCallAt == fixtureNow, "never earlier than firstSeen")
    }

    @Test func theSmallValuesSayWhatTheyHold() {
        let progress = CodeProgress(source: .backgroundTasks, unit: .agents, done: 4, total: 6)
        #expect(progress.pending == 2 && abs(progress.fraction - 4.0 / 6.0) < 1e-12)
        #expect(CodeProgress(source: .todos, unit: .todos, done: 9, total: 7).fraction == 1)
        #expect(CodeProgress(source: .todos, unit: .todos, done: 0, total: 0).fraction == 0)
        let recent = CodeRecentSession(id: sessionA, profile: .a, lastFocusedAt: fixtureNow,
                                       latestUserFrameAt: fixtureNow.addingTimeInterval(60), ownLastActivity: fixtureNow)
        #expect(recent.usersLastActivity == fixtureNow.addingTimeInterval(60))
        #expect(CodeRecentSession(id: sessionA, profile: .a).usersLastActivity == nil)
        #expect(CodeWarning.Kind.failedInARow.rawValue == "failed_in_a_row" && CodeWarning.Kind.sameFile.rawValue == "same_file")
        #expect(CodeWarning(kind: .sameFile, since: fixtureNow, otherSessionID: sessionB).id == "same_file:\(sessionB)")
        let result = CodeResult(kind: .preview, origin: .replyLink, url: URL(string: "http://localhost:5173/"), label: "localhost:5173")
        #expect(result.id == "preview:http://localhost:5173/")
        #expect(CodeMemoryKey.allCases.map(\.rawValue) == ["seen", "finished", "ready", "eta", "background", "dashboard",
                                                          "dashboardScan", "silenced"])
    }

    @Test func derivedFieldsApplyOnlyTheWaveTwoFields() {
        let base = CodeSessionSnapshot(id: sessionA, index: 3, profile: .a, headline: "h", title: "h", place: .ssh, state: .working,
                                       replyUUID: "r-1")
        var fields = CodeDerivedFields()
        fields.otherLinkCount = 2
        fields.unread = true
        fields.warnings = [CodeWarning(kind: .silence, since: fixtureNow)]
        let applied = fields.applied(to: base)
        #expect(applied.otherLinkCount == 2 && applied.unread && applied.warnings.count == 1)
        #expect(applied.state == .working && applied.index == 3 && applied.replyUUID == "r-1" && applied.place == .ssh)
        #expect(CodeDeriveRunner.logLabel("Same File ✓ x") == "samefilex" && CodeDeriveRunner.logLabel("✓") == "deriver")
    }
}
