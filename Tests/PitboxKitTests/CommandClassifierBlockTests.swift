import Foundation
import Testing
@testable import PitboxKit

// B1-B6 (docs/SHELL_LANGUAGE.md §3.4-§3.5, §5): the character policy generated from the Unicode data of this Mac,
// look-alikes by position, the language boundary, the size limits, decoded scripts and the known destroyers.

@Suite struct CommandClassifierBlockTests {
    // MARK: B1

    @Test func b1BlocksEveryCharacterThePolicyNamesInAnyPosition() {
        var hidden: [Unicode.Scalar] = []
        for v in UInt32(0)...0x10FFFF {
            guard let s = Unicode.Scalar(v), CommandCharacterPolicy.isHidden(s) else { continue }
            hidden.append(s)
        }
        #expect(hidden.count > 300)
        for s in hidden {
            let c = String(Character(s))
            for text in ["ls\(c) -la", "echo \"a\(c)b\"", "ls # \(c)"] {
                let a = CC.assess(text)
                #expect(a.commandClass == .blocked, "\(CommandCharacterPolicy.codePoint(s)) is B1")
                #expect(a.flags.contains { $0.rule == .b1 })
            }
        }
    }

    @Test func b1PolicyMatchesTheSpecsList() {
        let named: [UInt32] = [0x0000, 0x001B, 0x007F, 0x0085, 0x00AD, 0x061C, 0x200E, 0x200F, 0x202A, 0x202E, 0x2066,
                               0x2069, 0x200B, 0x200C, 0x200D, 0x2060, 0x2064, 0xFEFF, 0xE0001, 0xE0020, 0xE007F, 0x034F,
                               0x115F, 0x1160, 0x17B4, 0x17B5, 0x180B, 0x180F, 0x3164, 0xFE00, 0xFE0F, 0xFFA0, 0xE0100,
                               0xE01EF, 0x2028, 0x2029, 0x00A0, 0x1680, 0x2000, 0x200A, 0x202F, 0x205F, 0x3000, 0x000D]
        for v in named {
            #expect(Unicode.Scalar(v).map(CommandCharacterPolicy.isHidden) == true, "U+\(String(v, radix: 16)) is B1")
        }
        let allowed: [UInt32] = [0x09, 0x0A, 0x20, 0x41, 0xE9, 0xDC, 0x65E5, 0x1F642, 0x2705, 0x2026, 0x0441, 0xFF52, 0x2010]
        for v in allowed {
            #expect(Unicode.Scalar(v).map(CommandCharacterPolicy.isHidden) == false, "U+\(String(v, radix: 16)) is not B1")
        }
    }

    @Test func thePublicPredicateAgreesWithB1OnTheVectors() {
        for vector in ShellVectors.hiddenCharacters {
            let hasHidden = vector.text.unicodeScalars.contains(where: CommandClassifier.isHiddenCharacter)
            #expect(hasHidden == vector.mustHave.contains(.b1), "\(vector.name)")
            let flagged = CommandClassifier.assess(text: vector.text, context: vector.context).flags.contains { $0.rule == .b1 }
            #expect(hasHidden == flagged, "\(vector.name)")
        }
        // The same predicate drives Copy cleaned.
        for vector in ShellVectors.hiddenCharacters {
            let cleaned = CommandClassifier.cleanedText(vector.text)
            #expect(!cleaned.text.unicodeScalars.contains(where: CommandClassifier.isHiddenCharacter))
            #expect(cleaned.removals.count == vector.text.unicodeScalars.filter(CommandClassifier.isHiddenCharacter).count)
        }
    }

    @Test func b1FlagsPointAtEachCharacterAndShowItEscaped() {
        let a = CC.assess("echo a\u{202E}b\u{200B}c")
        let b1 = a.flags.filter { $0.rule == .b1 }
        #expect(b1.map(\.utf16Range) == [6..<7, 8..<9])
        #expect(b1.first?.words == "Hidden or deceptive character ⟨U+202E⟩ RIGHT-TO-LEFT OVERRIDE")
        #expect(b1.allSatisfy { $0.segment == nil })
        // A flood of hidden characters stays a bounded list.
        let flood = CC.assess("echo " + String(repeating: "\u{200B}", count: 300))
        #expect(flood.flags.filter { $0.rule == .b1 }.count == 65)
    }

