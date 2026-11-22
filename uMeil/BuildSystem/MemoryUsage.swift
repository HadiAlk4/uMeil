import Foundation

/// How much of the chip's flash and RAM a built program takes, for the bar
/// under the editor: "Flash 12% · RAM 3%".
struct MemoryUsage: Equatable, Sendable {
    struct Region: Equatable, Sendable {
        var name: String
        var used: Int
        var capacity: Int

        var fraction: Double {
            capacity > 0 ? Double(used) / Double(capacity) : 0
        }

        /// "12%", "4.5%", or "<0.1%" for a sliver, so a tiny program does
        /// not read as empty.
        var percentText: String {
            let percent = fraction * 100
            if used > 0, percent < 0.1 { return "<0.1%" }
            if percent < 10 { return String(format: "%.1f%%", percent) }
            return "\(Int(percent.rounded()))%"
        }

        /// For example "Flash 1.4 KB of 1 MB (0.1%)".
        var detailText: String {
            let usedText = ByteCountFormatter.string(fromByteCount: Int64(used), countStyle: .memory)
            let capacityText = ByteCountFormatter.string(fromByteCount: Int64(capacity), countStyle: .memory)
            return "\(name) \(usedText) of \(capacityText) (\(percentText))"
        }

        /// Whether the program is close to not fitting.
        var level: Level {
            switch fraction {
            case ..<0.75: .comfortable
            case ..<0.9: .tight
            default: .full
            }
        }
    }

    enum Level: Equatable, Sendable {
        case comfortable, tight, full
    }

    var flash: Region
    var ram: Region

    init(size: ProgramSize, chip: Chip) {
        flash = Region(name: "Flash", used: size.flash, capacity: Int(chip.flash.length))
        ram = Region(name: "RAM", used: size.ram, capacity: Int(chip.ram.length))
    }

    /// "Flash 0.1% · RAM 3.2%"
    var summary: String {
        "\(flash.name) \(flash.percentText) · \(ram.name) \(ram.percentText)"
    }
}
