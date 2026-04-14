import Cocoa
import IOKit

// MARK: - SMC Types & Constants

/// Convert a 4-character string to a UInt32 FourCharCode used by the SMC.
func fourCharCode(_ value: String) -> UInt32 {
    var result: UInt32 = 0
    for byte in value.utf8.prefix(4) {
        result = (result << 8) | UInt32(byte)
    }
    return result
}

/// Convert a UInt32 FourCharCode back to a 4-character string.
func fourCharCodeToString(_ value: UInt32) -> String {
    let bytes: [UInt8] = [
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8(value & 0xFF)
    ]
    return String(bytes: bytes, encoding: .ascii) ?? "????"
}

/// 32-byte tuple type matching the SMC's fixed-size byte buffer.
typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

/// SMC kernel call selectors.
let kSMCHandleYPCEvent: UInt32 = 2
/// SMC sub-commands sent via the data8 field.
let kSMCReadKey: UInt8 = 5
let kSMCGetKeyInfo: UInt8 = 9

/// SMC key data version sub-structure.
struct SMCKeyDataVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

/// SMC key data power limit sub-structure.
struct SMCKeyDataPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

/// SMC key info sub-structure — describes the data type and size of a key.
struct SMCKeyDataKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

/// Primary structure sent to/from the SMC kernel interface via IOConnectCallStructMethod.
struct SMCKeyData {
    var key: UInt32 = 0
    var vers: SMCKeyDataVersion = SMCKeyDataVersion()
    var pLimitData: SMCKeyDataPLimitData = SMCKeyDataPLimitData()
    var keyInfo: SMCKeyDataKeyInfo = SMCKeyDataKeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
                           0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

// MARK: - Byte Conversion

/// Safely convert an SMCBytes tuple to a [UInt8] array of the given size.
func smcBytesToArray(_ bytes: SMCBytes, size: Int) -> [UInt8] {
    guard size >= 0, size <= 32 else { return [] }
    var bytes = bytes
    return withUnsafeBytes(of: &bytes) { buffer in
        Array(buffer.prefix(size))
    }
}

/// Convert raw SMC bytes to a Double temperature value based on the SMC data type.
/// Returns nil if the data type is unrecognized or the value is out of sensor range.
func convertSMCTemp(bytes: SMCBytes, dataType: UInt32, dataSize: UInt32) -> Double? {
    let typeStr = fourCharCodeToString(dataType)
    let byteArray = smcBytesToArray(bytes, size: Int(dataSize))

    let value: Double
    switch typeStr {
    case "flt ":
        // IEEE 754 float — little-endian on Apple Silicon, big-endian on Intel
        guard byteArray.count >= 4 else { return nil }
        // Try little-endian first (Apple Silicon native byte order)
        let rawLE = UInt32(byteArray[0])
                  | UInt32(byteArray[1]) << 8
                  | UInt32(byteArray[2]) << 16
                  | UInt32(byteArray[3]) << 24
        let floatLE = Float(bitPattern: rawLE)
        if floatLE > -20 && floatLE < 150 {
            value = Double(floatLE)
        } else {
            // Fallback to big-endian (Intel Macs)
            let rawBE = UInt32(byteArray[0]) << 24
                      | UInt32(byteArray[1]) << 16
                      | UInt32(byteArray[2]) << 8
                      | UInt32(byteArray[3])
            value = Double(Float(bitPattern: rawBE))
        }
    case "sp78":
        // Signed 8.8 fixed-point, big-endian
        guard byteArray.count >= 2 else { return nil }
        let raw = Int16(bitPattern: UInt16(byteArray[0]) << 8 | UInt16(byteArray[1]))
        value = Double(raw) / 256.0
    case "fpe2":
        // Unsigned 14.2 fixed-point, big-endian
        guard byteArray.count >= 2 else { return nil }
        let raw = UInt16(byteArray[0]) << 8 | UInt16(byteArray[1])
        value = Double(raw) / 4.0
    case "ui8 ":
        guard byteArray.count >= 1 else { return nil }
        value = Double(byteArray[0])
    case "ui16":
        guard byteArray.count >= 2 else { return nil }
        let raw = UInt16(byteArray[0]) << 8 | UInt16(byteArray[1])
        value = Double(raw)
    case "ui32":
        guard byteArray.count >= 4 else { return nil }
        let raw = UInt32(byteArray[0]) << 24
                | UInt32(byteArray[1]) << 16
                | UInt32(byteArray[2]) << 8
                | UInt32(byteArray[3])
        value = Double(raw)
    default:
        return nil
    }

    // Bounds check: reject values outside plausible sensor range
    guard value > -20.0 && value < 150.0 else { return nil }
    return value
}

// MARK: - SMCClient

/// Communicates with the AppleSMC IOService to read sensor values.
/// Manages the IOKit connection lifecycle — opens on init, closes on deinit.
final class SMCClient {
    private var connection: io_connect_t = 0
    private(set) var isOpen: Bool = false

