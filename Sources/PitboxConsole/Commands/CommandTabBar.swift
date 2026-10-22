import AppKit
import PitboxKit

/// What a command or Type tab's bar says. Pure, so tests check every state.
struct CommandBarContent: Equatable {
    enum Tone: Equatable { case starting, running, ok, failed, typed, neutral }

    /// "From " and the rest of the origin line in Pitbox's words; the headline is session text, drawn quoted.
    var headline: String
    var originTail: String
    var state: String
    var tone: Tone
    var showsStop: Bool
    var stopTitle: String

    @MainActor
    static func make(_ command: CommandTab, now: Date) -> CommandBarContent {
        let origin = command.origin
        var tail: [String] = []
        if let profile = origin.profileName { tail.append(SessionTitle.clean(profile, limit: 24)) }
        tail.append(origin.machineLabel)
        tail.append(origin.folderShort)
        let headline = CommandPlainText.singleLine(origin.headline, maxCharacters: 60)
        let keyboard = command.keyboardHere ? "Keyboard: here" : "Keyboard: elsewhere, click here to type"
        var state: String
        var tone: Tone
        var showsStop = false
        switch command.role {
        case .run, .server:
            switch command.phase {
            case .waiting, .starting:
                state = "Starting…"
                tone = .starting
            case .running:
                let elapsed = CommandTimeFormat.running(now.timeIntervalSince(command.startedAt ?? now))
                if command.asksForHiddenInput {
                    state = "running \(elapsed) · " + (command.keyboardHere ? "asks for hidden input · Keyboard: here"
                                                                              : "asks for hidden input, click here to type")
                } else {
                    state = "running \(elapsed) · \(keyboard)"
                }
                if command.stopPresses == 1 { state += " · Stop sent (Ctrl-C)" }
                tone = .running
                showsStop = true
            case .ended(let exit):
                let seconds = (command.endedAt ?? now).timeIntervalSince(command.startedAt ?? command.endedAt ?? now)
                let duration = CommandTimeFormat.duration(seconds)
                switch exit {
                case .exited(let code):
                    state = "Finished · exit \(code) · \(duration)"
                    if code == 127 { state += " · a program wasn't found in the clean shell's PATH (add its folder to extraPath) or couldn't start here" }
                    tone = code == 0 ? .ok : .failed
                case .signaled(let signal):
                    state = "Stopped by signal \(signal)\(ProcessExit.signalName(signal).map { " (\($0))" } ?? "") · \(duration)"
                    tone = .failed
                case .unknown:
                    state = "Finished · exit status unknown · \(duration)"
                    tone = .neutral
                }
                if command.stopPresses > 0 { state += " · after Stop" }
            case .didNotStart(let reason):
                state = "Did not start: \(reason)"
                tone = .failed
            }
        case .typeIntoTerminal:
            switch (command.phase, command.typing) {
            case (.didNotStart(let reason), _):
                state = "Did not start: \(reason)"
                tone = .failed
            case (.ended(let exit), _):
                state = "Shell ended · \(exit.summary.lowercased())"
                tone = .neutral
            case (_, .waitingForShell):
                state = "Starting a clean shell…"
                tone = .starting
            case (_, .typed):
                state = command.keyboardHere ? "Typed, not run · press Return to run it" : "Typed, not run · click here, then Return to run it"
                tone = .typed
            case (_, .notTyped):
                state = "Not typed: the shell wasn't ready; use Copy"
                tone = .failed
            default:
                state = "Clean shell (no startup files) · \(keyboard)"
                tone = .neutral
            }
        }
        return CommandBarContent(headline: headline, originTail: tail.joined(separator: " · "), state: state, tone: tone,
                                 showsStop: showsStop, stopTitle: command.stopPresses == 0 ? "Stop" : "Kill")
    }
}

/// The native bar above a command or Type tab's terminal: read-only lines no program output can reach, and
/// Stop. Where the command came from, its state, who has the keyboard, how it ended: what Pitbox vouches for, not
/// the terminal text. A click on the bar (outside Stop) gives the tab the keyboard, as a click in the terminal does.
@MainActor
final class CommandTabBar: NSView {
    static let height: CGFloat = 44

