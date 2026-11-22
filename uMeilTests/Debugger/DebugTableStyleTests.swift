import AppKit
import Testing
@testable import uMeil

@MainActor
struct DebugTableStyleTests {
    @Test func flashesOnlyRightAfterAnUpdate() {
        let update = Date(timeIntervalSince1970: 1_000)

        #expect(DebugTableStyle.shouldFlash(since: update, now: update.addingTimeInterval(0.1)))
        #expect(!DebugTableStyle.shouldFlash(since: update, now: update.addingTimeInterval(2)))
        #expect(!DebugTableStyle.shouldFlash(since: nil))
    }

    @Test func aChangedValueIsRedAndGlows() {
        let label = NSTextField(labelWithString: "0x00000001")

        DebugTableStyle.markChanged(label, flash: true)

        #expect(label.textColor == .systemRed)
        #expect(label.layer?.animation(forKey: "changedFlash") != nil)
    }

    @Test func colorsOnlyTheChangedHexBytes() {
        let text = DebugTableStyle.hexBytes("0A 0B 0C", changedOffsets: [1])

        func color(at index: Int) -> NSColor? {
            text.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
        }
        #expect(color(at: 0) == .labelColor)
        #expect(color(at: 3) == .systemRed)
        #expect(color(at: 4) == .systemRed)
        #expect(color(at: 6) == .labelColor)
    }

    @Test func memoryHexBytesDimUnchangedZeroBytesButKeepChangedZeroBytesRed() {
        let text = DebugTableStyle.hexBytes("00 0A 00 FF", changedOffsets: [2])

        func color(at index: Int) -> NSColor? {
            text.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
        }
        #expect(color(at: 0) == DebugTableStyle.dimmedHexColor)
        #expect(color(at: 1) == DebugTableStyle.dimmedHexColor)
        #expect(color(at: 3) == .labelColor)
        #expect(color(at: 4) == .labelColor)
        #expect(color(at: 6) == .systemRed)
        #expect(color(at: 7) == .systemRed)
        #expect(color(at: 9) == .labelColor)
        #expect(color(at: 10) == .labelColor)
    }

