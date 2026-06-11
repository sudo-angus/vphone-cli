import AppKit
import SwiftUI

/// Hosts the manager SwiftUI view in a standard Dock-app window. Mirrors the
/// shape of the other window controllers in the project (programmatic NSWindow
/// + NSHostingController, `isReleasedWhenClosed = false`).
@MainActor
final class VPhoneManagerWindowController {
    private var window: NSWindow?
    let model: VPhoneManagerModel

    init(model: VPhoneManagerModel) {
        self.model = model
    }

    func showWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: VPhoneManagerView(model: model))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "VPhone"
        window.subtitle = "VM manager"
        window.contentViewController = hosting
        window.contentMinSize = NSSize(width: 820, height: 520)
        window.setContentSize(NSSize(width: 980, height: 620))
        window.setFrameAutosaveName("vphone-manager")
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}
