import Foundation

/// Formats values, registers, processor status, and memory rows for the
/// debugger's inspection panels.
enum DebugValueFormatter {
    // MARK: - Numbers and variables

    /// Formats a GDB value string in hexadecimal (two's complement for negative
    /// integers, 64-bit for 64-bit types/values and 32-bit otherwise) or decimal
    /// according to its C type.
    static func format(_ rawValue: String?, type: String? = nil, hexadecimal: Bool) -> String {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespaces), !rawValue.isEmpty else {
            return "<complex>"
        }
        if type?.contains("*") == true {
            return normalizeHex(rawValue, is64Bit: false)
        }
        let is64 = is64BitIntegerType(type)
        return hexadecimal
            ? formatHexadecimal(rawValue, is64Bit: is64)
            : formatDecimal(rawValue, type: type, is64Bit: is64)
    }

    private static func formatHexadecimal(_ rawValue: String, is64Bit: Bool) -> String {
        if rawValue.hasPrefix("0x") || rawValue.hasPrefix("0X") {
            return normalizeHex(rawValue, is64Bit: is64Bit)
        }
        if let signed = Int64(rawValue) {
            if is64Bit || signed < Int64(Int32.min) || signed > Int64(UInt32.max) {
                return String(format: "0x%016llX", UInt64(bitPattern: signed))
            }
            let bits = signed < 0 ? UInt32(bitPattern: Int32(signed)) : UInt32(signed)
            return String(format: "0x%08X", bits)
        }
        if let unsigned = UInt64(rawValue) {
            return String(format: "0x%016llX", unsigned)
        }
        return rawValue
    }

    private static func formatDecimal(_ rawValue: String, type: String?, is64Bit: Bool) -> String {
        guard rawValue.hasPrefix("0x") || rawValue.hasPrefix("0X") else { return rawValue }
        let hexDigits = rawValue.dropFirst(2)
        guard let bits = UInt64(hexDigits, radix: 16) else { return rawValue }
        if isUnsignedIntegerType(type) {
            return String(bits)
        }
        if is64Bit || bits > UInt64(UInt32.max) || hexDigits.count > 8 {
            return String(Int64(bitPattern: bits))
        }
        return String(Int32(bitPattern: UInt32(bits)))
    }

    private static func typeTokens(_ type: String?) -> [Substring] {
        guard let type else { return [] }
        return type.lowercased().split { !($0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_")) }
    }

    private static func is64BitIntegerType(_ type: String?) -> Bool {
        let tokens = typeTokens(type)
        if tokens.contains(where: {
            $0.hasPrefix("int64") || $0.hasPrefix("uint64") || $0 == "__int64" || $0 == "__uint64"
        }) {
            return true
        }
        for index in 0..<max(0, tokens.count - 1) where tokens[index] == "long" && tokens[index + 1] == "long" {
            return true
        }
        return false
    }

    private static func isUnsignedIntegerType(_ type: String?) -> Bool {
        let tokens = typeTokens(type)
        return tokens.contains {
            $0 == "unsigned" || $0.hasPrefix("uint") || $0 == "size_t" || $0 == "uintptr_t"
        }
    }

    private static func normalizeHex(_ text: String, is64Bit: Bool) -> String {
        guard text.hasPrefix("0x") || text.hasPrefix("0X") else { return text }
        let digits = text.dropFirst(2).prefix { $0.isHexDigit }
        guard !digits.isEmpty else { return text }
        let suffix = text.dropFirst(2 + digits.count)
        guard let number = UInt64(digits, radix: 16) else { return text }
        let width = (is64Bit || number > UInt64(UInt32.max)) ? 16 : 8
        return String(format: "0x%0\(width)llX", number) + suffix
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

    private static let typeQualifiers: Set<Substring> = [
        "const", "volatile", "restrict", "__restrict", "__restrict__"
    ]

    /// Whether `variable` is a dereferenceable pointer that can be expanded to
    /// show `*name`. Excludes `void *`, function pointers (`(*`), and arrays of
    /// pointers (`[`).
    static func isPointer(_ variable: DebugVariable) -> Bool {
        guard let type = variable.type?.trimmingCharacters(in: .whitespaces),
              type.contains("*"),
              !type.contains("(*"),
              !type.contains("( *"),
              !type.contains("[")
        else { return false }
        let target = dereferencedType(type)
        let significant = target.split(whereSeparator: \.isWhitespace).filter { !typeQualifiers.contains($0) }
        return significant != ["void"]
    }

    /// The target type of a pointer type, removing the last `*` and any pointer
    /// qualifiers that follow it (such as `const` in `"const int * const"`).
    static func dereferencedType(_ type: String?) -> String {
        guard let trimmed = type?.trimmingCharacters(in: .whitespaces),
              let star = trimmed.lastIndex(of: "*")
        else { return "int" }
        let result = trimmed[..<star].trimmingCharacters(in: .whitespaces)
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

    /// Parses an address returned by GDB's `-data-evaluate-expression`, including
    /// uppercase `0X`, optional symbol suffixes (`0x20a <main>`), and type-cast
    /// prefixes such as `"(int (*)[4]) 0x20000258"` or `"{int (void)} 0x20a <main>"`.
    static func parseEvaluatedAddress(_ text: String) -> UInt64? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)[...]
        guard !trimmed.isEmpty, let rest = stripCastPrefix(trimmed), !rest.isEmpty else { return nil }
        if rest.hasPrefix("0x") || rest.hasPrefix("0X") {
            let afterPrefix = rest.dropFirst(2)
            let digits = afterPrefix.prefix { $0.isHexDigit }
            guard !digits.isEmpty else { return nil }
            let trailing = afterPrefix.dropFirst(digits.count)
            guard trailing.isEmpty || trailing.first?.isWhitespace == true else { return nil }
            return UInt64(digits, radix: 16)
        }
        return UInt64(rest)
    }

    private static func stripCastPrefix(_ text: Substring) -> Substring? {
        guard let open = text.first, open == "(" || open == "{" else { return text }
        let close: Character = open == "(" ? ")" : "}"
        var depth = 0
        for idx in text.indices {
            if text[idx] == open {
                depth += 1
            } else if text[idx] == close {
                depth -= 1
                if depth == 0 {
                    return text[text.index(after: idx)...].drop(while: \.isWhitespace)
                }
            }
        }
        return nil
    }
}
