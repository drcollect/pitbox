import AppKit
import PitboxKit

/// What the folded rail counts (the block's header counts, in the rail's three colours).
public struct RailCounts: Equatable, Sendable {
    /// Sessions that need you (amber).
    public var needsYou: Int
    /// Sessions finished and not looked at yet (green).
    public var finished: Int
    /// Sessions running (blue).
    public var running: Int
    /// A console command is running: the blue dot pulses (shown even with no running session).
    public var commandRunning: Bool

    public init(needsYou: Int = 0, finished: Int = 0, running: Int = 0, commandRunning: Bool = false) {
        self.needsYou = needsYou
        self.finished = finished
        self.running = running
        self.commandRunning = commandRunning
    }
}

/// The rail's dot colours: the monitors' amber and green (darker in light appearances, so a dot keeps 3:1 against the
/// light glass) and the theme's running blue. Status colours keep their meaning and are not part of the accent.
public enum RailPalette {
    /// "Needs you".
    public static let needsYou = ThemeColor(light: 0x8A5200, dark: 0xF2A33A)
    /// "Finished".
    public static let finished = ThemeColor(light: 0x346B17, dark: 0x6FCF73)
    /// "Running" (and a running command, pulsing).
    public static let running = PitboxTheme.blue
}

/// The folded block: a 24 pt full-height rail with + at the top (unfold) and below it up to three dots with counts:
/// amber needs you, green finished, blue running (pulsing while a console command runs). The words are the pit-stop
/// words the header uses; VoiceOver reads the same.
///
/// Spring-loaded unfold: while a dragged window hovers over the rail, the drag controller calls `hoverBegan()`; after
/// `springLoadDelay` (0.6 s) without `hoverEnded()` the rail calls `onSpringLoadedUnfold`.
public final class FoldRailView: NSView {
    /// The counts shown. Zero counts hide their dot.
    public var counts = RailCounts() {
        didSet { if counts != oldValue { updateRows() } }
    }
    /// + was clicked.
    public var onUnfold: (() -> Void)?
    /// A hover lasted `springLoadDelay`.
    public var onSpringLoadedUnfold: (() -> Void)?
    /// Seconds a hover must last before the spring-loaded unfold.
    public var springLoadDelay: TimeInterval = 0.6
    /// True between `hoverBegan()` and the unfold or `hoverEnded()`.
    public private(set) var isSpringLoading = false {
        didSet { if isSpringLoading != oldValue { needsDisplay = true } }
    }
    /// False when the rail shows because nothing wider fits: + is then disabled.
    public var canUnfold = true {
        didSet {
            plusButton.isEnabled = canUnfold
            updatePlusWords()
            if !canUnfold { hoverEnded() }
        }
    }

