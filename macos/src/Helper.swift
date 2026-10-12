import Foundation

// Changing the gateway and routes needs root. Rather than running the whole app as root (as the
// Windows app runs as administrator), a small helper script is installed once with an
// administrator password and then run through `sudo -n`, so switches never prompt.
enum Helper {
    static let installedPath = "/Library/PrivilegedHelperTools/com.pinggadget.helper"

    private static var bundledPath: String? { return Bundle.main.path(forResource: "pinggadget-helper", ofType: nil) }
    private static var installerPath: String? { return Bundle.main.path(forResource: "install-helper", ofType: "sh") }

    // True when the installed helper matches this app's copy and sudo lets us run it without a password.
    static func isInstalled() -> Bool {
        guard let bundled = bundledPath,
              let mine = FileManager.default.contents(atPath: bundled),
              FileManager.default.contents(atPath: installedPath) == mine else { return false }
        return (try? execute("/usr/bin/sudo", ["-n", installedPath, "check"])) != nil
    }

    static func checkInstalled() throws {
        if !isInstalled() {
            throw SwitchError("Router switching needs administrator rights. Pick a router in the gadget to grant them.")
        }
    }

    // Shows the macOS administrator password prompt. Blocks until it is answered.
    static func install() throws {
        guard let helper = bundledPath, let installer = installerPath else {
            throw SwitchError("The helper is missing from the app bundle. Rebuild the app.")
        }
        let script = """
            on run argv
                do shell script "/bin/sh " & quoted form of item 1 of argv & " " & item 2 of argv & " " & quoted form of item 3 of argv ¬
                    with prompt "Ping Gadget needs administrator rights once to change the router (gateway)." with administrator privileges
            end run
            """
        do {
            try execute("/usr/bin/osascript", ["-e", script, installer, String(getuid()), helper])
        } catch {
            if error.localizedDescription.contains("-128") { throw SwitchError("Administrator rights were not granted.") }
            throw error
        }
    }

    static func run(_ args: [String]) throws {
        try execute("/usr/bin/sudo", ["-n", installedPath] + args)
    }

    // Runs a program and returns its output; throws with its error output when it fails.
    @discardableResult
    static func execute(_ path: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let output = String(decoding: outData, as: UTF8.self)
        guard p.terminationStatus == 0 else {
            let message = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw SwitchError(message.isEmpty ? "\((path as NSString).lastPathComponent) failed with exit code \(p.terminationStatus)." : message)
        }
        return output
    }
}
