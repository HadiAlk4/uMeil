import Foundation

/// The debugger's actions, each one or two GDB/MI commands.
extension GDBSession {
    // MARK: - Starting

    /// Connects to the chip, writes the program to it, and runs to `main`.
    /// Returns once the program is running; the stop at `main` arrives on
    /// `events` like any other.
    func start(_ plan: DebugPlan) async throws {
        for command in plan.connectCommands + plan.loadCommands {
            try await send(command)
        }
    }

    // MARK: - Running

    /// Runs until a breakpoint, a pause, or a fault.
    func resume() async throws {
        try await send("-exec-continue")
    }

    /// Stops the program wherever it is.
    func pause() async throws {
        try await send("-exec-interrupt")
    }

    /// Runs the current line, treating a function call as one step.
    func stepOver() async throws {
        try await send("-exec-next")
    }

    /// Runs the current line, stopping inside a function it calls.
    func stepInto() async throws {
        try await send("-exec-step")
    }

    /// Runs until the current function returns to its caller.
    func stepOut() async throws {
        try await send("-exec-finish")
    }

    /// Runs until `line` of `file` is reached, or something else stops the
    /// program first.
    func run(toLine line: Int, of file: URL) async throws {
        try await send("-break-insert -t \(Self.location(file, line))")
        try await resume()
    }

    /// Resets the chip and leaves it stopped at its first instruction.
    /// Returns where that is.
    func reset() async throws -> StackFrame? {
        try await send(DebugPlan.resetCommand)
        // GDB was not told the chip moved, so make it forget what it read.
        try await send("-interpreter-exec console \"maintenance flush register-cache\"")
        return try await send("-stack-info-frame")["frame"].flatMap(StackFrame.init)
    }

    // MARK: - Breakpoints

    /// Sets a breakpoint. GDB moves it to the next line with code if `line`
    /// has none; the result says where it ended up.
    func insertBreakpoint(line: Int, of file: URL) async throws -> Breakpoint {
        let command = "-break-insert \(Self.location(file, line))"
        guard let breakpoint = try await send(command)["bkpt"].flatMap(Breakpoint.init) else {
            throw DebugError.unexpectedAnswer(command)
        }
        return breakpoint
    }

    func deleteBreakpoint(_ breakpoint: Breakpoint) async throws {
        try await send("-break-delete \(breakpoint.number)")
    }

    /// A place in the source, in the form that survives spaces in the path.
    private static func location(_ file: URL, _ line: Int) -> String {
        "--source \(DebugPlan.cQuoted(file.path(percentEncoded: false))) --line \(line)"
    }

    /// The lines of `file` that have machine code, where a breakpoint can
    /// stop. Empty if the file is not part of the program.
    func executableLines(of file: URL) async throws -> Set<Int> {
        let command = "-symbol-list-lines \(DebugPlan.cQuoted(file.path(percentEncoded: false)))"
        guard let lines = try await send(command)["lines"]?.list else {
            throw DebugError.unexpectedAnswer(command)
        }
        // GDB lists line 0 for code that belongs to no line.
        return Set(lines.compactMap { $0.integer("line") }.filter { $0 > 0 })
    }

    // MARK: - Looking at the stopped program

    /// The call stack, running function first.
    func frames() async throws -> [StackFrame] {
        let command = "-stack-list-frames"
        guard let frames = try await send(command)["stack"]?.list else {
            throw DebugError.unexpectedAnswer(command)
        }
        return frames.compactMap(StackFrame.init)
    }

    /// Selects the frame at `level` as GDB's active frame.
    func selectFrame(_ level: Int) async throws {
        try await send("-stack-select-frame \(level)")
    }

    /// The arguments and local variables of the frame at `level`.
    func variables(inFrame level: Int = 0) async throws -> [DebugVariable] {
        let command = "-stack-list-variables --thread \(currentThreadId) --frame \(level) --simple-values"
        guard let variables = try await send(command)["variables"]?.list else {
            throw DebugError.unexpectedAnswer(command)
        }
        return variables.compactMap(DebugVariable.init)
    }

    /// Every register GDB knows for the chip, in GDB's order: `r0` to `r12`,
    /// `sp`, `lr`, `pc`, `xpsr`, then the floating-point and special ones.
    func registers() async throws -> [RegisterValue] {
        if registerNames == nil {
            let command = "-data-list-register-names"
            guard let names = try await send(command)["register-names"]?.list else {
                throw DebugError.unexpectedAnswer(command)
            }
            registerNames = names.map { $0.string ?? "" }
        }
        let names = registerNames ?? []

        let command = "-data-list-register-values x"
        guard let values = try await send(command)["register-values"]?.list else {
            throw DebugError.unexpectedAnswer(command)
        }
        return values.compactMap { value in
            // GDB numbers registers with gaps; the gaps have empty names.
            guard let number = value.integer("number"), names.indices.contains(number),
                  !names[number].isEmpty
            else { return nil }
            return RegisterValue(name: names[number], value: value.address("value"))
        }
    }

