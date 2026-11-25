import AppKit
import Testing
@testable import uMeil

/// The serial monitor window, talking to a pseudo-terminal through the real port code.
@MainActor
struct SerialMonitorTests {
    let terminal: PseudoTerminal
    let defaults: UserDefaults
    let monitor: SerialMonitorViewController

    init() throws {
        defaults = TestDefaults()
        let terminal = try PseudoTerminal()
        self.terminal = terminal
        monitor = SerialMonitorViewController(listPorts: { [info = terminal.info] in [info] }, defaults: defaults)
        monitor.loadViewIfNeeded()
    }

    @Test func startsDisconnectedWithThePortChosen() {
        #expect(!monitor.isConnected)
        #expect(monitor.selectedPort == terminal.info)
        #expect(monitor.portPopUp.titleOfSelectedItem == terminal.info.displayName)
        #expect(monitor.baudPopUp.selectedTag() == 115_200)
        #expect(monitor.framing == .standard)
        #expect(monitor.dataBitsPopUp.titleOfSelectedItem == "8 Data Bits")
        #expect(monitor.parityPopUp.titleOfSelectedItem == "No Parity")
        #expect(monitor.stopBitsPopUp.titleOfSelectedItem == "1 Stop Bit")
        #expect(monitor.lineEnding == .carriageReturn)
        #expect(monitor.connectButton.title == "Connect")
        #expect(monitor.connectButton.isEnabled)
        #expect(!monitor.inputField.isEnabled)
        #expect(!monitor.sendButton.isEnabled)
        #expect(monitor.statusLabel.stringValue == "Not connected")
    }

    @Test func showsWhatTheBoardPrints() async {
        monitor.connect()
        #expect(monitor.isConnected)
        #expect(monitor.statusLabel.stringValue == "Connected at 115200 baud, 8,N,1")
        #expect(monitor.connectButton.title == "Disconnect")
        #expect(!monitor.portPopUp.isEnabled)
        #expect(!monitor.baudPopUp.isEnabled)
        #expect(!monitor.dataBitsPopUp.isEnabled)
        #expect(!monitor.parityPopUp.isEnabled)
        #expect(!monitor.stopBitsPopUp.isEnabled)

        terminal.send("Temperature: 25 °C\r\n")
        terminal.send("Ready\r\n")

        #expect(await eventually { monitor.outputText == "Temperature: 25 °C\nReady\n" })
    }

    @Test func connectsAtTheChosenSpeed() {
        monitor.baudPopUp.selectItem(withTag: 9600)
        monitor.connect()

        var attributes = terminal.attributes
        #expect(cfgetospeed(&attributes) == 9600)
        #expect(monitor.statusLabel.stringValue == "Connected at 9600 baud, 8,N,1")
    }

    /// Lab 2 (Wednesday) relays its UART3 output at 38400, 7 bits, no parity, 2 stop bits.
    @Test func connectsWithTheChosenFraming() {
        monitor.baudPopUp.selectItem(withTag: 38400)
        monitor.dataBitsPopUp.selectItem(withTitle: "7 Data Bits")
        monitor.stopBitsPopUp.selectItem(withTitle: "2 Stop Bits")
        monitor.connect()

        let attributes = terminal.attributes
        #expect(attributes.c_cflag & tcflag_t(CSIZE) == tcflag_t(CS7))
        #expect(attributes.c_cflag & tcflag_t(CSTOPB) != 0)
        #expect(attributes.c_cflag & tcflag_t(PARENB) == 0)
        #expect(monitor.statusLabel.stringValue == "Connected at 38400 baud, 7,N,2")
    }

