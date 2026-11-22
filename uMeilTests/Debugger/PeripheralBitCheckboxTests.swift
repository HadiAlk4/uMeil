import AppKit
import Testing
@testable import uMeil

@MainActor
struct PeripheralBitCheckboxTests {
    private static func field(_ name: String, bit: Int, width: Int = 1, access: SVDAccess = .readWrite) -> SVDField {
        SVDField(name: name, description: nil, bitOffset: bit, bitWidth: width, access: access, enumeratedValues: [])
    }

    /// A port with two LED pins, a read-only status bit, and a two-bit field.
    private static let register = SVDRegister(
        name: "DATA", description: nil, addressOffset: 0x3FC, size: 32, access: .readWrite, resetValue: 0,
        readHasSideEffects: false,
        fields: [field("PIN0", bit: 0), field("PIN1", bit: 1), field("LOCKED", bit: 2, access: .readOnly),
                 field("MODE", bit: 4, width: 2)]
    )
    private static let port = SVDPeripheral(
        name: "GPIO_PORTN", description: nil, groupName: "GPIO", baseAddress: 0x4006_4000, registers: [register]
    )

    private func makePanel(value: UInt64) throws -> PeripheralsViewController {
        let suite = "uMeilTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let panel = PeripheralsViewController(defaults: defaults)
        panel.loadViewIfNeeded()
        panel.view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        panel.setDevice(SVDDevice(name: "Test", peripherals: [Self.port]))
        panel.update(readings: ["DATA": .value(value)], for: Self.port)
        panel.outlineView.expandItem(panel.nodes.first)
        panel.view.layoutSubtreeIfNeeded()
        return panel
    }

    private func node(_ name: String, in panel: PeripheralsViewController) throws -> PeripheralsViewController.Node {
        try #require(panel.nodes.first?.children.first { $0.name == name })
    }

    private func valueCell(
        for node: PeripheralsViewController.Node,
        in panel: PeripheralsViewController
    ) -> NSTableCellView? {
        let row = panel.outlineView.row(forItem: node)
        let column = panel.outlineView.column(withIdentifier: NSUserInterfaceItemIdentifier("value"))
        return panel.outlineView.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView
    }

    private func locationCell(
        for node: PeripheralsViewController.Node,
        in panel: PeripheralsViewController
    ) -> NSTableCellView? {
        let row = panel.outlineView.row(forItem: node)
        let column = panel.outlineView.column(withIdentifier: NSUserInterfaceItemIdentifier("location"))
        return panel.outlineView.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView
    }

    private func checkbox(for node: PeripheralsViewController.Node, in panel: PeripheralsViewController) -> NSButton? {
        valueCell(for: node, in: panel)?.subviews.first as? NSButton
    }

    private func dot(for node: PeripheralsViewController.Node, in panel: PeripheralsViewController) -> NSImageView? {
        valueCell(for: node, in: panel)?.imageView
    }

    @Test func onlyWritableSingleBitsThatHaveBeenReadAreCheckboxes() throws {
        let panel = try makePanel(value: 0b10)
        #expect(panel.bitValue(of: try node("PIN0", in: panel)) == false)
        #expect(panel.bitValue(of: try node("PIN1", in: panel)) == true)
        #expect(panel.bitValue(of: try node("LOCKED", in: panel)) == nil)
        #expect(panel.bitValue(of: try node("MODE", in: panel)) == nil)
        #expect(panel.bitValue(of: try #require(panel.nodes.first)) == nil)

        panel.update(readings: ["DATA": .unreadable("clock off")], for: Self.port)
        #expect(panel.bitValue(of: try node("PIN0", in: panel)) == nil)
    }

    @Test func theCheckboxShowsTheBitAndIsOffWhileRunning() throws {
        let panel = try makePanel(value: 0b10)
        let pin1 = try #require(checkbox(for: try node("PIN1", in: panel), in: panel))
        #expect(pin1.state == .on)
        #expect(pin1.title.isEmpty)
        #expect(!pin1.isEnabled)

        panel.isEditable = true
        let enabled = try #require(checkbox(for: try node("PIN1", in: panel), in: panel))
        #expect(enabled.isEnabled)
    }

