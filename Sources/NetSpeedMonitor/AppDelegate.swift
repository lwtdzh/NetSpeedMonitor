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

        monitor.$downloadBytesPerSecond
            .combineLatest(monitor.$uploadBytesPerSecond)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.updateStatusItem()
            }
            .store(in: &cancellables)

        applyPresentationSettings()
        monitor.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
    }

    private func applyPresentationSettings() {
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
            button.toolTip = "Net Speed Monitor"
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
        let lines = monitor.menuBarLines(unit: settings.dataRateUnit)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.minimumLineHeight = 9
        paragraph.maximumLineHeight = 9

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.controlTextColor,
            .paragraphStyle: paragraph,
            .baselineOffset: -3.5
        ]

        statusItem?.button?.attributedTitle = NSAttributedString(
            string: lines.joined(separator: "\n"),
            attributes: attributes
        )

        let longestLine = lines
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        statusItem?.length = max(28, ceil(longestLine) + 1)

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
