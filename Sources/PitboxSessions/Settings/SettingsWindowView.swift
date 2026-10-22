import AppKit
import PitboxKit

/// The settings window's content: plain AppKit controls in sections, each control named by its `SettingsField` (its
/// accessibility identifier), every value read from `SettingsWindowModel` and every change sent to it. System colours
/// and fonts only, so it follows light and dark. Main thread.
final class SettingsWindowView: NSView {
    let model: SettingsWindowModel
    private(set) var popUps: [SettingsField: NSPopUpButton] = [:]
    private(set) var checkboxes: [SettingsField: NSButton] = [:]
    private(set) var hotkeyFields: [SettingsHotkey: NSTextField] = [:]
    private(set) var hotkeyLines: [SettingsHotkey: NSTextField] = [:]
    private(set) var fileOnlyValues: [String: NSTextField] = [:]
    let cellWidthSlider = NSSlider(value: 323, minValue: 300, maxValue: 360, target: nil, action: nil)
    let cellWidthValue = SettingsWindowView.valueLabel()
    let fontSizeStepper = NSStepper()
    let fontSizeValue = SettingsWindowView.valueLabel()
    let errorLine = SettingsWindowView.noteLabel(color: .systemRed)
    let showFileButton = NSButton(title: "Show the settings file", target: nil, action: nil)
    private let scroll = NSScrollView()
    private let content = SettingsFlippedView()
    private let stack = NSStackView()

    static let width: CGFloat = 560
    private static let labelWidth: CGFloat = 170