    @Test func connectsWithOddOrEvenParity() {
        monitor.parityPopUp.selectItem(withTitle: "Odd Parity")
        monitor.connect()
        #expect(terminal.attributes.c_cflag & tcflag_t(PARENB | PARODD) == tcflag_t(PARENB | PARODD))
        #expect(monitor.statusLabel.stringValue == "Connected at 115200 baud, 8,O,1")
        monitor.disconnect()

        monitor.parityPopUp.selectItem(withTitle: "Even Parity")
        monitor.connect()
        #expect(terminal.attributes.c_cflag & tcflag_t(PARENB | PARODD) == tcflag_t(PARENB))
        #expect(monitor.statusLabel.stringValue == "Connected at 115200 baud, 8,E,1")
    }

    @Test func sendsTheTypedLineWithTheChosenEnding() {
        monitor.connect()

        monitor.inputField.stringValue = "led on"
        monitor.sendButton.performClick(nil)

        #expect(terminal.receive(7) == Array("led on\r".utf8))
        #expect(monitor.inputField.stringValue.isEmpty)

        monitor.lineEndingPopUp.selectItem(withTitle: "CR LF")
        monitor.send("héllo")
        #expect(terminal.receive(8) == Array("héllo\r\n".utf8))
    }

    @Test func nothingIsSentWhileDisconnected() {
        monitor.inputField.stringValue = "led on"
        monitor.sendButton.performClick(nil)

        #expect(!monitor.send("led on"))
        #expect(monitor.inputField.stringValue == "led on")
    }

    @Test func disconnectingStopsTheOutput() async throws {
        monitor.connect()
        terminal.send("before\n")
        #expect(await eventually { monitor.outputText == "before\n" })

        monitor.connectButton.performClick(nil)
        terminal.send("after\n")
        try await Task.sleep(for: .milliseconds(100))

        #expect(!monitor.isConnected)
        #expect(monitor.outputText == "before\n")
        #expect(monitor.statusLabel.stringValue == "Not connected")
        #expect(monitor.connectButton.title == "Connect")
        #expect(monitor.portPopUp.isEnabled)
    }

    @Test func canConnectAgainAfterDisconnecting() async {
        monitor.connect()
        monitor.disconnect()
        monitor.connect()
        terminal.send("back\n")

        #expect(await eventually { monitor.outputText == "back\n" })
    }

    @Test func saysWhenTheBoardIsUnplugged() async {
        monitor.connect()
        terminal.send("running\n")
        #expect(await eventually { monitor.outputText == "running\n" })
        terminal.unplug()

        #expect(await eventually { !monitor.isConnected })
        #expect(monitor.outputText == "running\n")
        #expect(monitor.statusLabel.stringValue.hasSuffix("was disconnected"))
        #expect(monitor.connectButton.title == "Connect")
        #expect(!monitor.inputField.isEnabled)
    }

