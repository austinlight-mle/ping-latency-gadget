import AppKit
import ApplicationServices

// How turning Astrill back on ended.
enum VpnResult {
    case connected    // the VPN is back (or Astrill wasn't touched)
    case timedOut     // still connecting when the switch timed out
    case notStarted   // Astrill never started connecting
    case stopped      // Astrill started connecting, then gave up or was turned off
    case appClosed    // Astrill quit while we waited

    var status: String? {
        switch self {
        case .connected: return nil
        case .timedOut: return "VPN not reconnected"
        case .notStarted: return "VPN didn't turn on"
        case .stopped: return "VPN turned off"
        case .appClosed: return "Astrill closed"
        }
    }
}

enum AstrillOffResult {
    case untouched // Astrill was off, not running, or didn't respond: leave it as it is
    case toggled   // switched off with its ON/OFF toggle; switch it back on
    case closed    // toggle not reachable while connected, so the app was quit; start it again
}

// Astrill has no API. Its "Menu" has a "Toggle ON/OFF" item, which we press through the
// Accessibility API; that works while its window is visible, hidden in the menu bar or minimized.
// If the item can't be found, we click the big ON/OFF switch in its window when that is on screen.
// Both need the Accessibility permission. Rule: never touch Astrill unless we are sure it is ON.
enum Astrill {
    static let bundleID = "com.astrill.astrill"

    // The switch inside Astrill's borderless main window (480x604 layout: 64 header, then the
    // switch at 68,44 sized 348x146 in the panel below it), as fractions of the window size.
    private static let switchX = (68 + 348 / 2) / 480.0, switchY = (64 + 44 + 146 / 2) / 604.0

    // The VPN engines Astrill runs while it is ON (connected or connecting).
    private static let engines: Set<String> = ["asovpnc", "aswgvpnc", "openweb"]

    static func turnOff() -> AstrillOffResult {
        guard let app = findApp() else { return .untouched }

        let isOn = engineRunning() || NetworkManager.isVpnRouted()
        if !isOn { return .untouched }

        guard let toggle = findToggle(app) else {
            quit(app)
            return .closed
        }

        toggle()
        let off = waitUntil({ !engineRunning() && !NetworkManager.isVpnRouted() }, timeoutMs: 8000, cancel: .none)

        // If the press didn't register, don't press again later: that would turn it OFF.
        if !off { return .untouched }
        Thread.sleep(forTimeInterval: 0.3) // let the tunnel finish tearing down
        return .toggled
    }

    // Always presses the toggle first, even when already cancelled, so Astrill isn't left OFF.
    // Returns as soon as the VPN is back, Astrill gives up, or the switch is cancelled (timed out).
    static func turnOn(_ previous: AstrillOffResult, path: String, cancel: CancelToken) throws -> VpnResult {
        if previous == .closed {
            try start(path)
            return waitForVpn(cancel, startGraceSeconds: 30)
        }
        if previous != .toggled { return .connected }

        guard let app = findApp() else {
            try start(path)
            return waitForVpn(cancel, startGraceSeconds: 30)
        }
        guard let toggle = findToggle(app) else {
            quit(app)
            try start(path)
            return waitForVpn(cancel, startGraceSeconds: 30)
        }

        Thread.sleep(forTimeInterval: 0.7) // Astrill may ignore presses while still disconnecting
        // Press once only. Astrill can take several seconds (server lookup) before its VPN engine
        // starts, so a second press "because nothing happened yet" would turn it back OFF.
        if !running().engine && !NetworkManager.isVpnRouted() { toggle() }
        return waitForVpn(cancel, startGraceSeconds: 20)
    }

    // Reconnecting takes 3-7 s typically, but 30+ s when Astrill falls back to another
    // protocol; wait so callers don't judge the new router before the VPN is back. On a dead
    // or weak router it may never reconnect, so the wait ends when the switch times out, or
    // earlier when Astrill visibly isn't trying any more: its VPN engine never starts within
    // startGraceSeconds, stays down for 10 s after running (failed or turned off), or the app quits.
    private static func waitForVpn(_ cancel: CancelToken, startGraceSeconds: Double) -> VpnResult {
        let start = Date()
        var lastEngine: Date?
        while true {
            if NetworkManager.isVpnRouted() { return .connected }
            let state = running()
            let now = Date()
            if state.engine { lastEngine = now }
            if !state.app && !state.engine && now.timeIntervalSince(start) > 10 { return .appClosed }
            if let last = lastEngine {
                if now.timeIntervalSince(last) > 10 { return .stopped }
            } else if now.timeIntervalSince(start) > startGraceSeconds {
                return .notStarted
            }
            if cancel.wait(ms: 250) { return .timedOut }
        }
    }

