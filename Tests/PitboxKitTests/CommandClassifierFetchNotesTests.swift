import Foundation
import Testing
@testable import PitboxKit

// Fetch file, the grey notes and Needs editing.

@Suite struct CommandClassifierFetchNotesTests {
    // MARK: Fetch file

    @Test func fetchShapesThatMatch() {
        let cases: [(String, FetchFileRequest)] = [
            ("scp box1:/srv/a.pdf ~/Downloads/", FetchFileRequest(alias: "box1", replyUser: nil, remotePath: "/srv/a.pdf", destinationName: nil)),
            ("scp -pqCv deploy@box1:app/log.txt ~/Downloads", FetchFileRequest(alias: "box1", replyUser: "deploy", remotePath: "app/log.txt", destinationName: nil)),
            ("scp 203.0.113.5:a.txt \"$HOME/Downloads/b.txt\"", FetchFileRequest(alias: "box1", replyUser: nil, remotePath: "a.txt", destinationName: "b.txt")),
            ("scp box1.internal.test:a ${HOME}/Downloads/", FetchFileRequest(alias: "box1", replyUser: nil, remotePath: "a", destinationName: nil)),
            ("rsync -avzhtP --partial box1:~/r.csv /Users/someone/Downloads/", FetchFileRequest(alias: "box1", replyUser: nil, remotePath: "~/r.csv", destinationName: nil)),
            ("scp 'box1:/srv/My Report.pdf' ~/Downloads/", FetchFileRequest(alias: "box1", replyUser: nil, remotePath: "/srv/My Report.pdf", destinationName: nil)),
        ]
        for (text, expected) in cases {
            let a = CC.assess(text, .ssh)
            #expect(a.commandClass == .fetchFile, "a Fetch file shape")
            #expect(a.fetch == expected)
            #expect(a.machine == .thisMac)
            #expect(a.notes.contains { $0.kind == .fetchShape })
            #expect(!a.notes.contains { $0.kind == .notQuarantined })
        }
        #expect(CC.assess("scp box1:/srv/a.pdf ~/Downloads/", .ssh).notes.contains { $0.words == "Copies a.pdf from box1 into Downloads" })
        // R20 stays a flag on a Fetch file shape (A7).
        let task = CC.assess("scp box1:/srv/a.pdf ~/Downloads/", .ssh, origin: .taskNotification)
        #expect(task.commandClass == .fetchFile)
        #expect(task.flags.contains { $0.rule == .r20 })
    }

    @Test func fetchNearMissesAreOrdinaryCommands() {
        for text in ["scp -l 100 box1:a ~/Downloads/", "scp -3 box1:a ~/Downloads/", "rsync -avr box1:a ~/Downloads/",
                     "rsync --delete box1:a ~/Downloads/", "scp box1:a ~/Downloads/x/y", "scp box1:a \"~/Downloads/\"",
                     "scp box1:a ~/downloads2/", "scp box1:a $DEST", "scp box1:~ ~/Downloads/", "scp box1:a/../b ~/Downloads/",
                     "scp box1:'a;b' ~/Downloads/", "scp box1:a ~/Downloads/ &", "FOO=1 scp box1:a ~/Downloads/",
                     "sudo scp box1:a ~/Downloads/", "scp box1:a ~/Downloads/ 2>/dev/null", "scp box1:a{b,c} ~/Downloads/",
                     "scp -- box1:a ~/Downloads/", "scp \"box1:$(cat f)\" ~/Downloads/", "scp ROOT@box1:a ~/Downloads/",
                     "scp box1:\(String(repeating: "a", count: 1025)) ~/Downloads/", "/usr/bin/scp box1:a ~/Downloads/ ; ls"] {
            let a = CC.assess(text, .ssh)
            #expect(a.commandClass != .fetchFile, "not a Fetch file shape")
            #expect(a.fetch == nil)
        }
        // Not from local or unknown sessions, and not without an alias.
        #expect(CC.assess("scp box1:a ~/Downloads/", .local).commandClass == .notFlagged)
        #expect(CC.assess("scp box1:a ~/Downloads/", .local).notes.contains { $0.kind == .notQuarantined })
        #expect(CC.assess("scp box1:a ~/Downloads/", .unknown).commandClass == .unclearMachine)
        var noAlias = CC.facts(.ssh)
        noAlias.sshAlias = nil
        let a = CommandClassifier.assess(text: "scp box1:a ~/Downloads/", context: CommandContext(facts: noAlias))
        #expect(a.commandClass != .fetchFile)
    }

    // MARK: Notes

