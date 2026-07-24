import AppKit

final class SettingsWindowController: NSWindowController, NSComboBoxDelegate {
    private let settings = SettingsStore.shared
    private let chineseFonts = NSComboBox()
    private let latinFonts = NSComboBox()
    private let fontSize = NSPopUpButton()
    private let syncOffset = NSSlider()
    private let syncOffsetValue = NSTextField(labelWithString: "")
    private let preview = NSTextField(labelWithString: "")
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 350),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Lyric Fever Scroll 设置"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        buildInterface(in: window)
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildInterface(in window: NSWindow) {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 18, right: 22)
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor)
        ])

        let explanation = NSTextField(wrappingLabelWithString:
            "歌词会整句显示；太长时只缩小字号，不进行高耗电的连续动画。"
        )
        explanation.textColor = .secondaryLabelColor
        root.addArrangedSubview(explanation)

        let families = NSFontManager.shared.availableFontFamilies.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        configure(chineseFonts, values: families, selected: settings.chineseFont)
        configure(latinFonts, values: families, selected: settings.latinFont)
        root.addArrangedSubview(row(label: "中文字体", control: chineseFonts))
        root.addArrangedSubview(row(label: "英文字体", control: latinFonts))

        for size in 9...16 { fontSize.addItem(withTitle: String(size)) }
        fontSize.selectItem(withTitle: String(Int(settings.fontSize.rounded())))
        fontSize.target = self
        fontSize.action = #selector(controlChanged)
        root.addArrangedSubview(row(label: "字号", control: fontSize))

        syncOffset.minValue = SettingsStore.minimumSyncOffset
        syncOffset.maxValue = SettingsStore.maximumSyncOffset
        syncOffset.doubleValue = settings.syncOffset
        syncOffset.isContinuous = true
        syncOffset.target = self
        syncOffset.action = #selector(syncOffsetChanged)
        syncOffset.setAccessibilityLabel("歌词同步偏移")
        syncOffset.translatesAutoresizingMaskIntoConstraints = false
        syncOffset.widthAnchor.constraint(equalToConstant: 220).isActive = true
        syncOffsetValue.alignment = .right
        syncOffsetValue.translatesAutoresizingMaskIntoConstraints = false
        syncOffsetValue.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let syncControls = NSStackView(views: [syncOffset, syncOffsetValue])
        syncControls.orientation = .horizontal
        syncControls.spacing = 8
        root.addArrangedSubview(row(label: "同步偏移", control: syncControls))
        updateSyncOffsetValue()

        preview.maximumNumberOfLines = 1
        preview.lineBreakMode = .byClipping
        preview.alignment = .center
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 7
        preview.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.heightAnchor.constraint(equalToConstant: 42).isActive = true
        root.addArrangedSubview(preview)
        preview.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 10
        let defaultsButton = NSButton(title: "恢复默认", target: self, action: #selector(restoreDefaults))
        let systemSettingsButton = NSButton(title: "打开菜单栏设置", target: self, action: #selector(openMenuBarSettings))
        let closeButton = NSButton(title: "关闭", target: self, action: #selector(closeWindow))
        closeButton.keyEquivalent = "\r"
        buttons.addArrangedSubview(defaultsButton)
        buttons.addArrangedSubview(systemSettingsButton)
        buttons.addArrangedSubview(closeButton)
        root.addArrangedSubview(buttons)

        window.initialFirstResponder = closeButton

        updatePreview()
    }

    private func configure(_ combo: NSComboBox, values: [String], selected: String) {
        combo.addItems(withObjectValues: values)
        combo.stringValue = selected
        combo.isEditable = true
        combo.completes = true
        combo.delegate = self
        combo.target = self
        combo.action = #selector(controlChanged)
        combo.translatesAutoresizingMaskIntoConstraints = false
        combo.widthAnchor.constraint(equalToConstant: 300).isActive = true
    }

    private func row(label: String, control: NSView) -> NSView {
        let title = NSTextField(labelWithString: label)
        title.alignment = .right
        title.translatesAutoresizingMaskIntoConstraints = false
        title.widthAnchor.constraint(equalToConstant: 78).isActive = true
        let row = NSStackView(views: [title, control])
        row.orientation = .horizontal
        row.spacing = 12
        return row
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        applyValues()
    }

    @objc private func controlChanged() {
        applyValues()
    }

    @objc private func syncOffsetChanged() {
        settings.syncOffset = syncOffset.doubleValue
        updateSyncOffsetValue()
        onChange()
    }

    private func applyValues() {
        if NSFont(name: chineseFonts.stringValue, size: 13) != nil {
            settings.chineseFont = chineseFonts.stringValue
        }
        if NSFont(name: latinFonts.stringValue, size: 13) != nil {
            settings.latinFont = latinFonts.stringValue
        }
        settings.fontSize = CGFloat(Int(fontSize.titleOfSelectedItem ?? "13") ?? 13)
        updatePreview()
        onChange()
    }

    private func updatePreview() {
        preview.attributedStringValue = AttributedLyricFormatter.make(
            "中文歌词 Lyrics 123",
            chineseFont: settings.chineseFont,
            latinFont: settings.latinFont,
            size: settings.fontSize
        )
    }

    private func updateSyncOffsetValue() {
        syncOffsetValue.stringValue = SettingsStore.syncOffsetLabel(settings.syncOffset)
    }

    @objc private func restoreDefaults() {
        settings.restoreDefaults()
        chineseFonts.stringValue = settings.chineseFont
        latinFonts.stringValue = settings.latinFont
        fontSize.selectItem(withTitle: String(Int(settings.fontSize)))
        syncOffset.doubleValue = settings.syncOffset
        updateSyncOffsetValue()
        updatePreview()
        onChange()
    }

    @objc private func openMenuBarSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.MenuBar-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func closeWindow() {
        window?.close()
    }
}
