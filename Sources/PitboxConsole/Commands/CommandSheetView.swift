import AppKit
import PitboxKit

/// The command sheet's content: a fixed header (title, ✕), a body that scrolls vertically when it is taller than the
/// sheet may be (rows, red lines, notes, the command area, disclosures), and a fixed footer (the machine or user
/// choice, the status line, the buttons). It draws an opaque card: nothing shows through it. It holds no authority:
/// every press goes to the controller, which checks everything again.
@MainActor
final class CommandSheetView: NSView {
    static let defaultWidth: CGFloat = 720
    static let maxWidth: CGFloat = 960
    static let side: CGFloat = 18
    static let labelWidth: CGFloat = 92
    static let headerHeight: CGFloat = 46
    static let buttonHeight: CGFloat = 30

    /// What the buttons do; set by the controller.
    struct Actions {
        var run: () -> Void = {}
        var type: () -> Void = {}
        var copy: () -> Void = {}
        var copyCleaned: () -> Void = {}
        var server: () -> Void = {}
        var fetch: () -> Void = {}
        var runInstead: () -> Void = {}
        var showInFinder: () -> Void = {}
        var openFetched: () -> Void = {}
        var cancel: () -> Void = {}
        var close: () -> Void = {}
        var tick: (String) -> Void = { _ in }
        var pickMachine: (CommandSheetState.MachinePick) -> Void = { _ in }
        var pickUser: (String) -> Void = { _ in }
        var toggle: (CommandSheetState.Disclosure) -> Void = { _ in }
        /// The bottom of the command area has been on screen.
        var scrolledToEnd: () -> Void = {}
        /// Anything was clicked or scrolled (the 10-minute timer restarts).
        var touched: () -> Void = {}
    }

    var actions = Actions()
    var palette: CommandSheetPalette { didSet { if palette != oldValue { applyPalette() } } }
    private(set) var model: CommandSheetModel?
    private var commandText = ""
    private var commandDisplay: [CommandOffer.DisplayLine] = []
    private var commandFlags: [CommandFlag] = []
    /// The palette the command area's text was built with.
    private var contentPalette: CommandSheetPalette?

    let titleField = CommandSheetView.label("", font: CommandSheetFonts.title)
    let closeButton: CommandSheetButton
    let scroll = NSScrollView()
    let body = CommandSheetBody()
    private(set) var commandArea: CommandAreaView?
    private(set) var cleanedArea: CommandAreaView?
    let messageField = CommandSheetView.label("", font: CommandSheetFonts.note)
    let pickerLabel = CommandSheetView.label("Run on:", font: CommandSheetFonts.label)
    let thisMacChip: CommandSheetButton
    let serverChip: CommandSheetButton
    let userLabel = CommandSheetView.label("Log in as:", font: CommandSheetFonts.label)
    let configUserChip: CommandSheetButton
    let replyUserChip: CommandSheetButton
    let runButton: CommandSheetButton
    let typeButton: CommandSheetButton
    let copyButton: CommandSheetButton
    let copyCleanedButton: CommandSheetButton
    let serverButton: CommandSheetButton
    let fetchButton: CommandSheetButton
    let runInsteadButton: CommandSheetButton
    let showInFinderButton: CommandSheetButton
    /// Open or Preview after a saved fetch: it opens something, so it arms like Show in Finder.
    let openFetchedButton: CommandSheetButton
    let cancelButton: CommandSheetButton
    private(set) var tickButtons: [String: CommandSheetButton] = [:]
    private(set) var disclosureButtons: [CommandSheetState.Disclosure: CommandSheetButton] = [:]
    private var bodyObserver: NSObjectProtocol?

    /// Every button that acts (the footer's, the ticks, the chips): the controller re-arms them together.
    var armedControls: [CommandSheetButton] {
        [runButton, typeButton, copyButton, copyCleanedButton, serverButton, fetchButton, runInsteadButton, showInFinderButton, openFetchedButton,
         thisMacChip, serverChip, configUserChip, replyUserChip] + Array(tickButtons.values)
    }

    private let arming: () -> CommandArming
    private let clock: () -> TimeInterval

