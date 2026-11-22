import Foundation

/// One function call on the call stack.
struct StackFrame: Equatable, Sendable {
    /// 0 is the function that is running; 1 is its caller, and so on.
    var level: Int
    var address: UInt64?
    /// `nil` when GDB has no symbol for the address.
    var function: String?
    /// The source file, when the code was built with debug information.
    var file: URL?
    /// The line in `file`, counting from 1.
    var line: Int?

    /// Reads GDB's `frame={level="0",addr="0x...",func="main",fullname="/...",line="21",...}`.
    init?(_ value: MIValue) {
        // The frame in a `*stopped` event has no level: it is always the top one.
        level = value.integer("level") ?? 0
        address = value.address("addr")
        function = value.text("func").flatMap { $0 == "??" ? nil : $0 }
        file = value.text("fullname").map { URL(filePath: $0, directoryHint: .notDirectory) }
        line = value.integer("line")
        guard address != nil || function != nil else { return nil }
    }
}

/// A breakpoint GDB has set.
struct Breakpoint: Equatable, Sendable {
    /// GDB's name for the breakpoint, used to remove it.
    var number: String
    var address: UInt64?
    var function: String?
    var file: URL?
    /// The line GDB chose, which is the next one with code when the
    /// requested line has none.
    var line: Int?
    var isEnabled: Bool

    /// Reads GDB's `bkpt={number="1",enabled="y",addr="0x...",fullname="/...",line="21",...}`.
    init?(_ value: MIValue) {
        guard let number = value.text("number") else { return nil }
        self.number = number
        address = value.address("addr")
        function = value.text("func")
        file = value.text("fullname").map { URL(filePath: $0, directoryHint: .notDirectory) }
        line = value.integer("line")
        isEnabled = value.text("enabled") != "n"
    }
}

/// Why the program stopped running.
enum StopReason: Equatable, Sendable {
    /// It reached breakpoint `number`.
    case breakpoint(number: String)
    /// A step over or step into finished.
    case stepFinished
    /// A step out finished: the function returned.
    case functionFinished
    /// A run to a line got there.
    case locationReached
    /// It was paused, or something else interrupted it.
    case signal(name: String, meaning: String?)
    /// The program ended. A microcontroller program never should.
    case exited
    /// A reason this build of uMeil does not know, as GDB named it. Empty
    /// when GDB gave none, as after connecting to a chip that is halted.
    case other(String)
}

/// The program stopped: GDB's `*stopped` event.
struct StopEvent: Equatable, Sendable {
    var reason: StopReason
    /// Where it stopped. `nil` when the program is gone.
    var frame: StackFrame?
    /// The thread that stopped, from GDB's `thread-id="..."`.
    var threadId: String?

    init(_ values: MIValue) {
        frame = values["frame"].flatMap(StackFrame.init)
        threadId = values.text("thread-id")
        switch values.text("reason") {
        case "breakpoint-hit":
            reason = .breakpoint(number: values.text("bkptno") ?? "")
        case "end-stepping-range":
            reason = .stepFinished
        case "function-finished":
            reason = .functionFinished
        case "location-reached":
            reason = .locationReached
        case "signal-received":
            reason = .signal(name: values.text("signal-name") ?? "", meaning: values.text("signal-meaning"))
        case "exited", "exited-normally", "exited-signalled":
            reason = .exited
        case let other:
            reason = .other(other ?? "")
        }
    }
}

/// A local variable or function argument, as GDB lists it for a frame.
struct DebugVariable: Equatable, Sendable {
    var name: String
    /// True for the function's parameters.
    var isArgument: Bool
    /// The C type, such as `int *`.
    var type: String?
    /// `nil` for arrays and structs, whose values GDB leaves out of a
    /// simple listing.
    var value: String?

    /// Reads GDB's `{name="a",arg="1",type="int",value="5"}`.
    init?(_ value: MIValue) {
        guard let name = value.text("name") else { return nil }
        self.name = name
        isArgument = value.text("arg") == "1"
        type = value.text("type")
        self.value = value.text("value")
    }
}

/// A CPU register and what it holds.
struct RegisterValue: Equatable, Sendable {
    /// The register's name, such as `r0`, `sp` or `xpsr`.
    var name: String
    /// `nil` when GDB could not read the register.
    var value: UInt64?
}

/// One machine instruction from GDB's `-data-disassemble`.
struct DisassembledInstruction: Equatable, Sendable {
    var address: UInt64
    var function: String?
    var offset: Int?
    /// The instruction's bytes in hex, such as `"00 22"`.
    var opcodes: String
    /// The assembly text, such as `"movs r2, #0"`.
    var instruction: String
    /// The source file and line, when GDB grouped instructions by line.
    var file: URL?
    var line: Int?

    /// Reads GDB's `{address="0x00000236",func-name="main",offset="46",opcodes="00 22",inst="movs\tr2, #0"}`.
    init?(_ value: MIValue, file: URL? = nil, line: Int? = nil) {
        guard let address = value.address("address"),
              let instruction = value.text("inst")
        else { return nil }
        self.address = address
        function = value.text("func-name")
        offset = value.integer("offset")
        opcodes = value.text("opcodes") ?? ""
        self.instruction = instruction.replacingOccurrences(of: "\t", with: " ")
        self.file = file
        self.line = line
    }

    /// Reads a flat list of instructions or `src_and_asm_line` tuples from `asm_insns`.
    static func parseList(_ items: [MIValue]) -> [DisassembledInstruction] {
        var result: [DisassembledInstruction] = []
        for item in items {
            if let nested = item["line_asm_insn"]?.list {
                let file = item.text("fullname").flatMap {
                    $0.isEmpty ? nil : URL(filePath: $0, directoryHint: .notDirectory)
                }
                // GDB reports line="0" for instructions with no associated source line.
                let line = item.integer("line").flatMap { $0 > 0 ? $0 : nil }
                result.append(contentsOf: nested.compactMap { DisassembledInstruction($0, file: file, line: line) })
            } else if let single = DisassembledInstruction(item) {
                result.append(single)
            }
        }
        return result
    }
}

/// What a debug session reports while it runs.
enum DebugEvent: Equatable, Sendable {
    /// The program started running. Nothing can be inspected until it stops.
    case running
    case stopped(StopEvent)
    /// A line for the command window: GDB's own output and OpenOCD's log.
    case output(String)
    /// GDB is gone, whether asked to quit or not.
    case ended
}

/// A command GDB refused, or one that could not be sent.
enum DebugError: Error, Equatable, LocalizedError {
    /// GDB's `^error,msg="..."`.
    case refused(String)
    /// GDB quit before answering.
    case sessionEnded
    /// GDB answered with something this build of uMeil cannot read.
    case unexpectedAnswer(String)

    var errorDescription: String? {
        switch self {
        case .refused(let message):
            message
        case .sessionEnded:
            "The debugger stopped unexpectedly."
        case .unexpectedAnswer(let command):
            "The debugger gave an answer uMeil could not read to \"\(command)\"."
        }
    }
}
