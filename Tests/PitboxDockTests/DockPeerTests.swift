import Darwin
import Foundation
import Testing
@testable import PitboxDock

/// A made-up app bundle in a temp folder: `<folder>/<name>.app/Contents/{Info.plist, MacOS/<executable>}`.
private struct FakeBundle {
    let folder: DockTestFolder
    let bundlePath: String
    let executablePath: String

    init(name: String = "Host", bundleID: String? = "com.example.host", writePlist: Bool = true) throws {
        folder = try DockTestFolder()
        bundlePath = folder.path + "/\(name).app"
        let macOS = bundlePath + "/Contents/MacOS"
        try FileManager.default.createDirectory(atPath: macOS, withIntermediateDirectories: true)
        executablePath = macOS + "/host"
        #expect(FileManager.default.createFile(atPath: executablePath, contents: Data("#!/bin/sh\n".utf8)))
        if writePlist {
            var plist: [String: Any] = ["CFBundleExecutable": "host"]
            if let bundleID { plist["CFBundleIdentifier"] = bundleID }
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: URL(fileURLWithPath: bundlePath + "/Contents/Info.plist"))
        }
    }

    func remove() { folder.remove() }
}

@Suite struct DockPeerCheckTests {
    private let me = getuid()

    @Test func aListedAppOfThisUserIsAccepted() throws {
        let facts = passingFacts(pid: 4242)
        let started = try #require(facts.started)
        let verdict = DockPeerCheck.verdict(facts, allowedHosts: ["com.example.host"], ownUID: me)
        #expect(verdict == .success(VerifiedHost(pid: 4242, started: started, bundleID: "com.example.host")))
    }

    @Test func aPeerWithoutAStartTimeIsRefused() {
        // Without its start time the pid cannot be bound to the process (a recycled pid would pass).
        var facts = passingFacts()
        facts.started = nil
        #expect(DockPeerCheck.verdict(facts, allowedHosts: ["com.example.host"], ownUID: me) == .failure(.notAnApp))
    }

    @Test func rootOwnedBundlesCountAsTrusted() {
        var facts = passingFacts()
        facts.bundle?.bundleOwner = 0
        facts.bundle?.executableOwner = 0
        #expect((try? DockPeerCheck.verdict(facts, allowedHosts: ["com.example.host"], ownUID: me).get()) != nil)
    }

    @Test func anotherUserIsRefused() {
        var facts = passingFacts()
        facts.uid = me + 1
        #expect(DockPeerCheck.verdict(facts, allowedHosts: ["com.example.host"], ownUID: me) == .failure(.otherUser))
        facts.uid = nil
        #expect(DockPeerCheck.verdict(facts, allowedHosts: ["com.example.host"], ownUID: me) == .failure(.otherUser))
    }

    @Test func notAnAppOrABundleOfSomeoneElseIsRefused() {
        var facts = passingFacts()
        facts.bundle = nil
        #expect(DockPeerCheck.verdict(facts, allowedHosts: ["com.example.host"], ownUID: me) == .failure(.notAnApp))
        facts = passingFacts()
        facts.bundle?.bundleOwner = me + 1
        #expect(DockPeerCheck.verdict(facts, allowedHosts: ["com.example.host"], ownUID: me) == .failure(.notAnApp))
        facts = passingFacts()
        facts.bundle?.executableOwner = me + 1
        #expect(DockPeerCheck.verdict(facts, allowedHosts: ["com.example.host"], ownUID: me) == .failure(.notAnApp))
        facts = passingFacts()
        facts.pid = nil
        #expect(DockPeerCheck.verdict(facts, allowedHosts: ["com.example.host"], ownUID: me) == .failure(.notAnApp))
    }