    init(palette: CommandSheetPalette, arming: @escaping () -> CommandArming, clock: @escaping () -> TimeInterval) {
        self.palette = palette
        self.arming = arming
        self.clock = clock
        func make(_ title: String, _ style: CommandSheetButton.Style, _ rule: CommandArming.Rule, ax: Bool = false) -> CommandSheetButton {
            let button = CommandSheetButton(title: title, style: style, arming: arming, clock: clock)
            button.rule = rule
            button.allowsAccessibilityPress = ax
            return button
        }
        closeButton = make("Close", .glyph, .immediate, ax: true)
        thisMacChip = make("This Mac", .chip, .choice)
        serverChip = make("The server", .chip, .choice)
        configUserChip = make("", .chip, .choice)
        replyUserChip = make("", .chip, .choice)
        runButton = make("Yes, run this", .go, .action(risky: false))
        runButton.accessibilityHint = "click to run"
        typeButton = make("Type into terminal (don't run)", .secondary, .action(risky: false))
        typeButton.accessibilityHint = "click to type it into a new terminal tab without running it"
        copyButton = make("Copy", .secondary, .normal)
        copyCleanedButton = make("Copy cleaned", .secondary, .normal)
        // It opens a tab: the acting buttons' arming, pointer rule included (never armed under a resting pointer).
        serverButton = make("Open a terminal", .secondary, .action(risky: false))
        fetchButton = make("Fetch file", .go, .action(risky: false))
        fetchButton.accessibilityHint = "click to fetch the file"
        runInsteadButton = make("Run in terminal instead", .secondary, .normal)
        showInFinderButton = make("Show in Finder", .secondary, .normal, ax: true)
        // It opens a file: a real click only, no Accessibility press, and the acting buttons' arming and pointer rule.
        openFetchedButton = make("Open", .secondary, .action(risky: false))
        cancelButton = make("Cancel", .secondary, .immediate, ax: true)
        super.init(frame: CGRect(x: 0, y: 0, width: Self.defaultWidth, height: 400))
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Command sheet")
        addSubview(titleField)
        addSubview(closeButton)
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        scroll.documentView = body
        scroll.contentView.postsBoundsChangedNotifications = true
        addSubview(scroll)
        for view in [messageField, pickerLabel, thisMacChip, serverChip, userLabel, configUserChip, replyUserChip, copyButton,
                     copyCleanedButton, typeButton, serverButton, runInsteadButton, showInFinderButton, openFetchedButton, cancelButton, runButton,
                     fetchButton] as [NSView] { addSubview(view) }
        closeButton.onPress = { [weak self] in self?.actions.close() }
        runButton.onPress = { [weak self] in self?.actions.run() }
        typeButton.onPress = { [weak self] in self?.actions.type() }
        copyButton.onPress = { [weak self] in self?.actions.copy() }
        copyCleanedButton.onPress = { [weak self] in self?.actions.copyCleaned() }
        serverButton.onPress = { [weak self] in self?.actions.server() }
        fetchButton.onPress = { [weak self] in self?.actions.fetch() }
        runInsteadButton.onPress = { [weak self] in self?.actions.runInstead() }
        showInFinderButton.onPress = { [weak self] in self?.actions.showInFinder() }
        openFetchedButton.onPress = { [weak self] in self?.actions.openFetched() }
        cancelButton.onPress = { [weak self] in self?.actions.cancel() }
        thisMacChip.onPress = { [weak self] in self?.actions.pickMachine(.thisMac) }
        serverChip.onPress = { [weak self] in self?.actions.pickMachine(.server) }
        configUserChip.onPress = { [weak self] in
            guard let self, let choice = model?.loginChoice else { return }
            actions.pickUser(choice.config)
        }
        replyUserChip.onPress = { [weak self] in
            guard let self, let choice = model?.loginChoice else { return }
            actions.pickUser(choice.reply)
        }
        bodyObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView,
                                                              queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkScrolledToEnd()
                self?.actions.touched()
            }
        }
        applyPalette()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        if let bodyObserver { NotificationCenter.default.removeObserver(bodyObserver) }
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }

    static func label(_ text: String, font: NSFont) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.isEditable = false
        field.isSelectable = false
        field.drawsBackground = false
        field.isBordered = false
        field.refusesFirstResponder = true
        field.lineBreakMode = .byWordWrapping
        field.cell?.wraps = true
        return field
    }

    // MARK: Content

    /// Shows `model`, with the command area for `text` (its display lines and red lines).
    func apply(_ model: CommandSheetModel, text: String, displayLines: [CommandOffer.DisplayLine], flags: [CommandFlag]) {
        let commandChanged = text != commandText || displayLines != commandDisplay || flags != commandFlags || commandArea == nil
            || contentPalette != palette
        contentPalette = palette
        self.model = model
        commandText = text
        commandDisplay = displayLines
        commandFlags = flags
        titleField.stringValue = model.title
        if !model.showsCommandArea {
            // A result fetch has no command text: no command area at all.
            commandArea = nil
        } else if commandChanged {
            let content = CommandAreaContent.build(text: text, displayLines: displayLines, flags: flags, palette: palette)
            if let area = commandArea { area.setContent(content) } else { commandArea = CommandAreaView(content: content, palette: palette) }
        }
        if let cleaned = model.cleaned {
            let content = CleanedTextContent.build(cleaned, palette: palette)
            if let area = cleanedArea { area.setContent(content) } else { cleanedArea = CommandAreaView(content: content, palette: palette) }
        } else {
            cleanedArea = nil
        }
        rebuildBody()
        applyButtons()
        needsLayout = true
    }

    private func applyButtons() {
        guard let model else { return }
        func set(_ button: CommandSheetButton, _ spec: CommandSheetModel.Button) {
            button.title = spec.title
            button.isHidden = !spec.state.isShown
            button.isEnabled = spec.state.isOn
            if case .off(let reason) = spec.state { button.toolTip = reason } else { button.toolTip = nil }
        }
        set(runButton, model.run)
        runButton.style = model.isRisky ? .danger : .go
        runButton.rule = .action(risky: model.isRisky)
        set(typeButton, model.type)
        set(copyButton, model.copy)
        set(copyCleanedButton, model.copyCleaned)
        set(serverButton, model.server)
        set(fetchButton, model.fetch)
        fetchButton.rule = .action(risky: model.isRisky)
        set(runInsteadButton, model.runInstead)
        set(showInFinderButton, model.showInFinder)
        set(openFetchedButton, model.openFetched)
        set(cancelButton, model.cancel)
        let picker = model.showsMachinePicker
        pickerLabel.isHidden = !picker
        thisMacChip.isHidden = !picker
        serverChip.isHidden = !picker
        thisMacChip.isSelected = model.machinePick == .thisMac
        serverChip.isSelected = model.machinePick == .server
        if let choice = model.loginChoice {
            userLabel.isHidden = false
            configUserChip.isHidden = false
            replyUserChip.isHidden = false
            configUserChip.title = "\(choice.config) (your config)"
            replyUserChip.title = "\(choice.reply) (from the reply)"
            configUserChip.isSelected = choice.picked == choice.config
            replyUserChip.isSelected = choice.picked == choice.reply
        } else {
            userLabel.isHidden = true
            configUserChip.isHidden = true
            replyUserChip.isHidden = true
        }
        if let message = model.message {
            messageField.isHidden = false
            messageField.stringValue = message.text
            messageField.textColor = message.tone == .problem ? palette.red : (message.tone == .warning ? palette.amber : palette.dim)
        } else {
            messageField.isHidden = true
            messageField.stringValue = ""
        }
    }

    /// The body's subviews, rebuilt from the model (cheap: a sheet holds a few dozen views).
    private func rebuildBody() {
        guard let model else { return }
        body.subviews.forEach { $0.removeFromSuperview() }
        body.items = []
        body.palette = palette
        let previousTicks = tickButtons
        tickButtons = [:]
        disclosureButtons = [:]
        for warning in model.warnings {
            body.add(.text(Self.attributed([.warning(warning)], palette: palette, font: CommandSheetFonts.value), indent: 0))
        }
        for row in model.rows {
            body.add(.row(label: row.label, lines: row.lines.map { Self.attributed($0, palette: palette, font: CommandSheetFonts.value) }))
        }
        if let check = model.checkText {
            body.add(.row(label: "Check", lines: [Self.attributed([model.redLines.isEmpty ? .host(check) : .warning(check)],
                                                                  palette: palette, font: CommandSheetFonts.value)]))
        }
        for line in model.redLines {
            let tick = previousTicks[line.key] ?? CommandSheetButton(title: line.words, style: .tick, arming: arming, clock: clock)
            tick.title = line.words
            tick.detail = line.lineLabel
            tick.isSelected = line.ticked
            tick.palette = palette
            tick.rule = .choice
            tick.accessibilityHint = "click to tick this red line"
            tick.onPress = { [weak self] in self?.actions.tick(line.key) }
            tickButtons[line.key] = tick
            body.add(.tick(tick))
        }
        if let since = model.sinceLine {
            body.add(.text(Self.attributed([.dim(since)], palette: palette, font: CommandSheetFonts.note), indent: Self.labelWidth))
        }
        if !model.notes.isEmpty {
            body.add(.row(label: "Notes", lines: model.notes.map { Self.attributed([.dim("• " + $0)], palette: palette, font: CommandSheetFonts.note) }))
        }
        if let caption = model.commandCaption {
            body.add(.text(Self.attributed([.dim(caption)], palette: palette, font: CommandSheetFonts.note), indent: 0))
        }
        for line in model.sourceLines {
            body.add(.text(Self.attributed(line, palette: palette, font: CommandSheetFonts.value), indent: 12))
        }
        if let area = commandArea {
            area.palette = palette
            body.add(.command(area))
        }
        if let cleaned = model.cleaned, let area = cleanedArea {
            let words = cleaned.removed == 1 ? "1 hidden character removed" : "\(cleaned.removed) hidden characters removed"
            body.add(.text(Self.attributed([.host("Cleaned: \(words), each place marked ‸. This is what Copy cleaned copies.")],
                                           palette: palette, font: CommandSheetFonts.note), indent: 0))
            area.palette = palette
            body.add(.command(area))
        }
        var disclosures: [CommandSheetButton] = []
        for section in model.sections {
            let button = CommandSheetButton(title: (section.isOpen ? "▾ " : "▸ ") + section.title, style: .plain, arming: arming, clock: clock)
            button.rule = .immediate
            button.allowsAccessibilityPress = true
            button.palette = palette
            let disclosure = section.disclosure
            button.onPress = { [weak self] in self?.actions.toggle(disclosure) }
            disclosureButtons[disclosure] = button
            disclosures.append(button)
        }
        if !disclosures.isEmpty { body.add(.buttons(disclosures)) }
        for section in model.sections where section.isOpen {
            if let caption = section.caption {
                body.add(.text(Self.attributed([.dim(section.title + " · " + caption)], palette: palette, font: CommandSheetFonts.note), indent: 0))
            }
            for line in section.lines {
                body.add(.text(Self.attributed(line, palette: palette, font: CommandSheetFonts.note), indent: 12))
            }
        }
        if let footer = model.footer {
            body.add(.text(Self.attributed([.dim(footer)], palette: palette, font: CommandSheetFonts.note), indent: 0))
        }
    }

    /// Turns parts into one attributed line: session text quoted, regular weight, on its own faint background.
    static func attributed(_ parts: [CommandSheetModel.Part], palette: CommandSheetPalette, font: NSFont) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for part in parts {
            switch part {
            case .host(let text):
                out.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: palette.fg]))
            case .session(let text):
                let quote: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: palette.faint, .backgroundColor: palette.sessionBackground]
                out.append(NSAttributedString(string: "“", attributes: quote))
                out.append(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: font.pointSize, weight: .regular),
                                                                         .foregroundColor: palette.fg, .backgroundColor: palette.sessionBackground]))
                out.append(NSAttributedString(string: "”", attributes: quote))
            case .dim(let text):
                out.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: palette.dim]))
            case .mono(let text):
                out.append(NSAttributedString(string: text, attributes: [.font: CommandSheetFonts.monoSmall, .foregroundColor: palette.fg]))
            case .warning(let text):
                out.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: palette.amber]))
            }
        }
        return out
    }

    private func applyPalette() {
        titleField.textColor = palette.fg
        pickerLabel.textColor = palette.dim
        userLabel.textColor = palette.dim
        for button in armedControls + [closeButton, cancelButton] { button.palette = palette }
        commandArea?.palette = palette
        needsDisplay = true
        if model != nil, let model { apply(model, text: commandText, displayLines: commandDisplay, flags: commandFlags) }
    }

    // MARK: Layout

    private var footerHeight: CGFloat {
        var height: CGFloat = 14 + Self.buttonHeight + 16
        if !messageField.isHidden { height += messageHeight(width: bounds.width - 2 * Self.side) + 6 }
        if !pickerLabel.isHidden { height += 26 + 8 }
        if !userLabel.isHidden { height += 26 + 8 }
        return height
    }

    private func messageHeight(width: CGFloat) -> CGFloat {
        ceil(messageField.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: width, height: 10_000)).height ?? 16)
    }

    /// The height the sheet wants at `width`: header, the whole body, footer.
    func naturalHeight(width: CGFloat) -> CGFloat {
        Self.headerHeight + body.contentHeight(width: width - 2 * Self.side) + footerHeight
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        titleField.frame = CGRect(x: Self.side, y: 14, width: width - 2 * Self.side - 30, height: 22)
        closeButton.frame = CGRect(x: width - Self.side - 24, y: 12, width: 24, height: 24)
        let footer = footerHeight
        scroll.frame = CGRect(x: Self.side, y: Self.headerHeight, width: width - 2 * Self.side,
                              height: max(40, bounds.height - Self.headerHeight - footer))
        body.layoutContent(width: scroll.frame.width)
        layoutFooter(top: bounds.height - footer + 6)
        checkScrolledToEnd()
    }

    private func layoutFooter(top: CGFloat) {
        let width = bounds.width
        var y = top
        if !pickerLabel.isHidden {
            pickerLabel.frame = CGRect(x: Self.side, y: y + 5, width: 64, height: 18)
            var x = Self.side + 70
            for chip in [thisMacChip, serverChip] {
                let w = chip.naturalWidth
                chip.frame = CGRect(x: x, y: y, width: w, height: 26)
                x += w + 8
            }
            y += 34
        }
        if !userLabel.isHidden {
            userLabel.frame = CGRect(x: Self.side, y: y + 5, width: 70, height: 18)
            var x = Self.side + 76
            for chip in [configUserChip, replyUserChip] {
                let w = chip.naturalWidth
                chip.frame = CGRect(x: x, y: y, width: w, height: 26)
                x += w + 8
            }
            y += 34
        }
        if !messageField.isHidden {
            let h = messageHeight(width: width - 2 * Self.side)
            messageField.frame = CGRect(x: Self.side, y: y, width: width - 2 * Self.side, height: h)
            y += h + 6
        }
        y += 8
        // Right: Cancel then the action, bottom right, away from the click that opened the sheet.
        var right = width - Self.side
        for button in [runButton, fetchButton, cancelButton] where !button.isHidden {
            let w = max(button.naturalWidth, button === cancelButton ? 84 : 120)
            button.frame = CGRect(x: right - w, y: y, width: w, height: Self.buttonHeight)
            right -= w + 10
        }
        var left = Self.side
        for button in [copyButton, copyCleanedButton, typeButton, serverButton, runInsteadButton, openFetchedButton, showInFinderButton] where !button.isHidden {
            let w = button.naturalWidth
            button.frame = CGRect(x: left, y: y, width: w, height: Self.buttonHeight)
            left += w + 8
        }
    }

    /// Reports once the bottom of the command area is inside the visible part of the body.
    func checkScrolledToEnd() {
        guard let area = commandArea, area.superview === body else { return }
        let visible = scroll.contentView.documentVisibleRect
        if area.frame.maxY <= visible.maxY + 0.5, area.frame.height > 0 { actions.scrolledToEnd() }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
        palette.fill.setFill()
        card.fill()
        palette.outline.setStroke()
        card.lineWidth = 1
        card.stroke()
        palette.line.setFill()
        CGRect(x: Self.side, y: Self.headerHeight - 2, width: bounds.width - 2 * Self.side, height: 1).fill()
        let footerTop = bounds.height - footerHeight
        CGRect(x: Self.side, y: footerTop, width: bounds.width - 2 * Self.side, height: 1).fill()
    }

    override func mouseDown(with event: NSEvent) { actions.touched() }
    override func scrollWheel(with event: NSEvent) {
        actions.touched()
        super.scrollWheel(with: event)
    }
}

