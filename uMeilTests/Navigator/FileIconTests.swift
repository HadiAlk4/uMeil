import AppKit
import Testing
@testable import uMeil

@MainActor
struct FileIconTests {
    @Test func picksAnIconByKindOfFile() {
        #expect(FileIcon(name: "src", isDirectory: true) == .folder)
        #expect(FileIcon(name: "main.c", isDirectory: false) == .cSource)
        #expect(FileIcon(name: "uart.H", isDirectory: false) == .header)
        #expect(FileIcon(name: "startup_TM4C129.s", isDirectory: false) == .assembly)
        #expect(FileIcon(name: "tm4c1294ncpdt.ld", isDirectory: false) == .linkerScript)
        #expect(FileIcon(name: "Blinky.umeil", isDirectory: false) == .project)
        #expect(FileIcon(name: "Lab1.uvprojx", isDirectory: false) == .project)
        #expect(FileIcon(name: "Makefile", isDirectory: false) == .makefile)
        #expect(FileIcon(name: "README.md", isDirectory: false) == .text)
        #expect(FileIcon(name: "image.bin", isDirectory: false) == .other)
    }

    @Test func aFolderNamedLikeASourceIsStillAFolder() {
        #expect(FileIcon(name: "drivers.c", isDirectory: true) == .folder)
    }

    @Test func sourcesAndHeadersAreColoredApart() {
        #expect(FileIcon.cSource.color == .systemBlue)
        #expect(FileIcon.header.color == .systemPurple)
        #expect(FileIcon.linkerScript.color == .systemGray)
    }

    @Test func everyIconHasASymbol() {
        let all: [FileIcon] = [
            .folder, .cSource, .header, .assembly, .linkerScript, .project, .makefile, .text, .other
        ]
        for icon in all {
            #expect(icon.image != nil, "\(icon.symbolName) is not an SF Symbol")
        }
    }
}
