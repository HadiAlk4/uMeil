import Foundation
import Testing
@testable import uMeil

/// A session captured on 16 November 2026 from Arm GNU Toolchain 15.2's GDB
/// (16.3.90) and xPack OpenOCD 0.12.0-7, debugging Blinky on an
/// EK-TM4C1294XL. Only the project path was shortened.
enum BlinkySession {
    static let lines: [String] = {
        let bundle = Bundle(for: TemporaryFolder.self)
        guard let url = bundle.url(forResource: "BlinkySession", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }()

    /// The first captured line that starts with `prefix`.
    static func line(startingWith prefix: String) throws -> String {
        try #require(lines.first { $0.hasPrefix(prefix) })
    }
}

struct MIParserTests {
    // MARK: - The captured session

    @Test func everyLineOfTheCapturedSessionParses() throws {
        #expect(BlinkySession.lines.count > 100)
        for line in BlinkySession.lines where !line.isEmpty {
            #expect(throws: Never.self, "Could not parse: \(line)") {
                try MIParser.parse(line)
            }
        }
    }

    @Test func aBreakpointResultCarriesItsFields() throws {
        let record = try MIParser.parse(BlinkySession.line(startingWith: "^done,bkpt={number=\"2\""))

        guard case .result(nil, .done, let values) = record else {
            Issue.record("Expected a result, got \(record)")
            return
        }
        let breakpoint = try #require(values["bkpt"])
        #expect(breakpoint.text("number") == "2")
        #expect(breakpoint.address("addr") == 0x222)
        #expect(breakpoint.integer("line") == 28)
        #expect(breakpoint.text("fullname") == "/tmp/Blinky/src/main.c")
        #expect(breakpoint["thread-groups"] == .list([.string("i1")]))
    }

    @Test func aStopEventCarriesItsFrame() throws {
        let record = try MIParser.parse(
            BlinkySession.line(startingWith: "*stopped,reason=\"end-stepping-range\"")
        )

        guard case .event(.exec, "stopped", let values) = record else {
            Issue.record("Expected a stop event, got \(record)")
            return
        }
        #expect(values.text("reason") == "end-stepping-range")
        #expect(values["frame"]?.text("func") == "main")
        #expect(values["frame"]?["args"] == .list([]))
    }

    @Test func listsOfNamedItemsDropTheNames() throws {
        let record = try MIParser.parse(BlinkySession.line(startingWith: "^done,stack=["))

        guard case .result(_, .done, let values) = record else {
            Issue.record("Expected a result, got \(record)")
            return
        }
        let frames = try #require(values["stack"]?.list)
        #expect(frames.count == 1)
        #expect(frames.first?.integer("level") == 0)
    }

    @Test func streamTextHasItsEscapesUndone() throws {
        let source = try MIParser.parse(BlinkySession.line(startingWith: "~\"21\\t"))
        let error = try MIParser.parse(BlinkySession.line(startingWith: "^error,msg=\"No symbol"))

        #expect(source == .stream(kind: .console, text: "21\t    SysCtlPeripheralEnable(SYSCTL_PERIPH_GPION);\n"))
        guard case .result(_, .error, let values) = error else {
            Issue.record("Expected an error, got \(error)")
            return
        }
        #expect(values.text("msg") == "No symbol \"nosuchvar\" in current context.")
    }

    @Test func theProbesMessagesArriveAsTargetOutput() throws {
        #expect(try MIParser.parse(BlinkySession.line(startingWith: "@\"SRST"))
            == .stream(kind: .target, text: "SRST error\n"))
    }

    @Test func thePromptIsRecognisedWithAndWithoutItsTrailingSpace() throws {
        #expect(try MIParser.parse("(gdb) ") == .prompt)
        #expect(try MIParser.parse("(gdb)") == .prompt)
    }

    // MARK: - Written from the GDB manual's syntax, not captured

    @Test func aResultKeepsTheTokenItsCommandWasSentWith() throws {
        #expect(try MIParser.parse("42^running") == .result(token: 42, outcome: .running, values: .empty))
        #expect(try MIParser.parse("7^done,value=\"4\"")
            == .result(token: 7, outcome: .done, values: .tuple([MIField(name: "value", value: .string("4"))])))
    }

    @Test func valuesNestToAnyDepth() throws {
        let record = try MIParser.parse(#"^done,a={b=[{c="1"},{c="2"}],d={}},e=[]"#)

        guard case .result(_, _, let values) = record else {
            Issue.record("Expected a result, got \(record)")
            return
        }
        #expect(values["a"]?["b"]?.list?.map { $0.text("c") } == ["1", "2"])
        #expect(values["a"]?["d"] == .tuple([]))
        #expect(values["e"] == .list([]))
    }

    @Test func octalEscapesAreReadAsUTF8Bytes() throws {
        #expect(try MIParser.parse(#"~"caf\303\251 \\ \"q\"""#) == .stream(kind: .console, text: "café \\ \"q\""))
    }

    @Test func downloadProgressIsReadDespiteItsUnnamedTuple() throws {
        let record = try MIParser.parse(#"+download,{section=".text",section-sent="512",section-size="1144"}"#)

        guard case .event(.status, "download", let values) = record else {
            Issue.record("Expected a status event, got \(record)")
            return
        }
        #expect(values[""]?.integer("section-sent") == 512)
    }

    @Test func addressesIgnoreTheSymbolGDBAddsAfterThem() {
        #expect(MIValue.address("0x0000020a") == 0x20a)
        #expect(MIValue.address("0x40c <GPIOPinWrite>") == 0x40c)
        #expect(MIValue.address("main") == nil)
    }

    @Test(arguments: [
        "",
        "halted: PC: 0x00000224",
        "Info : clock speed 1 kHz",
        "^done,value=\"unterminated",
        "^done,value=",
        "^done,{",
        "^done,[",
        "^nonsense",
        "~\"text\"trailing"
    ])
    func linesThatAreNotGDBMIAreRefused(line: String) {
        #expect(throws: MIParseError(line: line)) {
            try MIParser.parse(line)
        }
    }

    @Test func nestingDepthIsCappedAtSixtyFour() throws {
        func nestedTuples(_ depth: Int) -> String {
            "^done," + String(repeating: "a={", count: depth) + String(repeating: "}", count: depth)
        }
        func nestedLists(_ depth: Int) -> String {
            "^done,a=" + String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        }

        _ = try MIParser.parse(nestedTuples(64))
        _ = try MIParser.parse(nestedLists(64))

        let tooDeepTuple = nestedTuples(65)
        let tooDeepList = nestedLists(65)
        #expect(throws: MIParseError(line: tooDeepTuple)) {
            try MIParser.parse(tooDeepTuple)
        }
        #expect(throws: MIParseError(line: tooDeepList)) {
            try MIParser.parse(tooDeepList)
        }
    }
}
