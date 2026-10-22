import AppKit
import Foundation
import PitboxKit
import Testing
@testable import PitboxSessions

/// A stand-in for a monitor's screen, so the result and warning lines the monitor view draws (`CodeMonitorView`) can
/// be looked at in the monitor's own colours.
final class MonitorScreenStandIn: NSView {
    var resultLine: CodeMonitorResultLine?
    var warningLine: CodeMonitorWarningLine?
    var small = false

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let bezel = bounds.insetBy(dx: 2, dy: 2)
        CodeMonitorPalette.color(CodeMonitorPalette.bezel).setFill()
        NSBezierPath(roundedRect: bezel, xRadius: 10, yRadius: 10).fill()
        let screen = bezel.insetBy(dx: 6, dy: 6)
        CodeMonitorPalette.color(CodeMonitorPalette.screen).setFill()
        NSBezierPath(roundedRect: screen, xRadius: 5, yRadius: 5).fill()
        let content = screen.insetBy(dx: 10, dy: 8)
        ("Toy Cube · checkout tests" as NSString).draw(at: CGPoint(x: content.minX, y: content.minY), withAttributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: CodeMonitorPalette.color(CodeMonitorPalette.headline),
        ])
        if let warningLine {
            CodeMonitorWarningLine.draw(warningLine, in: CGRect(x: content.minX, y: content.minY + 22, width: content.width, height: 17),
                                        small: small)
            CodeMonitorWarningLine.strokeOutline(screen: screen, radius: 5)
        }
        if let resultLine {
            CodeMonitorResultLine.draw(resultLine, in: CGRect(x: content.minX - 3, y: content.maxY - 40, width: content.width + 6, height: 19),
                                       hovered: false, pressed: false)
        }
        ("review ready · 3 min · opus" as NSString).draw(at: CGPoint(x: content.minX, y: content.maxY - 16), withAttributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: CodeMonitorPalette.color(CodeMonitorPalette.dim),
        ])
    }
}

/// Renders the results' and warnings' components as PNGs when `PITBOX_TEST_OUT` is set:
/// `PITBOX_TEST_OUT=<dir> scripts/test.sh --filter renderResultAndWarningPictures`.
@MainActor
@Suite("Result and warning pictures")
struct ResultPictureTests {
    init() { CodeTileLog.enabled = false }

    static let results: [CodeResult] = [
        CodeResult(kind: .preview, origin: .replyLink, url: URL(string: "http://localhost:5173/"), label: "localhost:5173"),
        CodeResult(kind: .artifact, origin: .publishedArtifact, url: URL(string: "https://claude.ai/artifact/abcDEF12"), label: "artifact"),
        CodeResult(kind: .document, origin: .written, path: "/x/notes.md", label: "notes.md"),
        CodeResult(kind: .webDocument, origin: .written, path: "/x/checkout-test-report.html", label: "checkout-test-report.html"),
        CodeResult(kind: .otherFile, origin: .handedOver, path: "/x/run.sh", label: "run.sh"),
        CodeResult(kind: .serverFile, origin: .handedOver, path: "/home/buildbox/out/demo.mp4", label: "demo.mp4", toolUseID: "t"),
        CodeResult(kind: .serverPreview, origin: .replyLink, url: URL(string: "http://localhost:8080/"), label: "localhost:8080"),
        CodeResult(kind: .earlierArtifact, origin: .publishedArtifact, url: URL(string: "https://claude.ai/artifact/oldOLD12"),
                   label: "artifact", at: Date(timeIntervalSince1970: 1_792_400_000)),
        CodeResult(kind: .mentionedPath, origin: .handedOver, path: "/Volumes/share/q3-letter.md", label: "/Volumes/share/q3-letter.md",
                   note: LocalReportCheck.networkNote),
    ]

    static let warnings: [CodeWarning] = [
        CodeWarning(kind: .failedInARow, since: ago(12), failures: 4, lastExitCode: 1),
        CodeWarning(kind: .sameFile, since: ago(5), otherSessionID: "local_x", otherHeadline: "Toy Cube · cart", path: "src/checkout.tsx"),
    ]

    func write(_ view: NSView, _ size: CGSize, dark: Bool, _ name: String, to out: URL?) throws {
        let png = try #require(PictureTests.picture(of: view, size: size, dark: dark), "\(name)")
        #expect(png.count > 1500, "\(name)")
        if let out {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try png.write(to: out.appendingPathComponent("\(name).png"))
        }
    }

    @Test func renderResultAndWarningPictures() throws {
        let out = ProcessInfo.processInfo.environment["PITBOX_TEST_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let buttons = CodeResultWords.workButtons(Self.results)
        let row = CodeResultButtonsView(buttons: buttons, note: "+2 more", width: 620)
        try write(row, CGSize(width: 620, height: row.frame.height), dark: true, "results-buttons-dark", to: out)
        for dark in [true, false] {
            let section = CodeResultsSectionView(results: Self.results, otherLinkCount: 2, alias: "buildbox", hidden: false,
                                                 palette: CodeResultPalette(dark: dark), width: 420)
            section.timeText = { _ in "19 Oct 14:02" }
            try write(section, CGSize(width: 420, height: section.height), dark: dark, "results-section-\(dark ? "dark" : "light")", to: out)
        }
        let hidden = CodeResultsSectionView(results: Self.results, otherLinkCount: 2, alias: "buildbox", hidden: true, width: 420)
        try write(hidden, CGSize(width: 420, height: hidden.height), dark: true, "results-section-hidden", to: out)

        let session = resultSession(results: Self.results)
        var warned = session
        warned.warnings = Self.warnings
        for (name, width, small) in [("monitor-lines-large", 323.0, false), ("monitor-lines-medium", 240.0, false),
                                     ("monitor-lines-small", 180.0, true)] {
            let screen = MonitorScreenStandIn(frame: CGRect(x: 0, y: 0, width: width, height: 150))
            screen.resultLine = small ? nil : CodeMonitorResultLine.make(session, textHidden: false)
            screen.warningLine = CodeMonitorWarningLine.make(warned, now: resultNow, textHidden: false)
            screen.small = small
            try write(screen, screen.frame.size, dark: true, name, to: out)
        }
        let line = CodeWarningLineView(warnings: Self.warnings, now: resultNow, hidden: false, width: 380)
        try write(line, CGSize(width: 380, height: line.frame.height), dark: true, "warning-line-dark", to: out)
        let details = CodeWarningDetailsView(warnings: Self.warnings, now: resultNow, hidden: false, width: 380)
        try write(details, CGSize(width: 380, height: details.height), dark: true, "warning-details-dark", to: out)
        let header = CodeWebPreviewContent(title: "checkout-test-report.html", webView: nil)
        header.frame = CGRect(x: 0, y: 0, width: CodeWebPreviewController.size.width, height: 120)
        header.layoutSubtreeIfNeeded()
        try write(header, header.frame.size, dark: true, "web-preview-frame", to: out)
    }
}