    /// Open a connection to the AppleSMC IOService.
    /// Returns true on success, false if the SMC service is unavailable.
    func open() -> Bool {
        let matchingDict = IOServiceMatching("AppleSMC")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matchingDict)
        guard service != IO_OBJECT_NULL else {
            return false
        }
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        IOObjectRelease(service)
        isOpen = (result == kIOReturnSuccess)
        return isOpen
    }

    /// Close the SMC connection and release resources.
    func close() {
        guard isOpen else { return }
        IOServiceClose(connection)
        connection = 0
        isOpen = false
    }

    deinit {
        close()
    }

    /// Read a temperature value for the given 4-character SMC key.
    /// Returns the temperature in Celsius, or nil if the key doesn't exist or can't be read.
    func readTemperature(key: String) -> Double? {
        guard isOpen else { return nil }
        guard key.utf8.count == 4 else { return nil }

        let keyCode = fourCharCode(key)

        // Step 1: Get key info (data type and size)
        var inputData = SMCKeyData()
        inputData.key = keyCode
        inputData.data8 = kSMCGetKeyInfo

        var outputData = SMCKeyData()
        let inputSize = MemoryLayout<SMCKeyData>.stride
        var outputSize = MemoryLayout<SMCKeyData>.stride

        var kr = IOConnectCallStructMethod(
            connection,
            kSMCHandleYPCEvent,
            &inputData, inputSize,
            &outputData, &outputSize
        )
        guard kr == kIOReturnSuccess else { return nil }

        let keyInfo = outputData.keyInfo

        // Step 2: Read the key value using the info from step 1
        inputData = SMCKeyData()
        inputData.key = keyCode
        inputData.data8 = kSMCReadKey
        inputData.keyInfo = keyInfo

        outputData = SMCKeyData()
        outputSize = MemoryLayout<SMCKeyData>.stride

        kr = IOConnectCallStructMethod(
            connection,
            kSMCHandleYPCEvent,
            &inputData, inputSize,
            &outputData, &outputSize
        )
        guard kr == kIOReturnSuccess else { return nil }

        // Step 3: Convert raw bytes to temperature
        return convertSMCTemp(
            bytes: outputData.bytes,
            dataType: keyInfo.dataType,
            dataSize: keyInfo.dataSize
        )
    }
}

// MARK: - TemperatureReader

/// Wraps SMCClient to read CPU and battery temperatures.
/// Probes for available sensor keys at startup since keys vary by Mac model.
final class TemperatureReader {
    private let smc: SMCClient

    /// The SMC key that was found to work for CPU temperature, or nil if none found.
    private(set) var cpuKey: String?
    /// The SMC key that was found to work for battery temperature, or nil if none found.
    private(set) var batteryKey: String?

    /// CPU temperature keys to probe, in priority order.
    /// Different Mac models expose different keys.
    private static let cpuKeyProbeList: [String] = [
        // Apple Silicon (M1/M2/M3/M4) — performance cores
        "Tp01", "Tp05", "Tp09", "Tp0D",
        // Apple Silicon — efficiency cores
        "Tp0T", "Tp0X", "Tp0b", "Tp0f", "Tp0j", "Tp0n",
        "Tp0h", "Tp0L", "Tp0P", "Tp0S",
        // M2/M3 additional
        "Tp1h", "Tp1t", "Tp1p", "Tp1l",
        // Intel — CPU proximity / die
        "TC0P", "TC0D", "TC0E", "TC0F",
    ]

