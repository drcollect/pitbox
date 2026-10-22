import AppKit
import PitboxKit
import WebKit

/// Shows one web document in the app's script-free preview (`CodeWebPreview`): a borderless, non-activating
/// panel beside the block that never becomes key (keys keep going where they went), with the file's name, "No scripts,
/// nothing loaded from the internet", Show in Finder and ✕. Escape closes it while the app is the active app (a
/// local monitor; the panel itself takes no keys). The file was checked at the click (`CodeResultActions`); only that
/// file is readable to the page. One preview at a time: a new one replaces it. The block closes it when it hides.
@MainActor
public final class CodeWebPreviewController {
    /// The preview's size (it fits in 80 % of the screen's height and its width, beside the block).
    static let size = CGSize(width: 760, height: 620)
    static let headerHeight: CGFloat = 46

    private let rules: CodeWebPreviewRules
    private let revealInFinder: (URL) -> Void
    private var panel: CodeWebPreviewPanel?
    private var navigator: CodeWebPreviewNavigator?
    private var keyMonitor: Any?
    private var generation = 0
    /// The block's frame (screen coordinates), so the preview opens beside it; nil places it by the anchor.
    public var stripFrame: () -> CGRect? = { nil }
    /// Called after the preview closed.
    public var onClose: (() -> Void)?

    /// - Parameters:
    ///   - revealInFinder: Show in Finder (`NSWorkspace.shared.activateFileViewerSelecting`).
    public convenience init(revealInFinder: @escaping (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }) {
        self.init(ruleListFolder: CodeWebPreview.defaultRuleListFolder, revealInFinder: revealInFinder)
    }

    /// Tests: the rule list compiled into `ruleListFolder`.
    init(ruleListFolder: URL, revealInFinder: @escaping (URL) -> Void) {
        rules = CodeWebPreviewRules(folder: ruleListFolder)
        self.revealInFinder = revealInFinder
    }

    /// Whether a preview is on screen.
    public var isShown: Bool { panel?.isVisible ?? false }

    /// Shows `file` (a checked local web document), titled `name` (session text, through the renderer), beside the
    /// block, level with `anchor` (screen coordinates). `beside`: a window next to the block the preview must not cover
    /// either (the command sheet, for a fetched file's Preview). Nothing opens when the network rule list cannot be
    /// compiled.
    public func show(_ file: URL, name: String, anchor: CGRect, beside: CGRect? = nil) {
        close()
        generation += 1
        let mine = generation
        rules.whenReady { [weak self] list in
            guard let self, self.generation == mine else { return }
            guard let list else { return }
            self.present(file, name: name, anchor: anchor, beside: beside, ruleList: list)
        }
    }

    /// Closes the preview (✕, Escape, the block hiding).
    public func close() {
        generation += 1
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        guard let panel else { return }
        self.panel = nil
        navigator = nil
        panel.content.webView?.stopLoading()
        panel.orderOut(nil)
        panel.contentView = nil
        onClose?()
    }

    /// Tests: the web view of the preview on screen, and its navigator.
    var webView: WKWebView? { panel?.content.webView }
    var currentNavigator: CodeWebPreviewNavigator? { navigator }
    var currentPanel: NSPanel? { panel }
    /// Tests: where the panel goes instead of beside the block (off screen).
    var placementOverride: CGRect?

    private func present(_ file: URL, name: String, anchor: CGRect, beside: CGRect?, ruleList: WKContentRuleList) {
        let configuration = CodeWebPreview.configuration(ruleList: ruleList)
        let web = CodeWebPreviewWebView(frame: .zero, configuration: configuration)
        web.unregisterDraggedTypes()
        let navigator = CodeWebPreviewNavigator(file: file)
        web.navigationDelegate = navigator
        let title = CodePlainText.line(name, limit: 200) ?? "Preview"
        let content = CodeWebPreviewContent(title: title, webView: web)
        content.onClose = { [weak self] in self?.close() }
        content.onShowInFinder = { [weak self] in self?.revealInFinder(file) }
        let panel = CodeWebPreviewPanel(content: content)
        panel.setFrame(placementOverride ?? placement(anchor: anchor, beside: beside), display: false)
        self.panel = panel
        self.navigator = navigator
        panel.orderFrontRegardless()
        web.loadFileURL(file, allowingReadAccessTo: file)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }   // Escape
            MainActor.assumeIsolated { self?.close() }
            return nil
        }
        CodeTileLog.info("web preview opened")
    }

    private func placement(anchor: CGRect, beside: CGRect?) -> CGRect {
        let strip = stripFrame()
        let screen = (NSScreen.screens.first { $0.frame.intersects(strip ?? anchor) } ?? NSScreen.main)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return CodeWebPreviewPlacement.frame(size: Self.size, anchor: anchor, strip: strip, beside: beside, screen: screen,
                                             pointer: NSEvent.mouseLocation)
    }
}

/// Where the preview goes (screen coordinates, y up): beside the block (and `beside`, a window next to it such as the
/// command sheet) on the side facing the rest of the screen, level with the button it came from, on screen, at most
/// 80 % of the screen high, never under the pointer. Pure.
enum CodeWebPreviewPlacement {
    static let gap: CGFloat = 10
    static let margin: CGFloat = 10

    static func frame(size: CGSize, anchor: CGRect, strip: CGRect?, beside: CGRect? = nil, screen: CGRect,
                      pointer: CGPoint?) -> CGRect {
        let width = min(size.width, max(screen.width - 2 * margin, 200))
        let height = min(size.height, max(screen.height * 0.8, 200), screen.height - 2 * margin)
        var reference = strip ?? anchor
        if let beside { reference = strip?.union(beside) ?? beside }
        var x: CGFloat
        if reference.minX - gap - width >= screen.minX + margin {
            x = reference.minX - gap - width
        } else if reference.maxX + gap + width <= screen.maxX - margin {
            x = reference.maxX + gap
        } else {
            x = screen.minX + margin
        }
        var y = min(max(anchor.midY - height / 2, screen.minY + margin), screen.maxY - margin - height)
        if let pointer, CGRect(x: x, y: y, width: width, height: height).insetBy(dx: -4, dy: -4).contains(pointer) {
            if pointer.y + 16 + height <= screen.maxY - margin {
                y = pointer.y + 16
            } else if pointer.y - 16 - height >= screen.minY + margin {
                y = pointer.y - 16 - height
            } else {
                x = pointer.x - 16 - width >= screen.minX + margin ? pointer.x - 16 - width : min(pointer.x + 16, screen.maxX - margin - width)
            }
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// The preview's window: borderless, non-activating, floating, never key or main; key events that reach it are dropped.
final class CodeWebPreviewPanel: NSPanel {
    let content: CodeWebPreviewContent

    init(content: CodeWebPreviewContent) {
        self.content = content
        super.init(contentRect: CGRect(origin: .zero, size: CodeWebPreviewController.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        tabbingMode = .disallowed
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        level = .floating
        // Best effort only (nothing is promised about screen sharing).
        sharingType = .none
        contentView = content
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func makeKey() {}
    override func makeMain() {}
    override func performKeyEquivalent(with event: NSEvent) -> Bool { false }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown, .keyUp, .flagsChanged: return
        default: super.sendEvent(event)
        }
    }
}
