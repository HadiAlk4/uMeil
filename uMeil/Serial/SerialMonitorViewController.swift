import AppKit

/// A console for a board's serial port: shows what the board prints and
/// sends what the user types.
final class SerialMonitorViewController: NSViewController {
    /// Where the chosen port, speed and line ending are remembered between launches.
    enum DefaultsKey {
        static let port = "SerialMonitorPort"
        static let baudRate = "SerialMonitorBaudRate"
        static let lineEnding = "SerialMonitorLineEnding"
    }

    /// The most text the console keeps. Older text is dropped a line at a time.
    static let maximumLength = 500_000

    private let listPorts: () -> [SerialPortInfo]
    private let defaults: UserDefaults

    private(set) var ports: [SerialPortInfo] = []
    private(set) var port: SerialPort?
    private var decoder = SerialTextDecoder()
    /// Counts connections, so bytes still on their way from a port that has
    /// since been closed are not shown.
    private var connection = 0

    let portPopUp = NSPopUpButton()
    let baudPopUp = NSPopUpButton()
    let lineEndingPopUp = NSPopUpButton()
    let statusLabel = NSTextField(labelWithString: "Not connected")
    let inputField = NSTextField()
    let textView = NSTextView()
    private let scrollView = NSScrollView()
    private(set) lazy var connectButton = NSButton(title: "Connect", target: self, action: #selector(toggle(_:)))
    private(set) lazy var sendButton = NSButton(title: "Send", target: self, action: #selector(sendInput(_:)))
    private lazy var clearButton = NSButton(title: "Clear", target: self, action: #selector(clear(_:)))

    var isConnected: Bool { port != nil }
    /// Everything in the console.
    var outputText: String { textView.string }

    init(
        listPorts: @escaping () -> [SerialPortInfo] = SerialPortList.current,
        defaults: UserDefaults = .standard
    ) {
        self.listPorts = listPorts
        self.defaults = defaults
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SerialMonitorViewController is created in code, not from a nib")
    }

    // MARK: - Layout

    override func loadView() {
        textView.isEditable = false
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .textColor
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.setAccessibilityLabel("Serial output")

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        setUpMenus()

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        inputField.placeholderString = "Type a line to send to the board"
        inputField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        inputField.target = self
        inputField.action = #selector(sendInput(_:)) // Return sends.
        inputField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let topBar = NSStackView(views: [portPopUp, baudPopUp, connectButton, statusLabel, NSView(), clearButton])
        let bottomBar = NSStackView(views: [inputField, lineEndingPopUp, sendButton])
        for bar in [topBar, bottomBar] {
            bar.orientation = .horizontal
            bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        }

        let stack = NSStackView(views: [topBar, separator(), scrollView, separator(), bottomBar])
        stack.orientation = .vertical
        stack.spacing = 0
        view = stack

        refreshPorts()
        updateControls()
    }

    /// Fills the speed and line ending menus and selects what was chosen last time.
    private func setUpMenus() {
        for rate in SerialPort.baudRates {
            baudPopUp.addItem(withTitle: "\(rate) baud")
            baudPopUp.lastItem?.tag = rate
        }
        let savedRate = defaults.integer(forKey: DefaultsKey.baudRate)
        baudPopUp.selectItem(withTag: SerialPort.baudRates.contains(savedRate) ? savedRate : SerialPort.defaultBaudRate)
        baudPopUp.toolTip = "Speed. It must match the speed the firmware sets."

        for ending in SerialLineEnding.allCases {
            lineEndingPopUp.addItem(withTitle: ending.title)
            lineEndingPopUp.lastItem?.representedObject = ending.rawValue
        }
        let savedEnding = defaults.string(forKey: DefaultsKey.lineEnding).flatMap(SerialLineEnding.init(rawValue:))
        select(savedEnding ?? .standard)
        lineEndingPopUp.toolTip = "What is added to the end of each line you send"
        lineEndingPopUp.target = self
        lineEndingPopUp.action = #selector(lineEndingChosen(_:))

        portPopUp.toolTip = "Serial port"
        // The list is brought up to date each time the menu opens.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(portMenuWillOpen(_:)),
            name: NSPopUpButton.willPopUpNotification,
            object: portPopUp
        )
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        if !isConnected {
            refreshPorts()
        }
    }

    // MARK: - Ports

    /// Reads the list of ports again, keeping the current choice if it is still there.
    func refreshPorts() {
        let chosen = isConnected ? port?.path : selectedPort?.path ?? defaults.string(forKey: DefaultsKey.port)
        ports = SerialPortList.sorted(listPorts())

        portPopUp.removeAllItems()
        if ports.isEmpty {
            portPopUp.addItem(withTitle: "No Serial Ports")
        }
        for port in ports {
            portPopUp.addItem(withTitle: port.displayName)
        }
        if let preferred = SerialPortList.preferred(in: ports, lastPath: chosen),
           let index = ports.firstIndex(of: preferred) {
            portPopUp.selectItem(at: index)
        }
        updateControls()
    }

    /// The port chosen in the menu.
    var selectedPort: SerialPortInfo? {
        let index = portPopUp.indexOfSelectedItem
        return ports.indices.contains(index) ? ports[index] : nil
    }

    @objc private func portMenuWillOpen(_ notification: Notification) {
        refreshPorts()
    }

    // MARK: - Connecting

    @objc private func toggle(_ sender: Any?) {
        if isConnected {
            disconnect()
        } else {
            connect()
        }
    }

    /// Opens the port chosen in the menu, at the chosen speed.
    func connect() {
        guard !isConnected, let info = selectedPort else { return }
        let baudRate = baudPopUp.selectedTag()
        connection += 1
        let connection = connection

        do {
            // The port calls back on its own queue. Handing each batch to the
            // main queue keeps the batches in the order they arrived.
            port = try SerialPort(
                path: info.path,
                baudRate: baudRate,
                onData: { [weak self] data in
                    DispatchQueue.main.async { [weak self] in self?.received(data, from: connection) }
                },
                onDisconnect: { [weak self] in
                    DispatchQueue.main.async { [weak self] in self?.lostPort(connection) }
                }
            )
        } catch {
            show(status: error.localizedDescription, isError: true)
            return
        }

        decoder = SerialTextDecoder()
        defaults.set(info.path, forKey: DefaultsKey.port)
        defaults.set(baudRate, forKey: DefaultsKey.baudRate)
        show(status: "Connected at \(baudRate) baud")
        updateControls()
        view.window?.makeFirstResponder(inputField)
    }

    /// Closes the port, if one is open.
    func disconnect() {
        guard let port else { return }
        port.close()
        self.port = nil
        connection += 1
        show(status: "Not connected")
        updateControls()
    }

    /// The device went away, for example because the board was unplugged.
    private func lostPort(_ connection: Int) {
        guard connection == self.connection, let port else { return }
        port.close()
        self.port = nil
        show(status: "\(URL(filePath: port.path).lastPathComponent) was disconnected", isError: true)
        refreshPorts()
    }

    private func updateControls() {
        connectButton.title = isConnected ? "Disconnect" : "Connect"
        connectButton.isEnabled = isConnected || selectedPort != nil
        portPopUp.isEnabled = !isConnected && !ports.isEmpty
        baudPopUp.isEnabled = !isConnected
        inputField.isEnabled = isConnected
        sendButton.isEnabled = isConnected
    }

    private func show(status: String, isError: Bool = false) {
        statusLabel.stringValue = status
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    // MARK: - Receiving

    private func received(_ data: Data, from connection: Int) {
        guard connection == self.connection else { return }
        append(decoder.decode(data))
    }

    /// Adds `text` to the end of the console. The view follows the new text
    /// unless the user has scrolled back to read something earlier.
    func append(_ text: String) {
        guard !text.isEmpty, let storage = textView.textStorage else { return }
        let visible = scrollView.contentView.bounds
        let wasAtEnd = visible.maxY >= textView.frame.height - 2

        let attributes: [NSAttributedString.Key: Any] = [
            .font: textView.font ?? .monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.textColor
        ]
        storage.append(NSAttributedString(string: text, attributes: attributes))

        let excess = storage.length - Self.maximumLength
        if excess > 0 {
            // Drop whole lines, so the console never starts mid-line, unless
            // the line to drop is the one still being received.
            let line = (storage.string as NSString).lineRange(for: NSRange(location: excess - 1, length: 0))
            let end = NSMaxRange(line)
            storage.deleteCharacters(in: NSRange(location: 0, length: end < storage.length ? end : excess))
        }
        if wasAtEnd {
            textView.scrollToEndOfDocument(nil)
        }
    }

    @objc private func clear(_ sender: Any?) {
        textView.string = ""
    }

    // MARK: - Sending

    var lineEnding: SerialLineEnding {
        (lineEndingPopUp.selectedItem?.representedObject as? String).flatMap(SerialLineEnding.init(rawValue:))
            ?? .standard
    }

    private func select(_ ending: SerialLineEnding) {
        lineEndingPopUp.selectItem(at: SerialLineEnding.allCases.firstIndex(of: ending) ?? 0)
    }

    @objc private func lineEndingChosen(_ sender: Any?) {
        defaults.set(lineEnding.rawValue, forKey: DefaultsKey.lineEnding)
    }

    @objc private func sendInput(_ sender: Any?) {
        guard isConnected else { return }
        if send(inputField.stringValue) {
            inputField.stringValue = ""
        }
    }

    /// Sends `line` to the board, followed by the chosen line ending.
    /// Returns false, after showing why, if it could not be sent.
    @discardableResult
    func send(_ line: String) -> Bool {
        guard let port else { return false }
        do {
            try port.write(Data((line + lineEnding.text).utf8))
            return true
        } catch {
            show(status: error.localizedDescription, isError: true)
            return false
        }
    }
}
