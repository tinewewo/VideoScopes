import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AppController()
    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.launch()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

// ---- minimal menu bar ----
let mainMenu = NSMenu()

let appItem = NSMenuItem()
mainMenu.addItem(appItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: "About VideoScopes", action: nil, keyEquivalent: "")
appMenu.addItem(.separator())
appMenu.addItem(withTitle: "Hide VideoScopes",
                action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
appMenu.addItem(.separator())
appMenu.addItem(withTitle: "Quit VideoScopes",
                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appItem.submenu = appMenu

let viewItem = NSMenuItem()
mainMenu.addItem(viewItem)
let viewMenu = NSMenu(title: "View")
let fs = NSMenuItem(title: "Toggle Full Screen",
                    action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
fs.keyEquivalentModifierMask = [.command, .control]
viewMenu.addItem(fs)
viewItem.submenu = viewMenu

let windowItem = NSMenuItem()
mainMenu.addItem(windowItem)
let windowMenu = NSMenu(title: "Window")
windowMenu.addItem(withTitle: "Minimize",
                   action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
windowMenu.addItem(withTitle: "Close",
                   action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
windowItem.submenu = windowMenu
app.windowsMenu = windowMenu

app.mainMenu = mainMenu

let delegate = AppDelegate()
app.delegate = delegate
app.run()