    @Test func saysWhyAPortCouldNotBeOpened() {
        let gone = SerialPortInfo(path: "/dev/cu.uMeilTests-gone", usbDevice: nil)
        let monitor = SerialMonitorViewController(listPorts: { [gone] }, defaults: defaults)
        monitor.loadViewIfNeeded()

        monitor.connect()

        #expect(!monitor.isConnected)
        #expect(monitor.statusLabel.stringValue
            == "cu.uMeilTests-gone is no longer there. Check that the board is plugged in.")
        #expect(monitor.connectButton.title == "Connect")
    }

    @Test func withNoPortsThereIsNothingToConnectTo() {
        let monitor = SerialMonitorViewController(listPorts: { [] }, defaults: defaults)
        monitor.loadViewIfNeeded()

        #expect(monitor.portPopUp.titleOfSelectedItem == "No Serial Ports")
        #expect(!monitor.portPopUp.isEnabled)
        #expect(!monitor.connectButton.isEnabled)
        monitor.connect()
        #expect(!monitor.isConnected)
    }

    @Test func aBoardPluggedInLaterShowsUpWhenThePortMenuOpens() {
        var ports: [SerialPortInfo] = []
        let monitor = SerialMonitorViewController(listPorts: { ports }, defaults: defaults)
        monitor.loadViewIfNeeded()
        #expect(monitor.selectedPort == nil)

        ports = [
            SerialPortInfo(path: "/dev/cu.Bluetooth-Incoming-Port", usbDevice: nil),
            SerialPortInfo(path: "/dev/cu.usbmodem0F0130B71", usbDevice: Board.ekTM4C1294XL.debugProbe)
        ]
        NotificationCenter.default.post(name: NSPopUpButton.willPopUpNotification, object: monitor.portPopUp)

        #expect(monitor.portPopUp.itemTitles == [
            "EK-TM4C1294XL LaunchPad (usbmodem0F0130B71)",
            "Bluetooth-Incoming-Port"
        ])
        #expect(monitor.selectedPort?.board == .ekTM4C1294XL)
        #expect(monitor.connectButton.isEnabled)
    }

    @Test func remembersThePortSpeedFramingAndLineEnding() {
        monitor.baudPopUp.selectItem(withTag: 9600)
        monitor.framing = SerialFraming(dataBits: 7, parity: .even, stopBits: 2)
        monitor.lineEndingPopUp.selectItem(withTitle: "LF")
        monitor.lineEndingPopUp.sendAction(monitor.lineEndingPopUp.action, to: monitor.lineEndingPopUp.target)
        monitor.connect()
        monitor.disconnect()

        let other = SerialPortInfo(path: "/dev/cu.usbserial-A50285BI", usbDevice: nil)
        let ports = [other, terminal.info]
        let next = SerialMonitorViewController(listPorts: { ports }, defaults: defaults)
        next.loadViewIfNeeded()

        #expect(next.selectedPort == terminal.info)
        #expect(next.baudPopUp.selectedTag() == 9600)
        #expect(next.framing == SerialFraming(dataBits: 7, parity: .even, stopBits: 2))
        #expect(next.lineEnding == .lineFeed)
    }

    @Test func oldOutputIsDroppedALineAtATimeWhenTheConsoleIsFull() {
        let line = String(repeating: "x", count: 99) + "\n"
        let lines = SerialMonitorViewController.maximumLength / line.count
        monitor.append(String(repeating: line, count: lines))
        #expect(monitor.outputText.count == SerialMonitorViewController.maximumLength)

        monitor.append("the newest line\n")

        #expect(monitor.outputText.count <= SerialMonitorViewController.maximumLength)
        #expect(monitor.outputText.hasPrefix(line))
        #expect(monitor.outputText.hasSuffix(line + "the newest line\n"))
    }

    @Test func theViewMenuShowsTheSerialMonitor() throws {
        let menu = MainMenu.make(appName: "uMeil")
        let view = try #require(menu.items.first { $0.submenu?.title == "View" }?.submenu)
        let item = try #require(view.items.first { $0.title == "Show Serial Monitor" })

        #expect(item.action == #selector(MainWindowController.toggleSerialMonitor(_:)))
        #expect(item.keyEquivalent == "m")
        #expect(item.keyEquivalentModifierMask == [.command, .shift])
    }

    @Test func theSerialMonitorIsATabInTheBottomPanelNotAWindow() async throws {
        let controller = MainWindowController(defaults: defaults, boardMonitor: FakeBoardMonitor())
        let windowsBefore = NSApp.windows.count

        controller.toggleSerialMonitor(nil)

        #expect(controller.isSerialMonitorVisible)
        #expect(controller.bottomPanel.selectedTab == .serial)
        #expect(controller.bottomPanel.serial.view.isDescendant(of: controller.bottomPanel.view))
        #expect(NSApp.windows.count == windowsBefore, "no separate window opens")

        let toggle = #selector(MainWindowController.toggleSerialMonitor(_:))
        let item = NSMenuItem(title: "", action: toggle, keyEquivalent: "")
        #expect(controller.validateMenuItem(item))
        #expect(item.title == "Hide Serial Monitor")

        controller.toggleSerialMonitor(nil)
        await waitUntil("the panel closes") { !controller.isSerialMonitorVisible }
    }
}
