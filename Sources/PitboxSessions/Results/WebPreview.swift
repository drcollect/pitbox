import AppKit
import PitboxKit
import WebKit

/// The app's preview of a web document a session wrote or handed over (`html`, `htm`, `xhtml`, `svg`,
/// `webarchive`): never the browser, where the page would run its scripts with the user's signed-in sessions
/// (docs/THREAT_MODEL.md). A web view set up so that the page can only be looked at: content
/// JavaScript off; every http, https, ws, wss and ftp load blocked by a content rule list (no remote style, image, frame,
/// preconnect or prefetch); a non-persistent data store; no navigation but the one file (links are made inert, and
/// a meta refresh, a frame, a form or a drop is cancelled); no downloads; no context menu; read access to that one file
/// only.
///
/// Why not Quick Look's own view: a measurement on macOS 26.5 (`WebPreviewC21Tests`) showed that
/// `QLPreviewView` renders these types with an in-process WKWebView whose scripts are off too, but which loads the page's
/// remote styles, images and frames and preconnects to its hosts, so a page can tell a server that the user looked and
/// from where. This is the same engine with the network off as well.
public enum CodeWebPreview {
    /// The measured result for this preview on this macOS: no script runs and nothing is loaded from the network. When
    /// false, web documents get Show in Finder only.
    public static let isScriptFree = true

    /// The rule list of the preview (one rule per scheme: WebKit's `url-filter` has no alternation).
    static let ruleListIdentifier = "pitbox.code.web-preview.block-network.v1"
    static let rules = """
    [
      {"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^ftp://"},"action":{"type":"block"}}
    ]
    """

    /// The app's own script (the page's stay off), run in its own world when each document has loaded: links lose
    /// their targets, so a click on one does nothing. Measured: a click on a link the navigation policy then
    /// cancels still made WebKit open a connection to the link's host first (a preconnect); without a target there is
    /// no navigation to start.
    static let inertLinksSource = """
    (function () {
      for (const element of document.querySelectorAll('a, area')) {
        element.removeAttribute('href');
        element.removeAttributeNS('http://www.w3.org/1999/xlink', 'href');
        element.removeAttribute('ping');
      }
    })();
    """

    /// The web view's configuration: scripts off, the rule list, inert links, a non-persistent store, no autoplay, no
    /// AirPlay.
    @MainActor
    static func configuration(ruleList: WKContentRuleList, inertLinks: Bool = true) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.userContentController.add(ruleList)
        guard inertLinks else { return configuration }
        configuration.userContentController.addUserScript(WKUserScript(source: inertLinksSource, injectionTime: .atDocumentEnd,
                                                                       forMainFrameOnly: false, in: .defaultClient))
        return configuration
    }

    /// The folder WebKit keeps the compiled rule list in: the app's caches (`Paths.cachesDir/ContentRuleLists`).
    static var defaultRuleListFolder: URL {
        Paths.cachesDir.appendingPathComponent("ContentRuleLists", isDirectory: true)
    }
}

/// Compiles the preview's rule list once (a few milliseconds, asynchronous) and hands it to whoever waits.
@MainActor
final class CodeWebPreviewRules {
    private enum State { case idle, compiling, ready(WKContentRuleList), failed }
    private var state = State.idle
    private var waiters: [(WKContentRuleList?) -> Void] = []
    private let folder: URL

    init(folder: URL) { self.folder = folder }

    /// Calls `body` with the compiled list, or nil when compiling failed (the preview then never opens: no network rule,
    /// no preview).
    func whenReady(_ body: @escaping (WKContentRuleList?) -> Void) {
        switch state {
        case .ready(let list): body(list)
        case .failed: body(nil)
        case .compiling: waiters.append(body)
        case .idle:
            waiters.append(body)
            compile()
        }
    }

    private func compile() {
        state = .compiling
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let store = WKContentRuleListStore(url: folder) else { return finish(nil) }
        store.compileContentRuleList(forIdentifier: CodeWebPreview.ruleListIdentifier,
                                     encodedContentRuleList: CodeWebPreview.rules) { list, _ in
            MainActor.assumeIsolated { self.finish(list) }
        }
    }

    private func finish(_ list: WKContentRuleList?) {
        if let list { state = .ready(list) } else {
            state = .failed
            CodeTileLog.warn("web preview rule list failed to compile: previews stay off")
        }
        let pending = waiters
        waiters = []
        for waiter in pending { waiter(list) }
    }
}

/// The preview's web view: no context menu (nothing to open, download or reload from there) and no drops (a dropped
/// file or link would navigate).
final class CodeWebPreviewWebView: WKWebView {
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        menu.removeAllItems()
        super.willOpenMenu(menu, with: event)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { [] }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { false }
}

/// Lets exactly one navigation through: the first load of the file in the main frame. Every other one (a link, a meta
/// refresh, a frame, a form, a drop) is cancelled, and so is a response WebKit cannot show (no download).
final class CodeWebPreviewNavigator: NSObject, WKNavigationDelegate {
    let file: URL
    private(set) var allowedFirstLoad = false
    /// Navigations cancelled (tests).
    private(set) var cancelled = 0
    var onFinish: (() -> Void)?

    init(file: URL) { self.file = file }

    /// Whether a navigation's address is the previewed file, by text only: the address is the page's choice, so it is
    /// never looked up (`standardizedFileURL` asks the disk before it drops `/private`, docs/THREAT_MODEL.md, T33).
    static func isTheFile(_ url: URL?, _ file: URL) -> Bool {
        guard let url, url.isFileURL else { return false }
        return FolderText.lexical(url.path) == FolderText.lexical(file.path)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if !allowedFirstLoad, navigationAction.targetFrame?.isMainFrame == true, Self.isTheFile(navigationAction.request.url, file) {
            allowedFirstLoad = true
            decisionHandler(.allow)
        } else {
            cancelled += 1
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.isForMainFrame && navigationResponse.canShowMIMEType ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish?() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { onFinish?() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { onFinish?() }
}
