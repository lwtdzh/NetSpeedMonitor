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
        static let dataRateUnit = "dataRateUnit"
        static let refreshInterval = "refreshInterval"
    }

    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var showMenuBar: Bool
    @Published private(set) var showFloatingPanel: Bool
    @Published private(set) var dataRateUnit: DataRateUnit
    @Published private(set) var refreshInterval: Int
    @Published var errorMessage: String?

    var onPresentationChanged: (() -> Void)?
    var onRefreshIntervalChanged: ((Int) -> Void)?

    init(defaults: UserDefaults = .standard) {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        showMenuBar = defaults.object(forKey: Key.showMenuBar) as? Bool ?? true
        showFloatingPanel = defaults.object(forKey: Key.showFloatingPanel) as? Bool ?? true
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
}
