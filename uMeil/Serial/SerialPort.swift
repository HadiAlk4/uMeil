import Foundation

/// Why a serial port could not be used.
enum SerialPortError: Error, Equatable, LocalizedError {
    /// The port could not be opened. `code` is the `errno` value.
    case cannotOpen(path: String, code: Int32)
    /// The port opened but would not take the speed and framing.
    case cannotConfigure(path: String, code: Int32)
    case writeFailed(code: Int32)
    /// The port has been closed, or the device was unplugged.
    case notOpen

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let path, let code):
            let name = URL(filePath: path).lastPathComponent
            switch code {
            case EBUSY: return "\(name) is in use by another app."
            case ENOENT, ENXIO: return "\(name) is no longer there. Check that the board is plugged in."
            case EACCES, EPERM: return "uMeil is not allowed to open \(name)."
            default: return "Could not open \(name): \(String(cString: strerror(code)))."
            }
        case .cannotConfigure(let path, let code):
            let name = URL(filePath: path).lastPathComponent
            return "Could not set up \(name): \(String(cString: strerror(code)))."
        case .writeFailed(let code):
            return "Could not send: \(String(cString: strerror(code)))."
        case .notOpen:
            return "The port is not open."
        }
    }
}

/// An open serial port, set up for raw 8N1 bytes with no flow control.
///
/// Uses the POSIX `termios` calls directly. Bytes that arrive are handed to
/// `onData` on a background queue. The port closes when `close()` is called
/// or the object goes away.
final class SerialPort: @unchecked Sendable {
    /// Speeds every macOS serial driver accepts through `termios`.
    static let baudRates = [1200, 2400, 4800, 9600, 19200, 38400, 57600, 115_200, 230_400]
    static let defaultBaudRate = 115_200

    let path: String
    let baudRate: Int

    private let descriptor: Int32
    private let queue: DispatchQueue
    private let source: DispatchSourceRead
    private let state: State

    /// Whether the descriptor is still open. Only touched on the port's queue.
    private final class State: @unchecked Sendable {
        var isOpen = true
    }

    /// `ioctl` request that keeps other apps from opening the port too.
    /// The C macro `TIOCEXCL` is `_IO('t', 13)`, which Swift cannot import.
    private static let exclusiveAccess: UInt = 0x2000_740D

    /// Opens the device at `path`, for example `/dev/cu.usbmodem0F0130B71`.
    ///
    /// - Parameters:
    ///   - onData: Called on a background queue with each batch of bytes received, in order.
    ///   - onDisconnect: Called once, on a background queue, if the device
    ///     goes away (for example, the board is unplugged). Not called for `close()`.
    init(
        path: String,
        baudRate: Int = SerialPort.defaultBaudRate,
        onData: @escaping @Sendable (Data) -> Void,
        onDisconnect: @escaping @Sendable () -> Void = {}
    ) throws {
        // Non-blocking, so opening does not wait for a carrier signal and
        // reading never stalls the queue.
        let descriptor = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw SerialPortError.cannotOpen(path: path, code: errno)
        }

        var attributes = termios()
        guard tcgetattr(descriptor, &attributes) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw SerialPortError.cannotConfigure(path: path, code: code)
        }
        Self.makeRaw(&attributes, baudRate: baudRate)
        guard tcsetattr(descriptor, TCSANOW, &attributes) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw SerialPortError.cannotConfigure(path: path, code: code)
        }
        // Best effort: not every device supports exclusive access.
        _ = ioctl(descriptor, Self.exclusiveAccess)
        // Drop whatever arrived before the port was set up.
        tcflush(descriptor, TCIOFLUSH)

        self.path = path
        self.baudRate = baudRate
        self.descriptor = descriptor
        let queue = DispatchQueue(label: "uMeil.SerialPort")
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        let state = State()
        self.queue = queue
        self.source = source
        self.state = state

        source.setEventHandler { [weak source] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = read(descriptor, &buffer, buffer.count)
            let code = errno
            if count > 0 {
                onData(Data(buffer[..<count]))
            } else if count == 0 || (code != EAGAIN && code != EINTR) {
                // End of file or an error: the device is gone.
                state.isOpen = false
                source?.cancel()
                onDisconnect()
            }
        }
        source.setCancelHandler {
            state.isOpen = false
            Darwin.close(descriptor)
        }
        source.resume()
    }

    deinit {
        source.cancel()
    }

    /// Changes `attributes` to raw mode: 8 data bits, no parity, 1 stop bit,
    /// no flow control, and no processing of the bytes in either direction.
    static func makeRaw(_ attributes: inout termios, baudRate: Int) {
        cfmakeraw(&attributes)
        // Ignore the modem control lines and enable the receiver.
        attributes.c_cflag |= tcflag_t(CLOCAL | CREAD)
        attributes.c_cflag &= ~tcflag_t(PARENB | CSTOPB | CRTSCTS | HUPCL)
        attributes.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        cfsetspeed(&attributes, speed_t(baudRate))
        withUnsafeMutableBytes(of: &attributes.c_cc) { controlCharacters in
            controlCharacters[Int(VMIN)] = 1
            controlCharacters[Int(VTIME)] = 0
        }
    }

    /// Sends `data`, waiting until the port has taken all of it.
    func write(_ data: Data) throws {
        try queue.sync {
            guard state.isOpen else { throw SerialPortError.notOpen }
            try data.withUnsafeBytes { bytes in
                var sent = 0
                while sent < bytes.count {
                    let count = Darwin.write(descriptor, bytes.baseAddress! + sent, bytes.count - sent)
                    if count > 0 {
                        sent += count
                        continue
                    }
                    let code = errno
                    if code == EINTR { continue }
                    guard code == EAGAIN, waitUntilWritable() else {
                        throw SerialPortError.writeFailed(code: code == EAGAIN ? ETIMEDOUT : code)
                    }
                }
            }
        }
    }

    /// Waits up to a second for the port to have room for more bytes.
    private func waitUntilWritable() -> Bool {
        var poller = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        return poll(&poller, 1, 1000) > 0 && poller.revents & Int16(POLLOUT) != 0
    }

    /// Closes the port. Nothing is delivered to `onData` after this returns.
    func close() {
        source.cancel()
        // The cancel handler runs on the queue; wait for it.
        queue.sync {}
    }
}