    /// Battery temperature keys to probe, in priority order.
    private static let batteryKeyProbeList: [String] = [
        "TB1T",  // Battery sensor 1 (Apple Silicon primary)
        "TB2T",  // Battery sensor 2
        "TB0T",  // Battery sensor 0 (Intel primary)
    ]

    init(smc: SMCClient) {
        self.smc = smc
        probeKeys()
    }

    /// Try each candidate key and keep the first one that returns a valid reading.
    private func probeKeys() {
        for key in Self.cpuKeyProbeList {
            if smc.readTemperature(key: key) != nil {
                cpuKey = key
                break
            }
        }
        for key in Self.batteryKeyProbeList {
            if smc.readTemperature(key: key) != nil {
                batteryKey = key
                break
            }
        }
    }

    /// Read the current CPU temperature in Celsius, or nil if unavailable.
    func readCPUTemp() -> Double? {
        guard let key = cpuKey else { return nil }
        return smc.readTemperature(key: key)
    }

    /// Read the current battery temperature in Celsius, or nil if unavailable.
    func readBatteryTemp() -> Double? {
        guard let key = batteryKey else { return nil }
        return smc.readTemperature(key: key)
    }
}

// MARK: - IOReport Frequency Reading

/// Function type aliases for dynamically-loaded IOReport functions.
private typealias IORCopyChannelsInGroupFn = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFDictionary>?
private typealias IORCreateSubscriptionFn = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> Unmanaged<CFTypeRef>?
private typealias IORCreateSamplesFn = @convention(c) (CFTypeRef, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
private typealias IORCreateSamplesDeltaFn = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
private typealias IORChannelGetNameFn = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
private typealias IORStateGetCountFn = @convention(c) (CFDictionary) -> Int32
private typealias IORStateGetResidencyFn = @convention(c) (CFDictionary, Int32) -> Int64
private typealias IORStateGetNameForIndexFn = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?

/// Reads real-time per-cluster CPU frequency via IOReport DVFS residency sampling.
/// Dynamically loads the private IOReport framework. No root/sudo required.
final class FrequencyReader {
    struct ClusterFrequency {
        var pClusterMHz: Double?
        var eClusterMHz: Double?

        var pClusterGHz: String { pClusterMHz.map { String(format: "%.1f", $0 / 1000.0) } ?? "--" }
        var eClusterGHz: String { eClusterMHz.map { String(format: "%.1f", $0 / 1000.0) } ?? "--" }
    }

    // IOReport dylib handle and function pointers
    private let handle: UnsafeMutableRawPointer
    private let copyChannelsInGroup: IORCopyChannelsInGroupFn
    private let createSubscription: IORCreateSubscriptionFn
    private let createSamples: IORCreateSamplesFn
    private let createSamplesDelta: IORCreateSamplesDeltaFn
    private let channelGetName: IORChannelGetNameFn
    private let stateGetCount: IORStateGetCountFn
    private let stateGetResidency: IORStateGetResidencyFn
    private let stateGetNameForIndex: IORStateGetNameForIndexFn

    // IOReport subscription state
    private let subscription: CFTypeRef
    private let subscribedChannels: CFMutableDictionary
    private var previousSample: CFDictionary?

    // DVFS frequency tables (Hz values from IORegistry)
    private let pClusterFreqs: [UInt32]  // P-cluster DVFS levels
    private let eClusterFreqs: [UInt32]  // E-cluster DVFS levels

    init?() {
        // Load IOReport dylib
        guard let h = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else {
            NSLog("FrequencyReader: Failed to load IOReport")
            return nil
        }
        handle = h

        func loadSym<T>(_ name: String) -> T? {
            guard let sym = dlsym(h, name) else { return nil }
            return unsafeBitCast(sym, to: T.self)
        }

        guard let fn1: IORCopyChannelsInGroupFn = loadSym("IOReportCopyChannelsInGroup"),
              let fn2: IORCreateSubscriptionFn = loadSym("IOReportCreateSubscription"),
              let fn3: IORCreateSamplesFn = loadSym("IOReportCreateSamples"),
              let fn4: IORCreateSamplesDeltaFn = loadSym("IOReportCreateSamplesDelta"),
              let fn5: IORChannelGetNameFn = loadSym("IOReportChannelGetChannelName"),
              let fn6: IORStateGetCountFn = loadSym("IOReportStateGetCount"),
              let fn7: IORStateGetResidencyFn = loadSym("IOReportStateGetResidency"),
              let fn8: IORStateGetNameForIndexFn = loadSym("IOReportStateGetNameForIndex")
        else {
            NSLog("FrequencyReader: Failed to load IOReport symbols")
            dlclose(h)
            return nil
        }

        copyChannelsInGroup = fn1; createSubscription = fn2
        createSamples = fn3; createSamplesDelta = fn4
        channelGetName = fn5; stateGetCount = fn6
        stateGetResidency = fn7; stateGetNameForIndex = fn8

        // Read DVFS frequency tables from IORegistry
        pClusterFreqs = FrequencyReader.readDVFSTable("voltage-states5-sram")
        eClusterFreqs = FrequencyReader.readDVFSTable("voltage-states1-sram")

        // Subscribe to CPU Core Performance States
        guard let channels = fn1("CPU Stats" as CFString, "CPU Core Performance States" as CFString, 0, 0, 0)?.takeRetainedValue() else {
            NSLog("FrequencyReader: Failed to get CPU channels")
            dlclose(h)
            return nil
        }

        let channelsMut = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, channels)!
        var subChPtr: Unmanaged<CFMutableDictionary>?
        guard let sub = fn2(nil, channelsMut, &subChPtr, 0, nil)?.takeRetainedValue() else {
            NSLog("FrequencyReader: Failed to create subscription")
            dlclose(h)
            return nil
        }
        guard let subCh = subChPtr?.takeRetainedValue() else {
            NSLog("FrequencyReader: No subscribed channels")
            dlclose(h)
            return nil
        }

        subscription = sub
        subscribedChannels = subCh
        previousSample = nil

        NSLog("FrequencyReader: Ready — P-levels: %d, E-levels: %d",
              pClusterFreqs.count, eClusterFreqs.count)
    }

    deinit {
        previousSample = nil
        dlclose(handle)
    }

    /// Take a sample and compute cluster frequencies from the delta against the previous sample.
    /// Returns nil for a cluster if no cores were active or on first call (no previous sample yet).
    func sample() -> ClusterFrequency {
        guard let currentSample = createSamples(subscription, subscribedChannels, nil)?.takeRetainedValue() else {
            return ClusterFrequency()
        }

        defer { previousSample = currentSample }

        guard let prev = previousSample else {
            // First call — no delta yet, just store the sample
            return ClusterFrequency()
        }

        guard let delta = createSamplesDelta(prev, currentSample, nil)?.takeRetainedValue() else {
            return ClusterFrequency()
        }

        return parseFrequencies(from: delta)
    }

    // MARK: - Private

    private func parseFrequencies(from delta: CFDictionary) -> ClusterFrequency {
        let key = Unmanaged.passUnretained("IOReportChannels" as CFString).toOpaque()
        guard let arrPtr = CFDictionaryGetValue(delta, key) else { return ClusterFrequency() }
        let arr = Unmanaged<CFArray>.fromOpaque(arrPtr).takeUnretainedValue()

        var pFreqSum = 0.0, pCores = 0
        var eFreqSum = 0.0, eCores = 0

        for i in 0..<CFArrayGetCount(arr) {
            guard let itemPtr = CFArrayGetValueAtIndex(arr, i) else { continue }
            let item = Unmanaged<CFDictionary>.fromOpaque(itemPtr).takeUnretainedValue()

            guard let name = channelGetName(item)?.takeUnretainedValue() as String? else { continue }
            let isPCPU = name.contains("PCPU")
            let isECPU = name.contains("ECPU")
            guard isPCPU || isECPU else { continue }

            let freqTable = isPCPU ? pClusterFreqs : eClusterFreqs
            let sc = Int(stateGetCount(item))

            var coreWeighted = 0.0, coreNs: Int64 = 0
            for s in 0..<sc {
                let sn = (stateGetNameForIndex(item, Int32(s))?.takeUnretainedValue() as String?) ?? ""
                if sn == "IDLE" || sn == "DOWN" || sn == "OFF" { continue }
                let ns = stateGetResidency(item, Int32(s))
                guard ns > 0 else { continue }
                if let idx = FrequencyReader.parseDVFSIndex(from: sn), idx < freqTable.count {
                    let mhz = Double(freqTable[idx]) / 1_000_000.0
                    coreWeighted += Double(ns) * mhz
                    coreNs += ns
                }
            }

            if coreNs > 0 {
                let avgMHz = coreWeighted / Double(coreNs)
                if isPCPU { pFreqSum += avgMHz; pCores += 1 }
                else { eFreqSum += avgMHz; eCores += 1 }
            }
        }

        return ClusterFrequency(
            pClusterMHz: pCores > 0 ? pFreqSum / Double(pCores) : nil,
            eClusterMHz: eCores > 0 ? eFreqSum / Double(eCores) : nil
        )
    }

    /// Parse the DVFS table index from a state name like "V0P19" → 19.
    private static func parseDVFSIndex(from name: String) -> Int? {
        // Find the last sequence of digits in the name
        var end = name.endIndex
        while end > name.startIndex && !name[name.index(before: end)].isNumber { end = name.index(before: end) }
        guard end > name.startIndex else { return nil }
        var start = end
        while start > name.startIndex && name[name.index(before: start)].isNumber { start = name.index(before: start) }
        return Int(name[start..<end])
    }

    /// Read DVFS frequency table from IORegistry for a given property name.
    /// Searches all AppleARMIODevice services for the property.
    private static func readDVFSTable(_ property: String) -> [UInt32] {
        let matching = IOServiceMatching("AppleARMIODevice")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess else { return [] }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            guard let ref = IORegistryEntryCreateCFProperty(service, property as CFString, kCFAllocatorDefault, 0) else { continue }
            guard let data = ref.takeRetainedValue() as? Data, data.count >= 8 else { continue }

            var freqs: [UInt32] = []
            for i in stride(from: 0, to: data.count, by: 8) {
                guard i + 4 <= data.count else { break }
                let freq = data.subdata(in: i..<i+4).withUnsafeBytes { $0.load(as: UInt32.self) }
                if freq > 0 { freqs.append(freq) }
            }
            return freqs
        }
        return []
    }
}

