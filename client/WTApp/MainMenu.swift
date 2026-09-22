import AppKit
import Sparkle

/// The menu bar, built in code (no MainMenu.xib).  Standard items target the responder chain
/// with the usual AppKit selectors so they enable and disable themselves.
enum MainMenu {
    @MainActor
    static func build(updater: SPUStandardUpdaterController) -> NSMenu {
        let menuBar = NSMenu(title: "Main")
        menuBar.addItem(submenu(applicationMenu(updater: updater)))
        menuBar.addItem(submenu(fileMenu()))
        menuBar.addItem(submenu(editMenu()))
        let windowMenu = windowMenuItems()
        menuBar.addItem(submenu(windowMenu))
        NSApp.windowsMenu = windowMenu
        let help = helpMenu()
        menuBar.addItem(submenu(help))
        NSApp.helpMenu = help
        return menuBar
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(
        _ title: String, _ action: Selector?, _ key: String = "",
        modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        return item
    }

    @MainActor
    private static func applicationMenu(updater: SPUStandardUpdaterController) -> NSMenu {
        let menu = NSMenu(title: "WireTuner")
        menu.addItem(item("About WireTuner", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(item(
            "Check for Updates…", #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            target: updater
        ))
        menu.addItem(.separator())
        menu.addItem(item("Hide WireTuner", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", modifiers: [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit WireTuner", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item("New", #selector(NSDocumentController.newDocument(_:)), "n"))
        menu.addItem(item("Open…", #selector(NSDocumentController.openDocument(_:)), "o"))
        menu.addItem(.separator())
        menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "Z"))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        return menu
    }

    private static func windowMenuItems() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    private static func helpMenu() -> NSMenu {
        let menu = NSMenu(title: "Help")
        menu.addItem(item("WireTuner Help", #selector(NSApplication.showHelp(_:)), "?"))
        return menu
    }
}
