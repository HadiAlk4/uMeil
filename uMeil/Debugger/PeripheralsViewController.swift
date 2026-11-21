import AppKit

/// The `Peripherals` panel, like Keil's peripheral windows: pick a
/// peripheral, see its registers and their bit fields decoded from the
/// chip's SVD file, and change them by typing a new value while the program
/// is stopped.
final class PeripheralsViewController: NSViewController {
    /// A register, or one bit field of it.
    final class Node {
        let register: SVDRegister
        let field: SVDField?
        let children: [Node]

        init(register: SVDRegister, field: SVDField? = nil) {
            self.register = register
            self.field = field
            children = field == nil ? register.fields.reversed().map { Node(register: register, field: $0) } : []
        }

        var name: String { field?.name ?? register.name }
    }

    let peripheralPopUp = NSPopUpButton()
    let outlineView = NSOutlineView()
    let messageLabel = NSTextField(labelWithString: "")

    private(set) var device: SVDDevice?
    private(set) var selectedPeripheral: SVDPeripheral?
    private(set) var nodes: [Node] = []
    /// The last values read for the selected peripheral, by register name.
    private(set) var readings: [String: RegisterReading] = [:]
    /// Registers whose value changed since the previous read.
    private(set) var changedRegisters: Set<String> = []
    /// When the values last changed, so their cells flash only then.
    var updatedAt: Date?
    /// Values can be typed only while the program is stopped.
    var isEditable = false {
        didSet {
            if isViewLoaded, isEditable != oldValue { outlineView.reloadData() }
        }
    }

    /// The user picked another peripheral; read it.
    var onSelectPeripheral: ((SVDPeripheral) -> Void)?
    /// The user typed a value for a register, or a field when one is given.
    var onWrite: ((SVDPeripheral, SVDRegister, SVDField?, String) -> Void)?
    /// The user asked to read a register whose read has side effects.
    var onReadNow: ((SVDPeripheral, SVDRegister) -> Void)?

    static let selectionKey = "PeripheralsSelection"

    init() {
        super.init(nibName: nil, bundle: nil)
        title = "Peripherals"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PeripheralsViewController is created in code, not from a nib")
    }

    override func loadView() {
        peripheralPopUp.target = self
        peripheralPopUp.action = #selector(peripheralChosen(_:))
        peripheralPopUp.controlSize = .small
        peripheralPopUp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let topBar = NSStackView(views: [peripheralPopUp, messageLabel])
        topBar.orientation = .horizontal
        topBar.spacing = 8
        topBar.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

        addColumn("name", title: "Register", width: 130)
        addColumn("value", title: "Value", width: 110)
        addColumn("location", title: "Address / Bits", width: 95)
        outlineView.outlineTableColumn = outlineView.tableColumns.first
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.rowHeight = 19
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        view = PanelLayout.view(bar: topBar, content: scrollView)
        if device != nil {
            rebuildMenu()
        }
    }

