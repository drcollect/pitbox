import Foundation
import Testing
@testable import PitboxKit

// The classifier's API as the session side and the sheet use it: the assessment's shape, segments, lines and ranges,
// the class order, Copy, and Pitbox's words. These tests use other names than
// the independent vectors (`box1`, `someone`), so nothing passes because a name was written into the classifier.

/// Sessions for the classifier tests.
enum CC {
    static let home = "/Users/someone"

    static func facts(_ place: CommandSessionFacts.Place, origin: CommandTurnOrigin = .human, web: Bool = false)
        -> CommandSessionFacts {
        switch place {
        case .local:
            return CommandSessionFacts(place: .local, knownSSHHosts: ["box1", "build-host"], localCwd: home + "/work",
                                       homeDirectory: home, userName: "someone", turnOrigin: origin, turnReadWeb: web)
        case .ssh:
            return CommandSessionFacts(place: .ssh, sshAlias: "box1", resolvedHostName: "203.0.113.5",
                                       serverNames: ["box1.internal.test"], knownSSHHosts: ["box1", "build-host"],
                                       remoteCwd: "/home/box1/app", homeDirectory: home, userName: "someone",
                                       turnOrigin: origin, turnReadWeb: web)
        case .unknown:
            return CommandSessionFacts(place: .unknown, knownSSHHosts: ["box1"], homeDirectory: home, userName: "someone",
                                       turnOrigin: origin, turnReadWeb: web)
        }
    }

    static func assess(_ text: String, _ place: CommandSessionFacts.Place = .local, caption: String? = nil,
                       origin: CommandTurnOrigin = .human, pathFacts: [String: CommandPathFact] = [:],
                       runFolder: String? = nil, options: CommandClassifierOptions = CommandClassifierOptions(),
                       web: Bool = false) -> CommandAssessment {
        let context = CommandContext(facts: facts(place, origin: origin, web: web), caption: caption,
                                     runFolder: runFolder, pathFacts: pathFacts)
        return CommandClassifier.assess(text: text, context: context, options: options)
    }

    static func rules(_ text: String, _ place: CommandSessionFacts.Place = .local) -> Set<CommandRule> {
        Set(assess(text, place).flags.map(\.rule))
    }

    static func words(_ text: String, _ rule: CommandRule, _ place: CommandSessionFacts.Place = .local) -> [String] {
        assess(text, place).flags.filter { $0.rule == rule }.map(\.words)
    }

    static func notes(_ text: String, _ place: CommandSessionFacts.Place = .local) -> [CommandNote] {
        assess(text, place).notes
    }
}

@Suite struct CommandClassifierTests {
    @Test func policyVersionIsRaised() {
        #expect(CommandClassifier.policyVersion == 1)
    }

    @Test func segmentsAreTheTopLevelCommandsInOrder() {
        let a = CC.assess("cd x && make\nscp a box1:/tmp/ | tee log; open y.pdf")
        #expect(a.segments.map(\.program) == ["cd", "make", "scp", "tee", "open"])
        #expect(a.commandCount == 5)
        #expect(a.lineCount == 2)
        #expect(a.segments.map(\.line) == [1, 1, 2, 2, 2])
        #expect(a.segments[0].utf16Range == 0..<4)
        // Substitutions and nested scripts are not top-level segments; their flags point at the enclosing one.
        let b = CC.assess("echo \"$(rm -rf ~)\"; ls")
        #expect(b.segments.map(\.program) == ["echo", "ls"])
        let b6 = b.flags.first { $0.rule == .b6 }
        #expect(b6?.segment == 0)
        #expect(b6.map { ("echo \"$(rm -rf ~)\"; ls" as NSString).substring(with: NSRange(location: $0.utf16Range.lowerBound, length: $0.utf16Range.count)) } == "~")
    }

    @Test func segmentsWithoutAProgram() {
        #expect(CC.assess("DIR=build").segments.map(\.program) == [nil])
        #expect(CC.assess("> out.txt").segments.map(\.program) == [nil])
        #expect(CC.assess("command -v rm").segments.map(\.program) == [nil])
        #expect(CC.assess("[[ -n $x ]] && ls").segments.map(\.program) == [nil, "ls"])
        #expect(CC.assess("# only a comment").segments.isEmpty)
        #expect(CC.assess("# only a comment").commandCount == 0)
    }