// MARK: - MenuBarController

/// Manages the NSStatusItem in the menu bar and its dropdown menu.
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let menu: NSMenu

    // Menu item references for updating text
    private let cpuMenuItem: NSMenuItem
    private let pFreqMenuItem: NSMenuItem
    private let eFreqMenuItem: NSMenuItem
    private let batteryMenuItem: NSMenuItem
    private let statusMenuItem: NSMenuItem

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu = NSMenu()

        cpuMenuItem = NSMenuItem(title: "CPU Temperature:  --", action: nil, keyEquivalent: "")
        cpuMenuItem.isEnabled = false
        menu.addItem(cpuMenuItem)

        pFreqMenuItem = NSMenuItem(title: "P-Cluster Frequency:  --", action: nil, keyEquivalent: "")
        pFreqMenuItem.isEnabled = false
        menu.addItem(pFreqMenuItem)

        eFreqMenuItem = NSMenuItem(title: "E-Cluster Frequency:  --", action: nil, keyEquivalent: "")
        eFreqMenuItem.isEnabled = false
        menu.addItem(eFreqMenuItem)

        batteryMenuItem = NSMenuItem(title: "Battery Temperature:  --", action: nil, keyEquivalent: "")
        batteryMenuItem.isEnabled = false
        menu.addItem(batteryMenuItem)

        menu.addItem(NSMenuItem.separator())

        statusMenuItem = NSMenuItem(title: "Status: Starting...", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit TempMonitor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    /// Update the menubar title and dropdown with current readings.
    func update(cpuTemp: Double?, batteryTemp: Double?, freq: FrequencyReader.ClusterFrequency?) {
        let cpuStr = cpuTemp.map { formatTemp($0) } ?? "N/A"
        let batStr = batteryTemp.map { formatTemp($0) } ?? "N/A"
        let pGHz = freq?.pClusterGHz ?? "--"
        let eGHz = freq?.eClusterGHz ?? "--"

        let title = "CPU: \(cpuStr) P:\(pGHz) E:\(eGHz) | Bat: \(batStr)"

        let color = worstColor(cpuTemp: cpuTemp, batteryTemp: batteryTemp)
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        ]
        statusItem.button?.attributedTitle = NSAttributedString(string: title, attributes: attrs)

        // Update dropdown menu items
        cpuMenuItem.title = "CPU Temperature:  \(cpuStr)"
        pFreqMenuItem.title = "P-Cluster Frequency:  \(pGHz) GHz"
        eFreqMenuItem.title = "E-Cluster Frequency:  \(eGHz) GHz"
        batteryMenuItem.title = "Battery Temperature:  \(batStr)"

        let status = overallStatus(cpuTemp: cpuTemp, batteryTemp: batteryTemp)
        statusMenuItem.title = "Status: \(status)"
    }

    /// Show an error state in the menubar.
    func showError(_ message: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.systemRed,
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        ]
        statusItem.button?.attributedTitle = NSAttributedString(string: message, attributes: attrs)
        statusMenuItem.title = "Status: Error"
    }

    // MARK: - Private helpers

    private func formatTemp(_ temp: Double) -> String {
        return String(format: "%.0f°C", temp)
    }

    private func cpuColor(_ temp: Double?) -> NSColor {
        guard let t = temp else { return .labelColor }
        if t < 60 { return .systemGreen }
        if t < 80 { return .systemOrange }
        return .systemRed
    }

    private func batteryColor(_ temp: Double?) -> NSColor {
        guard let t = temp else { return .labelColor }
        if t < 35 { return .systemGreen }
        if t < 40 { return .systemOrange }
        return .systemRed
    }

    /// Return the most severe color between CPU and battery.
    private func worstColor(cpuTemp: Double?, batteryTemp: Double?) -> NSColor {
        let colors = [cpuColor(cpuTemp), batteryColor(batteryTemp)]
        if colors.contains(.systemRed) { return .systemRed }
        if colors.contains(.systemOrange) { return .systemOrange }
        if colors.contains(.systemGreen) { return .systemGreen }
        return .labelColor
    }

    private func overallStatus(cpuTemp: Double?, batteryTemp: Double?) -> String {
        let color = worstColor(cpuTemp: cpuTemp, batteryTemp: batteryTemp)
        if color == .systemRed { return "Hot" }
        if color == .systemOrange { return "Warm" }
        if color == .systemGreen { return "Normal" }
        return "Unknown"
    }
}

