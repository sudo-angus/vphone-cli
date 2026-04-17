import AppKit
import Foundation
import Virtualization

// MARK: - Key Helper

@MainActor
class VPhoneKeyHelper {
    private let vm: VZVirtualMachine
    private let control: VPhoneControl
    weak var window: NSWindow?

    init(vm: VPhoneVirtualMachine, control: VPhoneControl) {
        self.vm = vm.virtualMachine
        self.control = control
    }

    // MARK: - Connection Guard

    private func requireConnection() -> Bool {
        if control.isConnected { return true }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 110),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "vphoned Not Connected"
        panel.center()

        let msg = NSTextField(labelWithString: "The guest agent is not connected. Key injection requires vphoned running inside the VM.")
        msg.frame = NSRect(x: 20, y: 50, width: 340, height: 44)
        msg.lineBreakMode = .byWordWrapping
        msg.maximumNumberOfLines = 3

        let ok = NSButton(frame: NSRect(x: 280, y: 12, width: 80, height: 28))
        ok.title = "OK"
        ok.bezelStyle = .rounded
        ok.keyEquivalent = "\r"
        ok.target = NSApp
        ok.action = #selector(NSApplication.stopModal(withCode:))

        panel.contentView?.addSubview(msg)
        panel.contentView?.addSubview(ok)

        NSApp.runModal(for: panel)
        panel.orderOut(nil)

        return false
    }

    // MARK: - Hardware Keys (Consumer Page 0x0C)

    func sendHome() {
        guard requireConnection() else { return }
        control.sendHIDPress(page: 0x0C, usage: 0x40)
    }

    func sendPower() {
        guard requireConnection() else { return }
        control.sendHIDPress(page: 0x0C, usage: 0x30)
    }

    func sendVolumeUp() {
        guard requireConnection() else { return }
        control.sendHIDPress(page: 0x0C, usage: 0xE9)
    }

    func sendVolumeDown() {
        guard requireConnection() else { return }
        control.sendHIDPress(page: 0x0C, usage: 0xEA)
    }

    // MARK: - Combos

    func sendSpotlight() {
        guard requireConnection() else { return }
        // Cmd+Space: messages are processed sequentially by vphoned
        control.sendHIDDown(page: 0x07, usage: 0xE3) // Cmd down
        control.sendHIDPress(page: 0x07, usage: 0x2C) // Space press
        control.sendHIDUp(page: 0x07, usage: 0xE3) // Cmd up
    }
}
