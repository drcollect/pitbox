import AppKit
import PitboxKit

/// The panel's root view: the backdrop (glass, vibrancy or solid, each with the theme's tint), and on it either the block
/// (its root view on top, the console drawer at the bottom) or the fold rail. A hairline marks the window side; docked, a
/// 1 px seam marks the host side so the docked area reads as one surface. Manual layout (cheap), top-left origin.
final class BlockRootView: NSView {
    let contentContainer = BlockFlippedView()
    let blockHost = BlockFlippedView()
    let drawerHost = BlockFlippedView()
    let rail: FoldRailView
    private let windowSideLine = BlockHairlineView()
    private let hostSeam = BlockHairlineView()
    private let tintView = BlockTintView()
    private var backdropView: NSView?
    /// The backdrop in use.
    private(set) var backdrop: BlockAppearance.Backdrop

    /// The layout the content follows.
    var blockLayout: BlockLayout {
        didSet { if blockLayout != oldValue { applyLayoutState() } }
    }
    /// The drawer's height as the drawer reports it (0 when it has no tabs).
    var drawerHeight: CGFloat = 0 {
        didSet { if drawerHeight != oldValue { needsLayout = true } }
    }
    /// Above the block and below the drawer.
    var verticalPadding: CGFloat = BlockGeometry.verticalPadding {
        didSet { if verticalPadding != oldValue { needsLayout = true } }
    }

    init(frame: NSRect, layout: BlockLayout, rail: FoldRailView, backdrop: BlockAppearance.Backdrop = .glass) {
        blockLayout = layout
        self.rail = rail
        self.backdrop = backdrop
        super.init(frame: frame)
        wantsLayer = true
        contentContainer.addSubview(blockHost)
        contentContainer.addSubview(drawerHost)
        contentContainer.addSubview(rail)
        installBackdrop(backdrop)
        addSubview(windowSideLine)
        addSubview(hostSeam)
        applyLayoutState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyGlassTint()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyGlassTint()
    }

    /// Replaces the backdrop material, keeping the content.
    func setBackdrop(_ newValue: BlockAppearance.Backdrop) {
        guard newValue != backdrop else { return }
        backdrop = newValue
        installBackdrop(newValue)
    }

    /// Puts `view` into `host`, replacing what was there, sized by the root view's layout.
    func setView(_ view: NSView?, in host: NSView) {
        host.subviews.forEach { $0.removeFromSuperview() }
        guard let view else { return }
        view.frame = host.bounds
        view.autoresizingMask = [.width, .height]
        view.translatesAutoresizingMaskIntoConstraints = true
        host.addSubview(view)
    }

    /// The frames the content gets for a size, padding and drawer height (pure, for tests): the block on top, a gutter,
    /// the drawer at the bottom; both inside the horizontal padding and `verticalPadding`. Rail: the whole size.
    static func contentFrames(size: CGSize, layout: BlockLayout, drawerHeight: CGFloat,
                              verticalPadding: CGFloat = BlockGeometry.verticalPadding)
        -> (block: CGRect, drawer: CGRect, rail: CGRect) {
        let whole = CGRect(origin: .zero, size: size)
        guard !layout.showsRail else { return (.zero, .zero, whole) }
        let v = verticalPadding.isFinite ? min(max(0, verticalPadding), size.height / 2) : 0
        let inner = CGRect(x: layout.leftPadding, y: v, width: max(0, size.width - layout.leftPadding - layout.rightPadding),
                           height: max(0, size.height - 2 * v))
        let wanted = drawerHeight.isFinite ? max(0, drawerHeight) : 0
        let drawerH = min(wanted, inner.height)
        let gap = drawerH > 0 ? min(BlockGeometry.gutter, inner.height - drawerH) : 0
        let blockH = max(0, inner.height - drawerH - gap)
        let block = CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: blockH)
        let drawer = CGRect(x: inner.minX, y: inner.maxY - drawerH, width: inner.width, height: drawerH)
        return (block, drawer, .zero)
    }

    override func layout() {
        super.layout()
        backdropView?.frame = bounds
        contentContainer.frame = backdrop == .glass ? (backdropView?.bounds ?? bounds) : bounds
        tintView.frame = bounds
        let frames = Self.contentFrames(size: bounds.size, layout: blockLayout, drawerHeight: drawerHeight,
                                        verticalPadding: verticalPadding)
        blockHost.frame = frames.block
        drawerHost.frame = frames.drawer
        rail.frame = frames.rail
        let w = BlockHairlineView.width
        let windowX = blockLayout.windowSide == .left ? 0 : bounds.width - w
        windowSideLine.frame = CGRect(x: windowX, y: 0, width: w, height: bounds.height)
        let hostX = blockLayout.windowSide == .left ? bounds.width - w : 0
        hostSeam.frame = CGRect(x: hostX, y: 0, width: w, height: bounds.height)
    }

    private func applyLayoutState() {
        let rail = blockLayout.showsRail
        self.rail.isHidden = !rail
        blockHost.isHidden = rail
        drawerHost.isHidden = rail
        hostSeam.isHidden = !blockLayout.docked
        needsLayout = true
    }

    /// Glass carries the content and takes the tint as its `tintColor`; vibrancy and solid get a tint layer over the
    /// material with the content above it.
    private func installBackdrop(_ kind: BlockAppearance.Backdrop) {
        backdropView?.removeFromSuperview()
        contentContainer.removeFromSuperview()
        tintView.removeFromSuperview()
        let view: NSView
        switch kind {
        case .glass:
            let glass = NSGlassEffectView(frame: bounds)
            glass.style = .regular
            glass.cornerRadius = 0
            glass.contentView = contentContainer
            view = glass
        case .vibrancy:
            let effect = NSVisualEffectView(frame: bounds)
            effect.material = .sidebar   // AppKit's side-strip material, as the host's strip uses
            effect.blendingMode = .behindWindow
            effect.state = .active
            view = effect
        case .solid:
            view = BlockSolidView(frame: bounds)
        }
        view.autoresizingMask = [.width, .height]
        addSubview(view, positioned: .below, relativeTo: subviews.first)
        if kind != .glass {
            addSubview(tintView, positioned: .above, relativeTo: view)
            addSubview(contentContainer, positioned: .above, relativeTo: tintView)
        }
        backdropView = view
        applyGlassTint()
        needsLayout = true
    }

    /// The glass takes the theme's tint for the current appearance (resolved here, so a light/dark switch re-tints it).
    private func applyGlassTint() {
        (backdropView as? NSGlassEffectView)?.tintColor = PitboxTheme.glassTint.color(dark: ThemeColor.isDark(effectiveAppearance))
    }
}

/// Top-left origin container, so hosted content lays out like SwiftUI expects when resized.
final class BlockFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The theme's tint over the vibrancy and solid backdrops (glass takes it as its `tintColor`). Never takes clicks.
final class BlockTintView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        layer?.backgroundColor = PitboxTheme.glassTint.color(dark: ThemeColor.isDark(effectiveAppearance)).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// The solid backdrop: the window background colour of the current appearance. Never takes clicks.
final class BlockSolidView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// A one-point line in the system separator colour (follows light and dark). Never takes clicks.
final class BlockHairlineView: NSView {
    static let width: CGFloat = 1

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.separatorColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
