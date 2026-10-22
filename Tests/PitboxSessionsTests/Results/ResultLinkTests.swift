import Foundation
import Testing
@testable import PitboxSessions

/// Links of a final reply (docs/THREAT_MODEL.md): two shapes, parsed hosts equal to the raw host text byte for byte, a
/// written port for previews, addresses rebuilt from checked parts.
@Suite("Result links")
struct ResultLinkTests {
    func preview(_ raw: String) -> (url: String, label: String)? {
        if case .preview(let url, let label) = ResultLinks.classify(raw) { return (url.absoluteString, label) }
        return nil
    }

    @Test func localPreviewsOpenAtTheirRootOnly() {
        #expect(preview("http://localhost:5173/x?y=1#z")?.url == "http://localhost:5173/")
        #expect(preview("http://localhost:5173/x?y=1#z")?.label == "localhost:5173")
        #expect(preview("http://127.0.0.1:3000")?.url == "http://127.0.0.1:3000/")
        #expect(preview("http://[::1]:3000")?.url == "http://[::1]:3000/")
        #expect(preview("http://0.0.0.0:3000/app")?.url == "http://localhost:3000/", "0.0.0.0 opens as localhost")
        #expect(preview("https://localhost:8443/")?.url == "https://localhost:8443/", "the written scheme stays")
    }

    @Test func previewsNeedAWrittenPortAbove1023() {
        #expect(ResultLinks.classify("http://localhost/") == .other, "no port written")
        #expect(ResultLinks.classify("http://localhost:80/") == .other)
        #expect(ResultLinks.classify("http://localhost:1023") == .other)
        #expect(ResultLinks.classify("http://localhost:65536") == .other)
        #expect(ResultLinks.classify("http://localhost:05173") == .other, "the port as written, no leading zero")
        #expect(preview("http://localhost:1024") != nil && preview("http://localhost:65535") != nil)
    }

    @Test func lookAlikeHostsAreRefused() {
        for raw in ["http://LOCALHOST:5173", "http://localhost.:5173", "http://127.1:5173", "http://0x7f000001:5173",
                    "http://%6Cocalhost:5173", "http://localhost.evil.com:5173", "http://user@localhost:5173",
                    "http://user:pw@localhost:5173", "http://xn--lcalhost-bza:5173", "HTTP://localhost:5173",
                    "http://[0:0:0:0:0:0:0:1]:3000", "http://[::1%25lo0]:3000", "ftp://localhost:2121"] {
            #expect(ResultLinks.classify(raw) == .other, "\(raw)")
        }
    }

    @Test func artifactsAreRebuiltWithoutQueryOrFragment() {
        #expect(ResultLinks.classify("https://claude.ai/artifact/abcDEF12?x=1#y") == .artifact(URL(string: "https://claude.ai/artifact/abcDEF12")!))
        #expect(ResultLinks.classify("https://claude.ai/code/artifact/a_b-c1234/") == .artifact(URL(string: "https://claude.ai/code/artifact/a_b-c1234")!))
        #expect(ResultLinks.classify("https://claude.ai/artifact/abc1234") == .other, "id too short")
        #expect(ResultLinks.classify("https://claude.ai/artifact/" + String(repeating: "a", count: 65)) == .other, "id too long")
        #expect(ResultLinks.classify("http://claude.ai/artifact/abcDEF12") == .other, "https only")
        #expect(ResultLinks.classify("https://claude.ai:443/artifact/abcDEF12") == .other, "no port")
        #expect(ResultLinks.classify("https://claude.ai.evil.com/artifact/abcDEF12") == .other)
        #expect(ResultLinks.classify("https://Claude.ai/artifact/abcDEF12") == .other)
        #expect(ResultLinks.classify("https://claude.ai/artifact/abc%44EF12") == .other, "percent-encoded id")
        #expect(ResultLinks.classify("https://claude.ai/artifact/abcDEF12/more") == .other)
    }

    @Test func otherShapesAreNoButtons() {
        #expect(ResultLinks.classify("https://github.com/someone/toy-cube/pull/142") == .other, "no pull-request shape")
        #expect(ResultLinks.classify("http://192.0.2.10:8080/") == .other)
        #expect(ResultLinks.classify("file:///etc/passwd") == .other)
        #expect(ResultLinks.classify("https://dash.example.com/dash/polar-shore/", dashboardSites: .test) == .dashboard)
        #expect(ResultLinks.classify("dash.example.com://dash.example.com/dash/x/", dashboardSites: .test) == .dashboard)
        // Without that site configured (the feature off) the same link is just another link.
        #expect(ResultLinks.classify("https://dash.example.com/dash/polar-shore/") == .other)
        #expect(ResultLinks.classify("https://dash.example.com:8443/dash/polar-shore/", dashboardSites: .test) == .other)
    }

    @Test func linksAreFoundInProseAndCodeButNotInQuotesOrLinkTexts() {
        let text = """
        The preview runs at http://localhost:5173/app, see also <https://claude.ai/artifact/abcDEF12>.
        [http://localhost:9999](https://claude.ai/code/artifact/zyxWVU98) and localhost:4000 without a scheme.
        > quoted http://localhost:7000
        lazily continued http://localhost:7001

        ```bash
        open http://127.0.0.1:3000/
        ```
        | col | http://localhost:8000 |
        Trailing http://localhost:6000)).
        """
        let found = ResultLinks.find(in: text)
        #expect(found == ["http://localhost:5173/app", "https://claude.ai/artifact/abcDEF12", "https://claude.ai/code/artifact/zyxWVU98",
                          "http://127.0.0.1:3000/", "http://localhost:8000", "http://localhost:6000"])
        #expect(!found.contains { $0.contains("9999") }, "a Markdown link's text is never used")
        #expect(!found.contains { $0.contains(":4000") }, "text without a scheme is never a link")
    }

    @Test func aQuotedFenceIsSkippedAndAnOpenFenceStillScans() {
        let text = "> ```\n> http://localhost:7000\n> ```\n\n~~~~\nhttp://localhost:7100\n~~~~\nhttp://localhost:7200"
        #expect(ResultLinks.find(in: text) == ["http://localhost:7100", "http://localhost:7200"])
    }

    @Test func aFloodOfLinksIsBounded() {
        let text = (0..<1000).map { "http://localhost:\(5000 + $0)" }.joined(separator: " ")
        #expect(ResultLinks.find(in: text).count == ResultLinks.maxLinksPerReply)
    }
}
