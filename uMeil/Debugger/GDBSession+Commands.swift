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

    /// The arguments and local variables of the frame at `level`.
    func variables(inFrame level: Int = 0) async throws -> [DebugVariable] {
        let command = "-stack-list-variables --thread 1 --frame \(level) --simple-values"
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
        let command = "-data-read-memory-bytes 0x\(String(address, radix: 16)) \(count)"
        guard let blocks = try await send(command)["memory"]?.list,
              let contents = blocks.first?.text("contents")
        else {
            throw DebugError.unexpectedAnswer(command)
        }
        // Two hex digits per byte, in address order.
        var bytes: [UInt8] = []
        var rest = Substring(contents)
        while rest.count >= 2, let byte = UInt8(rest.prefix(2), radix: 16) {
            bytes.append(byte)
            rest = rest.dropFirst(2)
        }
        return bytes
    }

    /// The value of a C expression in the current frame, as GDB prints it.
    func evaluate(_ expression: String) async throws -> String {
        let command = "-data-evaluate-expression \(DebugPlan.cQuoted(expression))"
        guard let value = try await send(command).text("value") else {
            throw DebugError.unexpectedAnswer(command)
        }
        return value
    }
}
