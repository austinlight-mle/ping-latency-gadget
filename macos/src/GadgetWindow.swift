import AppKit

// A router switch running on a background thread.
final class SwitchWork {
    let cancel = CancelToken()
    private let done = DispatchSemaphore(value: 0)
    private(set) var isCompleted = false // main thread only

    func run(_ body: @escaping () throws -> VpnResult, completion: @escaping (Result<VpnResult, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try body() }
            self.done.signal()
            DispatchQueue.main.async {
                self.isCompleted = true
                completion(result)
            }
        }
    }

    // Waits for the switch to finish; call once, off the main thread.
    func wait(seconds: Double) -> Bool {
        return done.wait(timeout: .now() + seconds) == .success
    }
}

final class GadgetView: NSView {
    weak var controller: GadgetController?

    override var isFlipped: Bool { return true }
    override var isOpaque: Bool { return false } // rounded corners show what's behind

    override func draw(_ dirtyRect: NSRect) {
        controller?.draw(bounds)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    override func mouseDown(with event: NSEvent) {
        guard let controller = controller else { return }
        if controller.routerRect.contains(convert(event.locationInWindow, from: nil)) {
            controller.showRouterMenu()
        } else {
            window?.performDrag(with: event) // drag anywhere to move; the position is saved in windowDidMove
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        return controller?.makeContextMenu()
    }
}

final class GadgetController: NSObject, NSWindowDelegate, NSMenuDelegate {
    private static let gap = "  "

    private var settings: AppSettings
    private let panel: NSPanel
    private let view = GadgetView()
    private var timer: Timer?
    private var watcher: NetworkWatcher?
    private var settingsWindow: SettingsWindow?
    private var shown = false
    private var quitting = false

    private var pingBusy = false
    private var pingText = "", upText = "", downText = ""

    private var nic: Adapter?
    private var nicStale = true
    private var lastSent: UInt32 = 0, lastReceived: UInt32 = 0
    private var lastSample: TimeInterval?

    private var selectedIndex = -1
    private var routerEnabled = true
    private var switching = false
    private var switchWork: SwitchWork?  // the running switch, if any
    private var cancelSwitch: (() -> Void)?
    private var switchGeneration = 0
    private var lastAutoIndex = -1
    private var failStart: TimeInterval?

    private var font = NSFont.systemFont(ofSize: 13)
    private var lineHeight: CGFloat = 0
    private var arrowWidth: CGFloat = 0
    private var textRect = NSRect.zero
    private(set) var routerRect = NSRect.zero
    private var saveTimer: Timer?
    private var statusItem: NSStatusItem? // set while pinned to the menu bar

    init(settings: AppSettings) {
        self.settings = settings
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 30),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()

        panel.level = .floating
        // On every desktop, and out of Cmd+Tab / window cycling.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        // Transparent window: the view paints a rounded panel, and the shadow follows its shape.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        view.controller = self
        panel.contentView = view

        resetReadings()
        try? applySettings(settings)
    }

    func show() {
        shown = true
        placeOnScreen()
        syncRouterSelection()
        applyMode()
        watcher = NetworkWatcher { [weak self] in self?.onNetworkChanged() }
        let t = Timer(timeInterval: 1, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common) // keep ticking while a menu is open
        timer = t
        tick()
    }

    // Called from applicationShouldTerminate.
    func prepareToQuit() -> NSApplication.TerminateReply {
        quitting = true
        guard let work = switchWork, !work.isCompleted else { return .terminateNow }

        // Quit right away, but quitting mid-switch could leave Astrill OFF: hide the gadget,
        // cancel the switch so it skips the gateway change and the VPN wait, and give it a
        // moment to turn Astrill back ON (a pending OFF check can take up to 8 s).
        panel.orderOut(nil)
        if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
        statusItem = nil
        work.cancel.cancel()
        DispatchQueue.global().async {
            _ = work.wait(seconds: 15)
            DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    func willTerminate() {
        watcher = nil
        timer?.invalidate()
        savePosition()
    }

    func applySettings(_ newSettings: AppSettings) throws {
        var s = newSettings
        let targetChanged = s.pingTarget != settings.pingTarget
        // The window may have been dragged or pinned while the settings window was open.
        s.x = settings.x
        s.y = settings.y
        s.pinToMenuBar = settings.pinToMenuBar
        settings = s

        // Windows sizes fonts at 96 dpi and macOS at 72, so scale to make the same size look the same.
        font = NSFont.monospacedDigitSystemFont(ofSize: CGFloat(s.fontSize) * 4 / 3, weight: .regular)
        panel.alphaValue = CGFloat(max(20, min(100, s.opacity))) / 100

        if targetChanged { pingText = "Time=--- TTL=---" }
        nicStale = true
        lastAutoIndex = -1
        failStart = nil
        if !settings.routers.indices.contains(selectedIndex) { selectedIndex = -1 }

        layoutGadget()
        if shown {
            placeOnScreen()
            syncRouterSelection()
            try settings.save()
        }
        redraw()
    }

    // ---------- Layout and painting ----------

    private func buildLines(_ pingPart: String, _ upPart: String, _ downPart: String) -> [String] {
        var parts = [String]()
        if settings.showPing { parts.append(pingPart) }
        if settings.showUpload { parts.append(upPart) }
        if settings.showDownload { parts.append(downPart) }

        if parts.count == 3 { return [parts[0], parts[1] + GadgetController.gap + parts[2]] }
        return parts.isEmpty ? [] : [parts.joined(separator: GadgetController.gap)]
    }

    private func textAttributes(_ color: NSColor) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return [.font: font, .foregroundColor: color, .paragraphStyle: style]
    }

    private func textWidth(_ s: String) -> CGFloat {
        return ceil((s as NSString).size(withAttributes: [.font: font]).width)
    }

    private func layoutGadget() {
        let pad: CGFloat = 6, gap: CGFloat = 10

        // Size the text area from worst-case strings so the window doesn't jitter.
        let templates = buildLines("Time=9999ms TTL=999", "Up=999.9Mbps", "Down=999.9Mbps")
        lineHeight = ceil(font.ascender - font.descender + font.leading)
        let textW = templates.map(textWidth).max() ?? 0
        let textH = CGFloat(templates.count) * lineHeight

        let hasRouters = !settings.routers.isEmpty
        let comboH = lineHeight + 6
        arrowWidth = ceil(lineHeight * 0.8)
        var comboW: CGFloat = 0
        if hasRouters {
            comboW = (settings.routers.map { textWidth($0.name) }.max() ?? 0) + arrowWidth + 18
        }

        var innerH = max(textH, hasRouters ? comboH : 0)
        if innerH == 0 { innerH = lineHeight }
        textRect = NSRect(x: pad, y: pad + (innerH - textH) / 2, width: textW, height: textH)

        var x = pad + (templates.isEmpty ? 0 : textW)
        if !templates.isEmpty && hasRouters { x += gap }
        routerRect = hasRouters ? NSRect(x: x, y: pad + (innerH - comboH) / 2, width: comboW, height: comboH) : .zero

        // Resize around the top-left corner, which is what stays put on Windows.
        let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        panel.setContentSize(NSSize(width: max(x + comboW + pad, 40), height: innerH + 2 * pad))
        panel.setFrameTopLeftPoint(topLeft)
        redraw()
        panel.invalidateShadow()
    }

    func draw(_ bounds: NSRect) {
        NSColor.clear.set()
        bounds.fill(using: .copy)
        settings.backColor.setFill()
        let radius = min(10, bounds.height / 3)
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        let attrs = textAttributes(settings.foreColor)
        for (i, line) in buildLines(pingText, upText, downText).enumerated() {
            let r = NSRect(x: textRect.minX, y: textRect.minY + CGFloat(i) * lineHeight, width: textRect.width, height: lineHeight)
            (line as NSString).draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        }

        if routerRect != .zero { drawRouterBox() }
    }

    // A drop-down in the gadget's colors, shaped like a macOS pop-up button: a rounded box with
    // the selected router and up/down chevrons.
    private func drawRouterBox() {
        let fore = routerEnabled ? settings.foreColor : settings.foreColor.withAlphaComponent(0.45)
        let box = routerRect.insetBy(dx: 0.5, dy: 0.5)
        let radius = min(6, box.height / 2)
        let shape = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)
        fore.withAlphaComponent(fore.alphaComponent * 0.12).setFill()
        shape.fill()
        fore.withAlphaComponent(fore.alphaComponent * 0.4).setStroke()
        shape.lineWidth = 1
        shape.stroke()

        if settings.routers.indices.contains(selectedIndex) {
            let r = NSRect(x: routerRect.minX + 7, y: routerRect.minY + (routerRect.height - lineHeight) / 2,
                           width: routerRect.width - arrowWidth - 12, height: lineHeight)
            (settings.routers[selectedIndex].name as NSString).draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                                                   attributes: textAttributes(fore))
        }

        let cx = routerRect.maxX - 5 - arrowWidth / 2, cy = routerRect.midY
        let w = arrowWidth * 0.22, h = arrowWidth * 0.14, gap = arrowWidth * 0.1
        let chevrons = NSBezierPath()
        chevrons.move(to: NSPoint(x: cx - w, y: cy - gap))
        chevrons.line(to: NSPoint(x: cx, y: cy - gap - h * 2))
        chevrons.line(to: NSPoint(x: cx + w, y: cy - gap))
        chevrons.move(to: NSPoint(x: cx - w, y: cy + gap))
        chevrons.line(to: NSPoint(x: cx, y: cy + gap + h * 2))
        chevrons.line(to: NSPoint(x: cx + w, y: cy + gap))
        chevrons.lineWidth = max(1.2, arrowWidth * 0.1)
        chevrons.lineCapStyle = .round
        chevrons.lineJoinStyle = .round
        fore.setStroke()
        chevrons.stroke()
    }

