import AppKit
import Foundation
import Testing
@testable import uMeil

/// The first 20 bytes of a firmware file, for tests to vary.
private struct ELFHeader {
    var magic: [UInt8] = [0x7F, 0x45, 0x4C, 0x46]
    var wordSize: UInt8 = 1 // 32-bit
    var byteOrder: UInt8 = 1 // little-endian
    var kind: UInt8 = 2 // a program
    var machine: UInt8 = 40 // Arm

    var data: Data {
        Data(magic + [wordSize, byteOrder, 1, 0] + [UInt8](repeating: 0, count: 8) + [kind, 0, machine, 0])
    }

    /// Writes a file that starts with this header into `folder`.
    func write(named name: String = "Template.axf", in folder: TemporaryFolder) throws -> URL {
        let url = folder.url.appending(path: name)
        try (data + Data(repeating: 0, count: 64)).write(to: url)
        return url
    }
}

/// Product > Flash Image…: writing a firmware file that was built somewhere
/// else, such as Keil's `.axf`.
struct FlashImageTests {
    // MARK: - Recognising firmware

    @Test func anArmProgramIsRecognised() throws {
        let folder = try TemporaryFolder()
        #expect(try FirmwareImage.isArmProgram(ELFHeader().write(in: folder)))
    }

    @Test func otherFilesAreNotFirmware() throws {
        let folder = try TemporaryFolder()
        let text = folder.url.appending(path: "main.axf")
        try Data("int main(void) { for (;;) {} }\n".utf8).write(to: text)
        let tooShort = folder.url.appending(path: "short.elf")
        try Data([0x7F, 0x45, 0x4C, 0x46]).write(to: tooShort)

        #expect(!FirmwareImage.isArmProgram(text))
        #expect(!FirmwareImage.isArmProgram(tooShort))
        #expect(!FirmwareImage.isArmProgram(folder.url.appending(path: "missing.axf")))
        // A program for a Mac, an object file, and a 64-bit Arm program.
        #expect(try !FirmwareImage.isArmProgram(ELFHeader(machine: 62).write(named: "x86.elf", in: folder)))
        #expect(try !FirmwareImage.isArmProgram(ELFHeader(kind: 1).write(named: "main.o", in: folder)))
        #expect(try !FirmwareImage.isArmProgram(ELFHeader(wordSize: 2).write(named: "arm64.elf", in: folder)))
    }

    // MARK: - Planning

    private func locatorWithOpenOCD(in folder: TemporaryFolder) throws -> ToolLocator {
        let bin = folder.url.appending(path: "bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FakeTool.install(.openOCD, in: bin, script: "exit 0")
        return ToolLocator(searchDirectories: [bin])
    }

    @Test func thePlanWritesTheChosenFileToTheLaunchPadsChip() throws {
        let folder = try TemporaryFolder()
        let image = try ELFHeader().write(in: folder)

        let plan = try Flasher.plan(forImage: image, locator: locatorWithOpenOCD(in: folder))

        #expect(plan.image == image)
        #expect(plan.chip == .tm4c1294ncpdt)
        let file = FlashPlan.tclQuoted(image.path(percentEncoded: false))
        #expect(plan.arguments.contains("flash write_image erase \(file)"))
    }

    @Test func aFileThatIsNotFirmwareIsRefusedBeforeOpenOCDRuns() throws {
        let folder = try TemporaryFolder()
        let notes = folder.url.appending(path: "notes.axf")
        try Data("These are my lab notes, not a program.".utf8).write(to: notes)
        let locator = try locatorWithOpenOCD(in: folder)

        #expect(throws: FlashFailure.notAnImage(notes)) {
            try Flasher.plan(forImage: notes, locator: locator)
        }
        let missing = folder.url.appending(path: "missing.axf")
        #expect(throws: FlashFailure.imageNotFound(missing)) {
            try Flasher.plan(forImage: missing, locator: locator)
        }
    }

    @Test func missingOpenOCDIsReported() throws {
        let folder = try TemporaryFolder()
        let image = try ELFHeader().write(in: folder)

        #expect(throws: FlashFailure.openOCDNotFound) {
            try Flasher.plan(forImage: image, locator: ToolLocator(searchDirectories: []))
        }
    }

    // MARK: - From the window

    @MainActor
    private func makeWindow(in folder: TemporaryFolder, openOCD: FakeOpenOCD) throws -> MainWindowController {
        let defaults = TestDefaults()
        let controller = MainWindowController(defaults: defaults, boardMonitor: FakeBoardMonitor())
        controller.flasher = Flasher(runner: openOCD)
        let locator = try locatorWithOpenOCD(in: folder)
        controller.makeToolLocator = { locator }
        return controller
    }

    @MainActor
    @Test func anImageIsFlashedWithNoProjectOpen() async throws {
        let folder = try TemporaryFolder()
        let openOCD = FakeOpenOCD(log: FlashLog.success)
        let controller = try makeWindow(in: folder, openOCD: openOCD)
        let image = try ELFHeader().write(in: folder)
        let item = NSMenuItem(title: "", action: #selector(MainWindowController.flashImage(_:)), keyEquivalent: "")
        #expect(controller.folder == nil)
        #expect(controller.validateMenuItem(item))

        let result = try #require(await controller.flash(image: image))

        #expect(result.succeeded)
        #expect(controller.isIssuesPanelVisible)
        #expect(controller.issues.statusLabel.stringValue == "Flashed: 16 KB written to the board")
        #expect(controller.issues.diagnostics.isEmpty)
        #expect(!controller.isFlashing)
        let arguments = try #require(openOCD.calls.withLock { $0 }.first)
        #expect(arguments.contains("flash write_image erase \(FlashPlan.tclQuoted(image.path(percentEncoded: false)))"))
    }

    @MainActor
    @Test func aWrongFileIsExplainedAndNothingIsSentToTheBoard() async throws {
        let folder = try TemporaryFolder()
        let openOCD = FakeOpenOCD(log: FlashLog.success)
        let controller = try makeWindow(in: folder, openOCD: openOCD)
        let notes = folder.url.appending(path: "notes.axf")
        try Data("not a program".utf8).write(to: notes)

        let result = try #require(await controller.flash(image: notes))

        #expect(result.failure == .notAnImage(notes))
        #expect(openOCD.calls.withLock { $0 }.isEmpty)
        #expect(controller.issues.statusLabel.stringValue == "Flash failed")
        #expect(controller.issues.diagnostics.first?.message.hasPrefix("notes.axf is not a firmware image") == true)
    }

    @MainActor
    @Test func flashImageIsNotOfferedWhileAFlashIsRunning() throws {
        let folder = try TemporaryFolder()
        let controller = try makeWindow(in: folder, openOCD: FakeOpenOCD(log: FlashLog.success))
        let item = NSMenuItem(title: "", action: #selector(MainWindowController.flashImage(_:)), keyEquivalent: "")

        controller.isFlashing = true

        #expect(!controller.validateMenuItem(item))
    }

    @MainActor
    @Test func theProductMenuOffersFlashImage() throws {
        let menu = MainMenu.make(appName: "uMeil")
        let product = try #require(menu.items.compactMap(\.submenu).first { $0.title == "Product" })

        let item = try #require(product.items.first { $0.title == "Flash Image…" })
        #expect(item.action == #selector(MainWindowController.flashImage(_:)))
    }
}