    var content: CommandBarContent? { didSet { if content != oldValue { needsDisplay = true; updateStop(); updateAccessibility() } } }
    var palette: TerminalPalette = TerminalTheme.dark { didSet { if palette != oldValue { needsDisplay = true } } }
    /// A click on the bar's text: "click here to type".
    var onClickToType: (() -> Void)?
    var onStop: (() -> Void)?

    let stopButton = CommandBarButton(title: "Stop")

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(stopButton)
        stopButton.onPress = { [weak self] in self?.onStop?() }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Command")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        let width = stopButton.naturalWidth
        stopButton.frame = CGRect(x: bounds.width - width - 10, y: bounds.height - 6 - 22, width: width, height: 22)
    }

    private func updateStop() {
        stopButton.isHidden = !(content?.showsStop ?? false)
        stopButton.title = content?.stopTitle ?? "Stop"
        needsLayout = true
    }

    private func updateAccessibility() {
        guard let content else { return }
        setAccessibilityValue("From “\(content.headline)” · \(content.originTail). \(content.state)")
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 1 else { return }
        onClickToType?()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let dark = palette.isDark
        (dark ? NSColor(white: 1, alpha: 0.07) : NSColor(white: 0, alpha: 0.05)).setFill()
        bounds.fill()
        (dark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.12)).setFill()
        CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        guard let content else { return }
        let fg = palette.foreground
        let dim = fg.withAlphaComponent(0.66)
        let small = NSFont.systemFont(ofSize: 12, weight: .regular)
        let strong = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let line1 = NSMutableAttributedString(string: "From ", attributes: [.font: strong, .foregroundColor: dim])
        line1.append(NSAttributedString(string: "“" + content.headline + "”", attributes: [
            .font: small, .foregroundColor: fg, .backgroundColor: fg.withAlphaComponent(dark ? 0.08 : 0.06)]))
        line1.append(NSAttributedString(string: " · " + content.originTail, attributes: [.font: small, .foregroundColor: dim]))
        let textWidth = bounds.width - 20 - (content.showsStop ? stopButton.naturalWidth + 12 : 0)
        line1.draw(with: CGRect(x: 10, y: 5, width: max(10, bounds.width - 20), height: 16),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        let dot = CGRect(x: 10, y: 28, width: 7, height: 7)
        toneColor(content.tone).setFill()
        NSBezierPath(ovalIn: dot).fill()
        let state = NSAttributedString(string: content.state, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                                                                          .foregroundColor: fg])
        state.draw(with: CGRect(x: 23, y: 23, width: max(10, textWidth - 13), height: 16),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func toneColor(_ tone: CommandBarContent.Tone) -> NSColor {
        switch tone {
        case .starting, .running: return palette.ansi[12]
        case .ok: return palette.ansi[2]
        case .failed: return palette.ansi[1]
        case .typed: return palette.ansi[3]
        case .neutral: return palette.foreground.withAlphaComponent(0.5)
        }
    }
}

/// The bar's Stop button: mouse only, acts on release inside, never first responder. Stop only ever stops things, so
/// VoiceOver may press it.
@MainActor
final class CommandBarButton: NSView {
    var title: String { didSet { if title != oldValue { needsDisplay = true } } }
    var onPress: (() -> Void)?
    private var pressed = false

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityLabel() -> String? { title }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }

    var naturalWidth: CGFloat {
        ceil((title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width) + 20
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 1 else { return }
        pressed = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        let wasPressed = pressed
        pressed = false
        needsDisplay = true
        if wasPressed, inside { onPress?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = ThemeColor.isDark(effectiveAppearance)
        let fill = pressed ? NSColor.systemRed.withAlphaComponent(0.55) : NSColor.systemRed.withAlphaComponent(dark ? 0.32 : 0.18)
        fill.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6).fill()
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let ink = dark ? NSColor(white: 1, alpha: 0.95) : NSColor(srgbRed: 0.55, green: 0.05, blue: 0.05, alpha: 1)
        let size = (title as NSString).size(withAttributes: [.font: font])
        (title as NSString).draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                                 withAttributes: [.font: font, .foregroundColor: ink])
    }
}
