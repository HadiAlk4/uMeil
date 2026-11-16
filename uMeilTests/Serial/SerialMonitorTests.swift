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
        let suite = "uMeilTests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
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
        #expect(monitor.statusLabel.stringValue == "Connected at 115200 baud")
        #expect(monitor.connectButton.title == "Disconnect")
        #expect(!monitor.portPopUp.isEnabled)
        #expect(!monitor.baudPopUp.isEnabled)

        terminal.send("Temperature: 25 °C\r\n")
        terminal.send("Ready\r\n")

        #expect(await eventually { monitor.outputText == "Temperature: 25 °C\nReady\n" })
    }

    @Test func connectsAtTheChosenSpeed() {
        monitor.baudPopUp.selectItem(withTag: 9600)
        monitor.connect()

        var attributes = terminal.attributes
        #expect(cfgetospeed(&attributes) == 9600)
        #expect(monitor.statusLabel.stringValue == "Connected at 9600 baud")
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

    @Test func remembersThePortSpeedAndLineEnding() {
        monitor.baudPopUp.selectItem(withTag: 9600)
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

    @Test func theWindowMenuOpensTheSerialMonitor() throws {
        let menu = MainMenu.make(appName: "uMeil")
        let window = try #require(menu.items.first { $0.submenu?.title == "Window" }?.submenu)
        let item = try #require(window.items.first { $0.title == "Serial Monitor" })

        #expect(item.action == #selector(AppDelegate.showSerialMonitor(_:)))
        #expect(item.keyEquivalent == "m")
        #expect(item.keyEquivalentModifierMask == [.command, .shift])

        let controller = SerialMonitorWindowController()
        #expect(controller.window?.title == "Serial Monitor")
        #expect(controller.window?.contentViewController == controller.monitor)
    }
}
