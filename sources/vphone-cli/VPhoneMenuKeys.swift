import AppKit
import LocalAuthentication

// MARK: - Keys Menu

extension VPhoneMenuController {
    func buildKeysMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Keys")
        menu.addItem(makeItem("Home Screen", action: #selector(sendHome)))
        menu.addItem(makeItem("Power", action: #selector(sendPower)))
        menu.addItem(makeItem("Volume Up", action: #selector(sendVolumeUp)))
        menu.addItem(makeItem("Volume Down", action: #selector(sendVolumeDown)))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeItem("Spotlight (Cmd+Space)", action: #selector(sendSpotlight)))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeItem("Send Host Clipboard to Guest", action: #selector(sendHostClipboardToGuest)))
        menu.addItem(makeItem("Receive Guest Clipboard to Host", action: #selector(receiveGuestClipboardToHost)))
        let typeItem = makeItem("Type ASCII from Clipboard", action: #selector(typeFromClipboard))
        if !keyHelper.hasHardwareKeyboard {
            typeItem.isEnabled = false
            typeItem.toolTip = "Requires the hardware keyboard (disabled by --software-keyboard)."
        }
        menu.addItem(typeItem)
        menu.addItem(NSMenuItem.separator())
        let tidItem = makeItem("Touch ID Home Forwarding", action: #selector(toggleTouchIDForwarding))
        if hasTouchID {
            let tidEnabled = !UserDefaults.standard.bool(forKey: "touchIDForwardingDisabled")
            tidItem.state = tidEnabled ? .on : .off
        } else {
            tidItem.isEnabled = false
            tidItem.state = .off
        }
        touchIDMenuItem = tidItem
        menu.addItem(tidItem)
        item.submenu = menu
        return item
    }

    @objc func sendHome() {
        keyHelper.sendHome()
    }

    @objc func sendPower() {
        keyHelper.sendPower()
    }

    @objc func sendVolumeUp() {
        keyHelper.sendVolumeUp()
    }

    @objc func sendVolumeDown() {
        keyHelper.sendVolumeDown()
    }

    @objc func sendSpotlight() {
        keyHelper.sendSpotlight()
    }

    @objc func typeFromClipboard() {
        keyHelper.typeFromClipboard()
    }

    @objc func sendHostClipboardToGuest() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            showAlert(title: "Clipboard", message: "Host clipboard has no text.", style: .warning)
            return
        }
        Task {
            do {
                try await control.clipboardSet(text: text)
                showAlert(
                    title: "Clipboard",
                    message: "Sent \(text.count) characters to guest clipboard. Long-press in the target field to paste.",
                    style: .informational
                )
            } catch {
                showAlert(title: "Clipboard", message: "\(error)", style: .warning)
            }
        }
    }

    @objc func receiveGuestClipboardToHost() {
        Task {
            do {
                let content = try await control.clipboardGet()
                let pb = NSPasteboard.general
                pb.clearContents()
                var summary: [String] = []
                if let text = content.text, !text.isEmpty {
                    pb.setString(text, forType: .string)
                    summary.append("\(text.count) characters of text")
                }
                if content.hasImage, let data = content.imageData, !data.isEmpty {
                    pb.setData(data, forType: .png)
                    summary.append("\(data.count) bytes of image (PNG)")
                }
                guard !summary.isEmpty else {
                    showAlert(title: "Clipboard", message: "Guest clipboard is empty.", style: .warning)
                    return
                }
                showAlert(
                    title: "Clipboard",
                    message: "Copied from guest: \(summary.joined(separator: ", ")).",
                    style: .informational
                )
            } catch {
                showAlert(title: "Clipboard", message: "\(error)", style: .warning)
            }
        }
    }

    @objc func toggleTouchIDForwarding() {
        guard let monitor = touchIDMonitor, let item = touchIDMenuItem else { return }
        monitor.isEnabled.toggle()
        item.state = monitor.isEnabled ? .on : .off
        UserDefaults.standard.set(!monitor.isEnabled, forKey: "touchIDForwardingDisabled")
    }
}

private extension VPhoneMenuController {
    var hasTouchID: Bool {
        let ctx = LAContext()
        ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return ctx.biometryType == .touchID
    }
}
