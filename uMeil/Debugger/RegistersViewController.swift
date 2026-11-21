import AppKit

/// The `Regs` panel: shows general-purpose registers (`R0`–`R12`), `SP`, `LR`,
/// `PC`, `xPSR` (expandable into condition flags and `ISR`), special registers,
/// and the Cortex-M processor state (`Mode`, `Privilege`, `Stack`).
final class RegistersViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    final class Node {
        let key: String
        let name: String
        let value: String
        let isChanged: Bool
        let children: [Node]

        init(key: String, name: String, value: String, isChanged: Bool = false, children: [Node] = []) {
            self.key = key
            self.name = name
            self.value = value
            self.isChanged = isChanged
            self.children = children
        }
    }

    let outlineView = NSOutlineView()
    private(set) var nodes: [Node] = []
    /// Register names (`r0`, `pc`, etc.) whose value changed on the most recent stop.
    private(set) var changedNames: Set<String> = []
    private var previousValues: [String: UInt64] = [:]
    /// When the values last changed, so their cells flash only then.
    private var updatedAt: Date?

    private static let coreOrder: [(key: String, label: String)] = [
        ("r0", "R0"), ("r1", "R1"), ("r2", "R2"), ("r3", "R3"),
        ("r4", "R4"), ("r5", "R5"), ("r6", "R6"), ("r7", "R7"),
        ("r8", "R8"), ("r9", "R9"), ("r10", "R10"), ("r11", "R11"),
        ("r12", "R12"), ("sp", "SP (R13)"), ("lr", "LR (R14)"), ("pc", "PC (R15)"),
        ("xpsr", "xPSR"), ("msp", "MSP"), ("psp", "PSP"),
        ("primask", "PRIMASK"), ("basepri", "BASEPRI"),
        ("faultmask", "FAULTMASK"), ("control", "CONTROL")
    ]

    init() {
        super.init(nibName: nil, bundle: nil)
        title = "Regs"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RegistersViewController is created in code, not from a nib")
    }

    override func loadView() {
        let regColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("register"))
        regColumn.title = "Register"
        regColumn.width = 110
        let valColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value"))
        valColumn.title = "Value"
        valColumn.width = 120
        outlineView.addTableColumn(regColumn)
        outlineView.addTableColumn(valColumn)
        outlineView.outlineTableColumn = regColumn
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.rowHeight = 20

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        view = scrollView
    }

    /// Updates the register display and marks any register whose value changed
    /// since the previous stop.
    func update(with registers: [RegisterValue]) {
        loadViewIfNeeded()
        var byName: [String: UInt64] = [:]
        for reg in registers {
            if let value = reg.value {
                byName[reg.name.lowercased()] = value
            }
        }

        var changed: Set<String> = []
        if !previousValues.isEmpty {
            for (name, value) in byName where previousValues[name] != value {
                changed.insert(name)
            }
        }
        previousValues = byName
        changedNames = changed
        updatedAt = Date()
        nodes = buildNodes(from: byName, changed: changed)
        outlineView.reloadData()
        if let stateGroup = nodes.last {
            outlineView.expandItem(stateGroup)
        }
    }

    func clear() {
        previousValues = [:]
        changedNames = []
        nodes = []
        if isViewLoaded {
            outlineView.reloadData()
        }
    }

    private func buildNodes(from byName: [String: UInt64], changed: Set<String>) -> [Node] {
        guard !byName.isEmpty else { return [] }
        var result: [Node] = []
        for entry in Self.coreOrder {
            guard let raw = byName[entry.key] else { continue }
            let children: [Node]
            if entry.key == "xpsr" {
                children = DebugValueFormatter.xpsrBitfields(raw).map {
                    Node(key: $0.name, name: $0.name, value: $0.value)
                }
            } else {
                children = []
            }
            result.append(Node(
                key: entry.key,
                name: entry.label,
                value: DebugValueFormatter.hex32(raw),
                isChanged: changed.contains(entry.key),
                children: children
            ))
        }
        let stateChildren = DebugValueFormatter.executionState(
            xpsr: byName["xpsr"],
            control: byName["control"]
        ).map { Node(key: $0.name, name: $0.name, value: $0.value) }
        result.append(Node(key: "internal", name: "Internal", value: "", children: stateChildren))
        return result
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? Node else { return nodes.count }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? Node else { return nodes[index] }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? Node else { return false }
        return !node.children.isEmpty
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node, let identifier = tableColumn?.identifier else { return nil }
        let isName = identifier.rawValue == "register"
        let text = isName ? node.name : node.value
        let label = NSTextField(labelWithString: text)
        label.font = DebugTableStyle.font
        if !isName && node.isChanged {
            DebugTableStyle.markChanged(label, flash: DebugTableStyle.shouldFlash(since: updatedAt))
        }
        let cell = NSTableCellView()
        cell.identifier = identifier
        cell.textField = label
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}
