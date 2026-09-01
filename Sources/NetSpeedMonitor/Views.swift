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
            let diskRowCount = (settings.showDiskRead ? 1 : 0) + (settings.showDiskWrite ? 1 : 0)
            let networkRowCount = (settings.showDownload ? 1 : 0) + (settings.showUpload ? 1 : 0)
            let groupCount = (diskRowCount > 0 ? 1 : 0) + (networkRowCount > 0 ? 1 : 0)
            let rowCount = max(diskRowCount, networkRowCount)
            let fontSize = min(
                min(
                    max(geometry.size.width / (7.2 * CGFloat(groupCount)), 10),
                    max(geometry.size.height / (1.8 * CGFloat(rowCount)), 10)
                ),
                34
            )

            HStack(spacing: max(8, fontSize * 0.65)) {
                if diskRowCount > 0 {
                    VStack(spacing: max(2, fontSize * 0.08)) {
                        if settings.showDiskWrite {
                            rate(
                                label: "W",
                                color: .red,
                                bytesPerSecond: monitor.diskWriteBytesPerSecond,
                                fontSize: fontSize
                            )
                        }
                        if settings.showDiskRead {
                            rate(
                                label: "R",
                                color: .blue,
                                bytesPerSecond: monitor.diskReadBytesPerSecond,
                                fontSize: fontSize
                            )
                        }
                    }
                    .frame(maxWidth: .infinity)
                }

                if networkRowCount > 0 {
                    VStack(spacing: max(2, fontSize * 0.08)) {
                        if settings.showDownload {
                            rate(
                                systemImage: "arrow.down",
                                color: .green,
                                bytesPerSecond: monitor.downloadBytesPerSecond,
                                fontSize: fontSize
                            )
                        }
                        if settings.showUpload {
                            rate(
                                systemImage: "arrow.up",
                                color: .orange,
                                bytesPerSecond: monitor.uploadBytesPerSecond,
                                fontSize: fontSize
                            )
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
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
        label: String? = nil,
        systemImage: String? = nil,
        color: Color,
        bytesPerSecond: UInt64,
        fontSize: CGFloat
    ) -> some View {
        let rate = TrafficMonitor.formattedRate(
            bytesPerSecond,
            unit: settings.dataRateUnit
        )

        return HStack(spacing: max(3, fontSize * 0.28)) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage)
                } else {
                    Text(label ?? "")
                }
            }
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
            Section("Displayed rates") {
                Toggle(
                    "Network download",
                    isOn: Binding(
                        get: { settings.showDownload },
                        set: settings.setShowDownload
                    )
                )
                Toggle(
                    "Network upload",
                    isOn: Binding(
                        get: { settings.showUpload },
                        set: settings.setShowUpload
                    )
                )
                Toggle(
                    "Disk read",
                    isOn: Binding(
                        get: { settings.showDiskRead },
                        set: settings.setShowDiskRead
                    )
                )
                Toggle(
                    "Disk write",
                    isOn: Binding(
                        get: { settings.showDiskWrite },
                        set: settings.setShowDiskWrite
                    )
                )
                Text("At least one rate must remain visible.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
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

                Picker(
                    "Refresh interval",
                    selection: Binding(
                        get: { settings.refreshInterval },
                        set: settings.setRefreshInterval
                    )
                ) {
                    ForEach(AppSettings.refreshIntervalOptions, id: \.self) { interval in
                        Text(interval == 1 ? "1 second" : "\(interval) seconds")
                            .tag(interval)
                    }
                }
                .pickerStyle(.menu)
            }

            if let error = settings.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .padding(8)
        .frame(width: 400, height: 430)
    }
}