    // ---------- Position ----------

    private func placeOnScreen() {
        let margin: CGFloat = 12
        let size = panel.frame.size
        var topLeft = NSPoint(x: CGFloat(settings.x), y: CGFloat(settings.y))
        let rect = NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
        if settings.x == Int.min || !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }),
           let wa = NSScreen.screens.first?.visibleFrame {
            topLeft = NSPoint(x: wa.maxX - size.width - margin, y: wa.maxY - margin)
        }
        panel.setFrameTopLeftPoint(topLeft)
    }

    func windowDidMove(_ notification: Notification) {
        guard shown else { return }
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in self?.savePosition() }
    }

    private func savePosition() {
        settings.x = Int(panel.frame.minX)
        settings.y = Int(panel.frame.maxY)
        try? settings.save() // position isn't worth an error dialog
    }

    // ---------- Measurements ----------

    private func resetReadings() {
        pingText = "Time=--- TTL=---"
        upText = "Up=---"
        downText = "Down=---"
    }

    @objc private func tick() {
        if settings.showUpload || settings.showDownload { updateSpeed() }
        redraw()

        // Auto-switch needs ping results even when ping isn't displayed.
        guard settings.showPing || settings.autoSwitch, !pingBusy, !switching else { return }
        pingBusy = true
        let generation = switchGeneration
        Pinger.send(settings.pingTarget, timeoutMs: 2000) { [weak self] reply in
            guard let self = self else { return }
            self.pingBusy = false
            // Ignore replies to pings sent before or during a router switch.
            if self.switching || generation != self.switchGeneration { return }
            self.pingText = reply.text
            self.onPingResult(reply.ok)
            self.redraw()
        }
    }

    private func onPingResult(_ ok: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        if ok {
            failStart = nil
            lastAutoIndex = -1
            return
        }
        if failStart == nil { failStart = now }

        if settings.autoSwitch && settings.routers.count > 1,
           let start = failStart, now - start >= Double(settings.autoSwitchSeconds) {
            // Continue from the last router we tried, so a router that fails to
            // switch doesn't make us retry the same one forever.
            let from = lastAutoIndex >= 0 ? lastAutoIndex : selectedIndex
            lastAutoIndex = (from + 1) % settings.routers.count
            switchTo(lastAutoIndex, interactive: false)
        }
    }

    private func updateSpeed() {
        if nicStale {
            nicStale = false
            nic = NetworkManager.findAdapter(settings.routers)
            lastSample = nil
        }
        guard let nic = nic else {
            upText = "Up=---"
            downText = "Down=---"
            return
        }
        guard let counters = NetworkManager.byteCounters(nic) else {
            nicStale = true
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastSample, now - last > 0 {
            let secs = now - last
            let up = Double(counters.sent &- lastSent) * 8 / secs / 1e6
            let down = Double(counters.received &- lastReceived) * 8 / secs / 1e6
            upText = "Up=" + formatMbps(up) + "Mbps"
            downText = "Down=" + formatMbps(down) + "Mbps"
        }
        lastSent = counters.sent
        lastReceived = counters.received
        lastSample = now
    }

    private func formatMbps(_ v: Double) -> String {
        return String(format: v >= 100 ? "%.0f" : "%.1f", v)
    }

    private func onNetworkChanged() {
        nicStale = true
        syncRouterSelection()
    }

    // ---------- Router selection ----------

    private func syncRouterSelection() {
        if switching { return }
        var index = -1
        if let n = NetworkManager.findAdapter(settings.routers), let gw = NetworkManager.gateway(of: n) {
            index = settings.routers.firstIndex { IPv4($0.ip) == gw } ?? -1
        }
        selectedIndex = index
        redraw()
    }

    func showRouterMenu() {
        guard routerEnabled, !settings.routers.isEmpty else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.font = font
        menu.minimumWidth = routerRect.width
        let back = settings.backColor.usingColorSpace(.sRGB) ?? .black
        let dark = 0.299 * back.redComponent + 0.587 * back.greenComponent + 0.114 * back.blueComponent < 0.5
        menu.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        for (i, r) in settings.routers.enumerated() {
            let item = NSMenuItem(title: r.name, action: #selector(routerChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = i == selectedIndex ? .on : .off
            menu.addItem(item)
        }
        // Like a drop-down list: the current router opens over the box, otherwise the list opens below it.
        let current = settings.routers.indices.contains(selectedIndex) ? menu.item(at: selectedIndex) : nil
        menu.popUp(positioning: current, at: NSPoint(x: routerRect.minX, y: current != nil ? routerRect.minY : routerRect.maxY), in: view)
    }

    @objc private func routerChosen(_ item: NSMenuItem) {
        if item.tag == selectedIndex { return }
        lastAutoIndex = -1
        switchTo(item.tag, interactive: true)
    }

    // interactive = picked by the user (show errors); otherwise an automatic switch.
    private func switchTo(_ index: Int, interactive: Bool) {
        guard !switching, settings.routers.indices.contains(index) else { return }
        let router = settings.routers[index]

        guard let ip = IPv4(router.ip) else {
            if interactive { alert("Invalid IP address: " + router.ip, title: "Ping Gadget") }
            syncRouterSelection()
            return
        }

        // The one-time administrator prompt; automatic switches fail with a message instead.
        if interactive && !Helper.isInstalled() {
            do {
                try Helper.install()
            } catch {
                alert(error.localizedDescription, title: "Switch router failed")
                syncRouterSelection()
                return
            }
        }

        switching = true
        selectedIndex = index
        routerEnabled = false
        pingText = "Switching..."
        redraw()

        // The worker stops waiting for the VPN when the token fires. The extra grace period on
        // the UI side covers a step that never returns (e.g. networksetup hanging); the worker
        // is then abandoned and later switches wait for it to finish.
        let current = settings
        let timeoutMs = current.switchTimeoutSeconds * 1000
        let work = SwitchWork()
        work.cancel.cancel(afterMs: timeoutMs)
        switchWork = work

        var concluded = false
        let conclude: (Result<VpnResult, Error>?) -> Void = { [weak self] result in
            guard !concluded, let self = self else { return }
            concluded = true
            if self.quitting { return } // closed while switching

            var status: String?, error: String?
            switch result {
            case nil:
                work.cancel.cancel()
                status = "Switch timed out"
            case .failure(let e) where e is SwitchStopped:
                work.cancel.cancel()
                status = "Switch cancelled"
            case .failure(let e) where e is SwitchCancelled:
                status = "Switch timed out"
            case .failure(let e):
                status = "Switch failed"
                error = e.localizedDescription
            case .success(let vpn):
                // Ends early when Astrill fails or is turned off, rather than at the timeout.
                status = vpn.status
            }

            self.switching = false
            self.cancelSwitch = nil
            self.switchGeneration += 1
            self.failStart = nil // give the new router the full wait before judging it
            self.routerEnabled = true
            self.nicStale = true
            self.pingText = status ?? "Time=--- TTL=---" // replaced by the next ping result
            self.syncRouterSelection()
            self.redraw()
            // Only after the gadget is usable again: the dialog blocks until it is dismissed.
            if let error = error, interactive { self.alert(error, title: "Switch router failed") }
        }

        // Cancelling skips the gateway change if it hasn't happened yet and stops waiting for the
        // VPN; the worker still turns Astrill back ON in the background before it ends.
        cancelSwitch = { conclude(.failure(SwitchStopped())) }
        work.run({ try NetworkManager.switchRouter(ip, settings: current, cancel: work.cancel) }, completion: conclude)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(timeoutMs + 5000)) { conclude(nil) }
    }

    private func alert(_ message: String, title: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.alertStyle = .warning
        a.runModal()
    }

    // ---------- Menu bar mode ----------

    // Repaints the gadget, or the menu bar readings while pinned.
    private func redraw() {
        view.needsDisplay = true
        guard let button = statusItem?.button else { return }

        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let title = menuBarText(pingText, upText, downText)
        // Sized from worst-case strings so the menu bar doesn't jitter, but never cut a long status.
        let template = menuBarText("Time=9999ms", "Up=999.9Mbps", "Down=999.9Mbps")
        let width = [template, title].map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) }.max() ?? 0
        button.font = font
        button.title = title
        statusItem?.length = width + 12
    }

    // "Time=250ms TTL=105", "Up=1.5Mbps", "Down=2.5Mbps" → "250ms  ↑1.5Mbps  ↓2.5Mbps".
    private func menuBarText(_ pingPart: String, _ upPart: String, _ downPart: String) -> String {
        var parts = [String]()
        if settings.showPing {
            var ping = pingPart
            if ping.hasPrefix("Time=") { ping.removeFirst(5) }
            if let ttl = ping.range(of: " TTL=") { ping = String(ping[..<ttl.lowerBound]) }
            parts.append(ping)
        }
        if settings.showUpload { parts.append("↑" + upPart.replacingOccurrences(of: "Up=", with: "")) }
        if settings.showDownload { parts.append("↓" + downPart.replacingOccurrences(of: "Down=", with: "")) }
        return parts.isEmpty ? "Ping Gadget" : parts.joined(separator: GadgetController.gap)
    }

    // Shows either the floating gadget or the readings in the menu bar.
    private func applyMode() {
        if settings.pinToMenuBar {
            panel.orderOut(nil)
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                let menu = NSMenu()
                menu.delegate = self // rebuilt each time it opens
                item.menu = menu
                statusItem = item
            }
        } else {
            if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
            statusItem = nil
            panel.orderFrontRegardless()
        }
        redraw()
    }

    private func setPinned(_ pinned: Bool) {
        settings.pinToMenuBar = pinned
        try? settings.save()
        applyMode()
    }

    @objc private func pinClicked() {
        setPinned(true)
    }

    @objc private func unpinClicked() {
        setPinned(false)
    }

    // The menu bar menu: the routers (in place of the drop-down), then the gadget's own menu.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        for (i, r) in settings.routers.enumerated() {
            let item = NSMenuItem(title: r.name, action: #selector(routerChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = i == selectedIndex ? .on : .off
            item.isEnabled = routerEnabled
            menu.addItem(item)
        }
        if !settings.routers.isEmpty { menu.addItem(.separator()) }
        let rest = makeContextMenu()
        for item in rest.items {
            rest.removeItem(item)
            menu.addItem(item)
        }
    }

    // ---------- Settings ----------

    @objc func showSettings() {
        if let w = settingsWindow {
            w.show()
            return
        }
        let w = SettingsWindow(settings: settings) { [weak self] s in try self?.applySettings(s) }
        w.onClose = { [weak self] in self?.settingsWindow = nil }
        settingsWindow = w
        w.show()
    }

    func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings", action: #selector(showSettings), keyEquivalent: "").target = self
        if switching {
            menu.addItem(withTitle: "Cancel switch", action: #selector(cancelSwitchClicked), keyEquivalent: "").target = self
        }
        if settings.pinToMenuBar {
            menu.addItem(withTitle: "Unpin from menu bar", action: #selector(unpinClicked), keyEquivalent: "").target = self
        } else {
            menu.addItem(withTitle: "Pin to menu bar", action: #selector(pinClicked), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "Close", action: #selector(close), keyEquivalent: "").target = self
        return menu
    }

    @objc private func cancelSwitchClicked() {
        cancelSwitch?()
    }

    @objc private func close() {
        NSApp.terminate(nil)
    }
}
