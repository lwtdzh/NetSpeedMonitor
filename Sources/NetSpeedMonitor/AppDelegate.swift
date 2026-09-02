import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings()

    private let monitor = TrafficMonitor()
    private var floatingPanel: FloatingPanelController?
    private var settingsWindow: SettingsWindowController?
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        floatingPanel = FloatingPanelController(
            monitor: monitor,
            settings: settings,
            openSettings: { [weak self] in self?.showSettings() }
        )

        settings.onPresentationChanged = { [weak self] in
            DispatchQueue.main.async {
                self?.applyPresentationSettings()
            }
        }
        settings.onRefreshIntervalChanged = { [weak self] interval in
            self?.monitor.setRefreshInterval(interval)
        }

        monitor.$downloadBytesPerSecond
            .combineLatest(
                monitor.$uploadBytesPerSecond,
                monitor.$diskReadBytesPerSecond,
                monitor.$diskWriteBytesPerSecond
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _, _ in
                self?.updateStatusItem()
            }
            .store(in: &cancellables)

        monitor.$cpuUsagePercent
            .combineLatest(monitor.$memoryUsagePercent)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.updateStatusItem()
            }
            .store(in: &cancellables)

        applyPresentationSettings()
        monitor.start(refreshInterval: settings.refreshInterval)
    }

    func applicationWillTerminate(_ notification: Notification) {
        floatingPanel?.savePlacement()
        monitor.stop()
    }

    private func applyPresentationSettings() {
        floatingPanel?.setAlwaysOnTop(settings.floatingPanelAlwaysOnTop)
        floatingPanel?.setVisible(settings.showFloatingPanel)

        if settings.showMenuBar {
            if statusItem == nil {
                createStatusItem()
            }
        } else if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }

        updateStatusItem()
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.cell?.usesSingleLineMode = false
            button.cell?.wraps = false
            button.alignment = .left
            button.toolTip = "Network and Disk Speed Monitor"
        }

        let menu = NSMenu()
        let panelItem = NSMenuItem(
            title: "Show Floating Panel",
            action: #selector(toggleFloatingPanel),
            keyEquivalent: ""
        )
        panelItem.target = self
        panelItem.state = settings.showFloatingPanel ? .on : .off
        panelItem.identifier = NSUserInterfaceItemIdentifier("floatingPanel")
        menu.addItem(panelItem)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettingsAction),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Net Speed Monitor",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }

    private func updateStatusItem() {
        let columns = monitor.menuBarColumns(unit: settings.dataRateUnit, settings: settings)
        let font = NSFont.monospacedSystemFont(ofSize: 8.5, weight: .semibold)
        let symbolWidth = ["W", "R", "↓", "↑", "C", "M"]
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        let rateValueWidth = ["0.000", "9.999", "99.99", "999.9"]
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        let rateUnitWidth = ["B", "KB", "MB", "GB", "TB", "PB", "EB"]
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        let percentValueWidth = ("99" as NSString).size(withAttributes: [.font: font]).width
        let percentUnitWidth = ("%" as NSString).size(withAttributes: [.font: font]).width
        let componentGap: CGFloat = 1
        let visibleColumns: [(
            metrics: [MenuBarMetric],
            symbolWidth: CGFloat,
            valueWidth: CGFloat,
            unitWidth: CGFloat
        )] = [
            (columns.disk, symbolWidth, rateValueWidth, rateUnitWidth),
            (columns.network, symbolWidth, rateValueWidth, rateUnitWidth),
            (columns.system, symbolWidth, percentValueWidth, percentUnitWidth)
        ].filter { !$0.metrics.isEmpty }
        let columnGap: CGFloat = visibleColumns.count > 1 ? 8 : 0
        let rowCount = visibleColumns.map { $0.metrics.count }.max() ?? 0
        let lines = (0..<rowCount).map { row in
            visibleColumns.compactMap { column in
                row < column.metrics.count
                    ? column.metrics[row].accessibilityText
                    : nil
            }
            .joined(separator: "  ")
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.minimumLineHeight = 9
        paragraph.maximumLineHeight = 9
        paragraph.lineBreakMode = .byClipping

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.controlTextColor,
            .paragraphStyle: paragraph,
            .baselineOffset: -4.7
        ]

        let contentWidth = visibleColumns.reduce(0) {
            $0 + $1.symbolWidth + $1.valueWidth + $1.unitWidth + componentGap * 2
        }
            + columnGap * CGFloat(max(0, visibleColumns.count - 1))
        let renderedWidth = ceil(contentWidth) + 2
        let imageSize = NSSize(width: renderedWidth, height: 18)
        let image = NSImage(size: imageSize, flipped: true) { _ in
            var originX: CGFloat = 0
            for column in visibleColumns {
                for (row, metric) in column.metrics.enumerated() {
                    let rowY = CGFloat(row) * 9
                    var componentX = originX
                    for (text, width) in [
                        (metric.symbol, column.symbolWidth),
                        (metric.value, column.valueWidth),
                        (metric.unit, column.unitWidth)
                    ] {
                        NSAttributedString(string: text, attributes: attributes).draw(
                            with: NSRect(x: componentX, y: rowY, width: ceil(width), height: 9),
                            options: [.usesLineFragmentOrigin, .usesFontLeading]
                        )
                        componentX += ceil(width) + componentGap
                    }
                }
                originX += column.symbolWidth
                    + column.valueWidth
                    + column.unitWidth
                    + componentGap * 2
                    + columnGap
            }
            return true
        }
        image.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.imagePosition = .imageOnly
        statusItem?.button?.attributedTitle = NSAttributedString()
        statusItem?.button?.setAccessibilityLabel(lines.joined(separator: ", "))
        statusItem?.length = max(28, renderedWidth + 1)

        if
            let item = statusItem?.menu?.items.first(
                where: { $0.identifier?.rawValue == "floatingPanel" }
            )
        {
            item.state = settings.showFloatingPanel ? .on : .off
        }
    }

    @objc private func toggleFloatingPanel() {
        settings.setShowFloatingPanel(!settings.showFloatingPanel)
    }

    @objc private func showSettingsAction() {
        showSettings()
    }

    private func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(settings: settings)
        }
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
