import Foundation

/// A firmware image's size split the way Keil reports it after a build:
/// "Program Size: Code=1300 RO-data=96 RW-data=8 ZI-data=16".
struct SectionSizes: Equatable, Sendable {
    /// Instructions, in flash.
    var code = 0
    /// Constants, in flash.
    var readOnlyData = 0
    /// Variables with a starting value. They take up both flash and RAM.
    var readWriteData = 0
    /// Variables that start at zero. RAM only.
    var zeroInitializedData = 0

    /// The line Keil prints, so the numbers can be compared side by side.
    var keilSummary: String {
        "Program Size: Code=\(code) RO-data=\(readOnlyData) RW-data=\(readWriteData) ZI-data=\(zeroInitializedData)"
    }

    /// Reads the sizes from a linked image (`.elf` or `.axf`).
    ///
    /// Each section the chip holds at run time is counted by what it is
    /// allowed to do, not by its name: code can be executed, read-only data
    /// cannot be written, and zero-initialised data takes no room in the file.
    /// Constants only count as RO-data when the linker script gives them a
    /// section of their own; ones placed inside `.text` count as code.
    ///
    /// Returns `nil` if `file` is not a 32-bit little-endian ELF file.
    static func read(from file: URL) -> SectionSizes? {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        return parse([UInt8](data))
    }

    static func parse(_ bytes: [UInt8]) -> SectionSizes? {
        func word(_ offset: Int) -> Int? {
            guard offset >= 0, offset + 4 <= bytes.count else { return nil }
            return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
                | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
        }
        func half(_ offset: Int) -> Int? {
            guard offset >= 0, offset + 2 <= bytes.count else { return nil }
            return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
        }

        // "\u{7F}ELF", 32-bit, little-endian.
        guard bytes.count >= 52, bytes[0...3].elementsEqual([0x7F, 0x45, 0x4C, 0x46]),
              bytes[4] == 1, bytes[5] == 1,
              let tableOffset = word(0x20), let entrySize = half(0x2E), let entryCount = half(0x30),
              entrySize >= 40
        else { return nil }

        let writable = 0x1, allocated = 0x2, executable = 0x4
        let noBitsType = 8 // Takes up memory but no room in the file.

        var sizes = SectionSizes()
        for index in 0..<entryCount {
            let entry = tableOffset + index * entrySize
            // A table that runs off the end means the file was cut short.
            guard entry + entrySize <= bytes.count,
                  let type = word(entry + 4), let flags = word(entry + 8), let size = word(entry + 20)
            else { return nil }
            // Debug information and symbol tables are not loaded onto the chip.
            guard flags & allocated != 0 else { continue }

            if flags & executable != 0 {
                sizes.code += size
            } else if flags & writable == 0 {
                sizes.readOnlyData += size
            } else if type == noBitsType {
                sizes.zeroInitializedData += size
            } else {
                sizes.readWriteData += size
            }
        }
        return sizes
    }
}
