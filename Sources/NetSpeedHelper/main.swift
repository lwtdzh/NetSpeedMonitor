import Darwin
import Foundation
import IOKit

struct Counters {
    var download: UInt64 = 0
    var upload: UInt64 = 0
}

struct DiskCounters {
    var read: UInt64 = 0
    var write: UInt64 = 0
}

struct CPUCounters {
    var active: UInt64 = 0
    var total: UInt64 = 0
}

func networkCounters() -> [String: Counters]? {
    let process = Process()
    let output = Pipe()
    let readHandle = output.fileHandleForReading
    let writeHandle = output.fileHandleForWriting
    defer {
        try? readHandle.close()
        try? writeHandle.close()
    }
    process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
    process.arguments = [
        "-P", "-t", "external", "-L", "1", "-n", "-x",
        "-J", "bytes_in,bytes_out"
    ]
    process.environment = ProcessInfo.processInfo.environment.merging(
        ["LC_ALL": "C"]
    ) { _, new in new }
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
    } catch {
        return nil
    }

    try? writeHandle.close()
    let data = readHandle.readDataToEndOfFile()
    process.waitUntilExit()
    guard
        process.terminationStatus == EXIT_SUCCESS,
        let text = String(data: data, encoding: .utf8)
    else {
        return nil
    }

    var counters: [String: Counters] = [:]
    for line in text.split(separator: "\n").dropFirst() {
        let fields = line.split(separator: ",", omittingEmptySubsequences: false)
        guard
            fields.count >= 3,
            !fields[0].isEmpty,
            let download = UInt64(fields[1]),
            let upload = UInt64(fields[2])
        else {
            continue
        }
        counters[String(fields[0])] = Counters(download: download, upload: upload)
    }
    return counters.isEmpty ? nil : counters
}

func cpuCounters() -> CPUCounters {
    var cpuCount: natural_t = 0
    var cpuInfo: processor_info_array_t?
    var infoCount: mach_msg_type_number_t = 0
    guard
        host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &cpuInfo,
            &infoCount
        ) == KERN_SUCCESS,
        let cpuInfo
    else {
        return CPUCounters()
    }
    defer {
        vm_deallocate(
            mach_task_self_,
            vm_address_t(UInt(bitPattern: cpuInfo)),
            vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
        )
    }

    var counters = CPUCounters()
    for cpu in 0..<Int(cpuCount) {
        let offset = cpu * Int(CPU_STATE_MAX)
        let user = UInt64(cpuInfo[offset + Int(CPU_STATE_USER)])
        let system = UInt64(cpuInfo[offset + Int(CPU_STATE_SYSTEM)])
        let nice = UInt64(cpuInfo[offset + Int(CPU_STATE_NICE)])
        let idle = UInt64(cpuInfo[offset + Int(CPU_STATE_IDLE)])
        counters.active += user + system + nice
        counters.total += user + system + nice + idle
    }
    return counters
}

func memoryUsagePercent() -> UInt64 {
    var statistics = vm_statistics64()
    var count = mach_msg_type_number_t(
        MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
    )
    let result = withUnsafeMutablePointer(to: &statistics) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return 0 }

    let usedPages = UInt64(statistics.active_count)
        + UInt64(statistics.wire_count)
        + UInt64(statistics.compressor_page_count)
    let usedBytes = usedPages * UInt64(vm_kernel_page_size)
    let totalBytes = ProcessInfo.processInfo.physicalMemory
    guard totalBytes > 0 else { return 0 }
    return min(100, UInt64((Double(usedBytes) / Double(totalBytes) * 100).rounded()))
}

