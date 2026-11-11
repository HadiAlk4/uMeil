import Foundation
import Testing
@testable import uMeil

/// The inputs here are real output from arm-none-eabi-gcc 15.2.1 and its
/// linker, saved with only the folder names shortened.
struct DiagnosticParserTests {
    private let project = URL(filePath: "/Users/me/Blinky", directoryHint: .isDirectory)

    private func file(_ path: String) -> URL {
        project.appending(path: path).standardizedFileURL
    }

    /// Compiling a file with several mistakes, including one in a header.
    private let compilerOutput = """
    In file included from src/bad.c:2:
    src/util.h: In function 'helper':
    src/util.h:1:48: error: expected ';' before '}' token
        1 | static int helper(int a) { int unused; return a }
          |                                                ^~
          |                                                ;
    src/util.h:1:32: warning: unused variable 'unused' [-Wunused-variable]
        1 | static int helper(int a) { int unused; return a }
          |                                ^~~~~~
    src/bad.c: In function 'main':
    src/bad.c:5:5: error: 'x' undeclared (first use in this function)
        5 |     x = 5;
          |     ^
    src/bad.c:5:5: note: each undeclared identifier is reported only once for each function it appears in
    src/bad.c:6:12: error: implicit declaration of function 'undefined_fn' [-Wimplicit-function-declaration]
        6 |     return undefined_fn(3);
          |            ^~~~~~~~~~~~
    src/bad.c:4:9: warning: unused variable 'y' [-Wunused-variable]
        4 |     int y;
          |         ^
    src/util.h: At top level:
    src/util.h:1:12: warning: 'helper' defined but not used [-Wunused-function]
        1 | static int helper(int a) { int unused; return a }
          |            ^~~~~~
    """