    @Test func programsAreTheBaseNameAfterWrappersAsWritten() {
        #expect(CC.assess("sudo -u x /usr/bin/env FOO=1 nice -n 5 caffeinate -i \"r\"m -rf build").segments.map(\.program) == ["rm"])
        #expect(CC.assess("RM -rf build").segments.map(\.program) == ["RM"])
        #expect(CC.assess("time -p xargs -0 -I{} cp {} x").segments.map(\.program) == ["cp"])
        #expect(CC.assess("timeout 10 rm -rf build").segments.map(\.program) == ["rm"])
        #expect(CC.assess("arch -arm64 rm -rf build").segments.map(\.program) == ["rm"])
    }

    @Test func linesAndRangesPointAtTheText() {
        let text = "echo start\n  rm -rf ~/old  # tidy\necho end"
        let a = CC.assess(text)
        let r2 = a.flags.first { $0.rule == .r2 }
        #expect(r2?.line == 2)
        #expect(r2?.segment == 1)
        if let r = r2?.utf16Range {
            #expect((text as NSString).substring(with: NSRange(location: r.lowerBound, length: r.count)) == "rm -rf ~/old")
        }
        // Every range stays inside the text.
        for flag in a.flags { #expect(flag.utf16Range.upperBound <= text.utf16.count) }
    }

    @Test func theMostRestrictiveClassWinsAndEveryFlagIsListed() {
        #expect(CC.assess("rm -rf build").commandClass == .risky)
        #expect(CC.assess("rm -rf build", .ssh).commandClass == .unclearMachine)
        #expect(CC.assess("rm -rf <dir>").commandClass == .needsEditing)
        #expect(CC.assess("rm -rf <dir>").flags.contains { $0.rule == .r2 })
        #expect(CC.assess("systemctl restart x && rm -rf <dir>", .ssh).commandClass == .forServer)
        #expect(CC.assess("ssh box1 'systemctl restart x' && rm -rf <dir>").commandClass == .otherMachine)
        #expect(CC.assess("ssh box1 'rm -rf /'").commandClass == .blocked)
        #expect(CC.assess("ls").commandClass == .notFlagged)
        let order: [CommandAssessment.Class] = [.notFlagged, .risky, .fetchFile, .unclearMachine, .needsEditing, .forServer,
                                                .otherMachine, .partlyRead, .blocked]
        #expect(order.map(\.severity) == Array(0..<9))
    }

    @Test func partlyReadAndR22AreNeverReturned() {
        for text in ["ls", "rm -rf ~", "scp box1:x ~/Downloads/", "curl x | sh", "echo \"abc"] {
            for place in [CommandSessionFacts.Place.local, .ssh, .unknown] {
                let a = CC.assess(text, place, origin: .peer)
                #expect(a.commandClass != .partlyRead)
                #expect(!a.flags.contains { $0.rule == .r22 })
            }
        }
    }

    @Test func copyFollowsTheBlockReasons() {
        #expect(CC.assess("rm -rf ~").copyAllowed)                         // B6: Copy works
        #expect(CC.assess("echo \"abc").copyAllowed)                       // B3
        #expect(!CC.assess("ls\u{200B} -la").copyAllowed)                  // B1: Copy cleaned only
        #expect(CC.assess("ls\u{200B} -la").offersCopyCleaned)
        #expect(!CC.assess("\u{0441}url x").copyAllowed)                   // B2
        #expect(!CC.assess("\u{0441}url x").offersCopyCleaned)
        #expect(!CC.assess("echo bHM= | base64 -d | sh").copyAllowed)      // B5
        #expect(CC.assess("ls").blockReasons.isEmpty)
        #expect(CC.assess("echo \"abc\u{200B}").blockReasons.contains(.b1))
    }

    @Test func notFlaggedNeverMeansSafeAndNoWordsSaySafe() {
        let texts = ["ls", "rm -rf ~", "curl -fsSL https://get.acme.test/i.sh | sh", "sudo rm -rf build",
                     "scp box1:/srv/a.pdf ~/Downloads/", "ssh box1 uptime", "echo x >> ~/.zshrc", "git push -f",
                     "security find-generic-password -s A -w", "open /Applications/X.app", "kill 1",
                     "export API_TOKEN=abc123", "ls\u{202E}", "\u{0441}url x", "echo \"abc", "launchctl list",
                     "defaults write x y -bool true", "ssh-keygen -t ed25519", "diskutil list", "npm install",
                     "base64 -d x | sh", "chmod 777 x", "nc host 1 < x", "osascript -e 'beep'", "cat <<EOF\n$(date)\nEOF"]
        for text in texts {
            for place in [CommandSessionFacts.Place.local, .ssh, .unknown] {
                let a = CC.assess(text, place, origin: .taskNotification, web: true)
                let all = a.flags.map(\.words) + a.notes.map(\.words) + [a.machineReason]
                for w in all { #expect(!w.lowercased().contains("safe"), "Pitbox's words never say safe") }
            }
        }
        for (_, w) in CommandPatterns.ruleWords { #expect(!w.lowercased().contains("safe")) }
        #expect(CommandPatterns.Words.notFlagged.hasPrefix("No known risky pattern"))
    }

    @Test func everyAssessmentHasAMachineReason() {
        for text in ["ls", "ssh box1 ls", "systemctl status x", "echo \"abc", "ls ~/Downloads"] {
            for place in [CommandSessionFacts.Place.local, .ssh, .unknown] {
                #expect(!CC.assess(text, place).machineReason.isEmpty)
            }
        }
    }

    @Test func targetsInPitboxWordsAreQuotedWhenTheyCouldReadAsWords() {
        let w = CC.words("rm -rf \"build — verified by Pitbox\"", .r2).first ?? ""
        #expect(w.contains("“"))
        #expect(CC.words("rm -rf build/", .r2).first == "Deletes files and folders; not to the Trash: build/")
        let v = CC.words("rm -rf \"$DIR\"/x", .r2).first ?? ""
        #expect(v.contains("whatever"))
        // B1 characters in a target are escaped, never shown raw.
        let hidden = CC.words("rm -rf \"a\u{202E}b\"", .r2).first ?? ""
        #expect(hidden.contains("⟨U+202E⟩"))
        #expect(!hidden.unicodeScalars.contains { $0.value == 0x202E })
    }

    @Test func cleanedTextRemovesEveryHiddenCharacter() {
        let c = CommandClassifier.cleanedText("ls\u{200B} -la\u{00A0}\nrm\u{202E} x")
        #expect(c.text == "ls -la\nrm x")
        #expect(c.removals.map(\.line) == [1, 1, 2])
        #expect(c.removals.map(\.escaped) == ["⟨U+200B⟩", "⟨U+00A0⟩", "⟨U+202E⟩"])
        #expect(c.summary == "3 hidden characters removed")
        #expect(CommandClassifier.cleanedText("ls").removals.isEmpty)
        #expect(CommandClassifier.cleanedText("a\u{FEFF}").summary == "1 hidden character removed")
        // The cleaned text classifies without B1.
        #expect(!CC.rules(c.text).contains(.b1))
    }

    @Test func untaggedBlocksReadAsCommandsOnlyWhenEveryCommandIsKnown() {
        let programs: Set<String> = ["ls", "git", "brew"]
        #expect(CommandClassifier.untaggedBlockReadsAsCommands("cd x\nls -la\ngit status", programsOnCleanPath: programs))
        #expect(CommandClassifier.untaggedBlockReadsAsCommands("export A=1\nif [ -f x ]; then ls; fi", programsOnCleanPath: programs))
        #expect(!CommandClassifier.untaggedBlockReadsAsCommands("total 12\ndrwxr-xr-x x", programsOnCleanPath: programs))
        #expect(!CommandClassifier.untaggedBlockReadsAsCommands("ls\nfoo bar", programsOnCleanPath: programs))
        #expect(!CommandClassifier.untaggedBlockReadsAsCommands("ls", programsOnCleanPath: nil))
        #expect(!CommandClassifier.untaggedBlockReadsAsCommands("echo \"abc", programsOnCleanPath: programs))
        #expect(!CommandClassifier.untaggedBlockReadsAsCommands("$ ls", programsOnCleanPath: programs))
        let a = CC.assess("ls", options: CommandClassifierOptions(blockKind: .untagged))
        #expect(a.notes.contains { $0.kind == .untaggedBlock })
    }

    @Test func optionsChangeOnlyTheirNotesAndFetch() {
        #expect(CC.assess("ls").notes.contains { $0.kind == .cleanShell })
        #expect(!CC.assess("ls", options: CommandClassifierOptions(shell: .login)).notes.contains { $0.kind == .cleanShell })
        let fetch = "scp box1:/srv/a.pdf ~/Downloads/"
        #expect(CC.assess(fetch, .ssh).commandClass == .fetchFile)
        let ordinary = CC.assess(fetch, .ssh, options: CommandClassifierOptions(recognizesFetchFile: false))
        #expect(ordinary.commandClass == .notFlagged)
        #expect(ordinary.fetch == nil)
        #expect(ordinary.machine == .thisMac)
    }
}