func diskCounters() -> DiskCounters {
    var iterator: io_iterator_t = 0
    guard
        let matching = IOServiceMatching("IOBlockStorageDriver"),
        IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
    else {
        return DiskCounters()
    }
    defer { IOObjectRelease(iterator) }

    var counters = DiskCounters()
    var service = IOIteratorNext(iterator)
    while service != 0 {
        if
            let value = IORegistryEntryCreateCFProperty(
                service,
                "Statistics" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue(),
            let statistics = value as? [String: Any]
        {
            counters.read += (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            counters.write += (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        IOObjectRelease(service)
        service = IOIteratorNext(iterator)
    }
    return counters
}

func refreshInterval() -> Int {
    guard
        let flagIndex = CommandLine.arguments.firstIndex(of: "--interval"),
        CommandLine.arguments.indices.contains(flagIndex + 1),
        let value = Int(CommandLine.arguments[flagIndex + 1])
    else {
        return 1
    }
    return min(max(value, 1), 60)
}

func emit(
    previousNetwork: inout [String: Counters],
    previousNetworkSampleTime: inout TimeInterval,
    previousDisk: inout DiskCounters,
    previousDiskSampleTime: inout TimeInterval,
    previousCPU: inout CPUCounters
) {
    let sampledNetwork = networkCounters()
    let currentNetworkSampleTime = ProcessInfo.processInfo.systemUptime
    let networkSampleInterval = max(currentNetworkSampleTime - previousNetworkSampleTime, 0.001)
    var externalDownload: UInt64 = 0
    var externalUpload: UInt64 = 0
    var interfaces: [String: [String: UInt64]] = [:]

    if let currentNetwork = sampledNetwork {
        for (process, current) in currentNetwork {
            guard let previous = previousNetwork[process] else { continue }
            let download = current.download >= previous.download
                ? current.download - previous.download
                : 0
            let upload = current.upload >= previous.upload
                ? current.upload - previous.upload
                : 0
            externalDownload += download
            externalUpload += upload
        }
        previousNetwork = currentNetwork
        previousNetworkSampleTime = currentNetworkSampleTime
    }
    interfaces["external"] = [
        "downloadBytesPerSecond": UInt64(Double(externalDownload) / networkSampleInterval),
        "uploadBytesPerSecond": UInt64(Double(externalUpload) / networkSampleInterval)
    ]

    let currentDisk = diskCounters()
    let currentDiskSampleTime = ProcessInfo.processInfo.systemUptime
    let diskSampleInterval = max(currentDiskSampleTime - previousDiskSampleTime, 0.001)
    let diskRead = currentDisk.read >= previousDisk.read
        ? currentDisk.read - previousDisk.read
        : 0
    let diskWrite = currentDisk.write >= previousDisk.write
        ? currentDisk.write - previousDisk.write
        : 0
    previousDisk = currentDisk
    previousDiskSampleTime = currentDiskSampleTime

    let currentCPU = cpuCounters()
    let activeDelta = currentCPU.active >= previousCPU.active
        ? currentCPU.active - previousCPU.active
        : 0
    let totalDelta = currentCPU.total >= previousCPU.total
        ? currentCPU.total - previousCPU.total
        : 0
    previousCPU = currentCPU
    let cpuUsage = totalDelta > 0
        ? min(100, UInt64((Double(activeDelta) / Double(totalDelta) * 100).rounded()))
        : 0

    let payload: [String: Any] = [
        "downloadBytesPerSecond": UInt64(Double(externalDownload) / networkSampleInterval),
        "uploadBytesPerSecond": UInt64(Double(externalUpload) / networkSampleInterval),
        "diskReadBytesPerSecond": UInt64(Double(diskRead) / diskSampleInterval),
        "diskWriteBytesPerSecond": UInt64(Double(diskWrite) / diskSampleInterval),
        "cpuUsagePercent": cpuUsage,
        "memoryUsagePercent": memoryUsagePercent(),
        "interfaces": interfaces
    ]

    guard
        let data = try? JSONSerialization.data(withJSONObject: payload),
        var line = String(data: data, encoding: .utf8)
    else {
        return
    }

    line.append("\n")
    FileHandle.standardOutput.write(Data(line.utf8))
}

_ = setpgid(0, 0)

let interval = refreshInterval()
var previousNetwork = networkCounters() ?? [:]
var previousNetworkSampleTime = ProcessInfo.processInfo.systemUptime
var previousDisk = diskCounters()
var previousDiskSampleTime = ProcessInfo.processInfo.systemUptime
var previousCPU = cpuCounters()

while true {
    Thread.sleep(forTimeInterval: TimeInterval(interval))
    emit(
        previousNetwork: &previousNetwork,
        previousNetworkSampleTime: &previousNetworkSampleTime,
        previousDisk: &previousDisk,
        previousDiskSampleTime: &previousDiskSampleTime,
        previousCPU: &previousCPU
    )
}