    @Test func allowedNonASCIIIsNotedWithItsCodePoint() {
        let n = CC.notes("mkdir \"Résumé\" && open ~/Documents/café.pdf")
        let note = n.first { $0.kind == .nonASCII }?.words ?? ""
        #expect(note.contains("é (U+00E9) in line 1"))
        #expect(!CC.rules("mkdir \"Übersicht\"").contains(.b2))
        #expect(CC.assess("open ~/Documents/Résumé.pdf").commandClass == .notFlagged)
    }

    // MARK: B2

    @Test func b2LookAlikesInProgramOptionHostAndUser() {
        for text in ["\u{0441}url x", "\"\u{0441}url\" x", "/usr/bin/c\u{0443}rl x", "sudo r\u{043C} x", "xargs \u{0441}at",
                     "ls \u{2212}la", "ls -l\u{0430}", "rm \"\u{2014}rf\" x", "ssh b\u{043E}x1", "scp a b\u{043E}x1:/tmp/",
                     "curl https://\u{0430}pi.acme.test/", "git clone https://g\u{0456}thub.com/x/y", "ssh r\u{043E}ot@box1",
                     "ssh box1 \u{0441}url x", "echo \"$(\u{0441}url x)\""] {
            let a = CC.assess(text)
            #expect(a.flags.contains { $0.rule == .b2 }, "B2 expected")
            #expect(a.commandClass == .blocked)
            #expect(!a.copyAllowed)
        }
        for text in ["echo \"\u{0441}url\"", "echo — done", "echo \"— quote\"", "git commit -m \"Übersicht\"",
                     "touch Résumé.txt"] {
            #expect(!CC.rules(text).contains(.b2), "no B2 expected")
        }
        // B2 comes before the host is compared with the server: never Fetch file, never R17.
        let a = CC.assess("scp b\u{043E}x1:/srv/a.pdf ~/Downloads/", .ssh)
        #expect(a.commandClass == .blocked)
        #expect(a.fetch == nil)
        #expect(!a.flags.contains { $0.rule == .r17 })
    }

    // MARK: B3

    @Test func b3ForEverythingOutsideTheLanguageWithItsReason() {
        let a = CC.assess("echo ${x:t}")
        #expect(a.commandClass == .blocked)
        let flag = a.flags.first { $0.rule == .b3 }
        #expect(flag?.words.hasPrefix("Pitbox can't read this shell syntax (") == true)
        #expect(flag?.words.hasSuffix("; use Copy") == true)
        #expect(flag?.utf16Range == 5..<10)          // `${x:t`
        #expect(a.segments.isEmpty)
        #expect(a.machine == .unclear)
        // Unknown wrapper options are B3: the program cannot be found without guessing.
        for text in ["sudo -X rm -rf ~", "env --frobnicate rm x", "nice --what rm x", "xargs -Q rm", "watch --nope ls",
                     "command -x rm", "timeout --bogus 5 rm x", "arch -what rm x"] {
            #expect(CC.rules(text).contains(.b3), "B3 expected")
        }
        // Not accepted after a wrapper either.
        for text in ["builtin setopt x", "command alias x=y", "exec noglob ls", "sudo trap x INT"] {
            #expect(CC.rules(text).contains(.b3), "B3 expected")
        }
        // Inside nested scripts.
        for text in ["sh -c 'echo ${x:h}'", "ssh box1 'echo \"abc'", "eval 'f() { :; }'", "bash <<'EOF'\nalias x=y\nEOF"] {
            #expect(CC.rules(text).contains(.b3), "B3 expected")
        }
    }

    @Test func b3NestedScriptsHaveTheirOwnDepthLimit() {
        #expect(CC.rules(String(repeating: "eval ", count: 12) + "ls").contains(.b3))
        #expect(!CC.rules("eval eval eval ls").contains(.b3))
        #expect(CC.rules("sh -c \"sh -c 'sh -c ls'\"").contains(.r18))
        #expect(!CC.rules("sh -c \"sh -c 'sh -c ls'\"").contains(.b3))
        var finds = "ls"
        for _ in 0..<20 { finds = "find . -exec " + finds + " \\;" }
        #expect(CC.assess(finds).commandClass == .blocked)
    }

    // MARK: B4

