import Foundation
import Testing
@testable import uMeil

struct SectionSizesTests {
    /// One row of an ELF file's section table.
    private struct Section {
        var type: UInt32 = 1 // Holds bytes in the file.
        var flags: UInt32
        var size: UInt32
    }

    private static let writable: UInt32 = 0x1
    private static let allocated: UInt32 = 0x2
    private static let executable: UInt32 = 0x4

    /// A 32-bit little-endian ELF file with only a header and a section table.
    private func makeELF(_ sections: [Section]) -> [UInt8] {
        func word(_ value: UInt32) -> [UInt8] {
            [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24)]
        }
        var bytes = [UInt8](repeating: 0, count: 52)
        bytes.replaceSubrange(0..<6, with: [0x7F, 0x45, 0x4C, 0x46, 1, 1])
        bytes.replaceSubrange(0x20..<0x24, with: word(52)) // The table follows the header.
        bytes[0x2E] = 40 // Bytes per row.
        bytes[0x30] = UInt8(sections.count)
        for section in sections {
            var row = [UInt8](repeating: 0, count: 40)
            row.replaceSubrange(4..<8, with: word(section.type))
            row.replaceSubrange(8..<12, with: word(section.flags))
            row.replaceSubrange(20..<24, with: word(section.size))
            bytes += row
        }
        return bytes
    }

    @Test func sortsSectionsByWhatTheChipMayDoWithThem() throws {
        let elf = makeELF([
            Section(flags: Self.allocated | Self.executable, size: 1300), // .text
            Section(flags: Self.allocated, size: 96), // .rodata
            Section(flags: Self.allocated, size: 8), // .ARM.exidx
            Section(flags: Self.allocated | Self.writable, size: 12), // .data
            Section(type: 8, flags: Self.allocated | Self.writable, size: 1024), // .bss
            Section(flags: 0, size: 50_000) // Debug information: not on the chip.
        ])

        let sizes = try #require(SectionSizes.parse(elf))

        #expect(sizes == SectionSizes(code: 1300, readOnlyData: 104, readWriteData: 12, zeroInitializedData: 1024))
        #expect(sizes.keilSummary == "Program Size: Code=1300 RO-data=104 RW-data=12 ZI-data=1024")
    }

    @Test func givesNothingForFilesThatAreNotFirmware() {
        #expect(SectionSizes.parse([]) == nil)
        let source = "int main(void) { for (;;) {} } /* long enough to hold a header */"
        #expect(SectionSizes.parse([UInt8](source.utf8)) == nil)

        // A section table that runs off the end of the file.
        var cutShort = makeELF([Section(flags: Self.allocated, size: 4)])
        cutShort.removeLast(10)
        #expect(SectionSizes.parse(cutShort) == nil)

        #expect(SectionSizes.read(from: URL(filePath: "/nonexistent/Blinky.elf")) == nil)
    }
}
