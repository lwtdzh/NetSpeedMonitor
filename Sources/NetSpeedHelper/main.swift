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
    _ counters: [String: Counters],
    interval: UInt64,
    previousDisk: inout DiskCounters,
    previousDiskSampleTime: inout TimeInterval,
    previousCPU: inout CPUCounters
) {
    var externalDownload: UInt64 = 0
    var externalUpload: UInt64 = 0
    var interfaces: [String: [String: UInt64]] = [:]

    for (name, value) in counters {
        interfaces[name] = [
            "downloadBytesPerSecond": value.download / interval,
            "uploadBytesPerSecond": value.upload / interval
        ]

        if name != "lo0" {
            externalDownload += value.download
            externalUpload += value.upload
        }
    }

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
        "downloadBytesPerSecond": externalDownload / interval,
        "uploadBytesPerSecond": externalUpload / interval,
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

func consume(
    _ line: String,
    sample: inout Int,
    counters: inout [String: Counters],
    interval: UInt64,
    previousDisk: inout DiskCounters,
    previousDiskSampleTime: inout TimeInterval,
    previousCPU: inout CPUCounters
) {
    let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    guard fields.count >= 4 else { return }

    if fields[0].isEmpty && fields[1] == "interface" {
        if sample >= 2 {
            emit(
                counters,
                interval: interval,
                previousDisk: &previousDisk,
                previousDiskSampleTime: &previousDiskSampleTime,
                previousCPU: &previousCPU
            )
        }
        counters.removeAll(keepingCapacity: true)
        sample += 1
        return
    }

    let interface = fields[1]
    guard
        !interface.isEmpty,
        let download = UInt64(fields[2]),
        let upload = UInt64(fields[3])
    else {
        return
    }

    var value = counters[interface, default: Counters()]
    value.download += download
    value.upload += upload
    counters[interface] = value
}

_ = setpgid(0, 0)

let interval = refreshInterval()
let nettop = Process()
let output = Pipe()
nettop.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
nettop.arguments = [
    "-n", "-d", "-L", "0", "-s", String(interval), "-x",
    "-J", "interface,bytes_in,bytes_out"
]
nettop.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C"]) { _, new in new }
nettop.standardOutput = output
nettop.standardError = FileHandle.nullDevice

do {
    try nettop.run()
} catch {
    FileHandle.standardError.write(Data("Unable to start nettop: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}

var buffer = Data()
var sample = 0
var counters: [String: Counters] = [:]
var previousDisk = diskCounters()
var previousDiskSampleTime = ProcessInfo.processInfo.systemUptime
var previousCPU = cpuCounters()
let reader = output.fileHandleForReading

while true {
    let data = reader.readData(ofLength: 16_384)
    if data.isEmpty { break }
    buffer.append(data)

    while let newline = buffer.firstIndex(of: 0x0A) {
        let lineData = buffer[..<newline]
        buffer.removeSubrange(...newline)
        if let line = String(data: lineData, encoding: .utf8) {
            consume(
                line,
                sample: &sample,
                counters: &counters,
                interval: UInt64(interval),
                previousDisk: &previousDisk,
                previousDiskSampleTime: &previousDiskSampleTime,
                previousCPU: &previousCPU
            )
        }
    }
}

nettop.terminate()
nettop.waitUntilExit()
