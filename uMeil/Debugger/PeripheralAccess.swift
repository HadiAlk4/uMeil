import Foundation

/// The chip's memory as the peripheral view reads and writes it. The
/// debugger provides it during a session; tests provide a fake.
@MainActor
protocol TargetMemory {
    func readMemoryOrThrow(at address: UInt64, count: Int) async throws -> [UInt8]
    func writeMemory(at address: UInt64, bytes: [UInt8]) async throws
}

extension DebugController: TargetMemory {}

/// What the peripheral view knows about one register's value.
enum RegisterReading: Equatable, Sendable {
    case value(UInt64)
    /// The chip refused the read, usually because the peripheral's clock is
    /// off. Holds GDB's message.
    case unreadable(String)
    /// Not read on purpose: reading would change the chip (a FIFO's data
    /// register), or the register is write-only.
    case notRead
}

/// Reads and writes a peripheral's registers in as few debugger commands as
/// is safe.
enum PeripheralAccess {
    /// Registers next to each other in memory, read with one command.
    struct Span: Equatable {
        var offset: UInt64
        var byteCount: Int
        var registers: [SVDRegister]
    }

    /// The registers to read, in runs of neighbours. A run never covers a
    /// gap: the TM4C129 can fault on reserved addresses, and a fault fails
    /// the whole read. Registers that must not be read are left out.
    static func spans(for peripheral: SVDPeripheral, maximumBytes: Int = 256) -> [Span] {
        var spans: [Span] = []
        let readable = peripheral.registers
            .filter { $0.access.isReadable && !$0.readHasSideEffects }
            .sorted { $0.addressOffset < $1.addressOffset }
        for register in readable {
            if var last = spans.last,
               last.offset + UInt64(last.byteCount) == register.addressOffset,
               last.byteCount + register.byteCount <= maximumBytes {
                last.byteCount += register.byteCount
                last.registers.append(register)
                spans[spans.count - 1] = last
            } else if spans.last.map({ $0.offset + UInt64($0.byteCount) > register.addressOffset }) == true {
                continue // Overlaps the previous register, as SVD alternates do.
            } else {
                spans.append(Span(offset: register.addressOffset, byteCount: register.byteCount, registers: [register]))
            }
        }
        return spans
    }

    /// Reads every register of `peripheral` that is safe to read, by name.
    /// A run the chip refuses is read again one register at a time, so one
    /// bad register does not hide its neighbours.
    @MainActor
    static func read(_ peripheral: SVDPeripheral, from memory: some TargetMemory) async -> [String: RegisterReading] {
        var readings: [String: RegisterReading] = [:]
        for register in peripheral.registers {
            readings[register.name] = .notRead
        }
        for span in spans(for: peripheral) {
            let address = peripheral.baseAddress + span.offset
            if let bytes = try? await memory.readMemoryOrThrow(at: address, count: span.byteCount),
               bytes.count == span.byteCount {
                for register in span.registers {
                    let start = Int(register.addressOffset - span.offset)
                    readings[register.name] = .value(littleEndian(bytes[start..<start + register.byteCount]))
                }
                continue
            }
            for register in span.registers {
                readings[register.name] = await read(register, of: peripheral, from: memory)
            }
        }
        return readings
    }

    /// Reads one register, whatever its read does to the chip.
    @MainActor
    static func read(
        _ register: SVDRegister,
        of peripheral: SVDPeripheral,
        from memory: some TargetMemory
    ) async -> RegisterReading {
        do {
            let bytes = try await memory.readMemoryOrThrow(
                at: peripheral.address(of: register), count: register.byteCount
            )
            guard bytes.count == register.byteCount else { return .unreadable("The chip returned too few bytes.") }
            return .value(littleEndian(bytes[...]))
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    /// Writes `value` to `register` as one store of the register's size.
    @MainActor
    static func write(
        _ value: UInt64,
        to register: SVDRegister,
        of peripheral: SVDPeripheral,
        in memory: some TargetMemory
    ) async throws {
        try await memory.writeMemory(
            at: peripheral.address(of: register),
            bytes: littleEndianBytes(value, count: register.byteCount)
        )
    }

    enum WriteFailure: Error, Equatable, LocalizedError {
        case notAValue(String, bits: Int)
        case readOnly(String)

        var errorDescription: String? {
            switch self {
            case let .notAValue(text, bits):
                "“\(text)” is not a value that fits in \(bits) bit\(bits == 1 ? "" : "s")."
            case .readOnly(let name):
                "\(name) is read-only."
            }
        }
    }

    /// Writes what the user typed into a register's or field's value, and
    /// returns the register's new value. A field is written by reading the
    /// register, changing the field's bits, and writing the whole register
    /// back. When the register cannot be read safely, `known` (the last
    /// value read) or the reset value stands in for the other bits.
    @MainActor
    @discardableResult
    static func apply(
        _ text: String,
        to register: SVDRegister,
        field: SVDField? = nil,
        of peripheral: SVDPeripheral,
        known: RegisterReading? = nil,
        in memory: some TargetMemory
    ) async throws -> UInt64 {
        let access = field?.access ?? register.access
        guard access.isWritable else { throw WriteFailure.readOnly(field?.name ?? register.name) }
        guard let typed = parseValue(text, field: field, bitWidth: register.size) else {
            throw WriteFailure.notAValue(text, bits: field?.bitWidth ?? register.size)
        }
        var newValue = typed
        if let field {
            var current = register.resetValue ?? 0
            if case .value(let value) = known {
                current = value
            }
            if register.access.isReadable, !register.readHasSideEffects,
               case .value(let value) = await read(register, of: peripheral, from: memory) {
                current = value
            }
            newValue = field.inserting(typed, into: current)
        }
        try await write(newValue, to: register, of: peripheral, in: memory)
        return newValue
    }

    // MARK: - Byte order

    static func littleEndian(_ bytes: ArraySlice<UInt8>) -> UInt64 {
        bytes.reversed().reduce(0) { ($0 << 8) | UInt64($1) }
    }

    static func littleEndianBytes(_ value: UInt64, count: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
    }

    // MARK: - Values the user types

    /// Reads a value typed for a register or field: `0x1F`, `0b101`, `31`,
    /// or one of the field's named values (`MOSC`). `nil` if it is none of
    /// these or does not fit in `bitWidth` bits.
    static func parseValue(_ text: String, field: SVDField? = nil, bitWidth: Int = 32) -> UInt64? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: UInt64?
        if let named = field?.enumeratedValues.first(where: { $0.name.caseInsensitiveCompare(text) == .orderedSame }) {
            value = named.value
        } else {
            let digits = text.replacingOccurrences(of: "_", with: "")
            value = SVDParser.number(digits)
        }
        let width = field?.bitWidth ?? bitWidth
        guard let value, width >= 64 || value < (UInt64(1) << UInt64(width)) else { return nil }
        return value
    }

    /// How a field's value is shown: `1`, `0x3 (MOSC)`, or `0x00F0`.
    static func fieldText(_ field: SVDField, registerValue: UInt64) -> String {
        let value = field.value(in: registerValue)
        let number = field.bitWidth <= 3 ? String(value) : "0x" + String(value, radix: 16, uppercase: true)
        if let name = field.enumeratedName(for: value) {
            return "\(number) (\(name))"
        }
        return number
    }
}