    static func isInstalled(_ path: String) -> Bool {
        return FileManager.default.fileExists(atPath: path)
    }

    private static func findApp() -> NSRunningApplication? {
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { !$0.isTerminated }
    }

    private static func engineRunning() -> Bool {
        return running().engine
    }

    // Whether Astrill's app and any of its VPN engines are running, from one process scan.
    // Engines run as root; their paths are still readable.
    private static func running() -> (app: Bool, engine: Bool) {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return (false, false) }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var path = [CChar](repeating: 0, count: 4096)
        var app = false, engine = false
        for pid in pids.prefix(Int(max(0, n))) where pid > 0 {
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            let p = String(cString: path)
            guard p.contains("/Astrill.app/") else { continue }
            let name = (p as NSString).lastPathComponent
            if name == "astrill" { app = true }
            if engines.contains(name) { engine = true }
        }
        return (app, engine)
    }

    // Returns an action that flips Astrill's ON/OFF state, or nil when there's no way to reach it.
    private static func findToggle(_ app: NSRunningApplication) -> (() -> Void)? {
        guard AXIsProcessTrusted() else { return nil }

        let ax = AXUIElementCreateApplication(app.processIdentifier)
        // Never hang on a frozen Astrill.
        AXUIElementSetMessagingTimeout(ax, 2)
        if let menuBar: AXUIElement = attribute(ax, kAXMenuBarAttribute), let item = findToggleItem(menuBar, depth: 0) {
            return { _ = AXUIElementPerformAction(item, kAXPressAction as CFString) }
        }
        if let point = switchPoint(app.processIdentifier) {
            return { click(point) }
        }
        return nil
    }

    private static func findToggleItem(_ element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 5, let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) else { return nil }
        for child in children {
            let role: String? = attribute(child, kAXRoleAttribute)
            let title: String? = attribute(child, kAXTitleAttribute)
            let enabled: Bool? = attribute(child, kAXEnabledAttribute)
            if role == kAXMenuItemRole, let t = title, t.lowercased().hasPrefix("toggle"), enabled != false { return child }
            if let found = findToggleItem(child, depth: depth + 1) { return found }
        }
        return nil
    }

    // Where the switch is on screen, if Astrill's main window is showing.
    private static func switchPoint(_ pid: pid_t) -> CGPoint? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        var best: CGRect?
        for w in windows where (w[kCGWindowOwnerPID as String] as? pid_t) == pid {
            guard let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: dict), r.height >= 150 else { continue }
            // The main window keeps its 480:604 shape at every scale.
            if abs(r.width / r.height - 480.0 / 604.0) > 0.08 { continue }
            if best == nil || r.height > best!.height { best = r }
        }
        guard let r = best else { return nil }
        return CGPoint(x: r.minX + r.width * switchX, y: r.minY + r.height * switchY)
    }

    // A real click at the point, then the pointer goes back where it was.
    private static func click(_ point: CGPoint) {
        let saved = CGEvent(source: nil)?.location
        for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.08)
        }
        if let saved = saved { CGWarpMouseCursorPosition(saved) }
    }

    private static func quit(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        app.terminate()
        if !waitUntil({ kill(pid, 0) != 0 }, timeoutMs: 3000, cancel: .none) {
            app.forceTerminate()
            _ = waitUntil({ kill(pid, 0) != 0 }, timeoutMs: 5000, cancel: .none)
        }
        // Give Astrill's root processes a moment to drop the tunnel.
        _ = waitUntil({ !engineRunning() }, timeoutMs: 3000, cancel: .none)
        Thread.sleep(forTimeInterval: 1)
    }

    // Starts Astrill the way its own login item does, so it connects by itself.
    private static func start(_ path: String) throws {
        guard isInstalled(path) else { throw SwitchError("Astrill was not found at \(path).") }
        try Helper.execute("/usr/bin/open", ["-g", path, "--args", "/autostart"])
    }

    private static func waitUntil(_ condition: () -> Bool, timeoutMs: Int?, cancel: CancelToken) -> Bool {
        let start = Date()
        while !condition() {
            if let t = timeoutMs, Date().timeIntervalSince(start) * 1000 >= Double(t) { return false }
            if cancel.wait(ms: 200) { return false }
        }
        return true
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
