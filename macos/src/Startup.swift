import Foundation

// "Open at login" is a per-user LaunchAgent that opens the app, like Astrill's own login item.
// No elevation is needed at login: router switches go through the installed helper.
enum Startup {
    static let label = "com.pinggadget.launcher"
    static var plistPath: String { return NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist" }

    static func isEnabled() -> Bool {
        return FileManager.default.fileExists(atPath: plistPath)
    }

    static func setEnabled(_ enabled: Bool) throws {
        if !enabled {
            if isEnabled() { try FileManager.default.removeItem(atPath: plistPath) }
            return
        }

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", Bundle.main.bundlePath],
            "LimitLoadToSessionType": "Aqua",
            "RunAtLoad": true
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(atPath: (plistPath as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: plistPath), options: .atomic)
    }
}
