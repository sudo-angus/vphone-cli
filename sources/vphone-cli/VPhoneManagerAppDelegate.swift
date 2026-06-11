import AppKit
import Foundation

/// App delegate for `vphone-cli manage` — the always-on VM manager. Unlike the
/// boot path (a menu-bar agent that owns one VM), this runs as a regular Dock
/// app and supervises `vphone-cli boot` children. The boot binary is untouched
/// in its per-VM role; this is a separate launch mode of the same executable.
final class VPhoneManagerAppDelegate: NSObject, NSApplicationDelegate {
    private let cli: VPhoneManageCLI
    private var windowController: VPhoneManagerWindowController?
    private var model: VPhoneManagerModel?

    init(cli: VPhoneManageCLI) {
        self.cli = cli
        super.init()
    }

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.regular)
        setupMainMenu()

        let repoRoot = VPhoneVMRegistry.findRepoRoot()
        let libraryRoot = cli.library.map { URL(fileURLWithPath: $0) }
        let registry = VPhoneVMRegistry(repoRoot: repoRoot, libraryRoot: libraryRoot)
        let privilege = VPhonePrivilege(repoRoot: repoRoot)
        // Spawn the entitled boot binary, not this (unentitled) manager binary.
        let exe = VPhoneVMRegistry.locateBootBinary(repoRoot: repoRoot).resolvingSymlinksInPath()

        let model = VPhoneManagerModel(registry: registry, privilege: privilege, executableURL: exe)
        self.model = model

        let wc = VPhoneManagerWindowController(model: model)
        windowController = wc
        wc.showWindow()

        Task { @MainActor in await model.bootstrap() }
    }

    // Standard Dock-app lifecycle: closing the window only closes the window —
    // the supervisor (and its VMs) keeps running until an explicit ⌘Q. Quitting
    // on last-window-close would also re-trigger termination every time the
    // confirm alert itself closed, looping the dialog forever.
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { windowController?.showWindow() }
        return true
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.supervisor.hasRunning else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit VPhone manager?"
        alert.informativeText = "VMs the manager started will be stopped. Adopted VMs keep running."
        alert.addButton(withTitle: "Quit and Stop VMs")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            model.teardownForQuit()
            return .terminateNow
        }
        return .terminateCancel
    }

    func applicationWillTerminate(_: Notification) {
        model?.teardownForQuit()
    }

    // MARK: - Menu

    /// A minimal but functional menu bar (the app is launched without a
    /// storyboard). Gives the standard App, Edit, and Window menus so
    /// ⌘Q / ⌘C / ⌘W and text selection in the log pane behave normally.
    @MainActor
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About VPhone", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide VPhone", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit VPhone", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }
}
