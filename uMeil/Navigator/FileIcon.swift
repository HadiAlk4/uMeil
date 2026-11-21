import AppKit

/// The small symbol the navigator shows next to a file or folder, tinted by
/// kind so sources, headers and build files are told apart at a glance.
enum FileIcon: Equatable {
    case folder
    case cSource
    case header
    case assembly
    case linkerScript
    case project
    case makefile
    case text
    case other

    init(name: String, isDirectory: Bool) {
        if isDirectory {
            self = .folder
            return
        }
        if name.caseInsensitiveCompare("Makefile") == .orderedSame {
            self = .makefile
            return
        }
        switch (name as NSString).pathExtension.lowercased() {
        case "c", "cpp", "cc", "cxx": self = .cSource
        case "h", "hpp", "hh": self = .header
        case "s", "asm": self = .assembly
        case "ld", "lds", "icf", "sct": self = .linkerScript
        case ProjectFile.fileExtension, KeilImporter.fileExtension: self = .project
        case "md", "txt", "rst": self = .text
        default: self = .other
        }
    }

    var symbolName: String {
        switch self {
        case .folder: "folder.fill"
        case .cSource: "c.square.fill"
        case .header: "h.square.fill"
        case .assembly: "a.square.fill"
        case .linkerScript: "map.fill"
        case .project: "hammer.fill"
        case .makefile: "gearshape.fill"
        case .text: "doc.text"
        case .other: "doc"
        }
    }

    var color: NSColor {
        switch self {
        case .folder: .secondaryLabelColor
        case .cSource: .systemBlue
        case .header: .systemPurple
        case .assembly: .systemOrange
        case .linkerScript: .systemGray
        case .project: .systemGreen
        case .makefile: .systemBrown
        case .text, .other: .secondaryLabelColor
        }
    }

    @MainActor
    var image: NSImage? {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        return image?.withSymbolConfiguration(config)
    }
}