    @Test func readOnlySingleBitsRenderAsOnOffDotsInsteadOfZeroOrOneText() throws {
        let panel = try makePanel(value: 0b000)
        let locked = try node("LOCKED", in: panel)
        #expect(panel.singleBitState(of: locked) == .init(isOn: false, isWritable: false))
        #expect(checkbox(for: locked, in: panel) == nil)
        #expect(valueCell(for: locked, in: panel)?.textField == nil)

        let offDot = try #require(dot(for: locked, in: panel))
        #expect(offDot.contentTintColor == .tertiaryLabelColor)
        #expect(offDot.accessibilityValue() as? String == "0")

        // Changing the read-only bit from 0 -> 1 turns the dot red and flashes.
        panel.update(readings: ["DATA": .value(0b100)], for: Self.port)
        let changedCell = try #require(valueCell(for: locked, in: panel))
        let changedDot = try #require(changedCell.imageView)
        #expect(changedDot.contentTintColor == DebugTableStyle.changedColor)
        #expect(changedDot.accessibilityValue() as? String == "1")
        #expect(changedCell.layer?.animation(forKey: "changedFlash") != nil)

        // Reading the same value again clears the changed highlight and shows the on accent tint.
        panel.update(readings: ["DATA": .value(0b100)], for: Self.port)
        let steadyCell = try #require(valueCell(for: locked, in: panel))
        let onDot = try #require(steadyCell.imageView)
        #expect(onDot.contentTintColor == .controlAccentColor)
        #expect(steadyCell.layer?.animation(forKey: "changedFlash") == nil)

        // Unreadable registers do not show a dot.
        panel.update(readings: ["DATA": .unreadable("clock off")], for: Self.port)
        #expect(panel.singleBitState(of: locked) == nil)
        #expect(dot(for: locked, in: panel) == nil)
    }

    @Test func changedWritableBitCheckboxTurnsRedAndFlashes() throws {
        let panel = try makePanel(value: 0b00)
        panel.update(readings: ["DATA": .value(0b01)], for: Self.port)

        let pin0 = try node("PIN0", in: panel)
        let cell = try #require(valueCell(for: pin0, in: panel))
        let box = try #require(cell.subviews.first as? NSButton)
        #expect(box.state == .on)
        #expect(box.contentTintColor == DebugTableStyle.changedColor)
        #expect(cell.layer?.animation(forKey: "changedFlash") != nil)
    }

    @Test func bitRangeColumnUsesSecondaryColorAndRegisterHexDimsLeadingZeros() throws {
        let panel = try makePanel(value: 0x0000_0002)
        let dataNode = try #require(panel.nodes.first)
        let pin1 = try node("PIN1", in: panel)
        let mode = try node("MODE", in: panel)

        // Bit-range cells ([1], [5:4]) render in secondaryLabelColor.
        let pin1Loc = try #require(locationCell(for: pin1, in: panel)?.textField)
        #expect(pin1Loc.stringValue == "[1]")
        #expect(pin1Loc.textColor == .secondaryLabelColor)

        let modeLoc = try #require(locationCell(for: mode, in: panel)?.textField)
        #expect(modeLoc.stringValue == "[5:4]")
        #expect(modeLoc.textColor == .secondaryLabelColor)

        // Register value 0x00000002 dims "0x0000000" and highlights "2".
        let dataVal = try #require(valueCell(for: dataNode, in: panel)?.textField)
        #expect(dataVal.stringValue == "0x00000002")
        #expect(dataVal.attributedStringValue.attribute(.foregroundColor, at: 8, effectiveRange: nil) as? NSColor
            == DebugTableStyle.dimmedHexColor)
        #expect(dataVal.attributedStringValue.attribute(.foregroundColor, at: 9, effectiveRange: nil) as? NSColor
            == .labelColor)

        // Register address 0x400643FC dims "0x" and uses secondaryLabelColor for digits.
        let dataLoc = try #require(locationCell(for: dataNode, in: panel)?.textField)
        #expect(dataLoc.stringValue == "0x400643FC")
        #expect(dataLoc.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            == DebugTableStyle.dimmedHexColor)
        #expect(dataLoc.attributedStringValue.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor
            == .secondaryLabelColor)
    }

    @Test func clickingABitWritesOneOrZero() throws {
        let panel = try makePanel(value: 0)
        panel.isEditable = true
        var writes: [(String?, String)] = []
        panel.onWrite = { _, _, field, text in writes.append((field?.name, text)) }

        let pin0 = try #require(checkbox(for: try node("PIN0", in: panel), in: panel))
        pin0.state = .on
        panel.bitClicked(pin0)
        pin0.state = .off
        panel.bitClicked(pin0)

        #expect(writes.map(\.0) == ["PIN0", "PIN0"])
        #expect(writes.map(\.1) == ["1", "0"])
    }

    @Test func clickingWhileRunningWritesNothing() throws {
        let panel = try makePanel(value: 0)
        var wrote = false
        panel.onWrite = { _, _, _, _ in wrote = true }
        panel.isEditable = true
        let pin0 = try #require(checkbox(for: try node("PIN0", in: panel), in: panel))
        panel.isEditable = false

        pin0.state = .on
        panel.bitClicked(pin0)

        #expect(!wrote)
    }
}
