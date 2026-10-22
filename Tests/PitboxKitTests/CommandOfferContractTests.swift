import Foundation
import Testing
@testable import PitboxKit

// The command offer contract of Code monitors: the shared types and their fixed values.

@Suite struct CommandOfferContractTests {
    private let facts = CommandSessionFacts(place: .local, localCwd: "/Users/someone/project",
                                            homeDirectory: "/Users/someone", userName: "someone", turnOrigin: .human)

    @Test func classifierFailsClosedUntilTheScannerLands() {
        guard CommandClassifier.policyVersion == 0 else { return }   // the real scanner raises the version
        let a = CommandClassifier.assess(text: "ls -la\npwd", context: CommandContext(facts: facts))
        #expect(a.commandClass == .blocked)
        #expect(a.blockReason == .b3)
        #expect(a.redLines.isEmpty)
        #expect(a.lineCount == 2)
    }

    @Test func rulesSplitIntoRedLinesAndBlocks() {
        #expect(CommandRule.allCases.count == 28)
        #expect(!CommandRule.r22.blocks)
        #expect(CommandRule.allCases.filter(\.blocks).map(\.rawValue) == ["B1", "B2", "B3", "B4", "B5", "B6"])
        #expect(!CommandRule.r21.blocks)
    }

    @Test func offerIDsLogWithoutSessionIDs() {
        let id = CommandOffer.ID(sessionIndex: 3, replyUUID: "0f3c2a9e-uuid", number: 1)
        #expect(id.description == "#3.1")
    }

    @Test func limitsAndCleanShellMatchTheSpec() {
        #expect(CommandOffer.maxLines == 40)
        #expect(CommandOffer.maxCharacters == 4_000)
        #expect(CommandOffer.maxLineCharacters == 500)
        #expect(CommandOffer.maxOffersPerReply == 8)
        #expect(CommandOfferFreshness.checkTimeout == 0.3)
        #expect(CommandExecutionDescriptor.cleanPath
                == "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(CommandExecutionDescriptor.cleanRunArguments == ["-f", "-i", "-o", "interactivecomments", "-o", "nobanghist"])
    }

}