    @Test func aBundleIDOutsideTheListIsRefused() {
        let facts = passingFacts(bundleID: "com.example.other")
        #expect(DockPeerCheck.verdict(facts, allowedHosts: ["com.example.host"], ownUID: me)
                == .failure(.notListed(bundleID: "com.example.other")))
        #expect(DockPeerCheck.verdict(passingFacts(), allowedHosts: [], ownUID: me)
                == .failure(.notListed(bundleID: "com.example.host")), "the default empty list docks with nobody")
        #expect(DockPeerCheck.verdict(passingFacts(bundleID: nil), allowedHosts: ["com.example.host"], ownUID: me)
                == .failure(.notListed(bundleID: nil)))
        #expect(DockPeerCheck.verdict(passingFacts(bundleID: "COM.EXAMPLE.HOST"), allowedHosts: ["com.example.host"],
                                      ownUID: me) == .failure(.notListed(bundleID: "COM.EXAMPLE.HOST")),
                "exact match")
    }

    @Test func bundleIDShape() {
        #expect(DockPeerCheck.isBundleID("com.example.host"))
        #expect(DockPeerCheck.isBundleID("io.github.some-one.app2"))
        for bad in ["", "ab", "nodots", ".com.x", "com.x.", "com..x", "com.ex ample", "com.exämple.x", "com/x.y"] {
            #expect(!DockPeerCheck.isBundleID(bad), "\(bad)")
        }
    }
}

@Suite struct DockPeerInspectorTests {
    @Test func aBundleOnDiskIsReadWithItsOwners() throws {
        let bundle = try FakeBundle()
        defer { bundle.remove() }
        let found = try #require(SystemPeerInspector.bundle(forExecutable: bundle.executablePath))
        #expect(found == DockPeerBundle(bundleID: "com.example.host", bundleOwner: getuid(), executableOwner: getuid()))
        // The same through a /private spelling and a redundant component.
        let spelled = "/private" + bundle.executablePath.replacingOccurrences(of: "/Contents/", with: "/Contents/./")
        #expect(SystemPeerInspector.bundle(forExecutable: spelled)?.bundleID == "com.example.host")
    }

    @Test func executablesOutsideContentsMacOSAreNotApps() throws {
        let bundle = try FakeBundle()
        defer { bundle.remove() }
        let resources = bundle.bundlePath + "/Contents/Resources"
        try FileManager.default.createDirectory(atPath: resources, withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: resources + "/tool", contents: Data()))
        #expect(SystemPeerInspector.bundle(forExecutable: resources + "/tool") == nil)
        #expect(SystemPeerInspector.bundle(forExecutable: bundle.folder.path + "/loose") == nil)
        #expect(SystemPeerInspector.bundle(forExecutable: "/usr/bin/true") == nil)
        #expect(SystemPeerInspector.bundle(forExecutable: bundle.bundlePath + "/Contents/MacOS/missing") == nil)
        #expect(SystemPeerInspector.bundle(forExecutable: bundle.folder.path + "/.app/Contents/MacOS/x") == nil)
    }

    @Test func aSymlinkedBundleIsNotAnApp() throws {
        let bundle = try FakeBundle()
        defer { bundle.remove() }
        let link = bundle.folder.path + "/Link.app"
        #expect(symlink(bundle.bundlePath, link) == 0)
        #expect(SystemPeerInspector.bundle(forExecutable: link + "/Contents/MacOS/host") == nil)
    }

    @Test func aMissingOrBrokenInfoPlistGivesNoBundleID() throws {
        let missing = try FakeBundle(writePlist: false)
        defer { missing.remove() }
        #expect(SystemPeerInspector.bundle(forExecutable: missing.executablePath)?.bundleID == nil)
        let invalid = try FakeBundle(bundleID: "not a bundle id")
        defer { invalid.remove() }
        #expect(SystemPeerInspector.bundle(forExecutable: invalid.executablePath)?.bundleID == nil)
        let broken = try FakeBundle(writePlist: false)
        defer { broken.remove() }
        try Data("not a plist".utf8).write(to: URL(fileURLWithPath: broken.bundlePath + "/Contents/Info.plist"))
        #expect(SystemPeerInspector.bundle(forExecutable: broken.executablePath)?.bundleID == nil)
    }

    @Test func theRealInspectorReadsUserAndPidAndRefusesThisTestRunner() throws {
        var fds: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        let facts = SystemPeerInspector().inspect(fds[0])
        #expect(facts.uid == getuid())
        #expect(facts.pid == getpid())
        #expect(facts.started == ProcessAncestry.identity(of: getpid())?.started)
        #expect(SystemPeerInspector.executablePath(of: getpid()) != nil)
        // The test runner is no app of dock.hosts: refused whatever the list says.
        let verdict = DockPeerCheck.verdict(facts, allowedHosts: ["com.example.host"], ownUID: getuid())
        #expect((try? verdict.get()) == nil)
        #expect(SystemPeerInspector.executablePath(of: -1) == nil)
    }
}
