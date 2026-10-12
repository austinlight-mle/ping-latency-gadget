import AppKit

struct RouterInfo {
    var name: String
    var ip: String
}

struct AppSettings {
    static let defaultAstrillPath = "/Applications/Astrill.app"

    static let minAutoSwitchSeconds = 3, minSwitchTimeoutSeconds = 20, maxSeconds = 600

    var routers: [RouterInfo] = []
    var pingTarget = "teams.com"
    var showPing = true
    var showUpload = true
    var showDownload = true
    var toggleAstrill = true
    var autoSwitch = false
    var autoSwitchSeconds = 10
    var switchTimeoutSeconds = 60
    var astrillPath = defaultAstrillPath
    var foreColor = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1) // lime
    var backColor = NSColor.black
    var fontSize: Double = 10
    var opacity = 85
    var pinToMenuBar = false // readings in the menu bar instead of the floating gadget
    // Top-left corner of the gadget in screen coordinates (Y grows upwards, as everywhere in AppKit).
    var x = Int.min
    var y = Int.min

    static let directory = (NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first
        ?? NSHomeDirectory() + "/Library/Application Support") + "/PingGadget"
    static let filePath = directory + "/settings.ini"

    static func load() -> AppSettings {
        var s = AppSettings()
        guard let text = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            s.routers.append(RouterInfo(name: "Router 1", ip: "192.168.1.1"))
            s.routers.append(RouterInfo(name: "Router 2", ip: "192.168.1.2"))
            s.routers.append(RouterInfo(name: "Router 3", ip: "192.168.1.3"))
            return s
        }

        for line in text.components(separatedBy: .newlines) {
            guard let eq = line.firstIndex(of: "="), eq != line.startIndex else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let val = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            // Malformed values (bad number, unknown color) are ignored and keep the default.
            switch key {
            case "Router":
                if let bar = val.lastIndex(of: "|"), bar != val.startIndex {
                    s.routers.append(RouterInfo(name: String(val[..<bar]), ip: String(val[val.index(after: bar)...])))
                }
            case "PingTarget": s.pingTarget = val
            case "ShowPing": s.showPing = val == "1"
            case "ShowUpload": s.showUpload = val == "1"
            case "ShowDownload": s.showDownload = val == "1"
            case "ToggleAstrill", "RestartAstrill": s.toggleAstrill = val == "1"
            case "AstrillPath": s.astrillPath = val
            case "AutoSwitch": s.autoSwitch = val == "1"
            case "AutoSwitchSeconds": s.autoSwitchSeconds = Int(val) ?? s.autoSwitchSeconds
            case "SwitchTimeoutSeconds": s.switchTimeoutSeconds = Int(val) ?? s.switchTimeoutSeconds
            case "ForeColor": s.foreColor = color(fromHex: val) ?? s.foreColor
            case "BackColor": s.backColor = color(fromHex: val) ?? s.backColor
            case "FontSize": s.fontSize = Double(val) ?? s.fontSize
            case "Opacity": s.opacity = Int(val) ?? s.opacity
            case "MenuBar": s.pinToMenuBar = val == "1"
            case "X": s.x = Int(val) ?? s.x
            case "Y": s.y = Int(val) ?? s.y
            default: break
            }
        }

        // Hand-edited values outside what the Settings window allows would misbehave (a zero
        // auto-switch delay switches every second), so clamp them the same way.
        s.autoSwitchSeconds = clamp(s.autoSwitchSeconds, minAutoSwitchSeconds, maxSeconds)
        s.switchTimeoutSeconds = clamp(s.switchTimeoutSeconds, minSwitchTimeoutSeconds, maxSeconds)
        s.opacity = clamp(s.opacity, 20, 100)
        s.fontSize = s.fontSize.isNaN ? 10 : max(6, min(36, s.fontSize))
        return s
    }

    func save() throws {
        var lines = routers.map { "Router=" + $0.name + "|" + $0.ip }
        lines.append("PingTarget=" + pingTarget)
        lines.append("ShowPing=" + (showPing ? "1" : "0"))
        lines.append("ShowUpload=" + (showUpload ? "1" : "0"))
        lines.append("ShowDownload=" + (showDownload ? "1" : "0"))
        lines.append("ToggleAstrill=" + (toggleAstrill ? "1" : "0"))
        lines.append("AstrillPath=" + astrillPath)
        lines.append("AutoSwitch=" + (autoSwitch ? "1" : "0"))
        lines.append("AutoSwitchSeconds=\(autoSwitchSeconds)")
        lines.append("SwitchTimeoutSeconds=\(switchTimeoutSeconds)")
        lines.append("ForeColor=" + AppSettings.hex(foreColor))
        lines.append("BackColor=" + AppSettings.hex(backColor))
        lines.append("FontSize=\(fontSize)")
        lines.append("Opacity=\(opacity)")
        lines.append("MenuBar=" + (pinToMenuBar ? "1" : "0"))
        lines.append("X=\(x)")
        lines.append("Y=\(y)")

        try FileManager.default.createDirectory(atPath: AppSettings.directory, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(toFile: AppSettings.filePath, atomically: true, encoding: .utf8)
    }

    static func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int {
        return max(lo, min(hi, v))
    }

    static func color(fromHex s: String) -> NSColor? {
        var hex = s
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    static func hex(_ c: NSColor) -> String {
        let rgb = c.usingColorSpace(.sRGB) ?? NSColor.black
        func byte(_ v: CGFloat) -> Int { return Int((max(0, min(1, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }
}
