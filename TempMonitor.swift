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
    precondition(size >= 0 && size <= 32, "SMC data size must be 0-32")
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
        // IEEE 754 float, big-endian (common on Apple Silicon)
        guard byteArray.count >= 4 else { return nil }
        let raw = UInt32(byteArray[0]) << 24
                | UInt32(byteArray[1]) << 16
                | UInt32(byteArray[2]) << 8
                | UInt32(byteArray[3])
        value = Double(Float(bitPattern: raw))
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