/// The cleaned text for Copy cleaned (B1): shown in the command area's style, with a red `‸` where something was
/// removed (the mark is drawn only; it is not part of what is copied). No comment dimming or here-doc panels here: it
/// is the text to copy, never the text that runs.
enum CleanedTextContent {
    static func build(_ cleaned: CommandSheetModel.Cleaned, palette: CommandSheetPalette) -> CommandAreaContent {
        let content = CommandAreaContent.build(text: cleaned.text, displayLines: [], flags: [], palette: palette, marks: .empty)
        let marked = NSMutableAttributedString(attributedString: content.attributed)
        // From the end, so the earlier display locations stay valid.
        for mark in cleaned.marks.reversed() {
            let location = mark < content.displayLocation.count ? content.displayLocation[mark] : marked.length
            marked.insert(NSAttributedString(string: "‸", attributes: [.font: CommandSheetFonts.mono, .foregroundColor: palette.red]),
                          at: min(location, marked.length))
        }
        return CommandAreaContent(attributed: marked, paragraphs: content.paragraphs, underlined: [],
                                  accessibilityText: cleaned.text, displayLocation: [], panels: [])
    }
}

/// The body of the sheet: a flipped stack of rows laid out for a width.
@MainActor
final class CommandSheetBody: NSView {
    enum Item {
        case row(label: String, lines: [NSAttributedString])
        case text(NSAttributedString, indent: CGFloat)
        case tick(CommandSheetButton)
        case command(CommandAreaView)
        case buttons([CommandSheetButton])
    }

