import Foundation
import Testing
@testable import uMeil

extension GDBSessionTests {
    // MARK: - Command injection hardening

    @Test func quotingEscapesLineBreaksAndStripsControlCharacters() {
        let dirty = "a\"b\\c\nd\re\r\nf\tg\u{00}h\u{01}\u{1F}\u{7F}i"
        #expect(DebugPlan.cQuoted(dirty) == #""a\"b\\c\nd\re\r\nf\tghi""#)

        let dirtyPath = "/tmp/it's\nhere\r\n\u{00}/openocd"
        #expect(DebugPlan.shellQuoted(dirtyPath) == "'/tmp/it'\\''shere/openocd'")
    }

    @Test(arguments: [
        "-exec-continue\n-gdb-exit",
        "-exec-continue\r-gdb-exit",
        "-exec-continue\r\n-gdb-exit",
        "-exec-continue\u{00}-gdb-exit"
    ])
    func sessionRejectsCommandsContainingNewlinesOrNul(command: String) async {
        let gdb = FakeDebugger()
        let session = GDBSession(connection: gdb)

        await #expect(throws: DebugError.refused("Invalid debugger command.")) {
            try await session.send(command)
        }
        #expect(gdb.commands.isEmpty)
    }

    @Test func gdbProcessDropsLinesWithNewlinesOrNulAndCollectsNoRetainedOutput() async throws {
        let process = try GDBProcess(URL(filePath: "/bin/cat"), arguments: [])
        defer { process.terminate() }

        process.send("bad\ninjected")
        process.send("bad\rinjected")
        process.send("bad\r\ninjected")
        process.send("bad\u{00}injected")
        process.send("good-line")

        var iterator = process.lines.makeAsyncIterator()
        let received = await iterator.next()
        #expect(received == "good-line")
        process.terminate()
    }
}
