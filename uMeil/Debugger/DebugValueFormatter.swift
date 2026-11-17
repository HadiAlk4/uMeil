import Foundation

/// Formats values, registers, processor status, and memory rows for the
/// debugger's inspection panels.
enum DebugValueFormatter {
    // MARK: - Numbers and variables

    /// Formats a GDB value string in hexadecimal (32-bit two's complement for
    /// negative integers) or decimal according to its C type.
    static func format(_ rawValue: String?, type: String? = nil, hexadecimal: Bool) -> String {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespaces), !rawValue.isEmpty else {
            return "<complex>"
        }
        let isPointer = type?.contains("*") == true
        if isPointer {
            return normalizeHex(rawValue)
        }
        if hexadecimal {
            if rawValue.hasPrefix("0x") || rawValue.hasPrefix("0X") {
                return normalizeHex(rawValue)
            }
            if let signed = Int64(rawValue) {
                let bits = UInt32(bitPattern: Int32(truncatingIfNeeded: signed))
                return String(format: "0x%08X", bits)
            }
            if let unsigned = UInt64(rawValue) {
                return String(format: "0x%08X", UInt32(truncatingIfNeeded: unsigned))
            }
            return rawValue
        } else {
            if rawValue.hasPrefix("0x") || rawValue.hasPrefix("0X"),
               let bits = UInt32(rawValue.dropFirst(2), radix: 16) {
                let isUnsigned = type?.contains("unsigned") == true || type?.contains("uint") == true
                return isUnsigned ? String(bits) : String(Int32(bitPattern: bits))
            }
            return rawValue
        }
    }

    private static func normalizeHex(_ text: String) -> String {
        guard text.hasPrefix("0x") || text.hasPrefix("0X") else { return text }
        let digits = text.dropFirst(2).prefix { $0.isHexDigit }
        let suffix = text.dropFirst(2 + digits.count)
        guard let number = UInt64(digits, radix: 16) else { return text }
        return String(format: "0x%08llX", number) + suffix
    }

    /// Formats a 32-bit register or address as `0x0000020A`.
    static func hex32(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        return String(format: "0x%08llX", value)
    }

    /// The storage class and C type shown in `Call Stack + Locals`, such as
    /// `"param int"` or `"auto int *"`.
    static func displayType(for variable: DebugVariable) -> String {
        let prefix = variable.isArgument ? "param" : "auto"
        guard let type = variable.type, !type.isEmpty else { return prefix }
        return "\(prefix) \(type)"
    }

    /// Whether `variable` is a pointer that can be expanded to show `*name`.
    static func isPointer(_ variable: DebugVariable) -> Bool {
        guard let type = variable.type else { return false }
        return type.contains("*")
    }

    /// The target type of a pointer type, removing one level of `*`.
    static func dereferencedType(_ type: String?) -> String {
        guard var trimmed = type?.trimmingCharacters(in: .whitespaces),
              let star = trimmed.lastIndex(of: "*")
        else { return "int" }
        trimmed.remove(at: star)
        let result = trimmed.trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? "void" : result
    }

    // MARK: - Cortex-M status registers

    struct Bitfield: Equatable, Sendable {
        var name: String
        var value: String
    }

    /// Decodes the condition flags and exception number in ARMv7-M `xPSR`.
    static func xpsrBitfields(_ xpsr: UInt64) -> [Bitfield] {
        [
            Bitfield(name: "N", value: String((xpsr >> 31) & 1)),
            Bitfield(name: "Z", value: String((xpsr >> 30) & 1)),
            Bitfield(name: "C", value: String((xpsr >> 29) & 1)),
            Bitfield(name: "V", value: String((xpsr >> 28) & 1)),
            Bitfield(name: "Q", value: String((xpsr >> 27) & 1)),
            Bitfield(name: "T", value: String((xpsr >> 24) & 1)),
            Bitfield(name: "ISR", value: String(xpsr & 0x1FF))
        ]
    }

    /// Decodes the Cortex-M processor mode, privilege, and active stack pointer
    /// from `xPSR` and `CONTROL`.
    static func executionState(xpsr: UInt64?, control: UInt64?) -> [Bitfield] {
        let isr = (xpsr ?? 0) & 0x1FF
        let ctrl = control ?? 0
        let mode = isr == 0 ? "Thread" : "Handler"
        let privilege = (isr != 0 || (ctrl & 1) == 0) ? "Privileged" : "Unprivileged"
        let stack = (isr == 0 && (ctrl & 2) != 0) ? "PSP" : "MSP"
        return [
            Bitfield(name: "Mode", value: mode),
            Bitfield(name: "Privilege", value: privilege),
            Bitfield(name: "Stack", value: stack)
        ]
    }

    // MARK: - Memory hex dump

    struct MemoryRow: Equatable, Sendable {
        var address: UInt64
        var bytes: [UInt8]

        var addressText: String {
            String(format: "0x%08llX", address)
        }

        var hexText: String {
            bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        }

        var asciiText: String {
            String(bytes.map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "." })
        }
    }

    /// Splits a contiguous block of bytes into 16-byte rows for the Memory view.
    static func memoryRows(from bytes: [UInt8], baseAddress: UInt64, bytesPerRow: Int = 16) -> [MemoryRow] {
        guard bytesPerRow > 0, !bytes.isEmpty else { return [] }
        var rows: [MemoryRow] = []
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + bytesPerRow, bytes.count)
            let slice = Array(bytes[offset..<end])
            rows.append(MemoryRow(address: baseAddress + UInt64(offset), bytes: slice))
            offset = end
        }
        return rows
    }

    /// Reads bytes typed into the memory view's hex column, such as
    /// `"9D FF 00"` or `"9dff00"`. `nil` if anything is not a hex byte.
    static func parseHexBytes(_ text: String) -> [UInt8]? {
        let words = text.split(whereSeparator: \.isWhitespace)
        var bytes: [UInt8] = []
        for word in words {
            guard word.count.isMultiple(of: 2) else { return nil }
            var rest = Substring(word)
            while !rest.isEmpty {
                guard let byte = UInt8(rest.prefix(2), radix: 16) else { return nil }
                bytes.append(byte)
                rest = rest.dropFirst(2)
            }
        }
        return bytes
    }

    /// The bytes of `edited` that differ from `original`, as the offset of
    /// the first one and the run up to the last one. `nil` when nothing
    /// changed or the lengths differ.
    static func changedRun(from original: [UInt8], to edited: [UInt8]) -> (offset: Int, bytes: [UInt8])? {
        guard original.count == edited.count,
              let first = original.indices.first(where: { original[$0] != edited[$0] }),
              let last = original.indices.last(where: { original[$0] != edited[$0] })
        else { return nil }
        return (first, Array(edited[first...last]))
    }

    /// Parses a user-entered hex or decimal address string such as `"0x20000258"`.
    static func parseAddress(_ text: String) -> UInt64? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") {
            return UInt64(trimmed.dropFirst(2), radix: 16)
        }
        return UInt64(trimmed)
    }
}
