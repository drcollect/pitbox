import Foundation
import Testing
@testable import PitboxKit

// Which machine a command is for (docs/SHELL_LANGUAGE.md §4.1): every rule in order, local, SSH and unknown sessions,
// claims, reasons and the per-segment machine. The SSH session here is `box1`
// (HostName 203.0.113.5, serverNames box1.internal.test, remote cwd /home/box1/app).

@Suite struct CommandClassifierMachineTests {
    private func machine(_ text: String, _ place: CommandSessionFacts.Place, caption: String? = nil) -> CommandMachine {
        CC.assess(text, place, caption: caption).machine
    }

    // MARK: Rule 1

    @Test func rule1SendsACommandToAnotherMachineFromEveryPlace() {
        for place in [CommandSessionFacts.Place.local, .ssh, .unknown] {
            #expect(machine("ssh box1 uptime", place) == .remote(host: "box1"))
            #expect(machine("ssh -t admin@box1 'sudo ls'", place) == .remote(host: "box1"))
            #expect(machine("ssh ssh://admin@box1:2222 ls", place) == .remote(host: "box1"))
            #expect(machine("ssh -o RemoteCommand=ls box1", place) == .remote(host: "box1"))
            #expect(machine("ssh box1 < run.sh", place) == .remote(host: "box1"))
            #expect(machine("printf 'ls\\n' | ssh box1", place) == .remote(host: "box1"))
            #expect(machine("ssh box1 <<< 'ls'", place) == .remote(host: "box1"))
            #expect(machine("ssh build-host -- ls", place) == .remote(host: "build-host"))
            #expect(machine("autossh -M 0 -f box1 ls", place) == .remote(host: "box1"))
            #expect(machine("mosh --ssh='ssh -p 2' box1 -- htop", place) == .remote(host: "box1"))
            #expect(machine("echo \"$(ssh box1 hostname)\"", place) == .remote(host: "box1"))
        }
        let a = CC.assess("ssh box1 'rm -rf /srv/x'")
        #expect(a.machineReason == "Runs on box1: it sends a command there.")
        #expect(a.flags.first { $0.rule == .r2 }?.words == "Deletes files and folders; not to the Trash: /srv/x (on box1)")
        #expect(a.segments.first?.machine == .remote(host: "box1"))
        #expect(a.commandClass == .otherMachine)
        #expect(a.flags.contains { $0.rule == .r2 })
    }

    @Test func sshAloneAndOptionsAreMacCommands() {
        for place in [CommandSessionFacts.Place.local, .ssh] {
            #expect(machine("ssh box1", place) == .thisMac)
            #expect(machine("ssh -v -p 2222 -i ~/.ssh/k -L 8080:localhost:80 box1", place) == .thisMac)
            #expect(machine("ssh -N -D 1080 box1", place) == .thisMac)
            #expect(machine("ssh -W localhost:22 box1", place) == .thisMac)
            #expect(machine("ssh -n box1 < /dev/null", place) == .thisMac)
        }
        #expect(CC.assess("ssh box1", .ssh).machineReason == "For this Mac: it opens a shell on box1.")
    }

    // MARK: Rule 2

    @Test func rule2ATransferNamingTheServerIsForThisMac() {
        for text in ["scp box1:/srv/a.tgz ~/Desktop/", "scp 203.0.113.5:a .", "rsync -a box1.internal.test:/x/ y/",
                     "scp BOX1:a b", "sftp box1:/srv/x", "scp ./a box1:/tmp/", "rsync -av --exclude x box1:$DIR ./"] {
            #expect(machine(text, .ssh) == .thisMac, "for this Mac")
        }
        #expect(CC.assess("scp box1:/srv/a.tgz ~/Desktop/", .ssh).machineReason == "For this Mac: it copies from box1.")
        #expect(CC.assess("scp a box1:/tmp/", .ssh).machineReason == "For this Mac: it copies to box1.")
        // The remote path is never a path hint (/srv/ would point to the server).
        #expect(machine("scp box1:/srv/x/report.pdf .", .ssh) == .thisMac)
        // Another host falls to the path rules.
        #expect(machine("scp build-host:x ~/Downloads/", .ssh) == .unclear)
        #expect(machine("scp build-host:x y", .ssh) == .unclear)
    }

    // MARK: Rules 3 and 4 in an SSH session

