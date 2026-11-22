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

    private func checkbox(for node: PeripheralsViewController.Node, in panel: PeripheralsViewController) -> NSButton? {
        let row = panel.outlineView.row(forItem: node)
        let column = panel.outlineView.column(withIdentifier: NSUserInterfaceItemIdentifier("value"))
        let cell = panel.outlineView.view(atColumn: column, row: row, makeIfNecessary: true)
        return cell?.subviews.first as? NSButton
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
        #expect(!pin1.isEnabled)

        panel.isEditable = true
        let enabled = try #require(checkbox(for: try node("PIN1", in: panel), in: panel))
        #expect(enabled.isEnabled)
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
