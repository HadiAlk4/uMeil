import Foundation
import Testing
@testable import uMeil

/// A chip's memory for tests: bytes by address, with addresses that refuse
/// to be read, and a record of every read and write.
@MainActor
final class FakeTargetMemory: TargetMemory {
    var bytes: [UInt64: UInt8] = [:]
    /// Reads touching any of these fail, as an unclocked peripheral does.
    var faulting: Set<UInt64> = []
    private(set) var reads: [(address: UInt64, count: Int)] = []
    private(set) var writes: [(address: UInt64, bytes: [UInt8])] = []

    func store(_ value: UInt32, at address: UInt64) {
        for index in 0..<4 {
            bytes[address + UInt64(index)] = UInt8(truncatingIfNeeded: value >> UInt32(index * 8))
        }
    }

    func readMemoryOrThrow(at address: UInt64, count: Int) async throws -> [UInt8] {
        reads.append((address, count))
        let range = address..<address + UInt64(count)
        if faulting.contains(where: range.contains) {
            throw DebugError.refused("Unable to read memory.")
        }
        return range.map { bytes[$0] ?? 0 }
    }

    func writeMemory(at address: UInt64, bytes newBytes: [UInt8]) async throws {
        writes.append((address, newBytes))
        for (index, byte) in newBytes.enumerated() {
            bytes[address + UInt64(index)] = byte
        }
    }
}

@MainActor
struct PeripheralAccessTests {
    private func register(
        _ name: String, _ offset: UInt64, size: Int = 32, access: SVDAccess = .readWrite, sideEffects: Bool = false,
        fields: [SVDField] = []
    ) -> SVDRegister {
        SVDRegister(
            name: name, description: nil, addressOffset: offset, size: size, access: access,
            resetValue: nil, readHasSideEffects: sideEffects, fields: fields
        )
    }

    private var oscillatorSource: SVDField {
        SVDField(
            name: "OSCSRC", description: nil, bitOffset: 20, bitWidth: 4, access: .readWrite,
            enumeratedValues: [
                SVDEnumeratedValue(name: "PIOSC", description: nil, value: 0),
                SVDEnumeratedValue(name: "MOSC", description: nil, value: 3)
            ]
        )
    }

    private var uart: SVDPeripheral {
        SVDPeripheral(name: "UART0", description: nil, groupName: "UART", baseAddress: 0x4000_C000, registers: [
            register("DR", 0x00, sideEffects: true),
            register("RSR", 0x04),
            register("FR", 0x18, access: .readOnly),
            register("ILPR", 0x20),
            register("IBRD", 0x24),
            register("FBRD", 0x28),
            register("ICR", 0x44, access: .writeOnly)
        ])
    }

    // MARK: - Planning reads

    @Test func readsRunsOfNeighboursAndSkipsSideEffectsWriteOnlyAndGaps() {
        let spans = PeripheralAccess.spans(for: uart)
        #expect(spans.map(\.offset) == [0x04, 0x18, 0x20])
        #expect(spans.map(\.byteCount) == [4, 4, 12])
        #expect(spans.last?.registers.map(\.name) == ["ILPR", "IBRD", "FBRD"])
    }

    @Test func longRunsAreSplitAtTheSizeLimit() {
        let registers = (0..<10).map { register("R\($0)", UInt64($0) * 4) }
        let peripheral = SVDPeripheral(
            name: "P", description: nil, groupName: nil, baseAddress: 0, registers: registers
        )
        #expect(PeripheralAccess.spans(for: peripheral, maximumBytes: 16).map(\.byteCount) == [16, 16, 8])
    }

    // MARK: - Reading

    @Test func readsValuesLittleEndianAndLeavesUnsafeRegistersUnread() async {
        let memory = FakeTargetMemory()
        memory.store(0x0000_0090, at: 0x4000_C018)
        memory.store(0x0000_002B, at: 0x4000_C024)
        memory.store(0xDEAD_BEEF, at: 0x4000_C000)

        let readings = await PeripheralAccess.read(uart, from: memory)

        #expect(readings["FR"] == .value(0x90))
        #expect(readings["IBRD"] == .value(0x2B))
        #expect(readings["DR"] == .notRead)
        #expect(readings["ICR"] == .notRead)
        #expect(!memory.reads.contains { $0.address == 0x4000_C000 })
        #expect(memory.reads.count == 3)
    }

    @Test func aRefusedRunIsRetriedOneRegisterAtATime() async {
        let memory = FakeTargetMemory()
        memory.store(7, at: 0x4000_C020)
        memory.store(9, at: 0x4000_C028)
        memory.faulting = [0x4000_C024]

        let readings = await PeripheralAccess.read(uart, from: memory)

        #expect(readings["ILPR"] == .value(7))
        #expect(readings["IBRD"] == .unreadable("Unable to read memory."))
        #expect(readings["FBRD"] == .value(9))
    }