    private func addColumn(_ identifier: String, title: String, width: CGFloat) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.width = width
        outlineView.addTableColumn(column)
    }

    // MARK: - Device and selection

    /// Shows the peripherals of `device` and selects the one used last
    /// (the LaunchPad's LED port the first time).
    func setDevice(_ device: SVDDevice) {
        self.device = device
        let remembered = UserDefaults.standard.string(forKey: Self.selectionKey) ?? "GPIO_PORTN"
        selectedPeripheral = device.peripheral(named: remembered) ?? device.peripherals.first
        nodes = selectedPeripheral.map { $0.registers.map { Node(register: $0) } } ?? []
        readings = [:]
        changedRegisters = []
        if isViewLoaded {
            rebuildMenu()
            outlineView.reloadData()
        }
    }

    func showMessage(_ text: String) {
        loadViewIfNeeded()
        messageLabel.stringValue = text
        messageLabel.toolTip = text
    }

    /// Selects the peripheral called `name` and asks for it to be read.
    func select(peripheralNamed name: String) {
        guard let peripheral = device?.peripheral(named: name) else { return }
        select(peripheral)
    }

    private func select(_ peripheral: SVDPeripheral) {
        selectedPeripheral = peripheral
        UserDefaults.standard.set(peripheral.name, forKey: Self.selectionKey)
        nodes = peripheral.registers.map { Node(register: $0) }
        readings = [:]
        changedRegisters = []
        showMessage("")
        if isViewLoaded {
            peripheralPopUp.selectItem(withTitle: peripheral.name)
            outlineView.reloadData()
        }
        onSelectPeripheral?(peripheral)
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        var group: String?
        for peripheral in device?.peripherals.sorted(by: Self.menuOrder) ?? [] {
            if peripheral.groupName != group {
                group = peripheral.groupName
                menu.addItem(NSMenuItem.sectionHeader(title: group ?? "Other"))
            }
            let item = NSMenuItem(title: peripheral.name, action: nil, keyEquivalent: "")
            item.toolTip = peripheral.description
            menu.addItem(item)
        }
        peripheralPopUp.menu = menu
        if let name = selectedPeripheral?.name {
            peripheralPopUp.selectItem(withTitle: name)
        }
    }

    /// Grouped by kind, then by name with numbers in order (`UART2` before `UART10`).
    private static func menuOrder(_ lhs: SVDPeripheral, _ rhs: SVDPeripheral) -> Bool {
        let left = lhs.groupName ?? "", right = rhs.groupName ?? ""
        if left != right { return left.localizedStandardCompare(right) == .orderedAscending }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    @objc private func peripheralChosen(_ sender: NSPopUpButton) {
        guard let title = sender.titleOfSelectedItem, title != selectedPeripheral?.name else { return }
        select(peripheralNamed: title)
    }

    // MARK: - Values

    /// Shows values just read for `peripheral`, marking the ones that
    /// changed since the previous read of the same peripheral.
    func update(readings newReadings: [String: RegisterReading], for peripheral: SVDPeripheral) {
        guard peripheral.name == selectedPeripheral?.name else { return }
        loadViewIfNeeded()
        var changed: Set<String> = []
        for (name, reading) in newReadings {
            if case .value = readings[name], readings[name] != reading,
               case .value = reading {
                changed.insert(name)
            }
        }
        // A register read on request keeps its value until it is read again.
        var merged = newReadings
        for (name, reading) in readings where newReadings[name] == .notRead {
            if case .value = reading { merged[name] = reading }
        }
        readings = merged
        changedRegisters = changed
        updatedAt = Date()
        let unreadable = newReadings.values.contains { if case .unreadable = $0 { true } else { false } }
        showMessage(unreadable ? "Some registers could not be read. Is the peripheral's clock on?" : "")
        outlineView.reloadData()
    }

    /// Shows one register's value, after a write or a read on request.
    func update(reading: RegisterReading, for register: SVDRegister, of peripheral: SVDPeripheral) {
        guard peripheral.name == selectedPeripheral?.name else { return }
        loadViewIfNeeded()
        if case .value = readings[register.name], readings[register.name] != reading {
            changedRegisters.insert(register.name)
        }
        readings[register.name] = reading
        outlineView.reloadData()
    }

    /// Forgets the values; the device and selection stay.
    func clear() {
        readings = [:]
        changedRegisters = []
        isEditable = false
        if isViewLoaded {
            showMessage("")
            outlineView.reloadData()
        }
    }

    /// What the Value column shows for `node`.
    func valueText(for node: Node) -> String {
        switch readings[node.register.name] {
        case .value(let value):
            if let field = node.field {
                return PeripheralAccess.fieldText(field, registerValue: value)
            }
            let digits = max(2, node.register.byteCount * 2)
            return "0x" + String(format: "%0\(digits)llX", value)
        case .unreadable:
            return node.field == nil ? "unreadable" : ""
        case .notRead:
            guard node.field == nil else { return "" }
            return node.register.access.isReadable ? "not read" : "write-only"
        case nil:
            return ""
        }
    }

    func locationText(for node: Node) -> String {
        if let field = node.field {
            return field.bitRangeText
        }
        guard let peripheral = selectedPeripheral else { return "" }
        return DebugValueFormatter.hex32(peripheral.address(of: node.register))
    }
}
