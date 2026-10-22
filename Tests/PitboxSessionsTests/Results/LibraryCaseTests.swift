import Darwin
import Foundation
import Testing
@testable import PitboxSessions

/// A handed-over file in `~/Library` is never a button, in any spelling of `Library` (the volume ignores case).
/// Invented folders only. The case-variant test failed before the fix (it became a document button, and the click-time
/// re-check accepted it).
@Suite("Results: ~/Library in any case")
struct LibraryCaseTests {
    let tree = ResultTree("library-case")

    func check(_ candidates: [ResultFileCandidate]) -> [CodeResult] {
        let env = tree.environment()
        return LocalReportCheck(environment: env).results(for: candidates, cwd: tree.repo.path, budget: env.budget())
    }

    func handed(_ path: String) -> ResultFileCandidate {
        ResultFileCandidate(path: path, origin: .handedOver, toolUseID: "toolu_send", at: ago(5))
    }

    @Test func libraryIsExcludedInItsOwnCase() {
        tree.write("TOKEN", "home/Library/Application Support/secret.md")
        let canonical = tree.home.appendingPathComponent("Library/Application Support/secret.md").path
        #expect(check([handed(canonical)]).first?.kind == .mentionedPath)
    }

    @Test func aCaseVariantOfLibraryIsExcludedToo() {
        tree.write("TOKEN", "home/Library/Application Support/secret.md")
        for spelling in ["LIBRARY", "library", "LiBrArY"] {
            let path = tree.home.appendingPathComponent("\(spelling)/Application Support/secret.md").path
            #expect(check([handed(path)]).first?.kind == .mentionedPath, "\(spelling) is the same folder")
        }
    }

    @Test func dotFoldersStayExcludedAcrossCase() {
        tree.write("PRIVATE", "home/.ssh/id_rsa.md")
        let upper = tree.home.appendingPathComponent(".SSH/id_rsa.md").path
        #expect(check([handed(upper)]).first?.kind == .mentionedPath)
    }

    @Test func anOrdinaryHomeFileStillBecomesAButton() {
        tree.write("NOTES", "home/Documents/notes.md")
        let path = tree.home.appendingPathComponent("Documents/notes.md").path
        #expect(check([handed(path)]).first?.kind == .document)
    }
}
