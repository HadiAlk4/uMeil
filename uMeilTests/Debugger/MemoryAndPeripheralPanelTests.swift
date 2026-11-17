import AppKit
import Testing
@testable import uMeil

/// Tests for M7's panels: typing into `Memory 1`, and the `Peripherals`
/// panel built from the shipped SVD file.
@MainActor
@Suite(.serialized)
struct MemoryAndPeripheralPanelTests {
    init() {
        UserDefaults.standard.removeObject(forKey: PeripheralsViewController.selectionKey)
    }

    // MARK: - Memory 1

    @Test func typedHexBytesAreReadWithOrWithoutSpaces() {
        #expect(DebugValueFormatter.parseHexBytes("9D FF ff 00") == [0x9D, 0xFF, 0xFF, 0x00])
        #expect(DebugValueFormatter.parseHexBytes("9dff00") == [0x9D, 0xFF, 0x00])
        #expect(DebugValueFormatter.parseHexBytes("9D F") == nil)
        #expect(DebugValueFormatter.parseHexBytes("GG") == nil)
    }

    @Test func onlyTheChangedRunOfARowIsWritten() {
        let memory = MemoryViewController()
        var written: [(UInt64, [UInt8])] = []
        memory.onWriteBytes = { written.append(($0, $1)) }
        memory.showMemory(at: 0x2000_0250, bytes: Array(repeating: 0, count: 16))

        #expect(memory.commitEdit("00 00 00 00 00 00 00 00 9D FF FF FF 00 00 00 00", inRow: 0))
        #expect(written.count == 1)
        #expect(written.first?.0 == 0x2000_0258)
        #expect(written.first?.1 == [0x9D, 0xFF, 0xFF, 0xFF])

        // The same bytes again is not a write; the wrong number of bytes is refused.
        #expect(memory.commitEdit(memory.rows[0].hexText, inRow: 0))
        #expect(!memory.commitEdit("00 11", inRow: 0))
        #expect(written.count == 1)
    }

    @Test func choosingALengthAsksForTheMemoryAgain() {
        let memory = MemoryViewController()
        var asked = 0
        memory.onLengthChange = { asked += 1 }
        #expect(memory.byteCount == 64)
        memory.setByteCount(256)
        memory.setByteCount(256)
        #expect(memory.byteCount == 256)
        #expect(asked == 1)
    }

    // MARK: - Peripherals

    private func loadedPanels() async throws -> DebugPanelsController {
        let panels = DebugPanelsController()
        await panels.loadDeviceIfNeeded()?.value
        _ = try #require(panels.peripherals.device)
        return panels
    }

    @Test func peripheralsTabSitsBesideMemoryAndStartsOnTheLEDPort() async throws {
        let panels = try await loadedPanels()
        #expect(panels.auxiliaryTabs.tabViewItems.map(\.label) == ["Watch 1", "Memory 1", "Peripherals", "Command"])
        #expect(panels.peripherals.selectedPeripheral?.name == "GPIO_PORTN")
        #expect(panels.peripherals.nodes.first?.name == "DATA")
        #expect(panels.peripherals.locationText(for: panels.peripherals.nodes[0]) == "0x400643FC")
    }

    @Test func readingTheLEDPortShowsRegistersAndPinsAndMarksChanges() async throws {
        let panels = try await loadedPanels()
        let chip = FakeTargetMemory()
        chip.store(0x02, at: 0x4006_43FC)  // DATA: PN1 high, LED D1 on.
        chip.store(0x03, at: 0x4006_4400)  // DIR: PN0 and PN1 outputs.

        await panels.refreshPeripheral(using: chip, isStopped: true)

        let view = panels.peripherals
        let data = try #require(view.nodes.first { $0.name == "DATA" })
        #expect(view.valueText(for: data) == "0x00000002")
        let pin1 = try #require(data.children.first { $0.name == "P1" })
        #expect(view.valueText(for: pin1) == "1")
        #expect(view.locationText(for: pin1) == "[1]")
        #expect(view.changedRegisters.isEmpty)

        chip.store(0x00, at: 0x4006_43FC)
        await panels.refreshPeripheral(using: chip, isStopped: true)
        #expect(view.valueText(for: data) == "0x00000000")
        #expect(view.changedRegisters == ["DATA"])
    }

