import Foundation

/// A chip's memory-mapped peripherals, read from a CMSIS-SVD file: each
/// peripheral's registers, their addresses, and the bit fields inside them.
struct SVDDevice: Equatable, Sendable {
    var name: String
    var peripherals: [SVDPeripheral]

    /// The peripheral called `name`, ignoring case.
    func peripheral(named name: String) -> SVDPeripheral? {
        peripherals.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The SVD file uMeil ships for the TM4C1294NCPDT, generated from
    /// TivaWare's register header by `Vendor/TivaWare/generate-svd.py`.
    static func bundledFile(in directory: URL = TivaWare.bundledDirectory) -> URL {
        directory.appending(path: "TM4C1294NCPDT.svd")
    }
}

/// Who may read and write a register or field.
enum SVDAccess: String, Equatable, Sendable {
    case readOnly = "read-only"
    case writeOnly = "write-only"
    case readWrite = "read-write"
    case writeOnce = "writeOnce"
    case readWriteOnce = "read-writeOnce"

    var isReadable: Bool { self != .writeOnly && self != .writeOnce }
    var isWritable: Bool { self != .readOnly }
}

struct SVDPeripheral: Equatable, Sendable {
    var name: String
    var description: String?
    /// Peripherals of the same kind share a group, such as `GPIO` or `UART`.
    var groupName: String?
    var baseAddress: UInt64
    /// In address order.
    var registers: [SVDRegister]

    func register(named name: String) -> SVDRegister? {
        registers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func address(of register: SVDRegister) -> UInt64 {
        baseAddress + register.addressOffset
    }
}

struct SVDRegister: Equatable, Sendable {
    var name: String
    var description: String?
    var addressOffset: UInt64
    /// In bits: 8, 16 or 32.
    var size: Int
    var access: SVDAccess
    var resetValue: UInt64?
    /// True when reading the register changes the chip, as reading a FIFO's
    /// data register takes an entry out of it. SVD's `readAction`.
    var readHasSideEffects: Bool
    /// From the lowest bit up.
    var fields: [SVDField]

    var byteCount: Int { max(1, size / 8) }
}

struct SVDField: Equatable, Sendable {
    var name: String
    var description: String?
    /// The lowest bit.
    var bitOffset: Int
    var bitWidth: Int
    var access: SVDAccess
    var enumeratedValues: [SVDEnumeratedValue]

    var mask: UInt64 {
        let ones: UInt64 = bitWidth >= 64 ? .max : (1 << UInt64(bitWidth)) - 1
        return ones << UInt64(bitOffset)
    }

    /// This field's value inside `registerValue`.
    func value(in registerValue: UInt64) -> UInt64 {
        (registerValue & mask) >> UInt64(bitOffset)
    }

    /// `registerValue` with this field set to `value`, other bits unchanged.
    /// Bits of `value` that do not fit in the field are dropped.
    func inserting(_ value: UInt64, into registerValue: UInt64) -> UInt64 {
        (registerValue & ~mask) | ((value << UInt64(bitOffset)) & mask)
    }

    /// The name the SVD gives `value`, such as `MOSC` for 3 in `OSCSRC`.
    func enumeratedName(for value: UInt64) -> String? {
        enumeratedValues.first { $0.value == value }?.name
    }

    /// `[3:0]` for a four-bit field at bit 0, `[5]` for a single bit.
    var bitRangeText: String {
        bitWidth == 1 ? "[\(bitOffset)]" : "[\(bitOffset + bitWidth - 1):\(bitOffset)]"
    }
}

struct SVDEnumeratedValue: Equatable, Sendable {
    var name: String
    var description: String?
    var value: UInt64
}
