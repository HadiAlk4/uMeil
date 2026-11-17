import Foundation
import os
import Testing
@testable import uMeil

/// The real port code, with a pseudo-terminal in place of a board.
@MainActor
struct SerialPortTests {
    @Test func receivesWhatTheBoardSends() async throws {
        let terminal = try PseudoTerminal()
        let recorder = SerialRecorder()
        let port = try recorder.open(terminal)
        defer { port.close() }

        terminal.send("Hello from the board\r\n")

        #expect(await eventually { recorder.text == "Hello from the board\r\n" })
    }

    @Test func sendsBytesToTheBoardUnchanged() throws {
        let terminal = try PseudoTerminal()
        let port = try SerialRecorder().open(terminal)
        defer { port.close() }

        // Bytes a terminal in its normal mode would translate or act on.
        let bytes: [UInt8] = [0x00, 0x03, 0x0A, 0x0D, 0x11, 0x13, 0x7F, 0xFF]
        try port.write(Data(bytes))

        #expect(terminal.receive(bytes.count) == bytes)
    }

    @Test func receivesBytesUnchanged() async throws {
        let terminal = try PseudoTerminal()
        let recorder = SerialRecorder()
        let port = try recorder.open(terminal)
        defer { port.close() }

        let bytes: [UInt8] = [0x00, 0x03, 0x0A, 0x0D, 0x11, 0x13, 0x7F, 0xFF]
        terminal.send(bytes)

        #expect(await eventually { recorder.data == Data(bytes) })
    }

    @Test func doesNotEchoWhatItReceives() async throws {
        let terminal = try PseudoTerminal()
        let recorder = SerialRecorder()
        let port = try recorder.open(terminal)
        defer { port.close() }

        terminal.send("ping")
        #expect(await eventually { recorder.text == "ping" })
        try port.write(Data("pong".utf8))

        // An echo of "ping" would arrive ahead of "pong".
        #expect(terminal.receive(4) == Array("pong".utf8))
    }

    @Test func sendsALargeBlockCompletely() throws {
        let terminal = try PseudoTerminal()
        let port = try SerialRecorder().open(terminal)
        defer { port.close() }
        let block = (0..<50_000).map { UInt8(truncatingIfNeeded: $0) }

        // More than the terminal buffers, so the write has to wait for the
        // reader. Both block, so the reader gets a thread of its own: as a
        // task it could wait for a free thread behind blocked ones (on CI's
        // three cores it did) and the write would time out.
        let received = OSAllocatedUnfairLock<[UInt8]>(initialState: [])
        let readerFinished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            let bytes = terminal.receive(block.count)
            received.withLock { $0 = bytes }
            readerFinished.signal()
        }
        try port.write(Data(block))
        readerFinished.wait()

        #expect(received.withLock { $0 } == block)
    }

    @Test(arguments: [9600, 115_200, 230_400])
    func setsTheSpeedAndRawMode(baudRate: Int) throws {
        let terminal = try PseudoTerminal()
        let port = try SerialRecorder().open(terminal, baudRate: baudRate)
        defer { port.close() }

        var attributes = terminal.attributes
        #expect(cfgetispeed(&attributes) == speed_t(baudRate))
        #expect(cfgetospeed(&attributes) == speed_t(baudRate))
        #expect(attributes.c_lflag & tcflag_t(ICANON | ECHO | ISIG) == 0)
        #expect(attributes.c_oflag & tcflag_t(OPOST) == 0)
        #expect(port.baudRate == baudRate)
    }

    @Test func rawModeIsEightBitsNoParityOneStopBitNoFlowControl() {
        var attributes = termios()
        attributes.c_cflag = tcflag_t(CS7 | PARENB | CSTOPB | CRTSCTS)
        attributes.c_iflag = tcflag_t(IXON | IXOFF | ICRNL)
        attributes.c_lflag = tcflag_t(ICANON | ECHO)

        SerialPort.makeRaw(&attributes, baudRate: 57600)

        #expect(attributes.c_cflag & tcflag_t(CSIZE) == tcflag_t(CS8))
        #expect(attributes.c_cflag & tcflag_t(PARENB | CSTOPB | CRTSCTS) == 0)
        #expect(attributes.c_cflag & tcflag_t(CLOCAL | CREAD) == tcflag_t(CLOCAL | CREAD))
        #expect(attributes.c_iflag & tcflag_t(IXON | IXOFF | ICRNL) == 0)
        #expect(attributes.c_lflag & tcflag_t(ICANON | ECHO) == 0)
        #expect(cfgetospeed(&attributes) == 57600)
    }

    @Test func reportsWhenTheBoardIsUnplugged() async throws {
        let terminal = try PseudoTerminal()
        let recorder = SerialRecorder()
        let port = try recorder.open(terminal)
        defer { port.close() }

        terminal.send("last words")
        #expect(await eventually { recorder.text == "last words" })
        terminal.unplug()

        #expect(await eventually { recorder.disconnects == 1 })
        #expect(recorder.text == "last words")
        #expect(throws: SerialPortError.notOpen) { try port.write(Data("x".utf8)) }
    }

    @Test func closingStopsDeliveryAndIsNotReportedAsUnplugging() async throws {
        let terminal = try PseudoTerminal()
        let recorder = SerialRecorder()
        let port = try recorder.open(terminal)

        port.close()
        port.close() // Closing twice is harmless.
        terminal.send("too late")
        try await Task.sleep(for: .milliseconds(100))

        #expect(recorder.data.isEmpty)
        #expect(recorder.disconnects == 0)
        #expect(throws: SerialPortError.notOpen) { try port.write(Data("x".utf8)) }
    }

    @Test func aPortCanBeOpenedAgainAfterClosing() async throws {
        let terminal = try PseudoTerminal()
        try SerialRecorder().open(terminal).close()

        let recorder = SerialRecorder()
        let port = try recorder.open(terminal)
        defer { port.close() }
        terminal.send("again")

        #expect(await eventually { recorder.text == "again" })
    }

    @Test func aPortThatIsNotThereCannotBeOpened() {
        let path = "/dev/cu.uMeilTests-no-such-port"

        #expect(throws: SerialPortError.cannotOpen(path: path, code: ENOENT)) {
            _ = try SerialPort(path: path, onData: { _ in })
        }
    }

    @Test func somethingThatIsNotASerialPortCannotBeSetUp() throws {
        let folder = try TemporaryDirectory()
        let file = folder.url.appending(path: "not-a-port")
        try Data().write(to: file)
        let path = file.path(percentEncoded: false)

        #expect(throws: SerialPortError.cannotConfigure(path: path, code: ENOTTY)) {
            _ = try SerialPort(path: path, onData: { _ in })
        }
    }

    @Test func errorsAreExplainedInPlainLanguage() {
        let path = "/dev/cu.usbmodem1"
        #expect(SerialPortError.cannotOpen(path: path, code: EBUSY).localizedDescription
            == "cu.usbmodem1 is in use by another app.")
        #expect(SerialPortError.cannotOpen(path: path, code: ENOENT).localizedDescription
            == "cu.usbmodem1 is no longer there. Check that the board is plugged in.")
        #expect(SerialPortError.cannotOpen(path: path, code: EACCES).localizedDescription
            == "uMeil is not allowed to open cu.usbmodem1.")
        #expect(SerialPortError.writeFailed(code: EIO).localizedDescription == "Could not send: Input/output error.")
    }
}