    @Test func rules3And4InAnSSHSession() {
        #expect(machine("pbpaste | wc -l", .ssh) == .thisMac)
        #expect(machine("osascript -e 'beep'", .ssh) == .thisMac)
        #expect(machine("caffeinate -i make", .ssh) == .thisMac)
        #expect(machine("journalctl -fu app", .ssh) == .server)
        #expect(machine("sudo ufw allow 22", .ssh) == .server)
        #expect(CC.assess("systemctl restart app", .ssh).machineReason == "For the server: it uses systemctl, a Linux program.")
        // Conflicts are unclear.
        #expect(machine("open /srv/x.pdf", .ssh) == .unclear)
        #expect(machine("pbcopy < /etc/hosts", .ssh) == .unclear)
        #expect(machine("systemctl status x > ~/Desktop/s.txt", .ssh) == .unclear)
        #expect(machine("scp box1:x . && apt list", .ssh) == .unclear)
        // Path hints alone never decide.
        #expect(machine("cat /etc/hosts", .ssh) == .unclear)
        #expect(machine("ls /home/box1/app", .ssh) == .unclear)
        #expect(machine("ls /home/box1/app/src", .ssh) == .unclear)
        #expect(machine("cd /srv/app", .ssh) == .unclear)
        #expect(machine("ls ~/Downloads ~/Documents", .ssh) == .unclear)
        #expect(machine("ls \"$HOME/Desktop\"", .ssh) == .unclear)
        #expect(machine("ls /opt/homebrew/bin", .ssh) == .unclear)
        #expect(CC.assess("ls ~/Downloads", .ssh).machineReason == "Unclear: it names ~/Downloads, so probably this Mac.")
        #expect(CC.assess("ls /srv/x", .ssh).machineReason == "Unclear: it names /srv/x, so probably the server.")
        #expect(CC.assess("make", .ssh).machineReason == "Unclear: nothing in it says which machine.")
        // A URL and options are not paths.
        #expect(machine("curl https://acme.test/srv/x", .ssh) == .unclear)
        #expect(machine("brew install --prefix=/srv/x jq", .ssh) == .thisMac)
    }

    @Test func localAndUnknownSessions() {
        for text in ["systemctl restart x", "ls /srv/x", "apt-get install jq", "cat /home/x/y", "ls"] {
            #expect(machine(text, .local) == .thisMac)
            #expect(machine(text, .unknown) == .unclear)
        }
        #expect(CC.assess("ls", .local).machineReason == "For this Mac: the session runs on this Mac.")
        #expect(CC.assess("ls", .unknown).machineReason == "Unclear: Pitbox couldn't tell where the session runs.")
        #expect(CC.assess("open x.pdf", .unknown).commandClass == .unclearMachine)
    }

    // MARK: Claims

    @Test func claimsAreShownAndOnlyEverMakeItUnclear() {
        let agrees = CC.assess("open x.pdf", .ssh, caption: "Open it on your Mac:")
        #expect(agrees.machine == .thisMac)
        #expect(agrees.replyClaim == "on your Mac")
        #expect(agrees.notes.contains { $0.kind == .replyClaim && $0.words == "The reply says: “on your Mac”" })
        let contradicts = CC.assess("open x.pdf", .ssh, caption: "Run this on box1:")
        #expect(contradicts.machine == .unclear)
        #expect(contradicts.machineReason.hasPrefix("Unclear: the reply says “on box1”, but for this Mac"))
        #expect(machine("systemctl restart x", .ssh, caption: "Locally, run:") == .unclear)
        #expect(machine("systemctl restart x", .ssh, caption: "On the server:") == .server)
        #expect(machine("ls", .ssh, caption: "on your Mac") == .unclear)
        #expect(machine("ls", .local, caption: "Run this on the box:") == .unclear)
        #expect(machine("ls", .local, caption: "Run this on the boxes:") == .thisMac)  // whole words only
        #expect(machine("# run on your Mac\nopen x.pdf", .ssh) == .thisMac)
        #expect(machine("# on the server\nopen x.pdf", .ssh) == .unclear)
        #expect(CC.assess("ls # on box1.internal.test", .ssh).replyClaim == "on box1.internal.test")
        // A claim never makes something run elsewhere, and never overrides rule 1.
        #expect(machine("ssh box1 ls", .local, caption: "on your Mac") == .remote(host: "box1"))
        #expect(CC.assess("ls", .local).replyClaim == nil)
        // A claim inside quotes or a here-doc is not a comment.
        #expect(CC.assess("echo '# on the server'", .local).machine == .thisMac)
    }

    @Test func segmentsCarryTheirOwnMachine() {
        let a = CC.assess("scp box1:a . && ssh box1 'rm a'", .ssh)
        #expect(a.machine == .remote(host: "box1"))
        #expect(a.segments.map(\.machine) == [.thisMac, .remote(host: "box1")])
        #expect(a.commandClass == .otherMachine)
    }
}
