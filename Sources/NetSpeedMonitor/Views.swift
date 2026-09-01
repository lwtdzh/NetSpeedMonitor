import AppKit
import SwiftUI

private enum PanelResizeEdge {
    case left
    case right
    case top
    case bottom
}

private struct PanelResizeHandle: NSViewRepresentable {
    let edge: PanelResizeEdge

    func makeNSView(context: Context) -> PanelResizeHandleView {
        PanelResizeHandleView(edge: edge)
    }

    func updateNSView(_ nsView: PanelResizeHandleView, context: Context) {}
}

private final class PanelResizeHandleView: NSView {
    private let edge: PanelResizeEdge

    init(edge: PanelResizeEdge) {
        self.edge = edge
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        let cursor: NSCursor = switch edge {
        case .left, .right: .resizeLeftRight
        case .top, .bottom: .resizeUpDown
        }
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let initialFrame = window.frame
        let initialMouse = NSEvent.mouseLocation
        let eventMask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp]

        while let event = window.nextEvent(
            matching: eventMask,
            until: .distantFuture,
            inMode: .eventTracking,
            dequeue: true
        ) {
            if event.type == .leftMouseUp {
                break
            }

            let mouse = NSEvent.mouseLocation
            let deltaX = mouse.x - initialMouse.x
            let deltaY = mouse.y - initialMouse.y
            var frame = initialFrame

            switch edge {
            case .left:
                frame.origin.x += deltaX
                frame.size.width -= deltaX
            case .right:
                frame.size.width += deltaX
            case .bottom:
                frame.origin.y += deltaY
                frame.size.height -= deltaY
            case .top:
                frame.size.height += deltaY
            }

            window.setFrame(frame, display: true)
        }

        window.saveFrame(usingName: "NetSpeedMonitorFloatingPanel")
    }
}

struct SpeedPanelView: View {
    @ObservedObject var monitor: TrafficMonitor
    @ObservedObject var settings: AppSettings
    let openSettings: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let fontSize = min(
                min(
                    max(geometry.size.width / 7.2, 10),
                    max(geometry.size.height / 3.6, 10)
                ),
                34
            )

            VStack(spacing: max(2, fontSize * 0.08)) {
                rate(
                    symbol: "arrow.down",
                    color: .green,
                    bytesPerSecond: monitor.downloadBytesPerSecond,
                    fontSize: fontSize
                )
                rate(
                    symbol: "arrow.up",
                    color: .orange,
                    bytesPerSecond: monitor.uploadBytesPerSecond,
                    fontSize: fontSize
                )
            }
            .padding(.horizontal, max(7, fontSize * 0.5))
            .padding(.vertical, max(4, fontSize * 0.25))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.white.opacity(0.16))
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: openSettings)
            .overlay(alignment: .leading) {
                PanelResizeHandle(edge: .left)
                    .frame(width: 10)
                    .frame(maxHeight: .infinity)
            }
            .overlay(alignment: .trailing) {
                PanelResizeHandle(edge: .right)
                    .frame(width: 10)
                    .frame(maxHeight: .infinity)
            }
            .overlay(alignment: .top) {
                PanelResizeHandle(edge: .top)
                    .frame(height: 10)
                    .frame(maxWidth: .infinity)
            }
            .overlay(alignment: .bottom) {
                PanelResizeHandle(edge: .bottom)
                    .frame(height: 10)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func rate(
        symbol: String,
        color: Color,
        bytesPerSecond: UInt64,
        fontSize: CGFloat
    ) -> some View {
        let rate = TrafficMonitor.formattedRate(
            bytesPerSecond,
            unit: settings.dataRateUnit
        )

        return HStack(spacing: max(3, fontSize * 0.28)) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .font(.system(size: fontSize * 0.86, weight: .semibold))
                .frame(width: fontSize, alignment: .center)

            Text(rate.value)
                .foregroundStyle(.primary)
                .monospacedDigit()
                .font(.system(size: fontSize, weight: .semibold))

            Text(rate.unit)
                .foregroundStyle(.secondary)
                .font(.system(size: fontSize * 0.54, weight: .medium))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.45)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Picker(
                "Speed unit",
                selection: Binding(
                    get: { settings.dataRateUnit },
                    set: settings.setDataRateUnit
                )
            ) {
                ForEach(DataRateUnit.allCases) { unit in
                    Text(unit.title).tag(unit)
                }
            }
            .pickerStyle(.segmented)

            Toggle(
                "Launch at login",
                isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: settings.setLaunchAtLogin
                )
            )

            Toggle(
                "Show speed in menu bar",
                isOn: Binding(
                    get: { settings.showMenuBar },
                    set: settings.setShowMenuBar
                )
            )

            Toggle(
                "Show always-on-top panel",
                isOn: Binding(
                    get: { settings.showFloatingPanel },
                    set: settings.setShowFloatingPanel
                )
            )

            LabeledContent("Refresh interval", value: "1 second")

            if let error = settings.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .padding(8)
        .frame(width: 380, height: 280)
    }
}
