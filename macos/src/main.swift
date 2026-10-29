import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var gadget: GadgetController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = AppDelegate.makeMainMenu()
        let settings = AppSettings.load()
        let g = GadgetController(settings: settings)
        gadget = g
        g.show()

        // Ask for the permissions after the gadget is on screen.
        DispatchQueue.main.async {
            if settings.toggleAstrill && Astrill.isInstalled(settings.astrillPath) {
                AccessibilityPermission.requestOnce()
            }
            if !settings.routers.isEmpty && !Helper.isInstalled() {
                try? Helper.install()
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        return gadget?.prepareToQuit() ?? .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        gadget?.willTerminate()
    }

    // The app has no menu bar of its own (it's an agent app), but the main menu still
    // provides Cmd+C/V/X/A/Z in text fields, Cmd+W and Cmd+Q.
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Ping Gadget", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = appMenu

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = window
        return main
    }
}

// One gadget per user: a second copy exits right away.
try? FileManager.default.createDirectory(atPath: AppSettings.directory, withIntermediateDirectories: true)
let lockFd = open(AppSettings.directory + "/.lock", O_CREAT | O_RDWR, 0o600)
if lockFd < 0 || flock(lockFd, LOCK_EX | LOCK_NB) != 0 { exit(0) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // no Dock icon, like ShowInTaskbar = false
app.run()
