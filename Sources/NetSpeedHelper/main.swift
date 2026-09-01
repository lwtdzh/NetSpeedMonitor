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
    previousDiskSampleTime: inout TimeInterval
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

    let payload: [String: Any] = [
        "downloadBytesPerSecond": externalDownload / interval,
        "uploadBytesPerSecond": externalUpload / interval,
        "diskReadBytesPerSecond": UInt64(Double(diskRead) / diskSampleInterval),
        "diskWriteBytesPerSecond": UInt64(Double(diskWrite) / diskSampleInterval),
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
    previousDiskSampleTime: inout TimeInterval
) {
    let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    guard fields.count >= 4 else { return }

    if fields[0].isEmpty && fields[1] == "interface" {
        if sample >= 2 {
            emit(
                counters,
                interval: interval,
                previousDisk: &previousDisk,
                previousDiskSampleTime: &previousDiskSampleTime
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
                previousDiskSampleTime: &previousDiskSampleTime
            )
        }
    }
}

nettop.terminate()
nettop.waitUntilExit()
