import Foundation
import Testing
@testable import uMeil

struct FlashPlanTests {
    private func makePlan(image: String = "/tmp/Blinky/build/Blinky.elf") -> FlashPlan {
        FlashPlan(
            openOCD: URL(filePath: "/tools/bin/openocd"),
            image: URL(filePath: image),
            chip: .tm4c1294ncpdt
        )
    }

    /// The commands given to OpenOCD with `-c`, in order.
    private func commands(in plan: FlashPlan) -> [String] {
        plan.arguments.indices
            .filter { plan.arguments[$0] == "-c" }
            .map { plan.arguments[$0 + 1] }
    }

    @Test func startsWithTheBoardScript() {
        let plan = makePlan()

        #expect(Array(plan.arguments.prefix(2)) == ["-f", "board/ek-tm4c1294xl.cfg"])
        // Every other argument is a command.
        #expect(plan.arguments.count == 2 + 2 * commands(in: plan).count)
    }

    @Test func connectsWritesVerifiesAndRestartsInThatOrder() {
        let steps = commands(in: makePlan()).filter { !$0.hasPrefix("echo ") && !$0.hasPrefix("set umeil_chip") }

        #expect(steps == [
            "init",
            "reset init",
            "flash write_image erase \"/tmp/Blinky/build/Blinky.elf\"",
            "verify_image \"/tmp/Blinky/build/Blinky.elf\"",
            "reset run",
            "shutdown"
        ])
    }

    @Test func announcesEachStageBeforeItsCommand() {
        let commands = commands(in: makePlan())

        func index(of command: String) -> Int? {
            commands.firstIndex { $0.hasPrefix(command) }
        }
        let pairs = [
            ("echo \"uMeil: connected\"", "reset init"),
            ("echo \"uMeil: writing\"", "flash write_image"),
            ("echo \"uMeil: verifying\"", "verify_image"),
            ("echo \"uMeil: resetting\"", "reset run"),
            ("echo \"uMeil: done\"", "shutdown")
        ]
        for (marker, command) in pairs {
            let markerIndex = index(of: marker)
            #expect(markerIndex != nil, "Missing \(marker)")
            #expect(markerIndex.map { $0 + 1 } == index(of: command), "\(marker) should come just before \(command)")
        }
    }

    @Test func checksTheChipBeforeWritingAnything() throws {
        let commands = commands(in: makePlan())
        let check = try #require(commands.firstIndex { $0.contains("flash info 0") })
        let write = try #require(commands.firstIndex { $0.hasPrefix("flash write_image") })

        #expect(check < write)
        #expect(commands[check].contains("* TM4C1294NCPDT rev*"))
        #expect(commands[check].contains("echo \"uMeil: wrong chip\""))
        #expect(commands[check].contains("shutdown error"))
    }

    @Test func quotesFileNamesWithSpacesAndSpecialCharacters() {
        #expect(FlashPlan.tclQuoted("/Users/me/My Project/build/My Project.elf")
            == "\"/Users/me/My Project/build/My Project.elf\"")
        #expect(FlashPlan.tclQuoted(#"a"b$c[d]e\f"#) == #""a\"b\$c\[d]e\\f""#)

        let commands = commands(in: makePlan(image: "/tmp/My Project/build/My $Project.elf"))
        #expect(commands.contains(#"flash write_image erase "/tmp/My Project/build/My \$Project.elf""#))
    }

    @Test func markersNameTheirStage() {
        #expect(FlashPlan.marker(for: .writing) == "uMeil: writing")
        for stage in FlashStage.allCases {
            #expect(FlashOutput.stage(announcedBy: FlashPlan.marker(for: stage)) == stage)
        }
    }
}