    var items: [Item] = [] { didSet { if items.isEmpty { fields = [] } } }
    private var fields: [[NSView]] = []
    var palette = CommandSheetPalette(dark: true)

    override var isFlipped: Bool { true }

    func add(_ item: Item) {
        items.append(item)
        var views: [NSView] = []
        switch item {
        case .row(let label, let lines):
            let labelField = CommandSheetView.label(label, font: CommandSheetFonts.label)
            labelField.textColor = palette.dim
            views.append(labelField)
            for line in lines {
                let field = CommandSheetView.label("", font: CommandSheetFonts.value)
                field.attributedStringValue = line
                views.append(field)
            }
        case .text(let text, _):
            let field = CommandSheetView.label("", font: CommandSheetFonts.note)
            field.attributedStringValue = text
            views.append(field)
        case .tick(let button):
            views.append(button)
        case .command(let area):
            views.append(area)
        case .buttons(let buttons):
            views += buttons
        }
        views.forEach(addSubview)
        fields.append(views)
    }

    /// Lays everything out for `width` and sizes the body to fit.
    func layoutContent(width: CGFloat) {
        let height = place(width: width, apply: true)
        setFrameSize(CGSize(width: width, height: height))
    }

    func contentHeight(width: CGFloat) -> CGFloat { place(width: width, apply: false) }

