import Testing
@testable import uMeil

struct ToolVersionTests {
    @Test(arguments: [
        // Arm's official toolchain: the distribution name has its own version.
        ("arm-none-eabi-gcc (Arm GNU Toolchain 13.2.Rel1 (Build arm-13.7)) 13.2.1 20231009", ToolVersion(13, 2, 1)),
        // Older releases add a trailing "(release)" after the version.
        (
            "arm-none-eabi-gcc (GNU Arm Embedded Toolchain 10.3-2021.10) 10.3.1 20210824 (release)",
            ToolVersion(10, 3, 1)
        ),
        // The exact release in ToolchainCatalog.
        ("arm-none-eabi-gcc (Arm GNU Toolchain 15.2.Rel1 (Build arm-15.86)) 15.2.1 20251203", ToolVersion(15, 2, 1)),
        // Homebrew.
        ("arm-none-eabi-gcc (GCC) 14.2.0", ToolVersion(14, 2, 0)),
        ("arm-none-eabi-gcc (Homebrew GCC 16.2.0) 16.2.0", ToolVersion(16, 2, 0))
    ])
    func parsesCompilerVersions(line: String, expected: ToolVersion) {
        let output = line + "\nCopyright (C) 2023 Free Software Foundation, Inc.\n"
        #expect(ToolVersion.parse(versionOutput: output, for: .compiler) == expected)
    }

    @Test(arguments: [
        ("GNU gdb (Arm GNU Toolchain 13.2.Rel1 (Build arm-13.7)) 13.2.90.20231008-git", ToolVersion(13, 2, 90)),
        // The exact release in ToolchainCatalog.
        ("GNU gdb (Arm GNU Toolchain 15.2.Rel1 (Build arm-15.86)) 16.3.90.20250906-git", ToolVersion(16, 3, 90)),
        ("GNU gdb (GDB) 15.2", ToolVersion(15, 2, 0))
    ])
    func parsesDebuggerVersions(line: String, expected: ToolVersion) {
        let output = line + "\nCopyright (C) 2023 Free Software Foundation, Inc.\n"
        #expect(ToolVersion.parse(versionOutput: output, for: .debugger) == expected)
    }

    @Test(arguments: [
        ("Open On-Chip Debugger 0.12.0", ToolVersion(0, 12, 0)),
        ("xPack Open On-Chip Debugger 0.12.0+dev-01685-gb9224c0c0 (2024-08-02-19:51)", ToolVersion(0, 12, 0)),
        // The exact release in ToolchainCatalog.
        ("xPack Open On-Chip Debugger 0.12.0+dev-02228-ge5888bda3-dirty (2025-10-04-22:45)", ToolVersion(0, 12, 0)),
        // A stray line before the banner must not be mistaken for the version.
        ("Info 1.2.3 ready\nOpen On-Chip Debugger 0.11.0", ToolVersion(0, 11, 0))
    ])
    func parsesOpenOCDVersions(banner: String, expected: ToolVersion) {
        let output = banner + "\nLicensed under GNU GPL v2\n"
        #expect(ToolVersion.parse(versionOutput: output, for: .openOCD) == expected)
    }

    @Test func rejectsOutputWithoutAVersion() {
        #expect(ToolVersion.parse(versionOutput: "", for: .compiler) == nil)
        #expect(ToolVersion.parse(versionOutput: "command not found", for: .compiler) == nil)
        #expect(ToolVersion.parse(versionOutput: "some other program 1.2.3", for: .openOCD) == nil)
    }

    @Test func comparesNumerically() {
        #expect(ToolVersion(9, 10, 0) < ToolVersion(10, 2, 0))
        #expect(ToolVersion(13, 2, 1) < ToolVersion(13, 10, 0))
        #expect(ToolVersion(13, 2, 1) < ToolVersion(13, 2, 2))
        #expect(ToolVersion(13, 2).description == "13.2.0")
    }
}
