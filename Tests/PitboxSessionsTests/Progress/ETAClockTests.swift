import Foundation
import Testing
@testable import PitboxSessions

/// Placing a stated clock and the estimate.
@Suite("ETA clock and estimate")
struct ETAClockTests {
    @Test func aClockIsPlacedAtItsFirstMomentFromHalfAnHourBeforeTheStatement() throws {
        // A local session in Lisbon (WEST, UTC+1, on 20 October 2026).
        let late = utcDate(2026, 10, 20, 22, 50)                       // 23:50 local
        let next = try #require(ETAClock.place(hour: 0, minute: 20, in: lisbonZone, statedAt: late))
        #expect(next == utcDate(2026, 10, 20, 23, 20), "00:20 the next day")
        let afternoon = utcDate(2026, 10, 20, 13, 0)                    // 14:00 local
        let passed = try #require(ETAClock.place(hour: 13, minute: 50, in: lisbonZone, statedAt: afternoon))
        #expect(passed == utcDate(2026, 10, 20, 12, 50) && passed < afternoon, "today, already passed")
        let evening = utcDate(2026, 10, 20, 22, 0)                      // 23:00 local
        #expect(ETAClock.place(hour: 22, minute: 0, in: lisbonZone, statedAt: evening) == nil, "22:00 is over 12 h away")
        #expect(ETAClock.place(hour: 24, minute: 0, in: lisbonZone, statedAt: evening) == nil)
    }

    @Test func serverClocksAreReadInTheirZoneAndShownInThisMacs() throws {
        // An SSH session states "ETA ~22:24" at 22:10 server time (UTC): shown as 23:24 in Lisbon summer time.
        let stated = utcDate(2026, 10, 20, 22, 10)
        let at = try #require(ETAClock.place(hour: 22, minute: 24, in: utcZone, statedAt: stated))
        #expect(at == utcDate(2026, 10, 20, 22, 24))
        #expect(clockLisbon.string(at) == "23:24" && clockUTC.string(at) == "22:24")
        let eta = CodeETA(kind: .stated, at: at, statedZone: "UTC", statedAt: stated)
        #expect(RunText.statedAs(eta, clock: clockLisbon) == "22:24 UTC")
        // After the clocks go back Lisbon reads UTC's clock: no "(stated as …)".
        let winter = try #require(ETAClock.place(hour: 22, minute: 24, in: utcZone, statedAt: utcDate(2026, 11, 2, 22, 10)))
        #expect(RunText.statedAs(CodeETA(kind: .stated, at: winter, statedZone: "UTC"), clock: clockLisbon) == nil)
    }

    @Test func theLisbonClockChangeOn25October2026() throws {
        // WEST (UTC+1) ends at 01:00 UTC: local 01:00-02:00 happens twice.
        let beforeChange = utcDate(2026, 10, 24, 23, 30)                // 00:30 WEST on 25 October
        let three = try #require(ETAClock.place(hour: 3, minute: 0, in: lisbonZone, statedAt: beforeChange))
        #expect(three == utcDate(2026, 10, 25, 3, 0), "03:00 is in WET (UTC+0), not an hour early")
        #expect(clockLisbon.string(three) == "03:00")
        // Stated during the second 01:xx (WET): its first 01:30 lies before the bound, the second one counts.
        let secondPass = utcDate(2026, 10, 25, 1, 10)
        let repeated = try #require(ETAClock.place(hour: 1, minute: 30, in: lisbonZone, statedAt: secondPass))
        #expect(repeated == utcDate(2026, 10, 25, 1, 30))
        // Stated during the first 01:xx (WEST): its own 01:30 (00:30 UTC) comes first.
        let firstPass = utcDate(2026, 10, 25, 0, 20)
        #expect(ETAClock.place(hour: 1, minute: 30, in: lisbonZone, statedAt: firstPass) == utcDate(2026, 10, 25, 0, 30))
        // The hour the clocks skip in spring (29 March 2026): 01:30 does not occur, the next one is a day away.
        #expect(ETAClock.place(hour: 1, minute: 30, in: lisbonZone, statedAt: utcDate(2026, 3, 29, 0, 50)) == nil)
    }

    @Test func clockFormats() {
        let at = utcDate(2026, 10, 20, 22, 24)
        #expect(clockUTC.string(at) == "22:24")
        let twelve = CodeClockFormat(timeZone: utcZone, uses24Hour: false)
        #expect(twelve.string(at) == "10:24 PM" && twelve.string(utcDate(2026, 10, 20, 0, 5)) == "12:05 AM")
        #expect(CodeDurationText.minutes(34) == "34 min" && CodeDurationText.minutes(72) == "1 h 12 min")
        #expect(CodeDurationText.minutes(120) == "2 h")
    }

    // MARK: Estimate

    @Test func theEstimateFollowsTheDemosFormulaWithItsGuards() throws {
        let start = utcDate(2026, 10, 20, 22, 0)
        #expect(ETAEstimator.estimate(done: 0, total: 2, since: start, now: start.addingTimeInterval(120)) == nil)
        let estimate = try #require(ETAEstimator.estimate(done: 3, total: 7, since: start, now: start.addingTimeInterval(12 * 60)))
        #expect(estimate.minutesLeft == 16 && estimate.at == start.addingTimeInterval(28 * 60))
        #expect(ETAEstimator.estimate(done: 1, total: 2, since: start, now: start.addingTimeInterval(600)) == nil, "total < 3")
        #expect(ETAEstimator.estimate(done: 1, total: 3, since: start, now: start.addingTimeInterval(150)) == nil, "elapsed < 3")
        #expect(ETAEstimator.estimate(done: 3, total: 3, since: start, now: start.addingTimeInterval(600)) == nil, "p = 1")
        #expect(ETAEstimator.estimate(done: 1, total: 10, since: start, now: start.addingTimeInterval(1800)) == nil,
                "270 minutes: over 240, nothing")
        #expect(ETAEstimator.estimate(done: 6, total: 7, since: start, now: start.addingTimeInterval(180))?.minutesLeft == 1,
                "at least 1")
    }

    @Test func estimateWordsRound() {
        #expect(ETAEstimator.words(minutesLeft: 9) == "≈ 9 min left")
        #expect(ETAEstimator.words(minutesLeft: 12) == "≈ 10 min left")
        #expect(ETAEstimator.words(minutesLeft: 23) == "≈ 25 min left")
        #expect(ETAEstimator.words(minutesLeft: 58) == "≈ 1 h left")
        #expect(ETAEstimator.words(minutesLeft: 64) == "≈ 1 h left")
        #expect(ETAEstimator.words(minutesLeft: 76) == "≈ 1 h 20 min left")
        #expect(ETAEstimator.words(minutesLeft: 238) == "≈ 4 h left")
        #expect(ETAEstimator.shortWords(minutesLeft: 9) == "≈ 9 min")
    }
}
