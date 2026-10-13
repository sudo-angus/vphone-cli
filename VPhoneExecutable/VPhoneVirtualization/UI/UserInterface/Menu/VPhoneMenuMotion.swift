import AppKit

// MARK: - Motion Sensors

extension VPhoneMenuController {
    func buildMotionSensorsMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Motion Sensors", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Motion Sensors")
        menu.autoenablesItems = false
        menu.addItem(makePanelItem(.gyroscope, "3D Gyroscope", keyEquivalent: "", symbol: "gyroscope"))
        menu.addItem(makePanelItem(.attitude, "Device Attitude", keyEquivalent: "", symbol: "rotate.3d"))
        let shake = NSMenuItem(title: VPhoneLocalization.text("Shake"), action: #selector(shakeGuest), keyEquivalent: "")
        shake.target = self
        shake.isEnabled = false
        menu.addItem(.separator())
        menu.addItem(shake)
        shakeMenuItem = shake
        item.submenu = menu
        return item
    }

    @objc func shakeGuest() {
        Task {
            do { _ = try await control.call("input.shake") }
            catch {
                VPhoneAlert.present(title: "Shake", message: String(describing: error), style: .warning)
            }
        }
    }
}
