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
    let interfaces: [String: InterfaceTraffic]
}

struct FormattedRate {
    let value: String
    let unit: String

    var compact: String {
        "\(value)\(unit)"
    }
}

struct MenuBarColumns {
    let disk: [String]
    let network: [String]
}

final class TrafficMonitor: ObservableObject {
    @Published private(set) var downloadBytesPerSecond: UInt64 = 0
    @Published private(set) var uploadBytesPerSecond: UInt64 = 0
    @Published private(set) var diskReadBytesPerSecond: UInt64 = 0
    @Published private(set) var diskWriteBytesPerSecond: UInt64 = 0
    @Published private(set) var interfaces: [String: InterfaceTraffic] = [:]
    @Published private(set) var errorMessage: String?

    private let decoder = JSONDecoder()
    private let parsingQueue = DispatchQueue(label: "com.lwtdzh.NetSpeedMonitor.parser")
    private var process: Process?
    private var buffer = Data()
    private var shouldRun = false
    private var refreshInterval = 1

    func menuBarColumns(unit: DataRateUnit, settings: AppSettings) -> MenuBarColumns {
        var diskLines: [String] = []
        var networkLines: [String] = []

        if settings.showDiskWrite {
            diskLines.append("W \(Self.formattedRate(diskWriteBytesPerSecond, unit: unit).compact)")
        }
        if settings.showDiskRead {
            diskLines.append("R \(Self.formattedRate(diskReadBytesPerSecond, unit: unit).compact)")
        }
        if settings.showDownload {
            networkLines.append("↓\(Self.formattedRate(downloadBytesPerSecond, unit: unit).compact)")
        }
        if settings.showUpload {
            networkLines.append("↑\(Self.formattedRate(uploadBytesPerSecond, unit: unit).compact)")
        }
        return MenuBarColumns(disk: diskLines, network: networkLines)
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
                self?.interfaces = sample.interfaces
                self?.errorMessage = nil
            }
        }
    }

    static func formattedRate(
        _ bytesPerSecond: UInt64,
        unit: DataRateUnit
    ) -> FormattedRate {
        let rate = Double(bytesPerSecond) * (unit == .bits ? 8 : 1)
        let suffix = unit == .bits ? "b" : "B"

        if rate >= 1_000_000_000 {
            return FormattedRate(
                value: String(format: "%.1f", rate / 1_000_000_000),
                unit: "G\(suffix)"
            )
        }
        if rate >= 1_000_000 {
            return FormattedRate(
                value: String(format: "%.1f", rate / 1_000_000),
                unit: "M\(suffix)"
            )
        }
        if rate >= 1_000 {
            return FormattedRate(
                value: String(format: "%.1f", rate / 1_000),
                unit: "K\(suffix)"
            )
        }
        return FormattedRate(value: String(format: "%.0f", rate), unit: suffix)
    }
}
