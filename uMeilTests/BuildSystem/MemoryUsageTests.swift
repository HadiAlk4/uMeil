import AppKit
import Testing
@testable import uMeil

struct MemoryUsageTests {
    private func usage(text: Int, data: Int, bss: Int) -> MemoryUsage {
        MemoryUsage(size: ProgramSize(text: text, data: data, bss: bss), chip: .tm4c1294ncpdt)
    }

    @Test func comparesTheProgramWithTheChipsMemory() {
        // Flash holds code and starting values; RAM holds all the variables.
        let usage = usage(text: 112 * 1024, data: 8 * 1024, bss: 22 * 1024)

        #expect(usage.flash.used == 120 * 1024)
        #expect(usage.flash.capacity == 1024 * 1024)
        #expect(usage.ram.used == 30 * 1024)
        #expect(usage.summary == "Flash 12% · RAM 12%")
    }

    @Test func showsSmallUsageWithADecimalAndASliverAsLessThanATenth() {
        #expect(usage(text: 47_186, data: 0, bss: 0).flash.percentText == "4.5%")
        #expect(usage(text: 100, data: 0, bss: 0).flash.percentText == "<0.1%")
        #expect(usage(text: 0, data: 0, bss: 0).ram.percentText == "0.0%")
    }

    @Test func warnsAsMemoryFillsUp() {
        let ram = 256 * 1024
        #expect(usage(text: 0, data: 0, bss: ram / 2).ram.level == .comfortable)
        #expect(usage(text: 0, data: 0, bss: ram * 8 / 10).ram.level == .tight)
        #expect(usage(text: 0, data: 0, bss: ram).ram.level == .full)
    }

    @Test func describesTheBytes() {
        #expect(usage(text: 1400, data: 0, bss: 0).flash.detailText.hasPrefix("Flash 1"))
        #expect(usage(text: 1400, data: 0, bss: 0).flash.detailText.hasSuffix("(0.1%)"))
    }
}

@MainActor
struct MemoryUsageBarTests {
    @Test func staysHiddenUntilABuildAndFillsItsMeters() {
        let bar = MemoryUsageBar()
        #expect(bar.isHidden)

        bar.show(MemoryUsage(size: ProgramSize(text: 900 * 1024, data: 0, bss: 1024), chip: .tm4c1294ncpdt))

        #expect(!bar.isHidden)
        #expect(bar.flashMeter.label.stringValue == "Flash 88%")
        #expect(bar.ramMeter.label.stringValue == "RAM 0.4%")
        #expect(bar.flashMeter.fraction > 0.87)
        bar.show(nil)
        #expect(bar.isHidden)
    }

    @Test func openingAnotherFolderHidesTheLastBuildsNumbers() throws {
        let controller = MainWindowController(boardMonitor: FakeBoardMonitor())
        controller.editor.memoryUsageBar.show(
            MemoryUsage(size: ProgramSize(text: 1, data: 0, bss: 0), chip: .tm4c1294ncpdt)
        )

        controller.openFolder(try TemporaryDirectory().url)

        #expect(controller.editor.memoryUsageBar.isHidden)
    }
}

/// With the real compiler.
@MainActor
@Suite(.enabled(if: BuildTestEnvironment.canBuild))
struct MemoryUsageAfterBuildTests {
    @Test func buildingBlinkyShowsHowFullFlashAndRAMAre() async throws {
        let folder = try TemporaryFolder()
        let controller = MainWindowController(defaults: TestDefaults())
        try controller.createProject(named: "Blinky", in: folder.url)

        let result = try #require(await controller.build())

        #expect(result.succeeded)
        let usage = try #require(controller.editor.memoryUsageBar.usage)
        #expect(usage.flash.used == result.size?.flash)
        #expect(usage.summary.hasPrefix("Flash "))
        #expect(!controller.editor.memoryUsageBar.isHidden)
    }
}
