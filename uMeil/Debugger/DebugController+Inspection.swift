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

    /// Reads `count` bytes of the chip's memory starting at `address`.
    func readMemory(at address: UInt64, count: Int = 64) async -> [UInt8]? {
        guard isStopped, let session else { return nil }
        return try? await session.readMemory(at: address, count: count)
    }

    /// Evaluates a C expression in the current frame, returning `nil` if GDB refuses it.
    func evaluate(_ expression: String) async -> String? {
        guard isStopped, let session else { return nil }
        return try? await session.evaluate(expression)
    }

    /// Sends a console command to GDB.
    func sendConsoleCommand(_ command: String) async throws {
        guard let session else { throw DebugError.sessionEnded }
        try await session.executeConsole(command)
    }
}