    @Test func b4AtAndOverTheLimits() {
        let forty = Array(repeating: "echo x", count: 40).joined(separator: "\n")
        #expect(!CC.rules(forty).contains(.b4))
        #expect(CC.rules(forty + "\necho x").contains(.b4))
        #expect(!CC.rules(forty + "\n").contains(.b4))        // a trailing newline starts no line
        #expect(!CC.rules("echo " + String(repeating: "a", count: 495)).contains(.b4))
        #expect(CC.rules("echo " + String(repeating: "a", count: 496)).contains(.b4))
        let long = String(repeating: "echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n", count: 45)
        #expect(CC.rules(long).contains(.b4))
        let fourThousand = String(repeating: String(repeating: "a", count: 399) + "\n", count: 10)
        #expect(fourThousand.unicodeScalars.count == 4_000)
        #expect(!CC.rules(fourThousand).contains(.b4))
        #expect(CC.rules(fourThousand + "a").contains(.b4))
        // Characters are Unicode scalars, not bytes and not UTF-16 units.
        let emoji = String(repeating: String(repeating: "\u{1F642}", count: 399) + "\n", count: 10)
        #expect(!CC.rules(emoji).contains(.b4))
        // The token limit (B4) inside the character limits.
        #expect(CC.rules((0..<5).map { _ in String(repeating: "a;", count: 250) }.joined(separator: "\n")).contains(.b4))
        // A huge text is refused quickly and still checked for hidden characters.
        let huge = String(repeating: "a", count: 200_000) + "\u{202E}"
        let start = Date()
        let a = CC.assess(huge)
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(a.flags.contains { $0.rule == .b4 })
        #expect(a.flags.contains { $0.rule == .b1 })
    }

    // MARK: B5

    @Test func b5DecodedTextRunAsCode() {
        for text in ["echo bHM= | base64 -d | bash -s", "base64 --decode < x | sh", "gunzip -c x.gz | sh", "zcat x.gz | bash",
                     "xxd -r -p x | sudo sh", "eval \"$(base64 -D < x)\"", "sh -c \"$(echo x | base64 -d)\"",
                     "source <(base64 -d x)", "printf '\\101\\102' | sh", "echo '\\x6c\\x73' | zsh", "rev x | sh",
                     "python3 <(base64 -d x)", "base64 -d x | tee y | sh"] {
            #expect(CC.rules(text).contains(.b5), "B5 expected")
        }
        for text in ["base64 -d x > y", "echo x | base64 -d | wc -c", "gunzip x.gz", "printf 'a\\n' | sh", "rev x"] {
            #expect(!CC.rules(text).contains(.b5), "no B5 expected")
        }
    }

    // MARK: B6

    @Test func b6KnownDestroyers() {
        for text in ["rm -r ~", "rm -rf ~/*", "rm -rf ~/Library", "rm -rf /System", "rm -rf /Users/someone/*",
                     "rm -rf {~,x}", "rm -rf ~/{Library,x}", "X=/; rm -rf $X", "for d in / x; do rm -rf $d; done",
                     "rm -rf $1", "rm -rf \"${HOME:?}\"", "rm -rf \"$DIR\"/*", "rm -rf ../", "cd ~ && rm -rf ./*",
                     "rm -rf `pwd`", "sudo -u x rm -rf --no-preserve-root /", "xargs rm -rf ~", "sh -c 'rm -rf ~'",
                     "dd if=x of=/dev/rdisk9", "echo x > /dev/disk0s1", "diskutil eraseVolume APFS X /",
                     "diskutil zeroDisk disk0", "chmod -R 777 /", ":(){ :|:& };:", "bomb() { bomb | bomb & }; bomb",
                     "rm -rf ."] {
            let a = CC.assess(text)
            #expect(a.flags.contains { $0.rule == .b6 }, "B6 expected")
            #expect(a.commandClass == .blocked)
            #expect(a.copyAllowed)
        }
        for text in ["rm -rf ~/x/y", "rm -rf /tmp", "rm -rf \"${DIR:?}/\"", "rm -f ~", "rm -rf ./build",
                     "rm -rf \"$DIR\"/build", "DIR=build; rm -rf \"$DIR\"", "rm -rf ~/Library/Caches/x",
                     "dd if=/dev/zero of=x.img", "diskutil eraseDisk APFS X disk7", "chmod -R 700 ~/x",
                     "find ~ -name x -delete", "xargs -I{} rm -rf {}", "echo rm -rf /"] {
            #expect(!CC.rules(text).contains(.b6), "no B6 expected")
        }
        #expect(CC.words("rm -rf ~", .b6) == ["Known destroyer: deletes everything in ~"])
        #expect(CC.words("rm -rf \"$DIR\"", .b6) == ["Known destroyer: deletes everything in whatever `\"$DIR\"` holds when it runs"])
    }
}
