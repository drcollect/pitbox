import AppKit
import Darwin
import Foundation
import QuickLookUI
import Testing
import WebKit
@testable import PitboxSessions

/// A TCP listener on 127.0.0.1 (a dedicated thread, never a GCD pool thread): records every connection and request
/// line. The iframe's document it serves carries a script of its own.
final class LoopbackListener: @unchecked Sendable {
    private let fd: Int32
    private(set) var port: UInt16 = 0
    private let lock = NSLock()
    private var lines: [String] = []
    private var accepts = 0

    init() throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else { close(fd); throw POSIXError(.EADDRINUSE) }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        port = UInt16(bigEndian: actual.sin_port)
        let socketFD = fd
        let base = "http://127.0.0.1:\(port)"
        let thread = Thread { [weak self] in
            while true {
                let client = accept(socketFD, nil, nil)
                if client < 0 { return }
                self?.lock.withLock { self?.accepts += 1 }
                // A peer that already went away must not end the test process with SIGPIPE.
                var noSignal: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                var timeout = timeval(tv_sec: 1, tv_usec: 0)
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var buffer = [UInt8](repeating: 0, count: 4096)
                let count = recv(client, &buffer, buffer.count, 0)
                var first = ""
                if count > 0 {
                    first = String(decoding: buffer[0..<count], as: UTF8.self).split(separator: "\r\n").first.map(String.init) ?? ""
                    self?.lock.withLock { self?.lines.append(first) }
                }
                let body = first.contains("/markup-iframe")
                    ? "<html><body>frame<script>fetch('\(base)/iframe-script')</script></body></html>" : ""
                let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                _ = reply.withCString { send(client, $0, strlen($0), 0) }
                close(client)
            }
        }
        thread.start()
    }

    deinit { stop() }

    func stop() {
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }

    var requestLines: [String] { lock.withLock { lines } }
    var connections: Int { lock.withLock { accepts } }

    /// Requests a script or an event handler made (every marker of the fixtures).
    var scriptRequests: [String] {
        requestLines.filter { line in ["/script", "/onerror", "/svg-onload", "/svg-script", "/iframe-script", "/xhtml-script",
                                       "/archive-script"].contains { line.contains($0) } }
    }
}

/// The web preview check in this unit-test host on this macOS: made-up HTML, SVG, XHTML and webarchive files whose
/// scripts would change the page and call a listener on 127.0.0.1. The app's preview runs none of them and opens no
/// connection at all; Quick Look's own view (the first choice for previews) runs none either, which these tests also
/// record, but it loads the pages' remote styles, images and frames (why the preview is built
/// on a web view with the network off; see `CodeWebPreview`).
@MainActor
@Suite("Web documents without scripts", .serialized)
struct WebPreviewC21Tests {
    let folder = SeamFolder("c21")
    let listener: LoopbackListener

    init() throws {
        _ = NSApplication.shared
        CodeTileLog.enabled = false
        listener = try LoopbackListener()
    }

    var base: String { "http://127.0.0.1:\(listener.port)" }

    // MARK: Fixtures

    func html() -> URL {
        write("page.html", """
        <!doctype html><html><head><title>c21</title>
        <link rel="stylesheet" href="\(base)/markup-css">
        <link rel="preconnect" href="\(base)/">
        <link rel="prefetch" href="\(base)/prefetch">
        <meta http-equiv="refresh" content="0;url=\(base)/meta-refresh">
        <style>html,body{margin:0;height:100%;background:#ff0000}</style>
        </head><body>
        <p id="s">SCRIPT-DID-NOT-RUN</p>
        <img src="\(base)/markup-img" width="4" height="4">
        <iframe src="\(base)/markup-iframe" width="4" height="4"></iframe>
        <script>
        document.getElementById('s').textContent = 'SCRIPT-RAN';
        document.documentElement.style.background = '#00ff00';
        try { fetch('\(base)/script-fetch'); } catch (e) {}
        try { new Image().src = '\(base)/script-img'; } catch (e) {}
        try { navigator.sendBeacon('\(base)/script-beacon', 'x'); } catch (e) {}
        try { location.href = '\(base)/script-nav'; } catch (e) {}
        </script>
        <img src="missing.png" onerror="new Image().src='\(base)/onerror'">
        <a id="go" href="\(base)/link" ping="\(base)/ping">a link</a>
        <svg width="10" height="10"><a id="svg-go" href="\(base)/svg-link"><rect width="10" height="10"/></a></svg>
        </body></html>
        """)
    }