    @Test func typingAPinValueWritesTheWholeRegisterWithOnlyThatBitChanged() async throws {
        let panels = try await loadedPanels()
        let chip = FakeTargetMemory()
        chip.store(0x01, at: 0x4006_43FC)
        let port = try #require(panels.peripherals.selectedPeripheral)
        let data = try #require(port.register(named: "DATA"))
        let pin1 = try #require(data.fields.first { $0.name == "P1" })

        let failure = await panels.writePeripheral(port, register: data, field: pin1, text: "1", using: chip)

        #expect(failure == nil)
        #expect(chip.writes.map(\.address) == [0x4006_43FC])
        #expect(chip.writes.first?.bytes == [0x03, 0, 0, 0])
        #expect(panels.peripherals.valueText(for: panels.peripherals.nodes[0]) == "0x00000003")
    }

    @Test func aRefusedWriteIsExplainedAndWritesNothing() async throws {
        let panels = try await loadedPanels()
        let chip = FakeTargetMemory()
        let port = try #require(panels.peripherals.selectedPeripheral)
        let data = try #require(port.register(named: "DATA"))

        let failure = await panels.writePeripheral(port, register: data, field: nil, text: "LED", using: chip)

        #expect(failure == "“LED” is not a value that fits in 32 bits.")
        #expect(panels.peripherals.messageLabel.stringValue == failure)
        #expect(chip.writes.isEmpty)
    }

    @Test func anUnclockedPeripheralIsShownAsUnreadable() async throws {
        let panels = try await loadedPanels()
        panels.peripherals.select(peripheralNamed: "UART3")
        let chip = FakeTargetMemory()
        chip.faulting = Set(stride(from: UInt64(0x4000_F000), to: 0x4001_0000, by: 4))

        await panels.refreshPeripheral(using: chip, isStopped: true)

        let view = panels.peripherals
        let control = try #require(view.nodes.first { $0.name == "CTL" })
        #expect(view.valueText(for: control) == "unreadable")
        let dataRegister = try #require(view.nodes.first { $0.name == "DR" })
        #expect(view.valueText(for: dataRegister) == "not read")
        #expect(view.messageLabel.stringValue.contains("clock"))
        #expect(!chip.reads.contains { $0.address == 0x4000_F000 })
    }

    @Test func aRegisterWithSideEffectsIsReadOnlyOnRequest() async throws {
        let panels = try await loadedPanels()
        panels.peripherals.select(peripheralNamed: "UART0")
        let uart = try #require(panels.peripherals.selectedPeripheral)
        let dataRegister = try #require(uart.register(named: "DR"))
        let chip = FakeTargetMemory()
        chip.store(0x41, at: 0x4000_C000)

        await panels.refreshPeripheral(using: chip, isStopped: true)
        let node = try #require(panels.peripherals.nodes.first { $0.name == "DR" })
        #expect(panels.peripherals.valueText(for: node) == "not read")

        await panels.readPeripheralRegister(dataRegister, of: uart, using: chip)
        #expect(panels.peripherals.valueText(for: node) == "0x00000041")

        // The next stop leaves the value read on request in place.
        await panels.refreshPeripheral(using: chip, isStopped: true)
        #expect(panels.peripherals.valueText(for: node) == "0x00000041")
    }

    @Test func nothingIsReadWhileTheProgramRuns() async throws {
        let panels = try await loadedPanels()
        let chip = FakeTargetMemory()
        await panels.refreshPeripheral(using: chip, isStopped: false)
        #expect(chip.reads.isEmpty)
    }
}