    @Test func notesOfSection810() {
        func kinds(_ text: String, _ place: CommandSessionFacts.Place = .local) -> Set<CommandNote.Kind> {
            Set(CC.notes(text, place).map(\.kind))
        }
        #expect(CC.assess("ls", web: true).notes.first?.kind == .readWeb)
        #expect(kinds("curl -s https://api.acme.test/x").contains(.connects))
        #expect(CC.notes("ssh box1").contains { $0.words == "Connects to box1" })
        #expect(kinds("echo x > out.txt").contains(.writes))
        #expect(kinds("rm a").contains(.deletes))
        #expect(CC.notes("ls\npwd").contains { $0.words == "Runs 2 commands; later lines run even if one fails" })
        #expect(CC.notes("ls && pwd").contains { $0.words == "Runs 2 commands" })
        #expect(kinds("read -r \"?Name: \" n").contains(.asksValue))
        #expect(kinds("read -rs pw").contains(.asksSecret))
        #expect(kinds("sudo ls").contains(.asksSecret))
        #expect(kinds("security add-generic-password -U -a \"$USER\" -s K -w").contains(.storesKeychainItem))
        #expect(kinds("K=\"$(security find-generic-password -s K -w)\" tool").contains(.readsKeychainItem))
        #expect(kinds("git fetch").contains(.usesSSHAgent))
        #expect(kinds("scp box1:a .").contains(.notQuarantined))
        #expect(kinds("curl -o x.zip https://acme.test/x.zip").contains(.notQuarantined))
        #expect(kinds("brew install jq").contains(.homebrew))
        #expect(kinds("tail -f log").contains(.keepsRunning))
        #expect(kinds("watch -n 1 date").contains(.keepsRunning))
        #expect(kinds("top").contains(.keepsRunning))
        #expect(CC.notes("open https://acme.test/docs").contains { $0.words == "Opens acme.test" })
        #expect(CC.notes("echo $NAME").contains { $0.words == "Uses $NAME, filled in when it runs" })
        #expect(!CC.notes("echo $HOME").contains { $0.kind == .usesVariable })
        #expect(!CC.notes("X=1; echo $X").contains { $0.kind == .usesVariable })
        #expect(CC.notes("ls *.md").contains { $0.words == "Uses `*.md`, expanded when it runs" })
        #expect(kinds("echo {a,b}").contains(.usesGlob))
        #expect(!kinds("echo '*'").contains(.usesGlob))
        #expect(kinds("echo \"café\"").contains(.nonASCII))
        #expect(kinds("ls").contains(.cleanShell))
        // Notes never change the class.
        #expect(CC.assess("echo x > out.txt").commandClass == .notFlagged)
        #expect(CC.assess("ls\npwd").commandClass == .notFlagged)
        // readWeb comes first.
        let n = CC.assess("ssh box1", web: true).notes
        #expect(n.first?.kind == .readWeb)
    }

    // MARK: Needs editing

    @Test func placeholders() {
        let cases: [(String, String)] = [
            ("ssh <server>", "<server>"), ("curl -H \"X-Key: <api-key>\" https://acme.test/", "<api-key>"),
            ("export K=YOUR_API_KEY", "YOUR_API_KEY"), ("cd /path/to/repo", "/path/to/"), ("ssh username@hostname", "username@hostname"),
            ("curl https://api.example.com/x", "api.example.com"), ("echo TODO", "TODO"), ("cp [file] x", "[file]"),
            ("ls ~/…/x", "…"), ("cp your_file_here.txt x", "your_file_here"), ("git push origin [your-branch]", "[your-branch]"),
        ]
        for (text, expected) in cases {
            let a = CC.assess(text)
            #expect(a.commandClass == .needsEditing, "needs editing")
            #expect(a.placeholder == expected)
        }
        // Placeholders keep their red lines; blocks still win.
        #expect(CC.assess("sudo rm -rf <dir>").flags.contains { $0.rule == .r1 })
        #expect(CC.assess("rm -rf <dir> /").commandClass == .blocked)
        // Not placeholders.
        for text in ["cat < in.txt > out.txt", "diff <(a) <(b)", "echo \"<b>bold</b>\"", "cat <<EOF\n<key>Label</key>\nEOF",
                     "git commit -m \"TODO list\"", "# TODO: later\nls", "echo $((1<2))", "ls [abc]*", "[ -f x ] && ls",
                     "sort <file.txt", "ssh 203.0.113.5"] {
            #expect(CC.assess(text, .ssh).placeholder == nil, "no placeholder")
        }
    }
}