    @Test func aRegisterWithSideEffectsIsReadWhenAskedFor() async {
        let memory = FakeTargetMemory()
        memory.store(0x41, at: 0x4000_C000)
        let dataRegister = uart.registers[0]

        let reading = await PeripheralAccess.read(dataRegister, of: uart, from: memory)

        #expect(reading == .value(0x41))
    }

    // MARK: - Writing

    @Test func writesAreOneLittleEndianStoreOfTheRegistersSize() async throws {
        let memory = FakeTargetMemory()
        let portN = SVDPeripheral(
            name: "GPIO_PORTN", description: nil, groupName: "GPIO", baseAddress: 0x4006_4000,
            registers: [register("DATA", 0x3FC)]
        )

        try await PeripheralAccess.write(0x02, to: portN.registers[0], of: portN, in: memory)

        #expect(memory.writes.count == 1)
        #expect(memory.writes.first?.address == 0x4006_43FC)
        #expect(memory.writes.first?.bytes == [0x02, 0x00, 0x00, 0x00])
    }

    @Test func typingIntoAFieldChangesOnlyItsBits() async throws {
        let memory = FakeTargetMemory()
        memory.store(0x1300_0000, at: 0x400F_E0B0)
        let sysctl = SVDPeripheral(
            name: "SYSCTL", description: nil, groupName: nil, baseAddress: 0x400F_E000,
            registers: [register("RSCLKCFG", 0xB0, fields: [oscillatorSource])]
        )
        let rsclkcfg = sysctl.registers[0]

        let newValue = try await PeripheralAccess.apply(
            "MOSC", to: rsclkcfg, field: oscillatorSource, of: sysctl, in: memory
        )

        #expect(newValue == 0x1330_0000)
        #expect(memory.writes.last?.bytes == [0x00, 0x00, 0x30, 0x13])
    }

    @Test func typingIntoARegisterWithSideEffectsUsesTheLastKnownValue() async throws {
        let memory = FakeTargetMemory()
        let low = SVDField(name: "LOW", description: nil, bitOffset: 0, bitWidth: 8, access: .readWrite,
                           enumeratedValues: [])
        let peripheral = SVDPeripheral(
            name: "P", description: nil, groupName: nil, baseAddress: 0x1000,
            registers: [register("FIFO", 0, sideEffects: true, fields: [low])]
        )

        let newValue = try await PeripheralAccess.apply(
            "0x41", to: peripheral.registers[0], field: low, of: peripheral, known: .value(0xAB00), in: memory
        )

        #expect(newValue == 0xAB41)
        #expect(memory.reads.isEmpty)
    }

