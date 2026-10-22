import AppKit
import PitboxKit
import WebKit

/// The preview's content: an opaque dark card with a header (the file's name, "No scripts, nothing loaded from the
/// internet", Show in Finder, Close) above the page. Nothing shows through it; it takes no keyboard.
final class CodeWebPreviewContent: NSView {
    static let note = "Preview · no scripts, nothing loaded from the internet"
    static let cardFill: UInt32 = 0x16181D
    static let cardLine: UInt32 = 0x3A3D45
    static let titleColor: UInt32 = 0xF3F4F6
    static let noteColor: UInt32 = 0x9097A4

    let title: String
    private(set) var webView: WKWebView?
    let buttons: CodeResultButtonsView
    var onClose: (() -> Void)?
    var onShowInFinder: (() -> Void)?

    init(title: String, webView: WKWebView?) {
        self.title = title
        self.webView = webView
        buttons = CodeResultButtonsView(buttons: [
            CodeResultButton(resultID: "preview", action: .showInFinder, title: "Show in Finder", tone: .neutral, arms: true),
            CodeResultButton(resultID: "preview", action: .open, title: "Close", tone: .neutral, arms: false),
        ], width: 220)
        super.init(frame: CGRect(origin: .zero, size: CodeWebPreviewController.size))
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Preview")
        buttons.onPress = { [weak self] button in
            if button.action == .showInFinder { self?.onShowInFinder?() } else { self?.onClose?() }
        }
        addSubview(buttons)
        if let webView { addSubview(webView) }
        needsLayout = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        let header = CodeWebPreviewController.headerHeight
        let buttonsWidth = CodeResultButtonsView.naturalWidth(of: buttons.buttons) + 2
        buttons.frame = CGRect(x: bounds.width - buttonsWidth - 12, y: (header - CodeResultButtonsView.pillHeight) / 2,
                               width: buttonsWidth, height: CodeResultButtonsView.pillHeight)
        webView?.frame = CGRect(x: 1, y: header, width: max(0, bounds.width - 2), height: max(0, bounds.height - header - 1))
    }

    override func draw(_ dirtyRect: NSRect) {
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        CodeResultPalette.color(Self.cardFill).setFill()
        card.fill()
        CodeResultPalette.color(Self.cardLine).setStroke()
        card.lineWidth = 1
        card.stroke()
        let textWidth = max(40, buttons.frame.minX - 14 - 16)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        (title as NSString).draw(in: CGRect(x: 14, y: 6, width: textWidth, height: 18), withAttributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: CodeResultPalette.color(Self.titleColor),
            .paragraphStyle: paragraph,
        ])
        (Self.note as NSString).draw(in: CGRect(x: 14, y: 24, width: textWidth, height: 16), withAttributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: CodeResultPalette.color(Self.noteColor), .paragraphStyle: paragraph,
        ])
    }
}
