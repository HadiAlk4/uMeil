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
