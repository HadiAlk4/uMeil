import AppKit

/// The `Regs` panel: shows general-purpose registers (`R0`–`R12`), `SP`, `LR`,
/// `PC`, `xPSR` (expandable into condition flags and `ISR`), special registers,
/// and the Cortex-M processor state (`Mode`, `Privilege`, `Stack`).
final class RegistersViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    /// Row height at the standard font size.
    static let baseRowHeight: CGFloat = 20

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
    private var expandedKeys: Set<String> = ["internal"]
    private var isUpdating = false

    private static let coreOrder: [(key: String, label: String)] = [
        ("r0", "R0"), ("r1", "R1"), ("r2", "R2"), ("r3", "R3"),
        ("r4", "R4"), ("r5", "R5"), ("r6", "R6"), ("r7", "R7"),
        ("r8", "R8"), ("r9", "R9"), ("r10", "R10"), ("r11", "R11"),
        ("r12", "R12"), ("sp", "SP (R13)"), ("lr", "LR (R14)"), ("pc", "PC (R15)"),
        ("xpsr", "xPSR"), ("msp", "MSP"), ("psp", "PSP"),
        ("primask", "PRIMASK"), ("basepri", "BASEPRI"),
        ("faultmask", "FAULTMASK"), ("control", "CONTROL")
    ]

    private struct FPURegister {
        let key: String
        let label: String
        let is64Bit: Bool
    }

    private static let fpuOrder: [FPURegister] = {
        var list = [FPURegister(key: "fpscr", label: "FPSCR", is64Bit: false)]
        for index in 0..<32 {
            list.append(FPURegister(key: "s\(index)", label: "S\(index)", is64Bit: false))
        }
        for index in 0..<16 {
            list.append(FPURegister(key: "d\(index)", label: "D\(index)", is64Bit: true))
        }
        return list
    }()

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
        outlineView.rowHeight = DebugTableStyle.rowHeight(base: Self.baseRowHeight)

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
        // Sync expanded group state before replacing nodes.
        for node in nodes where !node.children.isEmpty {
            if outlineView.isItemExpanded(node) {
                expandedKeys.insert(node.key)
            } else {
                expandedKeys.remove(node.key)
            }
        }

        var byName: [String: UInt64] = [:]
        for reg in registers {
            if let value = reg.value {
                byName[reg.name.lowercased()] = value
            }
        }

        let oldValues = previousValues
        var changed: Set<String> = []
        if !oldValues.isEmpty {
            for (name, value) in byName where oldValues[name] != value {
                changed.insert(name)
            }
        }
        previousValues = byName
        changedNames = changed
        updatedAt = Date()
        nodes = buildNodes(from: byName, previous: oldValues, changed: changed)

        isUpdating = true
        outlineView.reloadData()
        for node in nodes where !node.children.isEmpty && expandedKeys.contains(node.key) {
            outlineView.expandItem(node)
        }
        isUpdating = false
    }

    func clear() {
        previousValues = [:]
        changedNames = []
        nodes = []
        expandedKeys = ["internal"]
        if isViewLoaded {
            isUpdating = true
            outlineView.reloadData()
            isUpdating = false
        }
    }

    private func buildNodes(
        from byName: [String: UInt64],
        previous: [String: UInt64],
        changed: Set<String>
    ) -> [Node] {
        guard !byName.isEmpty else { return [] }
        var result = buildCoreNodes(from: byName, previous: previous, changed: changed)
        if let fpuNode = buildFPUNode(from: byName, changed: changed) {
            result.append(fpuNode)
        }
        result.append(buildInternalNode(from: byName, previous: previous))
        return result
    }

    private func buildCoreNodes(
        from byName: [String: UInt64],
        previous: [String: UInt64],
        changed: Set<String>
    ) -> [Node] {
        let previousXPSRFields = previous["xpsr"].map {
            Dictionary(uniqueKeysWithValues: DebugValueFormatter.xpsrBitfields($0).map { ($0.name, $0.value) })
        } ?? [:]

        return Self.coreOrder.compactMap { entry in
            guard let raw = byName[entry.key] else { return nil }
            let children: [Node] = entry.key == "xpsr"
                ? DebugValueFormatter.xpsrBitfields(raw).map { field in
                    let isChanged = previousXPSRFields[field.name].map { $0 != field.value } ?? false
                    return Node(key: field.name, name: field.name, value: field.value, isChanged: isChanged)
                }
                : []
            return Node(
                key: entry.key,
                name: entry.label,
                value: DebugValueFormatter.hex32(raw),
                isChanged: changed.contains(entry.key),
                children: children
            )
        }
    }

    private func buildFPUNode(from byName: [String: UInt64], changed: Set<String>) -> Node? {
        let children: [Node] = Self.fpuOrder.compactMap { entry in
            guard let raw = byName[entry.key] else { return nil }
            let formatted = entry.is64Bit ? String(format: "0x%016llX", raw) : DebugValueFormatter.hex32(raw)
            return Node(key: entry.key, name: entry.label, value: formatted, isChanged: changed.contains(entry.key))
        }
        return children.isEmpty ? nil : Node(key: "fpu", name: "FPU", value: "", children: children)
    }

    private func buildInternalNode(from byName: [String: UInt64], previous: [String: UInt64]) -> Node {
        let previousStateFields: [String: String] = previous.isEmpty ? [:] : Dictionary(
            uniqueKeysWithValues: DebugValueFormatter.executionState(
                xpsr: previous["xpsr"],
                control: previous["control"]
            ).map { ($0.name, $0.value) }
        )
        let children = DebugValueFormatter.executionState(
            xpsr: byName["xpsr"],
            control: byName["control"]
        ).map { field in
            let isChanged = previousStateFields[field.name].map { $0 != field.value } ?? false
            return Node(key: field.name, name: field.name, value: field.value, isChanged: isChanged)
        }
        return Node(key: "internal", name: "Internal", value: "", children: children)
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

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isUpdating, let node = notification.userInfo?["NSObject"] as? Node else { return }
        expandedKeys.insert(node.key)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isUpdating, let node = notification.userInfo?["NSObject"] as? Node else { return }
        expandedKeys.remove(node.key)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node, let identifier = tableColumn?.identifier else { return nil }
        let isName = identifier.rawValue == "register"
        let text = isName ? node.name : node.value
        let cell: NSTableCellView
        let label: NSTextField
        if let reused = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView,
           let existingLabel = reused.textField {
            cell = reused
            label = existingLabel
        } else {
            let createdLabel = NSTextField(labelWithString: "")
            createdLabel.lineBreakMode = .byTruncatingTail
            createdLabel.translatesAutoresizingMaskIntoConstraints = false
            let createdCell = NSTableCellView()
            createdCell.identifier = identifier
            createdCell.textField = createdLabel
            createdCell.addSubview(createdLabel)
            NSLayoutConstraint.activate([
                createdLabel.leadingAnchor.constraint(equalTo: createdCell.leadingAnchor, constant: 2),
                createdLabel.trailingAnchor.constraint(equalTo: createdCell.trailingAnchor, constant: -2),
                createdLabel.centerYAnchor.constraint(equalTo: createdCell.centerYAnchor)
            ])
            cell = createdCell
            label = createdLabel
        }

        label.stringValue = text
        label.font = DebugTableStyle.font
        label.lineBreakMode = .byTruncatingTail
        label.layer?.removeAnimation(forKey: "changedFlash")
        label.layer?.backgroundColor = NSColor.clear.cgColor
        label.drawsBackground = false
        label.backgroundColor = .clear
        if !isName && node.isChanged {
            DebugTableStyle.markChanged(label, flash: DebugTableStyle.shouldFlash(since: updatedAt))
        } else {
            label.textColor = .labelColor
        }
        return cell
    }
}
