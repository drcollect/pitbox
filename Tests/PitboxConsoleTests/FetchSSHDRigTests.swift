import Foundation
import Testing
@testable import PitboxConsole

/// The real ssh behind the runner's real options (`-o LogLevel=ERROR -o BatchMode=yes -o StrictHostKeyChecking=yes …`),
/// against a local `sshd -i` run as the test's own ProxyCommand: no port, no network, scratch keys, no agent, and
/// `-F <sandbox config>` so neither the user's config nor their known_hosts is read. A non-root sshd cannot open a session
/// (BSM audit), so this rig covers the failures, which is what it is for; the sftp-server rig covers successful copies.
@MainActor
@Suite(.timeLimit(.minutes(2)), .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd")
                                            && FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh-keygen")))
struct FetchSSHDRigTests {
    @Test func realSshFailuresReadAsTheirReasons() async throws {
        let sandbox = FetchSandbox()
        let rig = sandbox.root + "/rig"
        FetchSandbox.makeFolder(rig)
        for key in ["hostkey", "clientkey", "otherkey"] {
            let made = await runTool("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "rig-\(key)",
                                                              "-f", rig + "/" + key])
            try #require(made.status == .exited(0), "\(made.stderr)")
        }
        func publicKey(_ name: String) throws -> String {
            try String(contentsOfFile: rig + "/\(name).pub", encoding: .utf8).split(separator: " ").prefix(2).joined(separator: " ")
        }
        let hostKey = try publicKey("hostkey")
        let otherKey = try publicKey("otherkey")
        sandbox.write(rig + "/authorized_keys", try publicKey("clientkey") + "\n")
        let sshd = """
        HostKey \(rig)/hostkey
        AuthorizedKeysFile \(rig)/authorized_keys
        UsePAM no
        KbdInteractiveAuthentication no
        StrictModes no
        PidFile none
        LogLevel QUIET

        """
        sandbox.write(rig + "/sshd_config", sshd + "PasswordAuthentication no\n")
        sandbox.write(rig + "/sshd_config_pw", sshd + "PasswordAuthentication yes\n")

        let cases: [(knownHosts: String, sshdConfig: String, identity: String, words: String)] = [
            ("", "sshd_config", "clientkey", "the host key for buildbox is unknown or changed: not fetched"),
            ("rig.invalid \(otherKey)\n", "sshd_config", "clientkey", "the host key for buildbox is unknown or changed: not fetched"),
            ("rig.invalid \(hostKey)\n", "sshd_config", "otherkey", "buildbox didn't accept your key for buildbox"),
            ("rig.invalid \(hostKey)\n", "sshd_config_pw", "otherkey", "buildbox asked for a password (use Run in terminal)"),
        ]
        for item in cases {
            sandbox.write(rig + "/known_hosts", item.knownHosts)
            sandbox.writeConfig("""
            Host buildbox
              HostName rig.invalid
              User buildbox
              ProxyCommand /usr/sbin/sshd -i -f \(rig)/\(item.sshdConfig)
              UserKnownHostsFile \(rig)/known_hosts
              GlobalKnownHostsFile /dev/null
              IdentitiesOnly yes
              IdentityAgent none
              IdentityFile \(rig)/\(item.identity)

            """)
            let runner = FetchRunner(environment: sandbox.environment(extraSCPOptions: ["-F", sandbox.userConfig],
                                                                      resolution: nil))
            let plan = try #require(await makePlan(runner, remotePath: "/etc/hosts"))
            #expect(plan.proxyNote == "your config runs a proxy command")
            #expect(await runFetch(runner, plan).outcome == .failed(reason: item.words), "\(item.sshdConfig) \(item.identity)")
        }
        #expect(sandbox.entries(sandbox.downloads).isEmpty)
        #expect(sandbox.entries(sandbox.stagingParent).isEmpty)
    }
}
