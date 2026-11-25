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
        memory.isEditable = true
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

    @Test func memoryCommitEditRefusesWritesWhenNotEditableAndClearResetsAddressField() {
        let memory = MemoryViewController()
        var written = 0
        memory.onWriteBytes = { _, _ in written += 1 }
        memory.showMemory(at: 0x2000_0250, bytes: Array(repeating: 0, count: 16))
        #expect(memory.addressField.stringValue == "0x20000250")

        // isEditable defaults to false: edits must be refused.
        #expect(!memory.commitEdit("01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00", inRow: 0))
        #expect(written == 0)

        memory.clear()
        #expect(memory.addressField.stringValue.isEmpty)
        #expect(memory.rows.isEmpty)
        #expect(memory.currentAddress == nil)
    }

    @Test func writeMemoryRevertsUncommittedEditsOnFailure() async throws {
        let mainC = URL(filePath: "/tmp/write_mem_fail_main.c")
        let gdb = FakeDebugger { command in
            if command.hasPrefix("-data-write-memory-bytes") {
                return ["^error,msg=\"Cannot write flash\""]
            }
            return ["^done"]
        }
        let debugger = DebugController()
        debugger.connect = { _ in gdb }
        try await debugger.start(FakeBlinky.plan)
        gdb.print(FakeBlinky.stop(atLine: 1, of: mainC, reason: "breakpoint-hit"))
        await waitUntil("stopped") { debugger.isStopped }

        let panels = DebugPanelsController()
        panels.memory.isEditable = true
        panels.memory.showMemory(at: 0x0000_0200, bytes: [0x11, 0x22, 0x33, 0x44])
        let cell = panels.memory.tableView.view(atColumn: 1, row: 0, makeIfNecessary: true) as? NSTableCellView
        cell?.textField?.stringValue = "FF FF FF FF"

        let failure = await panels.writeMemory(at: 0x0000_0200, bytes: [0xFF, 0xFF, 0xFF, 0xFF], using: debugger)
        #expect(failure == "Cannot write flash")
        let reloaded = panels.memory.tableView.view(atColumn: 1, row: 0, makeIfNecessary: true) as? NSTableCellView
        #expect(reloaded?.textField?.stringValue == "11 22 33 44")
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
        #expect(panels.auxiliaryTabs.tabViewItems.map(\.label) == ["Watch 1", "Memory 1", "Peripherals"])
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

    @Test func registersTheChipRefusesAreShownAsUnreadable() async throws {
        let panels = try await loadedPanels()
        panels.peripherals.select(peripheralNamed: "UART3")
        let chip = FakeTargetMemory()
        chip.store(0x08, at: 0x400F_EA18)  // PRUART: UART3 is on.
        chip.faulting = Set(stride(from: UInt64(0x4000_F000), to: 0x4001_0000, by: 4))

        await panels.refreshPeripheral(using: chip, isStopped: true)

        let view = panels.peripherals
        let control = try #require(view.nodes.first { $0.name == "CTL" })
        #expect(view.valueText(for: control) == "unreadable")
        let dataRegister = try #require(view.nodes.first { $0.name == "DR" })
        #expect(view.valueText(for: dataRegister) == "not read")
        #expect(view.messageLabel.stringValue == "Some registers could not be read. Is the peripheral's clock on?")
        #expect(!chip.reads.contains { $0.address == 0x4000_F000 })
    }

    @Test func aPeripheralWhoseClockIsOffIsCalledOut() async throws {
        // On the board, an unclocked peripheral reads as zeros rather than failing.
        let panels = try await loadedPanels()
        panels.peripherals.select(peripheralNamed: "UART3")
        let chip = FakeTargetMemory()

        await panels.refreshPeripheral(using: chip, isStopped: true)
        #expect(panels.peripherals.messageLabel.stringValue
            == "UART3's clock is off, so its registers read as 0. The program turns it on with SYSCTL RCGCUART bit 3.")

        chip.store(0x08, at: 0x400F_EA18)  // PRUART bit 3.
        await panels.refreshPeripheral(using: chip, isStopped: true)
        #expect(panels.peripherals.messageLabel.stringValue.isEmpty)
    }

    @Test func clockGatesFollowTheChipsBitOrder() throws {
        let device = try SVDParser.parse(contentsOf: SVDDevice.bundledFile())
        func gate(_ name: String) throws -> PeripheralClock.Gate? {
            PeripheralClock.gate(for: try #require(device.peripheral(named: name)))
        }
        #expect(try gate("GPIO_PORTN") == PeripheralClock.Gate(readyRegister: "PRGPIO", bit: 12))
        #expect(try gate("GPIO_PORTA_AHB") == PeripheralClock.Gate(readyRegister: "PRGPIO", bit: 0))
        #expect(try gate("GPIO_PORTQ") == PeripheralClock.Gate(readyRegister: "PRGPIO", bit: 14))
        #expect(try gate("UART7")?.gateRegister == "RCGCUART")
        #expect(try gate("I2C9") == PeripheralClock.Gate(readyRegister: "PRI2C", bit: 9))
        #expect(try gate("WATCHDOG1") == PeripheralClock.Gate(readyRegister: "PRWD", bit: 1))
        #expect(try gate("COMP") == PeripheralClock.Gate(readyRegister: "PRACMP", bit: 0))
        #expect(try gate("SYSCTL") == nil)
        #expect(try gate("NVIC") == nil)
        // Every ready register named exists in the SVD file.
        let sysctl = try #require(device.peripheral(named: "SYSCTL"))
        for peripheral in device.peripherals {
            if let gate = PeripheralClock.gate(for: peripheral) {
                #expect(sysctl.register(named: gate.readyRegister) != nil, "\(peripheral.name)")
            }
        }
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

extension MemoryAndPeripheralPanelTests {
    // MARK: - Regression tests: Peripherals

    @Test func peripheralsUsesInjectedUserDefaultsAndEmitsOtherSectionHeaderFirst() throws {
        let customDefaults = TestDefaults()

        let ungroupedNil = SVDPeripheral(
            name: "SYSCTL", description: nil, groupName: nil, baseAddress: 0x400F_E000, registers: []
        )
        let ungroupedEmpty = SVDPeripheral(
            name: "NVIC", description: nil, groupName: "", baseAddress: 0xE000_E000, registers: []
        )
        let grouped = SVDPeripheral(
            name: "UART0", description: nil, groupName: "UART", baseAddress: 0x4000_C000, registers: []
        )
        let device = SVDDevice(name: "TestChip", peripherals: [grouped, ungroupedNil, ungroupedEmpty])

        let panel = PeripheralsViewController(defaults: customDefaults)
        panel.loadViewIfNeeded()
        panel.setDevice(device)
        panel.select(peripheralNamed: "UART0")

        #expect(customDefaults.string(forKey: PeripheralsViewController.selectionKey) == "UART0")
        #expect(UserDefaults.standard.string(forKey: PeripheralsViewController.selectionKey) == nil)

        // Both nil and "" groupName share a single leading "Other" section header.
        let items = try #require(panel.peripheralPopUp.menu?.items)
        #expect(items.first?.isSectionHeader == true)
        #expect(items.first?.title == "Other")
        #expect(items.filter { $0.isSectionHeader && $0.title == "Other" }.count == 1)
        #expect(items.contains { $0.isSectionHeader && $0.title == "UART" })
    }

    @Test func refreshPeripheralAwaitsFirstStopSVDLoadAndRetriesAfterParseFailure() async throws {
        let panels = DebugPanelsController()
        panels.svdFile = URL(filePath: "/nonexistent/missing.svd")
        await panels.loadDeviceIfNeeded()?.value
        #expect(panels.peripherals.device == nil)
        #expect(panels.peripherals.messageLabel.stringValue.contains("Cannot read"))

        // Fixing svdFile after failure must retry cleanly when refreshPeripheral runs.
        panels.svdFile = SVDDevice.bundledFile()
        let chip = FakeTargetMemory()
        chip.store(0x02, at: 0x4006_43FC)
        await panels.refreshPeripheral(using: chip, isStopped: true)

        #expect(panels.peripherals.device != nil)
        let data = try #require(panels.peripherals.nodes.first { $0.name == "DATA" })
        #expect(panels.peripherals.valueText(for: data) == "0x00000002")
    }

    @Test func switchingPeripheralDuringClockCheckDoesNotOverwriteNewPeripheralsMessage() async throws {
        @MainActor
        final class HookedMemory: TargetMemory {
            let backing = FakeTargetMemory()
            var onRead: ((UInt64) async -> Void)?

            func readMemoryOrThrow(at address: UInt64, count: Int) async throws -> [UInt8] {
                await onRead?(address)
                return try await backing.readMemoryOrThrow(at: address, count: count)
            }

            func writeMemory(at address: UInt64, bytes: [UInt8]) async throws {
                try await backing.writeMemory(at: address, bytes: bytes)
            }
        }

        let panels = try await loadedPanels()
        panels.peripherals.select(peripheralNamed: "UART3")
        let memory = HookedMemory()
        var clockContinuation: CheckedContinuation<Void, Never>?
        memory.onRead = { address in
            if address == 0x400F_EA18 { // SYSCTL PRUART
                await withCheckedContinuation { clockContinuation = $0 }
            }
        }

        let task = Task { await panels.refreshPeripheral(using: memory, isStopped: true) }
        await waitUntil("clock check reached PRUART") { clockContinuation != nil }

        // User switches away from UART3 while its clock check is in flight.
        panels.peripherals.select(peripheralNamed: "GPIO_PORTN")
        clockContinuation?.resume()
        await task.value

        #expect(panels.peripherals.selectedPeripheral?.name == "GPIO_PORTN")
        #expect(panels.peripherals.messageLabel.stringValue.isEmpty)
    }

    @Test func fieldChangeHighlightingOnlyMarksChangedBitsAndIgnoresUnreadableTransitions() async throws {
        let panels = try await loadedPanels()
        let chip = FakeTargetMemory()
        chip.store(0x01, at: 0x4006_43FC) // P0=1, P1=0
        await panels.refreshPeripheral(using: chip, isStopped: true)

        chip.store(0x03, at: 0x4006_43FC) // P0=1 (unchanged), P1=1 (changed)
        await panels.refreshPeripheral(using: chip, isStopped: true)

        let view = panels.peripherals
        let data = try #require(view.nodes.first { $0.name == "DATA" })
        let pin0 = try #require(data.children.first { $0.name == "P0" })
        let pin1 = try #require(data.children.first { $0.name == "P1" })
        #expect(view.isChanged(data))
        #expect(!view.isChanged(pin0))
        #expect(view.isChanged(pin1))

        // Transitioning from .value to .unreadable must not mark the register changed.
        let port = try #require(view.selectedPeripheral)
        view.update(reading: .unreadable("Fault"), for: data.register, of: port)
        #expect(!view.changedRegisters.contains("DATA"))
        #expect(!view.isChanged(data))
    }

    @Test func peripheralEditingRevertsEmptyUnchangedFailedAndRunningWrites() async throws {
        let panels = try await loadedPanels()
        let chip = FakeTargetMemory()
        chip.store(0x02, at: 0x4006_43FC)
        await panels.refreshPeripheral(using: chip, isStopped: true)

        let view = panels.peripherals
        view.isEditable = true
        let port = try #require(view.selectedPeripheral)
        let data = try #require(port.register(named: "DATA"))

        // Empty or whitespace-padded unchanged edit reverts cell stringValue without invoking onWrite.
        var writeCount = 0
        view.onWrite = { _, _, _, _ in writeCount += 1 }
        let cell = try #require(view.outlineView.view(atColumn: 1, row: 0, makeIfNecessary: true) as? NSTableCellView)
        let field = try #require(cell.textField)
        field.stringValue = "   "
        view.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        #expect(field.stringValue == "0x00000002")
        #expect(writeCount == 0)

        // Ending an edit after the target resumes (isEditable == false) reverts without firing onWrite.
        view.isEditable = false
        let nonEditableCell = try #require(
            view.outlineView.view(atColumn: 1, row: 0, makeIfNecessary: true) as? NSTableCellView
        )
        let nonEditableField = try #require(nonEditableCell.textField)
        nonEditableField.stringValue = "0x000000AA"
        view.controlTextDidEndEditing(
            Notification(name: NSControl.textDidEndEditingNotification, object: nonEditableField)
        )
        #expect(nonEditableField.stringValue == "0x00000002")
        #expect(writeCount == 0)
        view.isEditable = true

        // Running target refuses write and reverts edits.
        let runningErr = await panels.writePeripheral(
            port, register: data, field: nil, text: "0xFF", using: chip, isStopped: false
        )
        #expect(runningErr != nil)
        #expect(chip.writes.isEmpty)
        let revertedCell = view.outlineView.view(atColumn: 1, row: 0, makeIfNecessary: true) as? NSTableCellView
        #expect(revertedCell?.textField?.stringValue == "0x00000002")

        // Failed parse reverts edits too.
        revertedCell?.textField?.stringValue = "INVALID"
        let parseErr = await panels.writePeripheral(port, register: data, field: nil, text: "INVALID", using: chip)
        #expect(parseErr != nil)
        let revertedAgain = view.outlineView.view(atColumn: 1, row: 0, makeIfNecessary: true) as? NSTableCellView
        #expect(revertedAgain?.textField?.stringValue == "0x00000002")
    }

    @Test func writePeripheralPreservesChangedStateForSideEffectRegister() async throws {
        let panels = try await loadedPanels()
        let chip = FakeTargetMemory()
        let view = panels.peripherals
        view.select(peripheralNamed: "UART0")
        let uart = try #require(view.selectedPeripheral)
        let drReg = try #require(uart.register(named: "DR"))
        chip.store(0x01, at: 0x400F_EA18) // PRUART: UART0 clock on
        chip.store(0x41, at: 0x4000_C000)
        await panels.readPeripheralRegister(drReg, of: uart, using: chip)
        #expect(view.changedRegisters.isEmpty)

        let writeErr = await panels.writePeripheral(uart, register: drReg, field: nil, text: "0x42", using: chip)
        #expect(writeErr == nil)
        #expect(view.changedRegisters.contains("DR"))
        let drNode = try #require(view.nodes.first { $0.name == "DR" })
        #expect(view.valueText(for: drNode) == "0x00000042")
        #expect(view.isChanged(drNode))
    }
}

/// The panels in the debugger's bottom-right tabs fill the tab, so their
/// lists are as wide and tall as the space they are given.
@MainActor
struct DebugTabLayoutTests {
    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }

    @Test(arguments: ["Watch 1", "Memory 1", "Peripherals"])
    func eachTabsListFillsTheTab(_ title: String) throws {
        let panels = DebugPanelsController()
        let tab = try #require(panels.auxiliaryTabs.tabViewItems.first { $0.label == title })
        let panel = try #require(tab.viewController)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        panel.view.frame = container.bounds
        panel.view.autoresizingMask = [.width, .height]
        container.addSubview(panel.view)
        container.layoutSubtreeIfNeeded()

        let list = try #require(scrollView(in: panel.view))
        let frame = list.convert(list.bounds, to: container)
        #expect(frame.width >= 590, "\(title) list is \(frame.width) wide")
        #expect(frame.height >= 220, "\(title) list is \(frame.height) tall")
    }
}