    func svg() -> URL {
        write("chart.svg", """
        <svg xmlns="http://www.w3.org/2000/svg" width="300" height="300" onload="fetch('\(base)/svg-onload')">
        <rect id="r" width="300" height="300" fill="red"/>
        <image href="\(base)/svg-markup-image" width="4" height="4"/>
        <script>document.getElementById('r').setAttribute('fill', 'lime'); fetch('\(base)/svg-script');</script>
        </svg>
        """)
    }

    func xhtml() -> URL {
        write("page.xhtml", """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>x</title>
        <style>html,body{margin:0;height:100%;background:#ff0000}</style></head>
        <body><p id="s">SCRIPT-DID-NOT-RUN</p>
        <script>document.getElementById('s').textContent = 'SCRIPT-RAN'; fetch('\(base)/xhtml-script');</script>
        </body></html>
        """)
    }

    func webarchive() throws -> URL {
        let page = "<html><body><p id=\"s\">SCRIPT-DID-NOT-RUN</p><script>document.getElementById('s').textContent = 'SCRIPT-RAN';"
            + " fetch('\(base)/archive-script');</script></body></html>"
        let archive: [String: Any] = ["WebMainResource": ["WebResourceData": Data(page.utf8), "WebResourceMIMEType": "text/html",
                                                          "WebResourceTextEncodingName": "UTF-8", "WebResourceURL": "\(base)/archive-main",
                                                          "WebResourceFrameName": ""]]
        let url = folder.file("site.webarchive")
        try PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0).write(to: url)
        return url
    }

    func write(_ name: String, _ text: String) -> URL {
        let url = folder.file(name)
        try? Data(text.utf8).write(to: url)
        return url
    }

    // MARK: Helpers

    /// `script` in the app's own world of `web` (the page's scripts are off; this one is the test's).
    func evaluate(_ web: WKWebView, _ script: String) async -> String? {
        try? await web.evaluateJavaScript(script, in: nil, contentWorld: .defaultClient) as? String
    }

    func loaded(_ web: WKWebView, timeout: Double = 8) async -> Bool {
        guard await onMain(timeout, { !web.isLoading && web.url != nil }) else { return false }
        return await evaluate(web, "document.readyState") == "complete"
    }

    static let probe = "[document.getElementById('s') ? document.getElementById('s').textContent : 'none',"
        + " document.getElementById('r') ? document.getElementById('r').getAttribute('fill') : 'none',"
        + " getComputedStyle(document.documentElement).backgroundColor].join('|')"

    func controller() -> CodeWebPreviewController {
        let controller = CodeWebPreviewController(ruleListFolder: folder.file("rules"), revealInFinder: { _ in })
        controller.placementOverride = CGRect(x: -20000, y: -20000, width: 600, height: 500)
        return controller
    }

    func firstWebView(in view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        for sub in view.subviews { if let found = firstWebView(in: sub) { return found } }
        return nil
    }

    // MARK: the app's preview

    @Test func thePreviewRunsNoScriptAndOpensNoConnection() async throws {
        let preview = controller()
        // The text, the rect's fill, and (HTML only) the page's background, as the scripts would have changed them.
        let cases: [(URL, String, String, String?)] = [(html(), "SCRIPT-DID-NOT-RUN", "none", "rgb(255, 0, 0)"), (svg(), "none", "red", nil),
                                                        (xhtml(), "SCRIPT-DID-NOT-RUN", "none", nil),
                                                        (try webarchive(), "SCRIPT-DID-NOT-RUN", "none", nil)]
        for (file, text, fill, background) in cases {
            preview.show(file, name: file.lastPathComponent, anchor: .zero)
            #expect(await onMain(8) { preview.webView != nil }, "\(file.lastPathComponent): the rule list compiled")
            let web = try #require(preview.webView)
            #expect(await loaded(web), "\(file.lastPathComponent) loaded")
            try await Task.sleep(nanoseconds: 800_000_000)
            let dom = (await evaluate(web, Self.probe) ?? "?").split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            #expect(dom.count == 3 && dom[0] == text && dom[1] == fill && (background.map { dom[2] == $0 } ?? true),
                    "\(file.lastPathComponent): \(dom)")
            #expect(web.configuration.defaultWebpagePreferences.allowsContentJavaScript == false)
            #expect(!web.configuration.websiteDataStore.isPersistent)
            preview.close()
        }
        #expect(listener.connections == 0, "no connection at all: \(listener.requestLines)")
    }

    /// L1 of the security review: the navigation's address is the page's choice, so it is compared by text and never
    /// looked up (`standardizedFileURL` stats the path without `/private` to decide whether to drop it).
    @Test func theFileIsRecognisedByTextOnly() {
        let file = URL(fileURLWithPath: "/var/folders/pitbox-test/T/page.html")
        #expect(CodeWebPreviewNavigator.isTheFile(file, file))
        #expect(CodeWebPreviewNavigator.isTheFile(URL(fileURLWithPath: "/var/folders/pitbox-test/T/x/../page.html"), file))
        #expect(!CodeWebPreviewNavigator.isTheFile(URL(fileURLWithPath: "/private/var/folders/pitbox-test/T/page.html"), file),
                "another spelling is another address: never resolved on disk")
        #expect(!CodeWebPreviewNavigator.isTheFile(URL(fileURLWithPath: "/private/var/automount/host/page.html"), file))
        #expect(!CodeWebPreviewNavigator.isTheFile(URL(string: "https://example.com/var/folders/pitbox-test/T/page.html"), file))
        #expect(!CodeWebPreviewNavigator.isTheFile(nil, file))
    }

    @Test func thePreviewLetsOnlyTheFileItselfNavigate() async throws {
        let preview = controller()
        preview.show(html(), name: "page.html", anchor: .zero)
        #expect(await onMain(8) { preview.webView != nil })
        let web = try #require(preview.webView)
        #expect(await loaded(web))
        try await Task.sleep(nanoseconds: 500_000_000)
        let navigator = try #require(preview.currentNavigator)
        #expect(navigator.allowedFirstLoad && navigator.cancelled >= 1, "the meta refresh and the frame are cancelled")
        #expect(web.url?.isFileURL == true, "still the file: \(web.url?.absoluteString ?? "")")
        // Links are inert: a click (dispatched from the test's own world, as a pointer click would arrive) starts nothing,
        // not even the preconnect WebKit makes before it asks the navigation policy.
        #expect(await evaluate(web, "String(document.getElementById('go').hasAttribute('href'))") == "false")
        _ = await evaluate(web, "document.getElementById('go').click(); document.getElementById('svg-go')"
                           + ".dispatchEvent(new MouseEvent('click', {bubbles: true})); 'clicked'")
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(web.url?.isFileURL == true && listener.connections == 0, "\(listener.connections) connection(s)")
        #expect(preview.currentPanel?.canBecomeKey == false && preview.currentPanel?.canBecomeMain == false)
        preview.close()
        #expect(!preview.isShown && preview.webView == nil)
    }

    @Test func controlALinkClickWithoutTheInertLinksScriptReachesTheListener() async throws {
        let rules = CodeWebPreviewRules(folder: folder.file("rules-control"))
        var compiled: WKContentRuleList?
        var settled = false
        rules.whenReady { list in compiled = list; settled = true }
        #expect(await onMain(8) { settled })
        let list = try #require(compiled)
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 500),
                            configuration: CodeWebPreview.configuration(ruleList: list, inertLinks: false))
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 600, height: 500), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.orderFrontRegardless()
        let file = html()
        let navigator = CodeWebPreviewNavigator(file: file)
        web.navigationDelegate = navigator
        web.loadFileURL(file, allowingReadAccessTo: file)
        #expect(await loaded(web))
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(listener.connections == 0, "loading alone opens nothing")
        _ = await evaluate(web, "document.getElementById('go').click(); 'clicked'")
        #expect(await onMain(3) { self.listener.connections > 0 }, "control: WebKit preconnects to a clicked link's host")
        #expect(web.url?.isFileURL == true, "the policy still cancelled the navigation")
        window.orderOut(nil)
        window.contentView = nil
    }

    // MARK: Quick Look's own view, for the record

    @Test func quickLookRunsNoScriptEither() async throws {
        for file in [html(), svg(), xhtml(), try webarchive()] {
            let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 600, height: 500), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.animationBehavior = .none
            window.isReleasedWhenClosed = false
            let view = try #require(QLPreviewView(frame: CGRect(x: 0, y: 0, width: 600, height: 500), style: .normal))
            window.contentView = view
            window.orderFrontRegardless()
            view.previewItem = file as NSURL
            // The preview loads asynchronously: on macOS 26 into an in-process WKWebView (when another macOS renders it
            // elsewhere, only the listener speaks).
            if await onMain(6, { self.firstWebView(in: view) != nil }), let web = firstWebView(in: view) {
                _ = await loaded(web, timeout: 6)
                try await Task.sleep(nanoseconds: 800_000_000)
                let dom = await evaluate(web, Self.probe) ?? ""
                #expect(!dom.contains("SCRIPT-RAN") && !dom.contains("lime") && !dom.contains("rgb(0, 255, 0)"), "\(file.lastPathComponent): \(dom)")
            } else {
                try await Task.sleep(nanoseconds: 1_500_000_000)
            }
            view.close()
            window.orderOut(nil)
            window.contentView = nil
        }
        #expect(listener.scriptRequests.isEmpty, "\(listener.scriptRequests)")
    }
}
