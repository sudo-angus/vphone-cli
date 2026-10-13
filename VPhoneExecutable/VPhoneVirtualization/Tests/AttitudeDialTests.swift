import AppKit
import SwiftUI

@main
struct AttitudeDialTests {
    @MainActor static func main() {
        let preview = CommandLine.arguments.contains("--preview")
        let windows = preview || CommandLine.arguments.contains("--windows")
        if windows {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.regular)
        }
        Task { @MainActor in
            let model = VPhoneMotionModel(ranges: [-180 ... 180, -90 ... 90, -180 ... 180], read: {
                VPhoneMotionReply(configuration: .init(enabled: true), providerRunning: true)
            }, write: { VPhoneMotionReply(configuration: $0, providerRunning: true) })
            await model.connectionChanged(true)
            VPhoneAttitudeAxis.roll.adjust(300, in: model)
            assert(model.xValue == 180 && model.yValue == 0 && model.zValue == 0)
            VPhoneAttitudeAxis.pitch.adjust(-300, in: model)
            assert(model.yValue == -90)
            VPhoneAttitudeAxis.yaw.adjust(-300, in: model)
            assert(model.zValue == -180)
            VPhoneAttitudeAxis.yaw.adjust(.infinity, in: model)
            assert(model.zValue == -180)
            await model.connectionChanged(false)
            VPhoneAttitudeAxis.roll.adjust(-10, in: model)
            assert(model.xValue == 180)
            await model.connectionChanged(true)
            model.reset()
            assert(abs(VPhoneAttitudeAxis.angularDelta(from: 179 * .pi / 180, to: -179 * .pi / 180) - 2) < 0.001)
            assert(abs(VPhoneAttitudeAxis.angularDelta(from: -179 * .pi / 180, to: 179 * .pi / 180) + 2) < 0.001)
            assert(VPhoneAttitudeAxis.roll.scrollDelta(x: 8, y: 1, precise: true) == -2)
            assert(VPhoneAttitudeAxis.pitch.scrollDelta(x: 8, y: -2, precise: false) == -4)
            assert(VPhoneAttitudeAxis.pitch.scrollDelta(x: 0, y: 4, precise: true) == 1)
            assert(VPhoneAttitudeAxis.yaw.scrollDelta(x: 0, y: 4, precise: true) == -1)
            let screen = NSRect(x: -1440, y: 0, width: 1440, height: 900)
            for parent in [NSRect(x: -1000, y: 240, width: 360, height: 420), screen] {
                for axis in VPhoneAttitudeAxis.allCases {
                    assert(screen.contains(VPhoneAttitudeDialsWindowController.dialFrame(axis: axis, around: parent, within: screen)))
                }
            }
            print("Attitude dials: angle bounds, axis isolation, disconnected input, wheel deltas, circular seam and screen-edge layout passed")
            guard windows else { exit(0) }
            await checkWindows(model: model, preview: preview)
        }
        if windows { NSApp.run() } else { dispatchMain() }
    }

    @MainActor static func checkWindows(model: VPhoneMotionModel, preview: Bool) async {
        let parent = NSWindow(contentRect: NSRect(x: 600, y: 270, width: 320, height: 440), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        parent.title = "Attitude Dial Preview"
        parent.isReleasedWhenClosed = false
        parent.contentView?.wantsLayer = true
        parent.contentView?.layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        parent.makeKeyAndOrderFront(nil)
        let controller = VPhoneAttitudeDialsWindowController(model: model)
        controller.attach(to: parent)
        controller.isShown = true
        try? await Task.sleep(for: .milliseconds(300))
        assert(parent.childWindows?.count == 4 && controller.isPresented)
        let roll = parent.childWindows!.first { $0.title == VPhoneLocalization.text("Roll") }!
        assert(!roll.canBecomeKey && roll.parent == parent)
        let original = roll.frame
        parent.setFrameOrigin(NSPoint(x: parent.frame.minX - 40, y: parent.frame.minY))
        assert(abs(roll.frame.minX - original.minX + 40) < 1)
        parent.setContentSize(NSSize(width: 360, height: 480))
        assert(abs(roll.frame.midX - parent.frame.midX) < 1)
        let overlay = parent.childWindows!.first { $0.ignoresMouseEvents }!
        assert(overlay.frame.size == parent.contentView!.frame.size)
        controller.setHovered(.yaw)
        assert(controller.hoveredAxis == .yaw)
        controller.isShown = false
        controller.isShown = true // An old hide completion must not hide a reopened dial.
        try? await Task.sleep(for: .milliseconds(300))
        assert(controller.isPresented && parent.childWindows!.allSatisfy(\.isVisible))

        // Exercise the real NSView drag handler, including the atan2 seam.
        let input = VPhoneAttitudeDialInputView(frame: NSRect(x: 0, y: 0, width: 144, height: 144))
        input.axis = .yaw
        input.enabled = true
        input.adjust = { VPhoneAttitudeAxis.yaw.adjust($0, in: model) }
        let inputWindow = NSWindow(contentRect: input.frame, styleMask: .borderless, backing: .buffered, defer: false)
        inputWindow.isReleasedWhenClosed = false
        inputWindow.contentView = input
        func event(_ type: NSEvent.EventType, angle: Double) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: 72 + cos(angle) * 50, y: 72 + sin(angle) * 50), modifierFlags: [], timestamp: 0, windowNumber: inputWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        input.mouseDown(with: event(.leftMouseDown, angle: 179 * .pi / 180))
        input.mouseDragged(with: event(.leftMouseDragged, angle: -179 * .pi / 180))
        assert(abs(model.zValue + 2) < 0.001)
        input.mouseUp(with: event(.leftMouseUp, angle: -179 * .pi / 180))
        func linearEvent(_ type: NSEvent.EventType, point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: inputWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        for axis in [VPhoneAttitudeAxis.roll, .pitch] {
            input.axis = axis
            input.adjust = { axis.adjust($0, in: model) }
            input.mouseDown(with: linearEvent(.leftMouseDown, point: NSPoint(x: 72, y: 72)))
            input.mouseDragged(with: linearEvent(.leftMouseDragged, point: NSPoint(x: 92, y: 92)))
            assert(axis.value(in: model) == -10)
            input.mouseUp(with: linearEvent(.leftMouseUp, point: NSPoint(x: 92, y: 92)))
        }
        inputWindow.close()
        print("Attitude dials: real circular drag, child attachment, focus, movement, resize, hover and rapid toggle passed")
        if preview {
            let editor = NSWindow(contentRect: NSRect(x: 100, y: 230, width: 480, height: 520), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            editor.title = "Device Attitude"
            editor.isReleasedWhenClosed = false
            editor.contentView = NSHostingView(rootView: VPhoneMotionEditor(model: model, sensor: .attitude, attitudeDials: controller))
            editor.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            while parent.isVisible, editor.isVisible {
                try? await Task.sleep(for: .seconds(1))
            }
            controller.close()
            exit(0)
        }
        controller.isShown = false
        try? await Task.sleep(for: .milliseconds(300))
        assert(parent.childWindows!.allSatisfy { !$0.isVisible })
        controller.close()
        assert(parent.childWindows?.isEmpty != false)
        parent.close()
        print("Attitude dials: animated dismissal and child-window cleanup passed")
        exit(0)
    }
}