    @Test func hexDimmingHighlightsMeaningfulDigitsAcrossZeroPartialAndFullValues() {
        func colors(in styled: NSAttributedString) -> [NSColor?] {
            (0..<styled.length).map { styled.attribute(.foregroundColor, at: $0, effectiveRange: nil) as? NSColor }
        }

        // 0x0000022E: "0x00000" dimmed, "22E" bright.
        let partial = DebugTableStyle.styledHex("0x0000022E")
        let partialColors = colors(in: partial)
        #expect(partialColors[0..<7].allSatisfy { $0 == DebugTableStyle.dimmedHexColor })
        #expect(partialColors[7..<10].allSatisfy { $0 == .labelColor })

        // 0x00000000: "0x0000000" dimmed, final "0" stays bright.
        let zero = DebugTableStyle.styledHex("0x00000000")
        let zeroColors = colors(in: zero)
        #expect(zeroColors[0..<9].allSatisfy { $0 == DebugTableStyle.dimmedHexColor })
        #expect(zeroColors[9] == .labelColor)

        // 0xFFFFFFFF: only "0x" prefix dimmed, all 8 digits stay bright.
        let allOnes = DebugTableStyle.styledHex("0xFFFFFFFF")
        let allOnesColors = colors(in: allOnes)
        #expect(allOnesColors[0..<2].allSatisfy { $0 == DebugTableStyle.dimmedHexColor })
        #expect(allOnesColors[2..<10].allSatisfy { $0 == .labelColor })

        // 64-bit hex and embedded literals.
        #expect(DebugValueFormatter.dimmedHexRanges(in: "0x0000000000000005") == [NSRange(location: 0, length: 17)])
        #expect(DebugValueFormatter.dimmedHexRanges(in: "0x0000000000000000") == [NSRange(location: 0, length: 17)])
        #expect(DebugValueFormatter.dimmedHexRanges(in: "0x0") == [NSRange(location: 0, length: 2)])
        #expect(DebugValueFormatter.dimmedHexRanges(in: "(int *) 0x00000258 <main>")
            == [NSRange(location: 8, length: 7)])
        #expect(DebugValueFormatter.dimmedHexRanges(in: "{a = 0x00000001, b = 0x00000000}")
            == [NSRange(location: 5, length: 9), NSRange(location: 21, length: 9)])

        // Non-hex strings and invalid tokens are untouched.
        #expect(DebugValueFormatter.dimmedHexRanges(in: "42").isEmpty)
        #expect(DebugValueFormatter.dimmedHexRanges(in: "-99").isEmpty)
        #expect(DebugValueFormatter.dimmedHexRanges(in: "Thread").isEmpty)
        #expect(DebugValueFormatter.dimmedHexRanges(in: "—").isEmpty)
        #expect(DebugValueFormatter.dimmedHexRanges(in: "0x").isEmpty)
        #expect(DebugValueFormatter.dimmedHexRanges(in: "0x00G").isEmpty)
        #expect(DebugValueFormatter.dimmedHexRanges(in: "foo0x0001").isEmpty)
    }

    @Test func changedHexValuesUseDimmedRedPrefixBrightRedDigitsAndPreserveFlash() {
        let label = NSTextField(labelWithString: "")

        DebugTableStyle.applyValue("0x0000022E", to: label, isChanged: true, flash: true)

        #expect(label.stringValue == "0x0000022E")
        let styled = label.attributedStringValue
        #expect(styled.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            == DebugTableStyle.dimmedChangedColor)
        #expect(styled.attribute(.foregroundColor, at: 6, effectiveRange: nil) as? NSColor
            == DebugTableStyle.dimmedChangedColor)
        #expect(styled.attribute(.foregroundColor, at: 7, effectiveRange: nil) as? NSColor
            == DebugTableStyle.changedColor)
        #expect(styled.attribute(.foregroundColor, at: 9, effectiveRange: nil) as? NSColor
            == DebugTableStyle.changedColor)
        #expect(label.layer?.animation(forKey: "changedFlash") != nil)

        // Changed zero still leaves the trailing 0 in full red.
        let zeroLabel = NSTextField(labelWithString: "")
        DebugTableStyle.applyValue("0x00000000", to: zeroLabel, isChanged: true, flash: false)
        let zeroStyled = zeroLabel.attributedStringValue
        #expect(zeroStyled.attribute(.foregroundColor, at: 8, effectiveRange: nil) as? NSColor
            == DebugTableStyle.dimmedChangedColor)
        #expect(zeroStyled.attribute(.foregroundColor, at: 9, effectiveRange: nil) as? NSColor
            == DebugTableStyle.changedColor)
        #expect(zeroLabel.layer?.animation(forKey: "changedFlash") == nil)
    }

    private func cellColor(in table: NSTableView, column: Int, row: Int, at index: Int) -> NSColor? {
        let cell = table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView
        return cell?.textField?.attributedStringValue.attribute(.foregroundColor, at: index, effectiveRange: nil)
            as? NSColor
    }

    @Test func registersAndCallStackStyleHexValuesConsistently() throws {
        // Registers: unchanged zero keeps last 0 bright; changed PC dims leading zeros in red with flash.
        let registers = RegistersViewController()
        registers.update(with: [
            RegisterValue(name: "r0", value: 0),
            RegisterValue(name: "pc", value: 0x0000_020A)
        ])
        registers.update(with: [
            RegisterValue(name: "r0", value: 0),
            RegisterValue(name: "pc", value: 0x0000_022E)
        ])
        #expect(cellColor(in: registers.outlineView, column: 1, row: 0, at: 8) == DebugTableStyle.dimmedHexColor)
        #expect(cellColor(in: registers.outlineView, column: 1, row: 0, at: 9) == .labelColor)

        let pcCell = try #require(
            registers.outlineView.view(atColumn: 1, row: 1, makeIfNecessary: true) as? NSTableCellView
        )
        #expect(cellColor(in: registers.outlineView, column: 1, row: 1, at: 6) == DebugTableStyle.dimmedChangedColor)
        #expect(cellColor(in: registers.outlineView, column: 1, row: 1, at: 7) == DebugTableStyle.changedColor)
        #expect(pcCell.textField?.layer?.animation(forKey: "changedFlash") != nil)

        // Call Stack + Locals: frame address and hex locals dim leading zeros.
        let stack = CallStackLocalsViewController()
        let frame = try #require(StackFrame(.tuple([
            MIField(name: "level", value: .string("0")),
            MIField(name: "addr", value: .string("0x0000020a")),
            MIField(name: "func", value: .string("main"))
        ])))
        let localVar = try #require(DebugVariable(.tuple([
            MIField(name: "name", value: .string("count")),
            MIField(name: "type", value: .string("int")),
            MIField(name: "value", value: .string("5"))
        ])))
        stack.update(frames: [frame], variablesByFrame: [0: [localVar]])
        #expect(cellColor(in: stack.outlineView, column: 1, row: 0, at: 6) == DebugTableStyle.dimmedHexColor)
        #expect(cellColor(in: stack.outlineView, column: 1, row: 0, at: 7) == .labelColor)
        #expect(cellColor(in: stack.outlineView, column: 1, row: 1, at: 8) == DebugTableStyle.dimmedHexColor)
        #expect(cellColor(in: stack.outlineView, column: 1, row: 1, at: 9) == .labelColor)
    }

    @Test func watchMemoryAndDisassemblyStyleHexValuesConsistently() throws {
        // Watch: hex values dim leading zeros and keep changed flash.
        let watch = WatchViewController()
        watch.addExpression("reg")
        watch.updateValues(["reg": "0x00000001"])
        watch.updateValues(["reg": "0x0000022E"])
        let watchCell = try #require(
            watch.tableView.view(atColumn: 1, row: 0, makeIfNecessary: true) as? NSTableCellView
        )
        #expect(cellColor(in: watch.tableView, column: 1, row: 0, at: 6) == DebugTableStyle.dimmedChangedColor)
        #expect(cellColor(in: watch.tableView, column: 1, row: 0, at: 7) == DebugTableStyle.changedColor)
        #expect(watchCell.textField?.layer?.animation(forKey: "changedFlash") != nil)

        // Memory: address column dims leading zeros, hex column dims 00 bytes.
        let memory = MemoryViewController()
        memory.showMemory(at: 0x0000_0200, bytes: [0x00, 0x2E])
        #expect(cellColor(in: memory.tableView, column: 0, row: 0, at: 6) == DebugTableStyle.dimmedHexColor)
        #expect(cellColor(in: memory.tableView, column: 0, row: 0, at: 7) == .labelColor)
        #expect(cellColor(in: memory.tableView, column: 1, row: 0, at: 0) == DebugTableStyle.dimmedHexColor)
        #expect(cellColor(in: memory.tableView, column: 1, row: 0, at: 3) == .labelColor)

        // Disassembly: address and instruction hex literals dim leading zeros.
        let disasm = DisassemblyViewController()
        let inst = try #require(DisassembledInstruction(.tuple([
            MIField(name: "address", value: .string("0x0000022e")),
            MIField(name: "opcodes", value: .string("00 f0")),
            MIField(name: "inst", value: .string("bl 0x00000410"))
        ])))
        disasm.update(instructions: [inst], programCounter: 0x22E)
        #expect(cellColor(in: disasm.tableView, column: 1, row: 0, at: 6) == DebugTableStyle.dimmedHexColor)
        #expect(cellColor(in: disasm.tableView, column: 1, row: 0, at: 7) == .labelColor)
        #expect(cellColor(in: disasm.tableView, column: 3, row: 0, at: 9) == DebugTableStyle.dimmedHexColor)
        #expect(cellColor(in: disasm.tableView, column: 3, row: 0, at: 10) == .labelColor)
    }

    @Test func memoryMarksTheBytesThatChangedSinceTheLastRead() {
        let memory = MemoryViewController()
        memory.showMemory(at: 0x2000_0000, bytes: [1, 2, 3, 4])
        #expect(memory.changedAddresses.isEmpty)

        memory.showMemory(at: 0x2000_0000, bytes: [1, 9, 3, 7])

        #expect(memory.changedAddresses == [0x2000_0001, 0x2000_0003])
        #expect(memory.changedOffsets(inRow: 0) == [1, 3])
    }

    @Test func memoryAtANewAddressStartsWithNothingChanged() {
        let memory = MemoryViewController()
        memory.showMemory(at: 0x2000_0000, bytes: [1, 2, 3, 4])

        memory.showMemory(at: 0x2000_1000, bytes: [5, 6, 7, 8])

        #expect(memory.changedAddresses.isEmpty)
    }

    @Test func clearingMemoryForgetsWhatItShowed() {
        let memory = MemoryViewController()
        memory.showMemory(at: 0x2000_0000, bytes: [1])
        memory.clear()

        memory.showMemory(at: 0x2000_0000, bytes: [2])

        #expect(memory.changedAddresses.isEmpty)
    }
}
