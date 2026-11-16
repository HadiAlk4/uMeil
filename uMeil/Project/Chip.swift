import Foundation

/// A microcontroller uMeil can build for. The raw value is the part number
/// stored in project files.
enum Chip: String, Codable, CaseIterable, Sendable {
    case tm4c1294ncpdt = "TM4C1294NCPDT"

    struct MemoryRegion: Equatable, Sendable {
        var origin: UInt32
        var length: UInt32
    }

    /// Compiler and linker flags that select the CPU core and FPU.
    var cpuFlags: [String] {
        ["-mcpu=cortex-m4", "-mthumb", "-mfpu=fpv4-sp-d16", "-mfloat-abi=hard"]
    }

    /// Preprocessor macros every source file for this chip is built with.
    /// TivaWare uses `PART_<chip>` to pick the pin and register definitions.
    var defines: [String] {
        ["PART_\(rawValue)"]
    }

    /// How many interrupts the chip has, on top of the 16 Cortex-M exceptions.
    var interruptCount: Int {
        114
    }

    var flash: MemoryRegion {
        MemoryRegion(origin: 0x0000_0000, length: 1024 * 1024)
    }

    var ram: MemoryRegion {
        MemoryRegion(origin: 0x2000_0000, length: 256 * 1024)
    }
}

/// A development board. The raw value is the name stored in project files.
enum Board: String, Codable, CaseIterable, Sendable {
    case ekTM4C1294XL = "EK-TM4C1294XL"

    var displayName: String {
        "EK-TM4C1294XL LaunchPad"
    }

    var chip: Chip {
        .tm4c1294ncpdt
    }

    /// Frequency of the main oscillator crystal fitted on the board.
    var crystalHz: Int {
        25_000_000
    }
}
