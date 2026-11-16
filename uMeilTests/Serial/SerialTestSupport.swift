import Foundation
import os
@testable import uMeil

/// A pseudo-terminal standing in for a board's serial port.
///
/// The test plays the board through the "device" end; the code under test
/// opens `path`, which behaves like a real serial device.
final class PseudoTerminal {
    /// The device end: what is written here arrives at the port, and what
    /// the port sends can be read here.
    private(set) var device: Int32 = -1
    /// Kept open so the port's end exists for as long as the test runs.
    private var portEnd: Int32 = -1
    /// The path to open as a serial port.
    let path: String

    init() throws {
        guard openpty(&device, &portEnd, nil, nil, nil) == 0, let name = ttyname(portEnd) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        path = String(cString: name)
    }

    deinit {
        unplug()
        close(portEnd)
    }

    /// The terminal settings as seen from the port's end.
    var attributes: termios {
        var attributes = termios()
        tcgetattr(portEnd, &attributes)
        return attributes
    }

    /// Sends bytes as the board would.
    func send(_ bytes: [UInt8]) {
        _ = bytes.withUnsafeBytes { write(device, $0.baseAddress, $0.count) }
    }

    func send(_ text: String) {
        send(Array(text.utf8))
    }

    /// Waits for `count` bytes from the port. Returns what arrived within a
    /// few seconds, which is fewer than `count` if the port sent less.
    func receive(_ count: Int) -> [UInt8] {
        var received: [UInt8] = []
        var poller = pollfd(fd: device, events: Int16(POLLIN), revents: 0)
        while received.count < count, poll(&poller, 1, 3000) > 0 {
            var buffer = [UInt8](repeating: 0, count: count - received.count)
            let length = read(device, &buffer, buffer.count)
            guard length > 0 else { break }
            received += buffer[..<length]
        }
        return received
    }

    /// Makes the device go away, as if the board were unplugged. Anything
    /// sent that the port has not read yet is thrown away with it.
    func unplug() {
        guard device >= 0 else { return }
        close(device)
        device = -1
    }

    var info: SerialPortInfo {
        SerialPortInfo(path: path, usbDevice: nil)
    }
}

/// Collects what a port reports from its background queue.
final class SerialRecorder: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (data: Data(), disconnects: 0))

    var data: Data { state.withLock { $0.data } }
    var text: String { String(bytes: data, encoding: .utf8) ?? "" }
    var disconnects: Int { state.withLock { $0.disconnects } }

    func record(_ data: Data) {
        state.withLock { $0.data += data }
    }

    func recordDisconnect() {
        state.withLock { $0.disconnects += 1 }
    }

    func open(_ terminal: PseudoTerminal, baudRate: Int = SerialPort.defaultBaudRate) throws -> SerialPort {
        try SerialPort(
            path: terminal.path,
            baudRate: baudRate,
            onData: { [self] in record($0) },
            onDisconnect: { [self] in recordDisconnect() }
        )
    }
}

/// Waits until `condition` holds. Returns false if it still does not after a few seconds.
@MainActor
func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<500 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
