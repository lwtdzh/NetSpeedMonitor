import Combine
import Darwin
import Foundation

struct InterfaceTraffic: Decodable {
    let downloadBytesPerSecond: UInt64
    let uploadBytesPerSecond: UInt64
}

struct TrafficSample: Decodable {
    let downloadBytesPerSecond: UInt64
    let uploadBytesPerSecond: UInt64
    let diskReadBytesPerSecond: UInt64
    let diskWriteBytesPerSecond: UInt64
    let cpuUsagePercent: UInt64
    let memoryUsagePercent: UInt64
    let interfaces: [String: InterfaceTraffic]
}

struct FormattedRate {
    let value: String
    let unit: String

    var compact: String {
        "\(value)\(unit)"
    }
}

struct MenuBarMetric {
    let symbol: String
    let value: String
    let unit: String

    var accessibilityText: String {
        "\(symbol) \(value)\(unit)"
    }
}

struct MenuBarColumns {
    let disk: [MenuBarMetric]
    let network: [MenuBarMetric]
    let system: [MenuBarMetric]
}

final class TrafficMonitor: ObservableObject {
    @Published private(set) var downloadBytesPerSecond: UInt64 = 0
    @Published private(set) var uploadBytesPerSecond: UInt64 = 0
    @Published private(set) var diskReadBytesPerSecond: UInt64 = 0
    @Published private(set) var diskWriteBytesPerSecond: UInt64 = 0
    @Published private(set) var cpuUsagePercent: UInt64 = 0
    @Published private(set) var memoryUsagePercent: UInt64 = 0
    @Published private(set) var interfaces: [String: InterfaceTraffic] = [:]
    @Published private(set) var errorMessage: String?

    private let decoder = JSONDecoder()
    private let parsingQueue = DispatchQueue(label: "com.lwtdzh.NetSpeedMonitor.parser")
    private var process: Process?
    private var buffer = Data()
    private var shouldRun = false
    private var refreshInterval = 1

    func menuBarColumns(unit: DataRateUnit, settings: AppSettings) -> MenuBarColumns {
        var diskLines: [MenuBarMetric] = []
        var networkLines: [MenuBarMetric] = []
        var systemLines: [MenuBarMetric] = []

        if settings.showDiskWrite {
            let rate = Self.formattedRate(diskWriteBytesPerSecond, unit: unit)
            diskLines.append(MenuBarMetric(symbol: "W", value: rate.value, unit: rate.unit))
        }
        if settings.showDiskRead {
            let rate = Self.formattedRate(diskReadBytesPerSecond, unit: unit)
            diskLines.append(MenuBarMetric(symbol: "R", value: rate.value, unit: rate.unit))
        }
        if settings.showDownload {
            let rate = Self.formattedRate(downloadBytesPerSecond, unit: unit)
            networkLines.append(MenuBarMetric(symbol: "↓", value: rate.value, unit: rate.unit))
        }
        if settings.showUpload {
            let rate = Self.formattedRate(uploadBytesPerSecond, unit: unit)
            networkLines.append(MenuBarMetric(symbol: "↑", value: rate.value, unit: rate.unit))
        }
        if settings.showCPU {
            systemLines.append(
                MenuBarMetric(symbol: "C", value: Self.formattedPercent(cpuUsagePercent), unit: "%")
            )
        }
        if settings.showMemory {
            systemLines.append(
                MenuBarMetric(symbol: "M", value: Self.formattedPercent(memoryUsagePercent), unit: "%")
            )
        }
        return MenuBarColumns(disk: diskLines, network: networkLines, system: systemLines)
    }

    func start(refreshInterval: Int = 1) {
        self.refreshInterval = max(1, refreshInterval)
        guard !shouldRun else { return }
        shouldRun = true
        launchHelper()
    }

    func setRefreshInterval(_ interval: Int) {
        let interval = max(1, interval)
        guard interval != refreshInterval else { return }
        refreshInterval = interval
        guard shouldRun else { return }

        stopHelper()
        launchHelper()
    }

    func stop() {
        shouldRun = false
        stopHelper()
    }

    private func launchHelper() {
        guard shouldRun, process == nil else { return }
        guard let helperURL = Bundle.main.url(forResource: "net-speed-all", withExtension: nil) else {
            errorMessage = "The bundled traffic helper is missing."
            return
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = helperURL
        process.arguments = ["--interval", String(refreshInterval)]
        process.standardOutput = output
        process.standardError = Pipe()

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.parsingQueue.async {
                self?.consume(data)
            }
        }

        process.terminationHandler = { [weak self, weak output] terminatedProcess in
            output?.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard let self else { return }
                guard self.process === terminatedProcess else { return }
                self.process = nil
                if self.shouldRun {
                    self.launchHelper()
                }
            }
        }

        do {
            try process.run()
            self.process = process
            errorMessage = nil
        } catch {
            errorMessage = "Unable to start traffic helper: \(error.localizedDescription)"
            self.process = nil
        }
    }

    private func stopHelper() {
        guard let process else { return }
        (process.standardOutput as? Pipe)?
            .fileHandleForReading
            .readabilityHandler = nil
        process.terminationHandler = nil
        if process.isRunning {
            kill(-process.processIdentifier, SIGTERM)
        }
        self.process = nil
        parsingQueue.sync {
            buffer.removeAll(keepingCapacity: true)
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)

        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)

            guard let sample = try? decoder.decode(TrafficSample.self, from: line) else {
                continue
            }

            DispatchQueue.main.async { [weak self] in
                self?.downloadBytesPerSecond = sample.downloadBytesPerSecond
                self?.uploadBytesPerSecond = sample.uploadBytesPerSecond
                self?.diskReadBytesPerSecond = sample.diskReadBytesPerSecond
                self?.diskWriteBytesPerSecond = sample.diskWriteBytesPerSecond
                self?.cpuUsagePercent = sample.cpuUsagePercent
                self?.memoryUsagePercent = sample.memoryUsagePercent
                self?.interfaces = sample.interfaces
                self?.errorMessage = nil
            }
        }
    }

    static func formattedRate(
        _ bytesPerSecond: UInt64,
        unit: DataRateUnit
    ) -> FormattedRate {
        let suffix = unit == .bits ? "b" : "B"
        let prefixes = ["", "K", "M", "G", "T", "P", "E"]
        var value = Double(bytesPerSecond) * (unit == .bits ? 8 : 1)
        var prefixIndex = 0

        while value >= 1_000, prefixIndex < prefixes.count - 1 {
            value /= 1_000
            prefixIndex += 1
        }

        var decimalPlaces = Self.decimalPlacesForFourDigits(value)
        let rounded = value.rounded(toDecimalPlaces: decimalPlaces)
        if rounded >= 1_000, prefixIndex < prefixes.count - 1 {
            value = rounded / 1_000
            prefixIndex += 1
            decimalPlaces = Self.decimalPlacesForFourDigits(value)
        }

        return FormattedRate(
            value: String(format: "%.\(decimalPlaces)f", value),
            unit: "\(prefixes[prefixIndex])\(suffix)"
        )
    }

    private static func decimalPlacesForFourDigits(_ value: Double) -> Int {
        if value >= 100 {
            return 1
        }
        if value >= 10 {
            return 2
        }
        return 3
    }

    static func formattedPercent(_ value: UInt64) -> String {
        value >= 100 ? "F" : "\(value)"
    }
}

private extension Double {
    func rounded(toDecimalPlaces places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (self * scale).rounded() / scale
    }
}
