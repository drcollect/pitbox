import Foundation
import Testing
@testable import PitboxConsole

/// The grammars and name rules for SSH aliases, Fetch file shapes and names in Downloads, as the runner applies them
/// itself.
struct FetchNamesTests {
    @Test func aliasesFollowTheGrammarWithoutALeadingDash() {
        for alias in ["buildbox", "my.server-1", "A_b", "box2", String(repeating: "a", count: 64)] {
            #expect(FetchNames.isValidAlias(alias), "\(alias)")
        }
        for alias in ["", "-oProxyCommand=x", "-x", "con ductor", "cönductor", String(repeating: "a", count: 65),
                      "a/b", "a:b", "user@host", "*", "con*", "!buildbox", "c\u{0}d", "buildbox\n"] {
            #expect(!FetchNames.isValidAlias(alias), "\(alias.debugDescription)")
        }
    }

    @Test func replyUsersFollowTheStrictGrammar() {
        for user in ["alex", "_x", "a-b_c9", "buildbox", String(repeating: "a", count: 32)] {
            #expect(FetchNames.isValidReplyUser(user), "\(user)")
        }
        for user in ["", "Alex", "9x", "-x", "al.ex", "älex", "a b", "a@b", String(repeating: "a", count: 33)] {
            #expect(!FetchNames.isValidReplyUser(user), "\(user)")
        }
    }

    @Test func theConfigsUserOnlyHasToKeepTheOperandUnambiguous() {
        for user in ["buildbox", "first.last", "Alex", "a_b-c"] {
            #expect(FetchNames.isUsableConfigUser(user), "\(user)")
        }
        for user in ["", "-x", "a@b", "a:b", "a b", "a/b", "ä", "a'b", "a\"b", "a$b", String(repeating: "a", count: 65)] {
            #expect(!FetchNames.isUsableConfigUser(user), "\(user)")
        }
    }

    @Test func remotePathsAreOneFileWithoutGlobsOrParentParts() {
        for path in ["/home/alex/drafts/release-notes.md", "~/drafts/x.md", "drafts/x.md", "x.md", "/srv/a b/c d.md",
                     "/home/x/-w.md", "/home/über/x.md", "/a/./b.md", String(repeating: "a", count: 1_024)] {
            #expect(FetchNames.isAcceptableRemotePath(path), "\(path)")
        }
        for path in ["", "/home/x/", "~", "~/", "~root/x.md", "../x.md", "/home/../etc/passwd", "a/..", "*.md",
                     "/home/x/?.md", "/home/[ab].md", "/home/{a,b}.md", "/home/x\\y.md", "/home/$USER/x.md",
                     "/home/`id`.md", "/home/x\u{202E}dm.exe", "/home/x\u{200B}.md", "/home/x\n.md", "/home/x\u{0}.md",
                     "/home/x/.", "/home/\u{E000}.md", String(repeating: "a", count: 1_025)] {
            #expect(!FetchNames.isAcceptableRemotePath(path), "\(path.debugDescription)")
        }
    }

    @Test func theBaseNameIsTheLastPart() {
        #expect(FetchNames.baseName(ofRemotePath: "/home/alex/drafts/release-notes.md") == "release-notes.md")
        #expect(FetchNames.baseName(ofRemotePath: "~/x.md") == "x.md")
        #expect(FetchNames.baseName(ofRemotePath: "x.md") == "x.md")
        #expect(FetchNames.baseName(ofRemotePath: "/home/x/") == nil)
    }

    @Test func plainNamesAreAccepted() {
        for name in ["release-notes.md", "My Draft.md", "archive.tar.gz", "install.sh", "README", "a.b.c", "photo.jpg",
                     "report (final).pdf", "x_1.csv", String(repeating: "a", count: 200)] {
            #expect(FetchNames.isAcceptableFileName(name), "\(name)")
        }
    }