    /// Reads `count` bytes of the chip's memory starting at `address`.
    func readMemory(at address: UInt64, count: Int) async throws -> [UInt8] {
        guard count > 0 else { return [] }
        let command = "-data-read-memory-bytes 0x\(String(address, radix: 16)) \(count)"
        guard let blocks = try await send(command)["memory"]?.list, !blocks.isEmpty else {
            throw DebugError.unexpectedAnswer(command)
        }

        var parsedBlocks: [(offset: UInt64, bytes: [UInt8])] = []
        parsedBlocks.reserveCapacity(blocks.count)
        for block in blocks {
            guard let contents = block.text("contents"),
                  let decoded = Self.decodeHexBytes(contents)
            else {
                throw DebugError.unexpectedAnswer(command)
            }
            let offset: UInt64
            if block["offset"] != nil {
                guard let parsedOffset = Self.parseOffset(block) else {
                    throw DebugError.unexpectedAnswer(command)
                }
                offset = parsedOffset
            } else if blocks.count == 1 {
                offset = 0
            } else {
                throw DebugError.unexpectedAnswer(command)
            }
            parsedBlocks.append((offset: offset, bytes: decoded))
        }
        parsedBlocks.sort { $0.offset < $1.offset }

        var bytes: [UInt8] = []
        for block in parsedBlocks {
            // Stop at any unreadable gap or overlap so bytes are never misaligned.
            guard block.offset == UInt64(bytes.count) else { break }
            bytes.append(contentsOf: block.bytes)
        }
        guard !bytes.isEmpty else {
            throw DebugError.unexpectedAnswer(command)
        }
        return bytes
    }

    private static func parseOffset(_ block: MIValue) -> UInt64? {
        if let address = block.address("offset") {
            return address
        }
        if let decimal = block.integer("offset"), decimal >= 0 {
            return UInt64(decimal)
        }
        return nil
    }

    private static func decodeHexBytes(_ contents: String) -> [UInt8]? {
        guard contents.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(contents.count / 2)
        var rest = Substring(contents)
        while rest.count >= 2 {
            guard let byte = UInt8(rest.prefix(2), radix: 16) else { return nil }
            bytes.append(byte)
            rest = rest.dropFirst(2)
        }
        return bytes
    }

    /// Writes `bytes` to the chip's memory starting at `address`, in address
    /// order. A peripheral register takes the write as the program's own
    /// store would, with the same effect on the hardware.
    func writeMemory(at address: UInt64, bytes: [UInt8]) async throws {
        guard !bytes.isEmpty else { return }
        let contents = bytes.map { String(format: "%02x", $0) }.joined()
        try await send("-data-write-memory-bytes 0x\(String(address, radix: 16)) \(contents)")
    }

    /// The value of a C expression in the current frame (or in frame `level`
    /// when specified), as GDB prints it.
    func evaluate(_ expression: String, inFrame level: Int? = nil) async throws -> String {
        let quoted = DebugPlan.cQuoted(expression)
        let command = if let level {
            "-data-evaluate-expression --thread \(currentThreadId) --frame \(level) \(quoted)"
        } else {
            "-data-evaluate-expression \(quoted)"
        }
        guard let value = try await send(command).text("value") else {
            throw DebugError.unexpectedAnswer(command)
        }
        return value
    }

    /// Disassembles `count` bytes starting at `address`, including source lines
    /// and raw opcodes.
    func disassemble(from address: UInt64, count: Int = 64) async throws -> [DisassembledInstruction] {
        let start = "0x" + String(address, radix: 16)
        let (endAddress, overflow) = address.addingReportingOverflow(UInt64(max(count, 4)))
        let end = "0x" + String(overflow ? UInt64.max : endAddress, radix: 16)
        let command = "-data-disassemble -s \(start) -e \(end) -- 5"
        guard let items = try await send(command)["asm_insns"]?.list else {
            throw DebugError.unexpectedAnswer(command)
        }
        return DisassembledInstruction.parseList(items)
    }

    /// Runs a GDB console command and echoes its output to the session stream.
    func executeConsole(_ command: String) async throws {
        try await send("-interpreter-exec console \(DebugPlan.cQuoted(command))")
    }
}
