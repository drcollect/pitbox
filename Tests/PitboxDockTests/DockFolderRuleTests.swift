import Darwin
import Foundation
import Testing
@testable import PitboxDock

/// Only specific app-private folders announced by a host pass (docs/DOCK_PROTOCOL.md §5.3).
@Suite struct DockFolderRuleTests {
    private let rule = DockFolderRule(home: "/Users/alex")

    @Test(arguments: [
        "/", "/Users", "/Users/alex", "/Users/alex/Library", "/Users/alex/Library/Application Support",
        "/Users/alex/Documents", "/Users/alex/Documents/notes", "/System", "/Library", "/Applications", "/private", "/var",
        "/tmp", "/private/tmp", "/private/var", "/private/var/folders/xy/T/host", "/Volumes", "/Volumes/Disk/a/b/c",
        "/opt", "/opt/host/state/run", "/usr", "/usr/local/var/host", "/bin", "/sbin", "/etc", "/private/etc", "/dev",
        "/tmp/", "//", "/./", "/private/tmp/.",
    ])
    func broadFoldersAreRefused(_ entry: String) {
        #expect(rule.check(entry) == .refused("too broad"), "\(entry)")
    }

    @Test func unresolvableAndRelativeEntriesAreRefused() {
        #expect(rule.check("/Users/alex/Library/Application Support/Host/../../..") == .refused("dot-dot"))
        #expect(rule.check("/private/tmp/x/..") == .refused("dot-dot"))
        #expect(rule.check("relative/folder") == .refused("not absolute"))
        #expect(rule.check("~/Library/Application Support/Host") == .refused("not absolute"))
        #expect(rule.check("") == .refused("not absolute"))
    }

    @Test func specificFoldersPassInCanonicalForm() {
        #expect(rule.check("/Users/alex/Library/Application Support/Host")
                == .accepted("/Users/alex/Library/Application Support/Host"))
        #expect(rule.check("/Users/alex/Library/Application Support/Host/./state")
                == .accepted("/Users/alex/Library/Application Support/Host/state"))
        #expect(rule.check("/tmp/host-runner-501") == .accepted("/private/tmp/host-runner-501"), "the canonical spelling")
        #expect(rule.check("/private/tmp/host-runner-501") == .accepted("/private/tmp/host-runner-501"))
    }

    @Test func linksAreFollowedBeforeTheRuleIsApplied() throws {
        let folder = try DockTestFolder()
        defer { folder.remove() }
        #expect(symlink("/", folder.path + "/to-root") == 0)
        #expect(symlink("/Users", folder.path + "/to-users") == 0)
        #expect(rule.check(folder.path + "/to-root") == .refused("too broad"))
        #expect(rule.check(folder.path + "/to-root/usr/local") == .refused("too broad"))
        #expect(rule.check(folder.path + "/to-users/alex") == .refused("too broad"), "a link to the home folder")
        let canonical = try #require(DockFolderRule.canonicalPath(folder.path))
        #expect(rule.check(folder.path + "/runner") == .accepted(canonical + "/runner"))
    }

    @Test func filterKeepsEachAcceptedFolderOnceAndCountsTheRest() {
        let result = rule.filter(["/", "/tmp/host-runner-501", "/private/tmp/host-runner-501", "/Users/alex", "x"])
        #expect(result.kept == ["/private/tmp/host-runner-501"])
        #expect(result.refused == 3)
    }

    @Test func theRealHomeIsMeasuredFromByDefault() {
        let real = DockFolderRule()
        #expect(real.check(NSHomeDirectory()) == .refused("too broad"))
        #expect(real.check(NSHomeDirectory() + "/Library") == .refused("too broad"))
        #expect(real.check(NSHomeDirectory() + "/Library/Application Support") == .refused("too broad"))
    }
}
