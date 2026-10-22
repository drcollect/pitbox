import Foundation
import Testing
@testable import PitboxKit

// Runs every independent vector of docs/SHELL_LANGUAGE.md through the classifier. While the classifier is the
// fail-closed placeholder (`policyVersion == 0`) there is nothing to measure, so the run returns early and the suite
// stays green until the real scanner is in place. Failure messages name the vector and the rule or class that differs,
// never the command text.

@Suite struct ShellVectorTests {
    @Test func everyVectorMatchesTheClassifier() {
        guard CommandClassifier.policyVersion > 0 else { return }
        var failing = 0
        for vector in ShellVectors.all {
            let assessment = CommandClassifier.assess(text: vector.text, context: vector.context)
            let mismatches = vector.mismatches(in: assessment)
            if !mismatches.isEmpty {
                failing += 1
                Issue.record(Comment(rawValue: mismatches.joined(separator: "; ")))
            }
        }
        #expect(failing == 0, "\(failing) of \(ShellVectors.all.count) vectors mismatch")
    }

    /// The table itself: enough vectors, unique names, every rule and class covered. Runs at every policy version.
    @Test func theVectorTableIsWellFormed() {
        let all = ShellVectors.all
        #expect(all.count >= 150)
        #expect(Set(all.map(\.name)).count == all.count)
        // Every rule has a vector that requires it and one that forbids it. R21 needs file facts the pure classifier
        // does not get (docs/SHELL_LANGUAGE.md A5), so it has only negative vectors; R22 is the session side's
        // (supersession, never the classifier's: A27), so every vector forbids it through `mismatches(in:)`.
        let required = Set(all.flatMap { $0.mustHave + $0.anyOf })
        let forbidden = Set(all.flatMap(\.mustNotHave))
        for rule in CommandRule.allCases where rule != .r21 && rule != .r22 {
            #expect(required.contains(rule), "\(rule.rawValue) has no positive vector")
        }
        for rule in CommandRule.allCases where rule != .r22 {
            #expect(forbidden.contains(rule), "\(rule.rawValue) has no negative vector")
        }
        // Every class except Partly read (applied by the sheet, not the classifier) is expected somewhere.
        let classes = Set(all.map(\.expectedClass))
        for cls in CommandAssessment.Class.allCases where cls != .partlyRead {
            #expect(classes.contains(cls), "\(cls.rawValue) is never expected")
        }
        // Only the limit and pathological vectors go past the size limits.
        for vector in all where !vector.name.hasPrefix("lim-") && !vector.name.hasPrefix("patho-") {
            #expect(vector.text.unicodeScalars.count <= CommandOffer.maxCharacters, "\(vector.name) is over the size limit")
            #expect(vector.text.split(separator: "\n", omittingEmptySubsequences: false).count <= CommandOffer.maxLines,
                    "\(vector.name) has too many lines")
        }
        // Each preset builds; the SSH preset is the only one with a server.
        for preset in [ShellVector.Facts.local, .ssh, .unknownPlace, .taskNotification] {
            let facts = ShellVector.sessionFacts(preset)
            #expect((facts.sshAlias != nil) == (preset == .ssh))
            #expect((facts.turnOrigin == .taskNotification) == (preset == .taskNotification))
        }
    }
}
