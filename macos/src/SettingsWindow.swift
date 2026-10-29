import AppKit

// A whole-number box with up/down arrows, like WinForms' NumericUpDown.
final class NumberBox: NSStackView, NSTextFieldDelegate {
    private let field = NSTextField()
    private let stepper = NSStepper()
    private let lo: Int, hi: Int

    init(min lo: Int, max hi: Int, step: Int = 1, value: Int) {
        self.lo = lo
        self.hi = hi
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 2
        field.alignment = .right
        field.bezelStyle = .roundedBezel
        field.widthAnchor.constraint(equalToConstant: 46).isActive = true
        field.delegate = self
        stepper.minValue = Double(lo)
        stepper.maxValue = Double(hi)
        stepper.increment = Double(step)
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = #selector(stepped)
        addArrangedSubview(field)
        addArrangedSubview(stepper)
        setHuggingPriority(.required, for: .horizontal)
        self.value = value
    }

    required init?(coder: NSCoder) { fatalError() }

    var value: Int {
        get { return AppSettings.clamp(Int(field.stringValue.trimmingCharacters(in: .whitespaces)) ?? stepper.integerValue, lo, hi) }
        set {
            let v = AppSettings.clamp(newValue, lo, hi)
            field.integerValue = v
            stepper.integerValue = v
        }
    }

    var isEnabled: Bool {
        get { return field.isEnabled }
        set {
            field.isEnabled = newValue
            stepper.isEnabled = newValue
        }
    }

    @objc private func stepped() {
        field.integerValue = stepper.integerValue
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        value = value // clamp what was typed
    }
}