    @Test func parsesCompilerErrorsWarningsAndNotes() {
        let diagnostics = DiagnosticParser.parse(compilerOutput, workingDirectory: project)

        #expect(diagnostics == [
            Diagnostic(
                severity: .error,
                message: "expected ';' before '}' token",
                file: file("src/util.h"), line: 1, column: 48
            ),
            Diagnostic(
                severity: .warning,
                message: "unused variable 'unused' [-Wunused-variable]",
                file: file("src/util.h"), line: 1, column: 32
            ),
            Diagnostic(
                severity: .error,
                message: "'x' undeclared (first use in this function)",
                file: file("src/bad.c"), line: 5, column: 5
            ),
            Diagnostic(
                severity: .note,
                message: "each undeclared identifier is reported only once for each function it appears in",
                file: file("src/bad.c"), line: 5, column: 5
            ),
            Diagnostic(
                severity: .error,
                message: "implicit declaration of function 'undefined_fn' [-Wimplicit-function-declaration]",
                file: file("src/bad.c"), line: 6, column: 12
            ),
            Diagnostic(
                severity: .warning,
                message: "unused variable 'y' [-Wunused-variable]",
                file: file("src/bad.c"), line: 4, column: 9
            ),
            Diagnostic(
                severity: .warning,
                message: "'helper' defined but not used [-Wunused-function]",
                file: file("src/util.h"), line: 1, column: 12
            )
        ])
    }

    @Test func treatsAFatalErrorAsAnError() {
        let output = """
        src/bad.c: At top level:
        src/bad.c:3:10: fatal error: missing.h: No such file or directory
            3 | #include "missing.h"
              |          ^~~~~~~~~~~
        compilation terminated.
        """

        #expect(DiagnosticParser.parse(output, workingDirectory: project) == [
            Diagnostic(
                severity: .error,
                message: "missing.h: No such file or directory",
                file: file("src/bad.c"), line: 3, column: 10
            )
        ])
    }

    @Test func parsesAMissingSourceFileWithNoLocation() {
        let output = """
        cc1: fatal error: src/nope.c: No such file or directory
        compilation terminated.
        """

        #expect(DiagnosticParser.parse(output, workingDirectory: project) == [
            Diagnostic(severity: .error, message: "src/nope.c: No such file or directory")
        ])
    }

    /// The linker's own path contains a space here ("Application Support"),
    /// as it does when uMeil installed the toolchain itself.
    private let linker = "/Users/me/Library/Application Support/uMeil/Toolchains/arm-gnu-toolchain-15.2.rel1/bin/"
        + "../lib/gcc/arm-none-eabi/15.2.1/../../../../arm-none-eabi/bin/ld"

    @Test func parsesAnUndefinedReferenceFromTheLinker() {
        let output = """
        \(linker): build/warn.o: in function `main':
        /Users/me/Blinky/src/warn.c:7:(.text.main+0x4): undefined reference to `missing_function'
        \(linker): (missing_function): Unknown destination type (ARM/Thumb) in build/warn.o
        /Users/me/Blinky/src/warn.c:7:(.text.main+0x4): dangerous relocation: unsupported relocation
        collect2: error: ld returned 1 exit status
        """

        let diagnostics = DiagnosticParser.parse(output, workingDirectory: project)

        #expect(diagnostics == [
            Diagnostic(
                severity: .error,
                message: "undefined reference to `missing_function'",
                file: file("src/warn.c"), line: 7, column: nil
            ),
            Diagnostic(
                severity: .error,
                message: "(missing_function): Unknown destination type (ARM/Thumb) in build/warn.o"
            ),
            Diagnostic(
                severity: .error,
                message: "dangerous relocation: unsupported relocation",
                file: file("src/warn.c"), line: 7, column: nil
            ),
            Diagnostic(severity: .error, message: "ld returned 1 exit status")
        ])
    }

    @Test func parsesLinkerMessagesWithoutALocation() {
        let output = """
        \(linker): cannot find -lnope: No such file or directory
        \(linker): warning: build/Blinky.elf has a LOAD segment with RWX permissions
        collect2: error: ld returned 1 exit status
        """

        #expect(DiagnosticParser.parse(output, workingDirectory: project) == [
            Diagnostic(severity: .error, message: "cannot find -lnope: No such file or directory"),
            Diagnostic(severity: .warning, message: "build/Blinky.elf has a LOAD segment with RWX permissions"),
            Diagnostic(severity: .error, message: "ld returned 1 exit status")
        ])
    }

    @Test func parsesAMessageWithoutAColumn() {
        let assembler = "startup/startup.s:14: Error: bad instruction `nope'"
        let diagnostics = DiagnosticParser.parse(assembler, workingDirectory: project)

        // The assembler writes "Error" with a capital, which is not GCC's
        // format, so it is not recognised. This documents the current limit.
        #expect(diagnostics.isEmpty)

        let gcc = DiagnosticParser.parse("src/main.c:14: warning: something odd", workingDirectory: project)
        #expect(gcc == [
            Diagnostic(severity: .warning, message: "something odd", file: file("src/main.c"), line: 14, column: nil)
        ])
    }

    @Test func keepsAbsolutePathsAndResolvesRelativeOnes() {
        let output = """
        /opt/sdk/inc/board.h:9:1: warning: absolute
        ../shared/util.c:2:3: warning: relative
        """

        let files = DiagnosticParser.parse(output, workingDirectory: project).map(\.file?.path)

        #expect(files == ["/opt/sdk/inc/board.h", "/Users/me/shared/util.c"])
    }

    @Test func reportsARepeatedMessageOnce() {
        let line = "src/board.h:3:9: warning: 'LED' redefined\n"

        #expect(DiagnosticParser.parse(line + line + line, workingDirectory: project).count == 1)
    }

    @Test func ignoresOutputWithNoMessages() {
        #expect(DiagnosticParser.parse("", workingDirectory: project).isEmpty)
        #expect(DiagnosticParser.parse("compilation terminated.\n\n", workingDirectory: project).isEmpty)
    }
}