    @discardableResult
    private func place(width: CGFloat, apply: Bool) -> CGFloat {
        var y: CGFloat = 12
        let valueX = CommandSheetView.labelWidth
        let valueWidth = max(60, width - valueX)
        for (index, item) in items.enumerated() where index < fields.count {
            let views = fields[index]
            switch item {
            case .row:
                var lineY = y
                if apply, let label = views.first { label.frame = CGRect(x: 0, y: y + 1, width: valueX - 8, height: 18) }
                for field in views.dropFirst() {
                    let h = Self.height(of: field, width: valueWidth)
                    if apply { field.frame = CGRect(x: valueX, y: lineY, width: valueWidth, height: h) }
                    lineY += h + 2
                }
                y = max(lineY, y + 20) + 6
            case .text(_, let indent):
                guard let field = views.first else { continue }
                let h = Self.height(of: field, width: width - indent)
                if apply { field.frame = CGRect(x: indent, y: y, width: width - indent, height: h) }
                y += h + 8
            case .tick(let button):
                let h = button.tickHeight(width: valueWidth)
                if apply { button.frame = CGRect(x: valueX, y: y, width: valueWidth, height: h) }
                y += h + 6
            case .command(let area):
                y += 4
                let h = area.height(for: width)
                if apply { area.frame = CGRect(x: 0, y: y, width: width, height: h) }
                y += h + 10
            case .buttons(let buttons):
                var x: CGFloat = -6
                for button in buttons {
                    let w = button.naturalWidth
                    if apply { button.frame = CGRect(x: x, y: y, width: w, height: 24) }
                    x += w + 6
                }
                y += 30
            }
        }
        return y + 4
    }

    static func height(of field: NSView, width: CGFloat) -> CGFloat {
        guard let field = field as? NSTextField else { return 18 }
        return ceil(field.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: width, height: 100_000)).height ?? 18)
    }
}
