import AppKit
import Observation
import SwiftUI

// MARK: - Attached Windows

@MainActor
@Observable
final class VPhoneAttitudeDialsWindowController: NSObject {
    let model: VPhoneMotionModel
    var isShown = false {
        didSet {
            guard isShown != oldValue else { return }
            updateVisibility()
        }
    }

    private(set) var isPresented = false
    private(set) var hoveredAxis: VPhoneAttitudeAxis?
    @ObservationIgnored private weak var parent: NSWindow?
    @ObservationIgnored private var dials: [VPhoneAttitudeAxis: NSPanel] = [:]
    @ObservationIgnored private var axesWindow: NSPanel?
    @ObservationIgnored private var visibilityTask: Task<Void, Never>?
    @ObservationIgnored private var connectionTask: Task<Void, Never>?

    init(model: VPhoneMotionModel) {
        self.model = model
        super.init()
    }

    func connectionChanged(_ connected: Bool) {
        connectionTask?.cancel()
        connectionTask = Task { await model.connectionChanged(connected) }
    }

    func attach(to window: NSWindow?) {
        removeWindows()
        NotificationCenter.default.removeObserver(self)
        parent = window
        guard let window else { return }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(layoutWindows), name: name, object: window)
        }
        for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(updateVisibility), name: name, object: window)
        }
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(updateVisibility), name: name, object: window)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(close), name: NSWindow.willCloseNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(clearHover), name: NSApplication.didResignActiveNotification, object: nil)
        updateVisibility()
    }

    func setHovered(_ axis: VPhoneAttitudeAxis?) {
        hoveredAxis = isShown && isPresented ? axis : nil
    }

    @objc private func clearHover() { hoveredAxis = nil }

    @objc private func updateVisibility() {
        visibilityTask?.cancel()
        hoveredAxis = nil
        guard let parent, isShown, !parent.isMiniaturized else {
            isPresented = false
            dials.values.forEach { $0.ignoresMouseEvents = true }
            visibilityTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled, let self else { return }
                self.dials.values.forEach { $0.orderOut(nil) }
                self.axesWindow?.orderOut(nil)
            }
            return
        }
        if dials.isEmpty { makeWindows() }
        layoutWindows()
        for dial in dials.values {
            dial.ignoresMouseEvents = false
            dial.orderFront(nil)
            dial.contentView?.layoutSubtreeIfNeeded()
        }
        axesWindow?.orderFront(nil)
        visibilityTask = Task { [weak self] in
            // Give the hosting views a first frame before animating them in.
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            self?.isPresented = true
        }
    }

    private func makeWindows() {
        guard let parent else { return }
        for axis in VPhoneAttitudeAxis.allCases {
            let panel = makePanel(size: axis.size)
            panel.title = VPhoneLocalization.text(axis.title)
            panel.contentView = NSHostingView(rootView: VPhoneAttitudeDial(axis: axis, controller: self))
            parent.addChildWindow(panel, ordered: .above)
            dials[axis] = panel
        }
        let overlay = makePanel(size: parent.frame.size)
        overlay.ignoresMouseEvents = true
        overlay.contentView = NSHostingView(rootView: VPhoneAttitudeAxesOverlay(controller: self))
        parent.addChildWindow(overlay, ordered: .above)
        axesWindow = overlay
    }

    private func makePanel(size: NSSize) -> NSPanel {
        let panel = VPhoneAttitudeDialPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false,
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = true
        panel.isMovable = false
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.animationBehavior = .none
        return panel
    }

    @objc private func layoutWindows() {
        guard let parent else { return }
        let frame = parent.frame
        let visible = parent.screen?.visibleFrame ?? frame.insetBy(dx: -300, dy: -300)
        for (axis, panel) in dials {
            panel.setFrame(Self.dialFrame(axis: axis, around: frame, within: visible), display: true)
        }
        if let content = parent.contentView {
            axesWindow?.setFrame(parent.convertToScreen(content.convert(content.bounds, to: nil)), display: true)
        }
    }

    /// Keep controls reachable at screen edges and in full screen. Child-window
    /// attachment handles movement; resize/screen notifications recompute anchors.
    static func dialFrame(axis: VPhoneAttitudeAxis, around parent: NSRect, within visible: NSRect) -> NSRect {
        let size = axis.size
        let origin: NSPoint
        switch axis {
        case .yaw: origin = NSPoint(x: parent.midX - size.width / 2, y: parent.maxY + 8)
        case .roll: origin = NSPoint(x: parent.midX - size.width / 2, y: parent.minY - size.height - 8)
        case .pitch: origin = NSPoint(x: parent.maxX + 8, y: parent.midY - size.height / 2)
        }
        return NSRect(
            x: min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - size.width)),
            y: min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - size.height)),
            width: size.width, height: size.height,
        )
    }

    private func removeWindows() {
        visibilityTask?.cancel()
        isPresented = false
        hoveredAxis = nil
        for window in Array(dials.values) + [axesWindow].compactMap({ $0 }) {
            parent?.removeChildWindow(window)
            // Hosting views retain this controller; clear them when tearing down.
            window.contentView = nil
            window.close()
        }
        dials.removeAll()
        axesWindow = nil
    }

    @objc func close() {
        connectionTask?.cancel()
        isShown = false
        removeWindows()
        NotificationCenter.default.removeObserver(self)
        parent = nil
    }
}

@MainActor
final class VPhoneAttitudeDialPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
