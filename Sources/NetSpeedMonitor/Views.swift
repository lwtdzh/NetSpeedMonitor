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
    private static let aspectRatio: CGFloat = 4.5
    private static let minimumHeight: CGFloat = 52
    private static let maximumHeight: CGFloat = 160
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
            let requestedHeight: CGFloat

            switch edge {
            case .left:
                requestedHeight = (initialFrame.width - deltaX) / Self.aspectRatio
            case .right:
                requestedHeight = (initialFrame.width + deltaX) / Self.aspectRatio
            case .bottom:
                requestedHeight = initialFrame.height - deltaY
            case .top:
                requestedHeight = initialFrame.height + deltaY
            }

            let height = min(
                max(requestedHeight, Self.minimumHeight),
                Self.maximumHeight
            )
            let width = height * Self.aspectRatio
            var frame = NSRect(
                x: initialFrame.midX - width / 2,
                y: initialFrame.midY - height / 2,
                width: width,
                height: height
            )

            switch edge {
            case .left:
                frame.origin.x = initialFrame.maxX - width
            case .right:
                frame.origin.x = initialFrame.minX
            case .bottom:
                frame.origin.y = initialFrame.maxY - height
            case .top:
                frame.origin.y = initialFrame.minY
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
            let systemRowCount = (settings.showCPU ? 1 : 0) + (settings.showMemory ? 1 : 0)
            let groupCount = (diskRowCount > 0 ? 1 : 0)
                + (networkRowCount > 0 ? 1 : 0)
                + (systemRowCount > 0 ? 1 : 0)
            let rowCount = max(diskRowCount, max(networkRowCount, systemRowCount))
            let fontSize = min(
                max(geometry.size.width / (5.2 * CGFloat(groupCount)), 10),
                max(geometry.size.height / (1.8 * CGFloat(rowCount)), 10)
            )

            HStack(spacing: max(6, fontSize * 0.3)) {
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
                    .fixedSize(horizontal: true, vertical: false)
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
                    .fixedSize(horizontal: true, vertical: false)
                }

                if systemRowCount > 0 {
                    VStack(spacing: max(2, fontSize * 0.08)) {
                        if settings.showCPU {
                            percentage(
                                label: "C",
                                value: monitor.cpuUsagePercent,
                                fontSize: fontSize
                            )
                        }
                        if settings.showMemory {
                            percentage(
                                label: "M",
                                value: monitor.memoryUsagePercent,
                                fontSize: fontSize
                            )
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(max(4, fontSize * 0.25))
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
        let symbolColumnWidth = fontSize
        let valueColumnWidth = fontSize * 3.15
        let unitColumnWidth = fontSize * 0.8
        let columnSpacing = max(1, fontSize * 0.08)

        return HStack(spacing: columnSpacing) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage)
                } else {
                    Text(label ?? "")
                }
            }
            .foregroundStyle(color)
            .font(.system(size: fontSize * 0.86, weight: .semibold))
            .frame(width: symbolColumnWidth, alignment: .center)

            Text(rate.value)
                .foregroundStyle(.primary)
                .monospacedDigit()
                .font(.system(size: fontSize, weight: .semibold))
                .frame(width: valueColumnWidth, alignment: .center)

            Text(rate.unit)
                .foregroundStyle(.secondary)
                .font(.system(size: fontSize * 0.54, weight: .medium))
                .frame(width: unitColumnWidth, alignment: .center)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.45)
    }

    private func percentage(label: String, value: UInt64, fontSize: CGFloat) -> some View {
        let symbolColumnWidth = fontSize
        let valueColumnWidth = fontSize * 1.3
        let unitColumnWidth = fontSize * 0.5
        let columnSpacing = max(1, fontSize * 0.08)

        return HStack(spacing: columnSpacing) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: symbolColumnWidth, alignment: .center)
            Text(TrafficMonitor.formattedPercent(value))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .frame(width: valueColumnWidth, alignment: .center)
            Text("%")
                .foregroundStyle(.secondary)
                .font(.system(size: fontSize * 0.54, weight: .medium))
                .frame(width: unitColumnWidth, alignment: .center)
        }
        .font(.system(size: fontSize, weight: .semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.45)
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
                Toggle(
                    "CPU usage",
                    isOn: Binding(
                        get: { settings.showCPU },
                        set: settings.setShowCPU
                    )
                )
                Toggle(
                    "Memory usage",
                    isOn: Binding(
                        get: { settings.showMemory },
                        set: settings.setShowMemory
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
                    "Show floating panel",
                    isOn: Binding(
                        get: { settings.showFloatingPanel },
                        set: settings.setShowFloatingPanel
                    )
                )

                Toggle(
                    "Keep floating panel on top",
                    isOn: Binding(
                        get: { settings.floatingPanelAlwaysOnTop },
                        set: settings.setFloatingPanelAlwaysOnTop
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
        .frame(width: 400, height: 530)
    }
}