    init(model: SettingsWindowModel) {
        self.model = model
        super.init(frame: CGRect(x: 0, y: 0, width: Self.width, height: 640))
        build()
        model.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    // MARK: Building

    private func build() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        scroll.documentView = content
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]
        scroll.frame = bounds
        addSubview(scroll)
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.topAnchor.constraint(equalTo: clip.topAnchor),
            content.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            content.widthAnchor.constraint(equalTo: clip.widthAnchor),
        ])

        section("Block", rows: [
            ("Columns", popUp(.columns)),
            ("Edge (alone)", popUp(.edge)),
            ("Display (alone)", popUp(.display)),
            ("Column width (alone)", sliderRow()),
        ])
        section("Monitors", rows: [
            ("Look", popUp(.look)),
            ("Desk windows", popUp(.deskWindows)),
            ("Hover peek", popUp(.peekDelay)),
            ("", checkbox(.deskTags, "Desk tags beside desk windows")),
            ("", checkbox(.dragToPark, "Drag windows into the block to pit them")),
        ])
        section("Ready and alerts", rows: [
            ("Ready for you", popUp(.ready)),
            ("", checkbox(.chime, "Chime when work is done")),
            ("", checkbox(.sayIt, "Say it when work is done")),
            ("While you were away", popUp(.recap)),
            ("Warnings", checkbox(.warningsStuck, "Looks stuck")),
            ("", checkbox(.warningsSameFile, "Same file")),
        ])
        section("Keys", rows: [
            ("Pit front window", hotkeyRow(.park, field: .parkHotkey)),
            ("Fold and unfold", hotkeyRow(.fold, field: .foldHotkey)),
        ])
        section("Dock", rows: [("", checkbox(.dock, "Dock with a host app"))])
        section("Console", rows: [
            ("Font size", stepperRow()),
            ("Theme", popUp(.consoleTheme)),
        ])
        fileOnlySection()
        errorLine.isHidden = true
        stack.addArrangedSubview(errorLine)
    }

    private func section(_ title: String, rows: [(String, NSView)]) {
        let header = NSTextField(labelWithString: title)
        header.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        header.textColor = .labelColor
        stack.addArrangedSubview(header)
        let grid = NSGridView(views: rows.map { label, control in [Self.rowLabel(label), control] })
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = Self.labelWidth
        grid.rowAlignment = .firstBaseline
        stack.addArrangedSubview(grid)
    }

    private func fileOnlySection() {
        let header = NSTextField(labelWithString: "Only in the settings file")
        header.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        stack.addArrangedSubview(header)
        let note = Self.noteLabel(color: .secondaryLabelColor)
        note.stringValue = "These keys change what runs or what is read, so the app never writes them. Edit the file to "
            + "change them; edits apply at once."
        stack.addArrangedSubview(note)
        var rows: [[NSView]] = []
        for row in model.fileOnlyRows {
            let key = Self.rowLabel(row.key)
            key.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            let value = Self.noteLabel(color: .secondaryLabelColor)
            value.setAccessibilityIdentifier("fileOnly.\(row.key)")
            fileOnlyValues[row.key] = value
            rows.append([key, value])
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 4
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = Self.labelWidth
        stack.addArrangedSubview(grid)
        showFileButton.target = self
        showFileButton.action = #selector(showFile)
        showFileButton.bezelStyle = .rounded
        showFileButton.setAccessibilityIdentifier("showSettingsFile")
        stack.addArrangedSubview(showFileButton)
    }

    private func popUp(_ field: SettingsField) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.autoenablesItems = false
        button.target = self
        button.action = #selector(popUpChanged(_:))
        button.setAccessibilityIdentifier(field.rawValue)
        button.identifier = NSUserInterfaceItemIdentifier(field.rawValue)
        popUps[field] = button
        return button
    }

    private func checkbox(_ field: SettingsField, _ title: String) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: #selector(checkboxChanged(_:)))
        button.setAccessibilityIdentifier(field.rawValue)
        button.identifier = NSUserInterfaceItemIdentifier(field.rawValue)
        checkboxes[field] = button
        return button
    }

    private func sliderRow() -> NSView {
        cellWidthSlider.numberOfTickMarks = 7
        cellWidthSlider.allowsTickMarkValuesOnly = false
        cellWidthSlider.isContinuous = false
        cellWidthSlider.target = self
        cellWidthSlider.action = #selector(cellWidthChanged(_:))
        cellWidthSlider.setAccessibilityIdentifier(SettingsField.cellWidth.rawValue)
        cellWidthSlider.identifier = NSUserInterfaceItemIdentifier(SettingsField.cellWidth.rawValue)
        cellWidthSlider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        return Self.row([cellWidthSlider, cellWidthValue])
    }

    private func stepperRow() -> NSView {
        fontSizeStepper.minValue = CodeSettings.consoleFontRange.lowerBound
        fontSizeStepper.maxValue = CodeSettings.consoleFontRange.upperBound
        fontSizeStepper.increment = 1
        fontSizeStepper.valueWraps = false
        fontSizeStepper.target = self
        fontSizeStepper.action = #selector(fontSizeChanged(_:))
        fontSizeStepper.setAccessibilityIdentifier(SettingsField.consoleFontSize.rawValue)
        fontSizeStepper.identifier = NSUserInterfaceItemIdentifier(SettingsField.consoleFontSize.rawValue)
        return Self.row([fontSizeValue, fontSizeStepper])
    }

    private func hotkeyRow(_ key: SettingsHotkey, field: SettingsField) -> NSView {
        let text = NSTextField(string: "")
        text.placeholderString = key == .park ? "ctrl+opt+p" : "ctrl+opt+c"
        text.target = self
        text.action = #selector(hotkeyEdited(_:))
        text.cell?.sendsActionOnEndEditing = true
        text.setAccessibilityIdentifier(field.rawValue)
        text.identifier = NSUserInterfaceItemIdentifier(field.rawValue)
        text.widthAnchor.constraint(equalToConstant: 200).isActive = true
        hotkeyFields[key] = text
        let line = Self.noteLabel(color: .secondaryLabelColor)
        line.setAccessibilityIdentifier(field.rawValue + ".status")
        hotkeyLines[key] = line
        let column = NSStackView(views: [text, line])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 3
        return column
    }

    // MARK: Refreshing

    /// Every control shows the model's value.
    func refresh() {
        for (field, button) in popUps {
            let list = model.choices(for: field)
            button.removeAllItems()
            for choice in list {
                button.addItem(withTitle: choice.title)
                button.lastItem?.isEnabled = choice.change != nil
            }
            if let index = list.firstIndex(where: \.selected) { button.selectItem(at: index) }
        }
        for (field, box) in checkboxes { box.state = model.isOn(field) ? .on : .off }
        let width = model.settings.cellWidth
        cellWidthSlider.doubleValue = width
        cellWidthValue.stringValue = "\(Int(width.rounded())) pt"
        let size = model.settings.console.fontSize
        fontSizeStepper.doubleValue = size
        fontSizeValue.stringValue = "\(Int(size.rounded())) pt"
        for key in SettingsHotkey.allCases {
            if let field = hotkeyFields[key], field.currentEditor() == nil, model.hotkeyErrors[key] == nil {
                field.stringValue = model.hotkeySpec(key)
            }
            let line = model.hotkeyLine(key)
            hotkeyLines[key]?.stringValue = line ?? ""
            hotkeyLines[key]?.textColor = model.hotkeyErrors[key] != nil ? .systemRed : .secondaryLabelColor
            hotkeyLines[key]?.isHidden = line == nil
        }
        for row in model.fileOnlyRows { fileOnlyValues[row.key]?.stringValue = row.value }
        errorLine.stringValue = model.lastError ?? ""
        errorLine.isHidden = model.lastError == nil
    }

    // MARK: Actions

    @objc private func popUpChanged(_ sender: NSPopUpButton) {
        guard let field = field(of: sender) else { return }
        if !model.choose(field, index: sender.indexOfSelectedItem) { refresh() }
    }

    @objc private func checkboxChanged(_ sender: NSButton) {
        guard let field = field(of: sender) else { return }
        if !model.setFlag(field, sender.state == .on) { refresh() }
    }

    @objc private func cellWidthChanged(_ sender: NSSlider) {
        if !model.setCellWidth(sender.doubleValue) { refresh() }
    }

    @objc private func fontSizeChanged(_ sender: NSStepper) {
        if !model.setConsoleFontSize(sender.doubleValue) { refresh() }
    }

    @objc private func hotkeyEdited(_ sender: NSTextField) {
        guard let key = hotkeyFields.first(where: { $0.value === sender })?.key else { return }
        model.setHotkey(key, text: sender.stringValue)
    }

    @objc private func showFile() { model.showSettingsFile() }

    private func field(of control: NSControl) -> SettingsField? {
        control.identifier.flatMap { SettingsField(rawValue: $0.rawValue) }
    }

    // MARK: Small views

    private static func rowLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.textColor = .labelColor
        label.alignment = .right
        return label
    }

    private static func valueLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.textColor = .secondaryLabelColor
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        return label
    }

    static func noteLabel(color: NSColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.textColor = color
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.preferredMaxLayoutWidth = width - labelWidth - 52
        label.isSelectable = true
        return label
    }

    private static func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        return row
    }
}

/// Top-left origin, so the scroll view starts at the first section.
final class SettingsFlippedView: NSView {
    override var isFlipped: Bool { true }
}
