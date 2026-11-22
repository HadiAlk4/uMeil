import Foundation

/// Inspecting the stopped program through `DebugController`.
extension DebugController {
    /// The active call stack frames, running function first. Empty unless stopped.
    func frames() async -> [StackFrame] {
        guard isStopped, let session else { return [] }
        return (try? await session.frames()) ?? []
    }

    /// The arguments and local variables of the frame at `level`.
    func variables(inFrame level: Int = 0) async -> [DebugVariable] {
        guard isStopped, let session else { return [] }
        return (try? await session.variables(inFrame: level)) ?? []
    }

    /// Every register GDB knows for the chip. Empty unless stopped.
    func registers() async -> [RegisterValue] {
        guard isStopped, let session else { return [] }
        return (try? await session.registers()) ?? []
    }

    /// Machine instructions starting at `address`. Empty unless stopped.
    func disassemble(from address: UInt64, count: Int = 64) async -> [DisassembledInstruction] {
        guard isStopped, let session else { return [] }
        return (try? await session.disassemble(from: address, count: count)) ?? []
    }

    /// Reads `count` bytes of the chip's memory starting at `address`, or
    /// fewer if flash or RAM ends sooner.
    func readMemory(at address: UInt64, count: Int = 64) async -> [UInt8]? {
        guard isStopped, let session else { return nil }
        let count = chip?.readableByteCount(at: address, count: count) ?? count
        return try? await session.readMemory(at: address, count: count)
    }

    /// Reads `count` bytes, throwing GDB's reason if it cannot: a peripheral
    /// whose clock is off cannot be read, for example.
    func readMemoryOrThrow(at address: UInt64, count: Int) async throws -> [UInt8] {
        guard isStopped, let session else { throw DebugError.refused("The program is not stopped.") }
        return try await session.readMemory(at: address, count: count)
    }

    /// Writes `bytes` to the chip's memory starting at `address`. Only while
    /// the program is stopped.
    func writeMemory(at address: UInt64, bytes: [UInt8]) async throws {
        guard isStopped, let session else { throw DebugError.refused("Stop the program to change memory.") }
        try await session.writeMemory(at: address, bytes: bytes)
    }

    /// Evaluates a C expression in the current frame (or frame `level` when
    /// given), returning `nil` if GDB refuses it.
    func evaluate(_ expression: String, inFrame level: Int? = nil) async -> String? {
        guard isStopped, let session else { return nil }
        return try? await session.evaluate(expression, inFrame: level)
    }

    /// Selects stack frame `level` in GDB so subsequent inspections run in that
    /// frame. No-op unless stopped.
    func selectFrame(_ level: Int) async {
        guard isStopped, let session else { return }
        try? await session.selectFrame(level)
    }

    /// Sends a console command to GDB.
    func sendConsoleCommand(_ command: String) async throws {
        guard let session else { throw DebugError.sessionEnded }
        try await session.executeConsole(command)
    }
}
