import Darwin
import Foundation
import Testing
@testable import PitboxConsole

/// Reading how scp ended, from the lines a real scp and ssh printed on this Mac.
struct FetchFailureTests {
    private let staging = "/Users/x/Library/Caches/Pitbox/fetch/fetch-0123"

    private func reason(_ stderr: String, _ exit: ProcessExit = .exited(255)) -> FetchFailure {
        FetchFailure.classify(exit: exit, stderr: stderr, stagingFolder: staging)
    }

    @Test func measuredLinesMapToTheirReasons() {
        #expect(reason("alex@192.0.2.10: Permission denied (publickey).\n/usr/bin/scp: Connection closed") == .keyRejected)
        #expect(reason("alex@192.0.2.10: Permission denied (publickey,password).") == .password)
        #expect(reason("Host key verification failed.\n/usr/bin/scp: Connection closed") == .hostKey)
        #expect(reason("Received disconnect from 192.0.2.10 port 22:2: Too many authentication failures") == .keyRejected)
        #expect(reason("/usr/bin/scp: /srv/x.md: No such file or directory", .exited(1)) == .noSuchFile)
        #expect(reason("/usr/bin/scp: remote open \"/srv/x.md\": Permission denied", .exited(1)) == .noPermission)
        #expect(reason("/usr/bin/scp: download /srv/dir/: not a regular file", .exited(1)) == .notAFile)
        #expect(reason("/usr/bin/scp: Connection closed") == .connectFailed)
        #expect(reason("", .signaled(SIGXFSZ)) == .tooLarge)
        #expect(reason("", .exited(1)) == .scpFailed)
    }

    @Test func aRemotePathCannotPoseAsAnSshLine() {
        // The remote path is the reply's text; scp prints it inside its own prefixed line.
        #expect(reason("/usr/bin/scp: /srv/Permission denied (publickey).md: No such file or directory", .exited(1)) == .noSuchFile)
        #expect(reason("/usr/bin/scp: /srv/Host key verification failed.md: No such file or directory", .exited(1)) == .noSuchFile)
        #expect(reason("scp: /srv/timed out.md: No such file or directory", .exited(1)) == .noSuchFile)
    }

    @Test func linesAboutTheStagingFolderAreLocal() {
        #expect(reason("/usr/bin/scp: \(staging)/x.md: No space left on device", .exited(1)) == .diskFull)
        #expect(reason("/usr/bin/scp: \(staging)/x.md: Permission denied", .exited(1)) == .localWrite)
        #expect(reason("/usr/bin/scp: \(staging)/x.md: No such file or directory", .exited(1)) == .localWrite)
    }

    @Test func theWrappersOwnFailuresAreNotRemoteFiles() {
        #expect(reason("sh: /usr/bin/scp: No such file or directory", .exited(127)) == .scpFailed)
        #expect(reason("sh: line 0: ulimit: file size: cannot modify limit: Operation not permitted", .exited(1)) == .scpFailed)
    }

    @Test func wordsNameTheAliasAndTheUserOnly() {
        let limits = FetchLimits()
        for failure in FetchFailure.allCases {
            let words = failure.words(alias: "buildbox", user: "alex", fileName: "x.md", limits: limits)
            #expect(!words.isEmpty)
            #expect(!words.contains("192.0.2.10"))
        }
        #expect(FetchFailure.keyRejected.words(alias: "buildbox", user: "alex", fileName: "x", limits: limits)
                == "buildbox didn't accept your key for alex")
        #expect(FetchFailure.spaceRanOut.words(alias: "c", user: "u", fileName: "x", limits: limits) == "stopped: less than 5 GB free")
    }
}
