import Combine
import Foundation
import ServiceManagement

enum DataRateUnit: String, CaseIterable, Identifiable {
    case bits
    case bytes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bits: "Bits/s"
        case .bytes: "Bytes/s"
        }
    }
}

final class AppSettings: ObservableObject {
    static let refreshIntervalOptions = [1, 2, 3, 5, 10]

    private enum Key {
        static let showMenuBar = "showMenuBar"
        static let showFloatingPanel = "showFloatingPanel"
        static let floatingPanelAlwaysOnTop = "floatingPanelAlwaysOnTop"
        static let showDownload = "showDownload"
        static let showUpload = "showUpload"
        static let showDiskRead = "showDiskRead"
        static let showDiskWrite = "showDiskWrite"
        static let showCPU = "showCPU"
        static let showMemory = "showMemory"
        static let dataRateUnit = "dataRateUnit"
        static let refreshInterval = "refreshInterval"
    }

    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var showMenuBar: Bool
    @Published private(set) var showFloatingPanel: Bool
    @Published private(set) var floatingPanelAlwaysOnTop: Bool
    @Published private(set) var showDownload: Bool
    @Published private(set) var showUpload: Bool
    @Published private(set) var showDiskRead: Bool
    @Published private(set) var showDiskWrite: Bool
    @Published private(set) var showCPU: Bool
    @Published private(set) var showMemory: Bool
    @Published private(set) var dataRateUnit: DataRateUnit
    @Published private(set) var refreshInterval: Int
    @Published var errorMessage: String?

    var onPresentationChanged: (() -> Void)?
    var onRefreshIntervalChanged: ((Int) -> Void)?

    init(defaults: UserDefaults = .standard) {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        showMenuBar = defaults.object(forKey: Key.showMenuBar) as? Bool ?? true
        showFloatingPanel = defaults.object(forKey: Key.showFloatingPanel) as? Bool ?? true
        floatingPanelAlwaysOnTop =
            defaults.object(forKey: Key.floatingPanelAlwaysOnTop) as? Bool ?? true
        showDownload = defaults.object(forKey: Key.showDownload) as? Bool ?? true
        showUpload = defaults.object(forKey: Key.showUpload) as? Bool ?? true
        showDiskRead = defaults.object(forKey: Key.showDiskRead) as? Bool ?? true
        showDiskWrite = defaults.object(forKey: Key.showDiskWrite) as? Bool ?? true
        showCPU = defaults.object(forKey: Key.showCPU) as? Bool ?? true
        showMemory = defaults.object(forKey: Key.showMemory) as? Bool ?? true
        dataRateUnit = DataRateUnit(
            rawValue: defaults.string(forKey: Key.dataRateUnit) ?? ""
        ) ?? .bits
        let savedRefreshInterval = defaults.integer(forKey: Key.refreshInterval)
        refreshInterval = Self.refreshIntervalOptions.contains(savedRefreshInterval)
            ? savedRefreshInterval
            : 1

        if !showMenuBar && !showFloatingPanel {
            showMenuBar = true
        }
        if !showDownload && !showUpload && !showDiskRead && !showDiskWrite && !showCPU && !showMemory {
            showDownload = true
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enabled
            errorMessage = nil
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            errorMessage = error.localizedDescription
        }
    }

    func setShowMenuBar(_ enabled: Bool) {
        if !enabled && !showFloatingPanel {
            showFloatingPanel = true
        }
        showMenuBar = enabled
        savePresentation()
    }

    func setShowFloatingPanel(_ enabled: Bool) {
        if !enabled && !showMenuBar {
            showMenuBar = true
        }
        showFloatingPanel = enabled
        savePresentation()
    }

    func setFloatingPanelAlwaysOnTop(_ enabled: Bool) {
        floatingPanelAlwaysOnTop = enabled
        UserDefaults.standard.set(enabled, forKey: Key.floatingPanelAlwaysOnTop)
        onPresentationChanged?()
    }

    func setShowDownload(_ enabled: Bool) {
        guard enabled || showUpload || showDiskRead || showDiskWrite || showCPU || showMemory else { return }
        showDownload = enabled
        saveMetricVisibility()
    }

    func setShowUpload(_ enabled: Bool) {
        guard enabled || showDownload || showDiskRead || showDiskWrite || showCPU || showMemory else { return }
        showUpload = enabled
        saveMetricVisibility()
    }

    func setShowDiskRead(_ enabled: Bool) {
        guard enabled || showDownload || showUpload || showDiskWrite || showCPU || showMemory else { return }
        showDiskRead = enabled
        saveMetricVisibility()
    }

    func setShowDiskWrite(_ enabled: Bool) {
        guard enabled || showDownload || showUpload || showDiskRead || showCPU || showMemory else { return }
        showDiskWrite = enabled
        saveMetricVisibility()
    }

    func setShowCPU(_ enabled: Bool) {
        guard enabled || showDownload || showUpload || showDiskRead || showDiskWrite || showMemory else {
            return
        }
        showCPU = enabled
        saveMetricVisibility()
    }

    func setShowMemory(_ enabled: Bool) {
        guard enabled || showDownload || showUpload || showDiskRead || showDiskWrite || showCPU else {
            return
        }
        showMemory = enabled
        saveMetricVisibility()
    }

    func setDataRateUnit(_ unit: DataRateUnit) {
        dataRateUnit = unit
        UserDefaults.standard.set(unit.rawValue, forKey: Key.dataRateUnit)
        onPresentationChanged?()
    }

    func setRefreshInterval(_ interval: Int) {
        guard Self.refreshIntervalOptions.contains(interval) else { return }
        refreshInterval = interval
        UserDefaults.standard.set(interval, forKey: Key.refreshInterval)
        onRefreshIntervalChanged?(interval)
    }

    private func savePresentation() {
        UserDefaults.standard.set(showMenuBar, forKey: Key.showMenuBar)
        UserDefaults.standard.set(showFloatingPanel, forKey: Key.showFloatingPanel)
        onPresentationChanged?()
    }

    private func saveMetricVisibility() {
        UserDefaults.standard.set(showDownload, forKey: Key.showDownload)
        UserDefaults.standard.set(showUpload, forKey: Key.showUpload)
        UserDefaults.standard.set(showDiskRead, forKey: Key.showDiskRead)
        UserDefaults.standard.set(showDiskWrite, forKey: Key.showDiskWrite)
        UserDefaults.standard.set(showCPU, forKey: Key.showCPU)
        UserDefaults.standard.set(showMemory, forKey: Key.showMemory)
        onPresentationChanged?()
    }
}