    let plusButton = NSButton()
    let needsYouRow = RailDotView(color: RailPalette.needsYou)
    let finishedRow = RailDotView(color: RailPalette.finished)
    let runningRow = RailDotView(color: RailPalette.running)
    private var pendingSpring: ScheduledCall?
    /// Delayed calls (the spring-loaded timer). Tests use a manual scheduler.
    var scheduler: ShellScheduler = MainQueueScheduler.shared

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        if let plus = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold)) {
            plusButton.image = plus
            plusButton.imagePosition = .imageOnly
        } else {
            plusButton.title = "+"
        }
        plusButton.isBordered = false
        plusButton.bezelStyle = .accessoryBarAction
        plusButton.contentTintColor = PitboxTheme.accent.nsColor
        plusButton.target = self
        plusButton.action = #selector(plusClicked)
        addSubview(plusButton)
        for row in [needsYouRow, finishedRow, runningRow] { addSubview(row) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(AppIdentity.displayName), folded")
        updatePlusWords()
        updateRows()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }
    public override var wantsUpdateLayer: Bool { true }

    public override func updateLayer() {
        let dark = ThemeColor.isDark(effectiveAppearance)
        layer?.backgroundColor = isSpringLoading ? PitboxTheme.accentSoft.color(dark: dark).cgColor : NSColor.clear.cgColor
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Spring-loaded unfold

    /// A dragged window entered the rail: start the spring-loaded timer (once; a second call while it runs changes
    /// nothing). Nothing happens while the rail cannot unfold (`canUnfold` false).
    public func hoverBegan() {
        guard pendingSpring == nil, canUnfold else { return }
        isSpringLoading = true
        pendingSpring = scheduler.after(max(0, springLoadDelay)) { [weak self] in self?.springFired() }
    }

    /// The dragged window left the rail (or the drag ended): cancel the timer.
    public func hoverEnded() {
        pendingSpring?.cancel()
        pendingSpring = nil
        isSpringLoading = false
    }

    private func springFired() {
        guard pendingSpring != nil else { return }
        pendingSpring = nil
        isSpringLoading = false
        onSpringLoadedUnfold?()
    }

    // MARK: Words

    /// "1 needs you", "2 need you".
    public static func needsYouWords(_ n: Int) -> String { n == 1 ? "1 needs you" : "\(n) need you" }
    /// "3 finished".
    public static func finishedWords(_ n: Int) -> String { "\(n) finished" }
    /// "2 running", "2 running, a command is running", "a command is running".
    public static func runningWords(_ n: Int, commandRunning: Bool) -> String {
        switch (n > 0, commandRunning) {
        case (true, true): return "\(n) running, a command is running"
        case (true, false): return "\(n) running"
        case (false, true): return "a command is running"
        case (false, false): return "0 running"
        }
    }

    /// A count as the rail prints it in 24 pt: up to 99, then "99+".
    static func shortCount(_ n: Int) -> String { n > 99 ? "99+" : String(max(0, n)) }

    // MARK: Layout

    public override func layout() {
        super.layout()
        let w = bounds.width
        plusButton.frame = CGRect(x: 0, y: 8, width: w, height: 24)
        var y: CGFloat = 44
        for row in [needsYouRow, finishedRow, runningRow] where !row.isHidden {
            row.frame = CGRect(x: 0, y: y, width: w, height: RailDotView.height)
            y += RailDotView.height + 6
        }
    }

    private func updatePlusWords() {
        let name = AppIdentity.displayName
        plusButton.setAccessibilityLabel(canUnfold ? "Unfold \(name)" : "Unfold \(name): not enough room")
        plusButton.toolTip = canUnfold ? "Unfold" : "Not enough room to unfold"
    }

    private func updateRows() {
        let c = counts
        needsYouRow.set(count: c.needsYou > 0 ? Self.shortCount(c.needsYou) : nil,
                        words: c.needsYou > 0 ? Self.needsYouWords(c.needsYou) : nil, pulsing: false)
        finishedRow.set(count: c.finished > 0 ? Self.shortCount(c.finished) : nil,
                        words: c.finished > 0 ? Self.finishedWords(c.finished) : nil, pulsing: false)
        let showRunning = c.running > 0 || c.commandRunning
        runningRow.set(count: c.running > 0 ? Self.shortCount(c.running) : (c.commandRunning ? "" : nil),
                       words: showRunning ? Self.runningWords(c.running, commandRunning: c.commandRunning) : nil,
                       pulsing: c.commandRunning)
        needsLayout = true
    }

    @objc private func plusClicked() {
        guard canUnfold else { return }
        onUnfold?()
    }
}

/// One dot of the rail with its count below it; hidden when it has nothing to say. One VoiceOver element.
final class RailDotView: NSView {
    static let height: CGFloat = 24
    static let dotSize: CGFloat = 8

    private let color: ThemeColor
    let dot = CALayer()
    let label = NSTextField(labelWithString: "")
    /// True while the dot pulses (asked for, and Reduce Motion is off).
    private(set) var isPulsing = false
    /// True while a pulse is asked for (a running command), whatever Reduce Motion says.
    private(set) var wantsPulse = false

    init(color: ThemeColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(dot)
        dot.cornerRadius = Self.dotSize / 2
        dot.borderWidth = 0.5
        label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        label.alignment = .center
        label.textColor = .labelColor
        label.setAccessibilityElement(false)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    /// `count` nil hides the row; "" shows the dot alone. `words` is the VoiceOver label and the tooltip.
    func set(count: String?, words: String?, pulsing: Bool) {
        guard let count, let words else {
            isHidden = true
            setPulsing(false)
            return
        }
        isHidden = false
        label.stringValue = count
        label.isHidden = count.isEmpty
        setAccessibilityLabel(words)
        toolTip = words
        setPulsing(pulsing)
    }

    override func layout() {
        super.layout()
        let s = Self.dotSize
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.frame = CGRect(x: (bounds.width - s) / 2, y: 2, width: s, height: s)
        CATransaction.commit()
        label.frame = CGRect(x: 0, y: 2 + s + 1, width: bounds.width, height: 13)
    }

    override func updateLayer() {
        let dark = ThemeColor.isDark(effectiveAppearance)
        dot.backgroundColor = color.color(dark: dark).cgColor
        // A faint ring so the dot keeps an edge on any glass (the count beside it carries the meaning too).
        dot.borderColor = (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.25).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func setPulsing(_ on: Bool) {
        wantsPulse = on
        let pulse = on && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard pulse != isPulsing else { return }
        isPulsing = pulse
        if pulse {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 1
            animation.toValue = 0.3
            animation.duration = 0.9
            animation.autoreverses = true
            animation.repeatCount = .infinity
            dot.add(animation, forKey: "pulse")
        } else {
            dot.removeAnimation(forKey: "pulse")
        }
    }
}
