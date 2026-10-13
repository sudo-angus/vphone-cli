import AppKit
import SwiftUI

// MARK: - Axes and Interaction

enum VPhoneAttitudeAxis: String, CaseIterable, Identifiable {
    case roll, pitch, yaw

    var id: Self { self }
    var title: String {
        switch self {
        case .roll: "Roll"
        case .pitch: "Pitch"
        case .yaw: "Yaw"
        }
    }

    var range: ClosedRange<Double> { self == .pitch ? -90 ... 90 : -180 ... 180 }
    var color: Color {
        switch self {
        case .roll: .green
        case .pitch: .red
        case .yaw: .blue
        }
    }

    var size: NSSize {
        switch self {
        case .roll: NSSize(width: 248, height: 80)
        case .pitch: NSSize(width: 80, height: 248)
        case .yaw: NSSize(width: 144, height: 144)
        }
    }

    @MainActor func value(in model: VPhoneMotionModel) -> Double {
        switch self {
        case .roll: model.xValue
        case .pitch: model.yValue
        case .yaw: model.zValue
        }
    }

    @MainActor func adjust(_ delta: Double, in model: VPhoneMotionModel) {
        guard model.canEdit, delta.isFinite else { return }
        let value = min(range.upperBound, max(range.lowerBound, value(in: model) + delta))
        switch self {
        case .roll: model.xValue = value
        case .pitch: model.yValue = value
        case .yaw: model.zValue = value
        }
    }

    /// The shortest signed turn avoids a jump when a circular drag crosses ±π.
    static func angularDelta(from: Double, to: Double) -> Double {
        atan2(sin(to - from), cos(to - from)) * 180 / .pi
    }

    func scrollDelta(x: Double, y: Double, precise: Bool) -> Double {
        let delta = self == .roll && abs(x) > abs(y) ? x : y
        let direction = self == .pitch ? 1.0 : -1.0
        return direction * delta * (precise ? 0.25 : 2)
    }
}

/// AppKit supplies wheel deltas and incremental circular drags without
/// intercepting any of the guest display's mouse or trackpad events.
struct VPhoneAttitudeDialInput: NSViewRepresentable {
    let axis: VPhoneAttitudeAxis
    let enabled: Bool
    let adjust: @MainActor (Double) -> Void
    let hover: @MainActor (Bool) -> Void

    func makeNSView(context _: Context) -> VPhoneAttitudeDialInputView {
        let view = VPhoneAttitudeDialInputView()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: VPhoneAttitudeDialInputView, context _: Context) {
        view.axis = axis
        view.enabled = enabled
        view.adjust = adjust
        view.hover = hover
    }
}

@MainActor
final class VPhoneAttitudeDialInputView: NSView {
    var axis = VPhoneAttitudeAxis.roll
    var enabled = false
    var adjust: (@MainActor (Double) -> Void)?
    var hover: (@MainActor (Bool) -> Void)?
    private var lastPoint: NSPoint?
    private var tracking: NSTrackingArea?

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: enabled ? .openHand : .arrow)
    }

    override func mouseEntered(with _: NSEvent) { hover?(true) }
    override func mouseExited(with _: NSEvent) { hover?(false) }
    override func mouseDown(with event: NSEvent) {
        guard enabled else { return }
        lastPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        defer { lastPoint = point }
        guard enabled, let lastPoint else { return }
        let delta: Double
        switch axis {
        case .roll: delta = -Double(point.x - lastPoint.x) * 0.5
        case .pitch: delta = -Double(point.y - lastPoint.y) * 0.5
        case .yaw:
            let center = NSPoint(x: bounds.midX, y: bounds.midY)
            // Near the hub an angle is undefined; rebase instead of jumping.
            guard hypot(point.x - center.x, point.y - center.y) > 12,
                  hypot(lastPoint.x - center.x, lastPoint.y - center.y) > 12 else { return }
            delta = -VPhoneAttitudeAxis.angularDelta(
                from: atan2(lastPoint.y - center.y, lastPoint.x - center.x),
                to: atan2(point.y - center.y, point.x - center.x),
            )
        }
        adjust?(delta)
    }

    override func mouseUp(with _: NSEvent) { lastPoint = nil }

    override func scrollWheel(with event: NSEvent) {
        guard enabled else { return }
        adjust?(axis.scrollDelta(x: event.scrollingDeltaX, y: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas))
    }
}

// MARK: - Dial Faces