    @Test func deceptiveNamesAreRefusedNotRepaired() {
        let refused = ["", ".zshrc", "..", "-rf.md", " lead.md", "trail.md ", "a/b.md", "a:b.md", "../x.md",
                       String(repeating: "a", count: 201), "report.pdf.command", "notes.md.app", "NOTES.MD.APP",
                       "photo.jpg .app", "invoice.pdf.scpt", "doc.docx.pkg", "sheet.xlsx.terminal", "a.txt.sh",
                       "movie.mp4.dmg", "x.pdf..command",
                       "r\u{0435}port.pdf",          // Cyrillic е: B2
                       "\u{FF52}eport.pdf",          // fullwidth ｒ: B2
                       "café.md", "naïve.txt"]       // any non-ASCII is B2 in a file name
        for name in refused {
            #expect(!FetchNames.isAcceptableFileName(name), "\(name.debugDescription)")
        }
    }

    @Test func everyB1CharacterIsRefusedInANameAndAPath() {
        let samples: [UInt32] = [0x0009, 0x000A, 0x000D, 0x001B, 0x007F, 0x0085, 0x00A0, 0x00AD, 0x034F, 0x061C, 0x115F,
                                 0x1160, 0x1680, 0x17B4, 0x17B5, 0x180B, 0x180E, 0x180F, 0x2000, 0x2007, 0x200A, 0x200B,
                                 0x200E, 0x200F, 0x2028, 0x2029, 0x202A, 0x202E, 0x202F, 0x205F, 0x2066, 0x2069, 0x3000,
                                 0x3164, 0xFE00, 0xFE0F, 0xFEFF, 0xFFA0, 0xE0001, 0xE0041, 0xE007F, 0xE0100, 0xE01EF]
        for value in samples {
            guard let scalar = Unicode.Scalar(value) else { Issue.record("U+\(String(value, radix: 16))"); continue }
            #expect(FetchNames.isB1(scalar), "U+\(String(value, radix: 16, uppercase: true))")
            let text = "re\(Character(scalar))port"
            #expect(!FetchNames.isAcceptableFileName(text + ".pdf"), "U+\(String(value, radix: 16, uppercase: true))")
            #expect(!FetchNames.isAcceptableRemotePath("/home/" + text + ".pdf"), "U+\(String(value, radix: 16, uppercase: true))")
        }
        for allowed in ["a", " ", "é", "-", "~"] {
            #expect(!FetchNames.isB1(allowed.unicodeScalars.first!), "\(allowed)")
        }
    }

    /// The policy is built from the system's Unicode data, so it is checked over every scalar: whatever is Cc, Cf, Zl,
    /// Zp, a space other than U+0020 or Default_Ignorable is B1, and nothing else.
    @Test func theB1PolicyFollowsTheUnicodeDataForEveryScalar() {
        var count = 0
        for value in UInt32(0)...0x10FFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            let properties = scalar.properties
            let expected: Bool
            switch properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: expected = true
            case .spaceSeparator: expected = value != 0x20
            default: expected = properties.isDefaultIgnorableCodePoint
            }
            if expected { count += 1 }
            if FetchNames.isB1(scalar) != expected { Issue.record("U+\(String(value, radix: 16))"); return }
        }
        #expect(count > 400, "Cc, Cf, the spaces and the default-ignorables (variation selectors, tags) together")
    }

    @Test func aHiddenTypeNeedsADocumentLookAndAnAppOrScriptEnd() {
        #expect(FetchNames.hidesItsType("x.pdf.command"))
        #expect(FetchNames.hidesItsType("x.MD.App"))
        #expect(!FetchNames.hidesItsType("x.command"), "one extension hides nothing; the sheet shows it")
        #expect(!FetchNames.hidesItsType("x.tar.gz"))
        #expect(!FetchNames.hidesItsType("setup.v2.sh"))
    }

    @Test func freeNamesAreNumberedLikeFinderCopies() {
        let names = FetchNames.candidates(for: "release-notes.md")
        #expect(names.count == 99)
        #expect(names.prefix(3) == ["release-notes.md", "release-notes 2.md", "release-notes 3.md"])
        #expect(names.last == "release-notes 99.md")
        #expect(FetchNames.candidates(for: "README").dropFirst().first == "README 2")
        #expect(FetchNames.candidates(for: "archive.tar.gz").dropFirst().first == "archive.tar 2.gz")
    }
}