    @Test func typingRejectsReadOnlyRegistersAndValuesThatDoNotFit() async {
        let memory = FakeTargetMemory()
        let flags = uart.registers[2]

        await #expect(throws: PeripheralAccess.WriteFailure.readOnly("FR")) {
            try await PeripheralAccess.apply("1", to: flags, of: uart, in: memory)
        }
        await #expect(throws: PeripheralAccess.WriteFailure.notAValue("lots", bits: 32)) {
            try await PeripheralAccess.apply("lots", to: uart.registers[4], of: uart, in: memory)
        }
        #expect(memory.writes.isEmpty)
    }

    @Test func byteOrderRoundTrips() {
        let bytes = PeripheralAccess.littleEndianBytes(0xFFFF_FF9D, count: 4)
        #expect(bytes == [0x9D, 0xFF, 0xFF, 0xFF])
        #expect(PeripheralAccess.littleEndian(bytes[...]) == 0xFFFF_FF9D)
        #expect(PeripheralAccess.littleEndianBytes(0x1234, count: 2) == [0x34, 0x12])
    }

    // MARK: - Typed values and display

    @Test func typedValuesAcceptNumbersAndNamedValuesThatFit() {
        let field = oscillatorSource
        #expect(PeripheralAccess.parseValue("0x3", field: field) == 3)
        #expect(PeripheralAccess.parseValue("mosc", field: field) == 3)
        #expect(PeripheralAccess.parseValue("0b0011", field: field) == 3)
        #expect(PeripheralAccess.parseValue("15", field: field) == 15)
        #expect(PeripheralAccess.parseValue("16", field: field) == nil)
        #expect(PeripheralAccess.parseValue("XTAL", field: field) == nil)
        #expect(PeripheralAccess.parseValue("0xFFFF_FFFF") == 0xFFFF_FFFF)
        #expect(PeripheralAccess.parseValue("0x1_0000_0000") == nil)
    }

    @Test func fieldsShowTheirValueAndItsName() {
        #expect(PeripheralAccess.fieldText(oscillatorSource, registerValue: 0x0030_0000) == "0x3 (MOSC)")
        #expect(PeripheralAccess.fieldText(oscillatorSource, registerValue: 0x00A0_0000) == "0xA")
        let pin = SVDField(
            name: "P1", description: nil, bitOffset: 1, bitWidth: 1, access: .readWrite, enumeratedValues: []
        )
        #expect(PeripheralAccess.fieldText(pin, registerValue: 0x2) == "1")
    }

    // MARK: - Overlapping registers, cancellation, and clock gates

    @Test func overlappingAlternateRegistersAreDecodedFromTheSameSpan() async {
        let peripheral = SVDPeripheral(
            name: "ALT", description: nil, groupName: nil, baseAddress: 0x4000_0000,
            registers: [
                register("RSR", 0x04),
                register("ECR", 0x04),
                register("LOW16", 0x10, size: 16),
                register("FULL32", 0x10, size: 32),
                register("HIGH16", 0x12, size: 16)
            ]
        )

        let spans = PeripheralAccess.spans(for: peripheral)
        #expect(spans.count == 2)
        #expect(spans[0].offset == 0x04)
        #expect(spans[0].byteCount == 4)
        #expect(spans[0].registers.map(\.name) == ["RSR", "ECR"])
        #expect(spans[1].offset == 0x10)
        #expect(spans[1].byteCount == 4)
        #expect(spans[1].registers.map(\.name) == ["LOW16", "FULL32", "HIGH16"])

        // When extending an overlapping register would exceed maximumBytes, start a new span.
        let split = PeripheralAccess.spans(for: peripheral, maximumBytes: 2)
        #expect(split.map(\.offset) == [0x04, 0x10, 0x10])
        #expect(split[0].registers.map(\.name) == ["RSR", "ECR"])
        #expect(split[1].registers.map(\.name) == ["LOW16"])
        #expect(split[2].registers.map(\.name) == ["FULL32", "HIGH16"])

        let memory = FakeTargetMemory()
        memory.store(0x0000_000F, at: 0x4000_0004)
        memory.store(0x1234_5678, at: 0x4000_0010)
        let readings = await PeripheralAccess.read(peripheral, from: memory)
        #expect(readings["RSR"] == .value(0x0000_000F))
        #expect(readings["ECR"] == .value(0x0000_000F))
        #expect(readings["LOW16"] == .value(0x5678))
        #expect(readings["FULL32"] == .value(0x1234_5678))
        #expect(readings["HIGH16"] == .value(0x1234))
        #expect(memory.reads.count == 2)
    }

    @Test func shippedSVDAlternateRegistersInUART0AndEPI0AreAllRead() async throws {
        let device = try SVDParser.parse(contentsOf: SVDDevice.bundledFile())
        let memory = FakeTargetMemory()

        let uart0 = try #require(device.peripheral(named: "UART0"))
        memory.store(0x0000_0005, at: uart0.baseAddress + 0x04)
        let uartReadings = await PeripheralAccess.read(uart0, from: memory)
        #expect(uartReadings["RSR"] == .value(5))
        #expect(uartReadings["ECR"] == .value(5))

        let epi0 = try #require(device.peripheral(named: "EPI0"))
        memory.store(0xABCD_1234, at: epi0.baseAddress + 0x10)
        let epiReadings = await PeripheralAccess.read(epi0, from: memory)
        for name in ["HB16CFG", "GPCFG", "SDRAMCFG", "HB8CFG"] {
            #expect(epiReadings[name] == .value(0xABCD_1234), "Expected \(name) to be read")
        }
    }

    @Test func readStopsImmediatelyWhenCancelled() async {
        @MainActor
        final class CancellingMemory: TargetMemory {
            var readCount = 0
            var onRead: (() -> Void)?

            func readMemoryOrThrow(at address: UInt64, count: Int) async throws -> [UInt8] {
                readCount += 1
                onRead?()
                throw DebugError.refused("fault")
            }

            func writeMemory(at address: UInt64, bytes: [UInt8]) async throws {}
        }

        let peripheral = SVDPeripheral(
            name: "BIG", description: nil, groupName: nil, baseAddress: 0x4000_0000,
            registers: [
                register("R0", 0x00),
                register("R1", 0x04),
                register("R2", 0x08),
                register("R3", 0x20),
                register("R4", 0x40)
            ]
        )
        let memory = CancellingMemory()
        var task: Task<[String: RegisterReading], Never>?
        memory.onRead = { task?.cancel() }
        task = Task { await PeripheralAccess.read(peripheral, from: memory) }
        _ = await task?.value

        // Cancelled during the first span read: must not fire fallback or later span reads.
        #expect(memory.readCount == 1)
    }

    @Test func clockGateRejectsNegativeAndOutOfRangeBitNumbers() {
        func peripheral(named name: String) -> SVDPeripheral {
            SVDPeripheral(name: name, description: nil, groupName: nil, baseAddress: 0, registers: [])
        }
        #expect(
            PeripheralClock.gate(for: peripheral(named: "UART0"))
                == PeripheralClock.Gate(readyRegister: "PRUART", bit: 0)
        )
        #expect(
            PeripheralClock.gate(for: peripheral(named: "UART63"))
                == PeripheralClock.Gate(readyRegister: "PRUART", bit: 63)
        )
        #expect(PeripheralClock.gate(for: peripheral(named: "UART-1")) == nil)
        #expect(PeripheralClock.gate(for: peripheral(named: "UART64")) == nil)
        #expect(PeripheralClock.gate(for: peripheral(named: "UART100")) == nil)
    }
}