struct VPhoneAttitudeDial: View {
    let axis: VPhoneAttitudeAxis
    let controller: VPhoneAttitudeDialsWindowController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let value = axis.value(in: controller.model)
        ZStack {
            if axis == .yaw {
                VPhoneAttitudeCircularScale(color: axis.color)
                    .rotationEffect(.degrees(value))
                Rectangle().fill(axis.color).frame(width: 2, height: 16).offset(y: -55)
            } else {
                VPhoneAttitudeLinearScale(vertical: axis == .pitch, value: value, color: axis.color)
            }
            VStack(spacing: 4) {
                Text(VPhoneLocalization.text(axis.title)).foregroundStyle(.secondary)
                Text(verbatim: value.formatted(.number.precision(.fractionLength(0 ... 1))) + "°")
                    .contentTransition(.numericText(value: value))
                    .foregroundStyle(axis.color)
            }
            .font(.system(.caption, design: .monospaced))
            .padding(4)
            .background(Color(red: 0.102, green: 0.102, blue: 0.102))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.102, green: 0.102, blue: 0.102))
        .clipShape(RoundedRectangle(cornerRadius: axis == .yaw ? 72 : 8))
        .overlay {
            RoundedRectangle(cornerRadius: axis == .yaw ? 72 : 8)
                .stroke(controller.hoveredAxis == axis ? axis.color : Color(white: 0.2), lineWidth: 1)
        }
        .opacity(controller.model.canEdit ? 1 : 0.5)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: value)
        .overlay {
            VPhoneAttitudeDialInput(axis: axis, enabled: controller.model.canEdit, adjust: {
                axis.adjust($0, in: controller.model)
            }, hover: { controller.setHovered($0 ? axis : nil) })
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(VPhoneLocalization.text(axis.title))
        .accessibilityValue(value.formatted(.number.precision(.fractionLength(0 ... 1))) + "°")
        .accessibilityIdentifier("attitude-dial-" + axis.rawValue)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: axis.adjust(1, in: controller.model)
            case .decrement: axis.adjust(-1, in: controller.model)
            @unknown default: break
            }
        }
        .scaleEffect(controller.isPresented ? 1 : 0.85)
        .opacity(controller.isPresented ? 1 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: controller.isPresented)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: controller.hoveredAxis)
        .environment(\.colorScheme, .dark)
        .padding(2)
    }
}

struct VPhoneAttitudeCircularScale: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 12
            for tick in 0 ..< 72 {
                let angle = Double(tick) * .pi / 36
                let inner = radius - (tick.isMultiple(of: 6) ? 12 : 6)
                var path = Path()
                path.move(to: CGPoint(x: center.x + sin(angle) * inner, y: center.y - cos(angle) * inner))
                path.addLine(to: CGPoint(x: center.x + sin(angle) * radius, y: center.y - cos(angle) * radius))
                context.stroke(path, with: .color(tick == 0 ? color : .gray), lineWidth: tick == 0 ? 2 : 1)
                if tick.isMultiple(of: 6) {
                    let degrees = (tick > 36 ? tick - 72 : tick) * 5
                    let labelRadius = radius - 24
                    context.draw(
                        Text(verbatim: "\(degrees)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.gray),
                        at: CGPoint(x: center.x + sin(angle) * labelRadius, y: center.y - cos(angle) * labelRadius),
                    )
                }
            }
        }
        .accessibilityHidden(true)
    }
}

struct VPhoneAttitudeLinearScale: View {
    let vertical: Bool
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            // Static scale, moved by a standard animatable offset. One degree
            // is two points; the center marker stays fixed as the ticks move.
            Canvas { context, size in
                for degrees in stride(from: -180, through: 180, by: 5) {
                    let position = CGFloat(vertical ? 180 - degrees : degrees + 180) * 2
                    let length: CGFloat = degrees.isMultiple(of: 30) ? 16 : 8
                    var path = Path()
                    if vertical {
                        path.move(to: CGPoint(x: 8, y: position))
                        path.addLine(to: CGPoint(x: 8 + length, y: position))
                    } else {
                        path.move(to: CGPoint(x: position, y: 8))
                        path.addLine(to: CGPoint(x: position, y: 8 + length))
                    }
                    context.stroke(path, with: .color(degrees == 0 ? color : .gray), lineWidth: degrees == 0 ? 2 : 1)
                    if degrees.isMultiple(of: 30) {
                        context.draw(
                            Text(verbatim: "\(degrees)").font(.system(.caption2, design: .monospaced)).foregroundStyle(.gray),
                            at: CGPoint(x: vertical ? size.width - 20 : position, y: vertical ? position : size.height - 16),
                        )
                    }
                }
            }
            .frame(width: vertical ? geometry.size.width : 720, height: vertical ? 720 : geometry.size.height)
            .offset(
                x: vertical ? 0 : geometry.size.width / 2 - 360 - value * 2,
                y: vertical ? geometry.size.height / 2 - 360 + value * 2 : 0,
            )
            Rectangle().fill(color)
                .frame(width: vertical ? 20 : 2, height: vertical ? 2 : 20)
                .position(x: vertical ? 18 : geometry.size.width / 2, y: vertical ? geometry.size.height / 2 : 18)
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

// MARK: - Hover Axes

struct VPhoneAttitudeAxesOverlay: View {
    let controller: VPhoneAttitudeDialsWindowController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Rectangle().fill(VPhoneAttitudeAxis.roll.color)
                    .frame(width: 2, height: geometry.size.height - 24)
                    .opacity(controller.hoveredAxis == .roll ? 0.85 : 0)
                Rectangle().fill(VPhoneAttitudeAxis.pitch.color)
                    .frame(width: geometry.size.width - 24, height: 2)
                    .opacity(controller.hoveredAxis == .pitch ? 0.85 : 0)
                Circle().stroke(VPhoneAttitudeAxis.yaw.color, lineWidth: 2)
                    .frame(width: min(geometry.size.width, geometry.size.height) - 24,
                           height: min(geometry.size.width, geometry.size.height) - 24)
                    .overlay(alignment: .top) {
                        Circle().fill(VPhoneAttitudeAxis.yaw.color).frame(width: 6, height: 6)
                    }
                    .rotationEffect(.degrees(controller.model.zValue))
                    .opacity(controller.hoveredAxis == .yaw ? 0.85 : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: controller.hoveredAxis)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: controller.model.zValue)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