// MARK: - AppDelegate

/// Application delegate. Owns the SMC reader and menu bar controller.
/// Sets up a 3-second repeating timer to refresh temperature readings.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var reader: TemperatureReader?
    private var freqReader: FrequencyReader?
    private var menuBar: MenuBarController?
    private var refreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let smc = SMCClient()
        guard smc.open() else {
            let mb = MenuBarController()
            mb.showError("⚠ SMC Error")
            menuBar = mb
            NSLog("TempMonitor: Failed to open SMC connection")
            return
        }

        let tempReader = TemperatureReader(smc: smc)
        reader = tempReader

        // FrequencyReader is optional — app works without it (shows "--" for freq)
        freqReader = FrequencyReader()
        if freqReader == nil {
            NSLog("TempMonitor: FrequencyReader unavailable — frequencies will show as --")
        }

        let mb = MenuBarController()
        menuBar = mb

        // Initial reading
        refreshReadings()

        // Schedule repeating timer — weak self to prevent retain cycle
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refreshReadings()
        }
        // Ensure timer fires during UI tracking (e.g., when menu is open)
        if let timer = refreshTimer {
            RunLoop.current.add(timer, forMode: .common)
        }

        NSLog("TempMonitor: Started — CPU key: %@, Battery key: %@, Freq: %@",
              tempReader.cpuKey ?? "none",
              tempReader.batteryKey ?? "none",
              freqReader != nil ? "yes" : "no")
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func refreshReadings() {
        guard let reader = reader, let menuBar = menuBar else { return }
        let cpuTemp = reader.readCPUTemp()
        let batteryTemp = reader.readBatteryTemp()
        let freq = freqReader?.sample()
        menuBar.update(cpuTemp: cpuTemp, batteryTemp: batteryTemp, freq: freq)
    }
}

// MARK: - Main Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