final class SettingsWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    var onClose: (() -> Void)?

    private let original: AppSettings
    private let onSave: (AppSettings) throws -> Void
    private let startupWasEnabled: Bool

    private let routerRows = NSStackView()
    private let pingBox = NSTextField()
    private let chkPing, chkUp, chkDown, chkStartup, chkAstrill, chkAutoSwitch: NSButton
    private let foreColorWell = NSColorWell(), backColorWell = NSColorWell()
    private let fontSizeBox, opacityBox, autoSwitchBox, switchTimeoutBox: NumberBox

    init(settings: AppSettings, onSave: @escaping (AppSettings) throws -> Void) {
        original = settings
        self.onSave = onSave
        startupWasEnabled = Startup.isEnabled()

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        chkAutoSwitch = SettingsWindow.check("Switch to next router when ping times out for", settings.autoSwitch)
        chkPing = SettingsWindow.check("Ping", settings.showPing)
        chkUp = SettingsWindow.check("Upload", settings.showUpload)
        chkDown = SettingsWindow.check("Download", settings.showDownload)
        chkStartup = SettingsWindow.check("Open at login", startupWasEnabled)
        chkAstrill = SettingsWindow.check("Toggle Astrill VPN off/on when switching router", settings.toggleAstrill)
        autoSwitchBox = NumberBox(min: AppSettings.minAutoSwitchSeconds, max: AppSettings.maxSeconds, value: settings.autoSwitchSeconds)
        switchTimeoutBox = NumberBox(min: AppSettings.minSwitchTimeoutSeconds, max: AppSettings.maxSeconds, value: settings.switchTimeoutSeconds)
        fontSizeBox = NumberBox(min: 6, max: 36, value: Int(settings.fontSize.rounded()))
        opacityBox = NumberBox(min: 20, max: 100, step: 5, value: settings.opacity)
        super.init()

        window.title = "Ping Gadget Settings"
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.delegate = self

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 6
        root.edgeInsets = NSEdgeInsets(top: 4, left: 16, bottom: 16, right: 16)

        // Routers
        addHeader("Routers", to: root)
        root.addArrangedSubview(row([caption("Name", 140), caption("IP address", 120)]))
        routerRows.orientation = .vertical
        routerRows.alignment = .leading
        routerRows.spacing = 4
        root.addArrangedSubview(routerRows)
        for r in settings.routers { addRouterRow(r.name, r.ip, at: nil) }
        if settings.routers.isEmpty { addRouterRow("", "", at: nil) }

        // Ping target
        addHeader("Ping", to: root)
        pingBox.stringValue = settings.pingTarget
        pingBox.bezelStyle = .roundedBezel
        pingBox.widthAnchor.constraint(equalToConstant: 270).isActive = true
        root.addArrangedSubview(pingBox)
        autoSwitchBox.isEnabled = chkAutoSwitch.state == .on
        chkAutoSwitch.target = self
        chkAutoSwitch.action = #selector(autoSwitchChanged)
        root.addArrangedSubview(row([chkAutoSwitch, autoSwitchBox, label("seconds")]))

        // What to show
        addHeader("Show", to: root)
        root.addArrangedSubview(row([chkPing, chkUp, chkDown]))

        // Startup and VPN
        addHeader("General", to: root)
        root.addArrangedSubview(chkStartup)
        root.addArrangedSubview(chkAstrill)
        if !AccessibilityPermission.isGranted {
            let allow = NSButton(title: "Allow Accessibility…", target: self, action: #selector(allowAccessibility))
            root.addArrangedSubview(row([label("Pressing Astrill's ON/OFF switch needs Accessibility."), allow]))
        }
        root.addArrangedSubview(row([label("Stop waiting for a router switch after"), switchTimeoutBox, label("seconds")]))

        // Style
        addHeader("Style", to: root)
        foreColorWell.color = settings.foreColor
        backColorWell.color = settings.backColor
        for well in [foreColorWell, backColorWell] {
            well.widthAnchor.constraint(equalToConstant: 60).isActive = true
            well.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        let style = NSGridView(views: [
            [label("Font color"), foreColorWell, label("Background"), backColorWell],
            [label("Font size"), fontSizeBox, label("Opacity %"), opacityBox]
        ])
        style.rowSpacing = 8
        style.columnSpacing = 8
        style.xPlacement = .leading
        style.yPlacement = .center
        style.column(at: 2).leadingPadding = 12
        root.addArrangedSubview(style)

        // Save / Close
        let closeBtn = NSButton(title: "Close", target: self, action: #selector(closeClicked))
        closeBtn.keyEquivalent = "\u{1b}"
        let saveBtn = NSButton(title: "Save", target: self, action: #selector(save))
        saveBtn.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = row([spacer, closeBtn, saveBtn])
        root.addArrangedSubview(buttons)
        root.setCustomSpacing(16, after: style)
        buttons.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true

        window.contentView = root
        window.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSColorPanel.shared.orderOut(nil)
        onClose?()
    }

    @objc private func allowAccessibility() {
        AccessibilityPermission.openSettings()
    }

    @objc private func autoSwitchChanged() {
        autoSwitchBox.isEnabled = chkAutoSwitch.state == .on
    }

    @objc private func closeClicked() {
        window.close()
    }

    private func addRouterRow(_ name: String, _ ip: String, at index: Int?) {
        let nameBox = NSTextField(string: name)
        let ipBox = NSTextField(string: ip)
        nameBox.bezelStyle = .roundedBezel
        ipBox.bezelStyle = .roundedBezel
        nameBox.widthAnchor.constraint(equalToConstant: 140).isActive = true
        ipBox.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let plus = SettingsWindow.roundButton("plus", "Add a router below")
        let minus = SettingsWindow.roundButton("minus", "Remove this router")
        let r = row([nameBox, ipBox, plus, minus])
        plus.target = self
        plus.action = #selector(plusClicked(_:))
        minus.target = self
        minus.action = #selector(minusClicked(_:))

        if let index = index {
            routerRows.insertArrangedSubview(r, at: index)
            window.makeFirstResponder(nameBox)
        } else {
            routerRows.addArrangedSubview(r)
        }
    }

    private func rowFields(_ r: NSView) -> (name: NSTextField, ip: NSTextField) {
        let views = (r as! NSStackView).arrangedSubviews
        return (views[0] as! NSTextField, views[1] as! NSTextField)
    }

    @objc private func plusClicked(_ sender: NSButton) {
        guard let r = sender.superview, let i = routerRows.arrangedSubviews.firstIndex(of: r) else { return }
        addRouterRow("", "", at: i + 1)
    }

    @objc private func minusClicked(_ sender: NSButton) {
        guard let r = sender.superview else { return }
        if routerRows.arrangedSubviews.count > 1 {
            routerRows.removeArrangedSubview(r)
            r.removeFromSuperview()
        } else {
            let f = rowFields(r)
            f.name.stringValue = ""
            f.ip.stringValue = ""
        }
    }

    @objc private func save() {
        window.makeFirstResponder(nil) // commit the field being edited
        var s = original

        s.routers.removeAll()
        for r in routerRows.arrangedSubviews {
            let f = rowFields(r)
            let name = f.name.stringValue.trimmingCharacters(in: .whitespaces)
            let ip = f.ip.stringValue.trimmingCharacters(in: .whitespaces)
            if name.isEmpty && ip.isEmpty { continue }

            guard let addr = IPv4(ip) else {
                warn("\"\(ip)\" is not a valid IPv4 address.")
                window.makeFirstResponder(f.ip)
                return
            }
            s.routers.append(RouterInfo(name: name.isEmpty ? addr.description : name.replacingOccurrences(of: "|", with: "/"),
                                        ip: addr.description))
        }

        s.pingTarget = pingBox.stringValue.trimmingCharacters(in: .whitespaces)
        if s.pingTarget.isEmpty {
            warn("Enter a ping destination, e.g. teams.com.")
            window.makeFirstResponder(pingBox)
            return
        }

        s.showPing = chkPing.state == .on
        s.showUpload = chkUp.state == .on
        s.showDownload = chkDown.state == .on
        s.toggleAstrill = chkAstrill.state == .on
        s.autoSwitch = chkAutoSwitch.state == .on
        s.autoSwitchSeconds = autoSwitchBox.value
        s.switchTimeoutSeconds = switchTimeoutBox.value
        s.foreColor = foreColorWell.color
        s.backColor = backColorWell.color
        s.fontSize = Double(fontSizeBox.value)
        s.opacity = opacityBox.value

        do {
            try onSave(s)
            let startup = chkStartup.state == .on
            if startup != startupWasEnabled { try Startup.setEnabled(startup) }
        } catch {
            warn("Could not save settings: " + error.localizedDescription)
            return
        }
        window.close()
    }

    private func warn(_ message: String) {
        let a = NSAlert()
        a.messageText = window.title
        a.informativeText = message
        a.alertStyle = .warning
        a.beginSheetModal(for: window)
    }

    private func addHeader(_ text: String, to root: NSStackView) {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        if let last = root.arrangedSubviews.last { root.setCustomSpacing(14, after: last) }
        root.addArrangedSubview(l)
    }

    private func caption(_ text: String, _ width: CGFloat) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.widthAnchor.constraint(equalToConstant: width).isActive = true
        return l
    }

    private func label(_ text: String) -> NSTextField {
        return NSTextField(labelWithString: text)
    }

    private static func roundButton(_ symbol: String, _ tip: String) -> NSButton {
        let b: NSButton
        if #available(macOS 11.0, *), let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) {
            b = NSButton(image: image, target: nil, action: nil)
        } else {
            b = NSButton(title: symbol == "plus" ? "+" : "−", target: nil, action: nil) // no SF Symbols before macOS 11
        }
        b.bezelStyle = .circular
        b.controlSize = .small
        b.toolTip = tip
        return b
    }

    private static func check(_ text: String, _ value: Bool) -> NSButton {
        let b = NSButton(checkboxWithTitle: text, target: nil, action: nil)
        b.state = value ? .on : .off
        return b
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let r = NSStackView(views: views)
        r.orientation = .horizontal
        r.alignment = .centerY
        r.spacing = 6
        return r
    }
}
