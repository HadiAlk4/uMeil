import Foundation
import Testing
@testable import uMeil

struct SerialPortListTests {
    private let launchPad = SerialPortInfo(
        path: "/dev/cu.usbmodem0F0130B71",
        usbDevice: Board.ekTM4C1294XL.debugProbe
    )
    private let adapter = SerialPortInfo(
        path: "/dev/cu.usbserial-A50285BI",
        usbDevice: USBDeviceID(vendorID: 0x0403, productID: 0x6001)
    )
    private let bluetooth = SerialPortInfo(path: "/dev/cu.Bluetooth-Incoming-Port", usbDevice: nil)

    @Test func aBoardsPortIsNamedAfterTheBoard() {
        #expect(launchPad.name == "usbmodem0F0130B71")
        #expect(launchPad.board == .ekTM4C1294XL)
        #expect(launchPad.displayName == "EK-TM4C1294XL LaunchPad (usbmodem0F0130B71)")
    }

    @Test func otherPortsAreNamedAfterTheDevice() {
        #expect(adapter.board == nil)
        #expect(adapter.displayName == "usbserial-A50285BI")
        #expect(bluetooth.displayName == "Bluetooth-Incoming-Port")
    }

    @Test func boardsComeFirstThenOtherUSBPorts() {
        #expect(SerialPortList.sorted([bluetooth, adapter, launchPad]) == [launchPad, adapter, bluetooth])
    }

    @Test func theBoardIsPreferredUntilThePersonChoosesAnotherPort() {
        let ports = [bluetooth, adapter, launchPad]

        #expect(SerialPortList.preferred(in: ports, lastPath: nil) == launchPad)
        #expect(SerialPortList.preferred(in: ports, lastPath: adapter.path) == adapter)
        // The port chosen last time has been unplugged.
        #expect(SerialPortList.preferred(in: ports, lastPath: "/dev/cu.usbmodem-gone") == launchPad)
        #expect(SerialPortList.preferred(in: [], lastPath: nil) == nil)
    }

    /// The real IOKit lookup, checked against what is true on any Mac and,
    /// when a LaunchPad is plugged in, against the board.
    @Test func listsTheSerialPortsOnThisMac() {
        let ports = SerialPortList.current()

        #expect(ports.allSatisfy { $0.path.hasPrefix("/dev/cu.") })
        #expect(ports.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(Set(ports.map(\.path)).count == ports.count)
        if USBBoardMonitor.isPresent(Board.ekTM4C1294XL.debugProbe) {
            #expect(ports.first?.board == .ekTM4C1294XL)
        }
    }
}
