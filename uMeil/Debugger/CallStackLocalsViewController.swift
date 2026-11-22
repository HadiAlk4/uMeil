import AppKit

/// The `Call Stack + Locals` panel: shows active stack frames and each frame's
/// parameters and local variables, with pointer expansion (`*p`), changed-value
/// highlighting, and a right-click toggle for Hexadecimal Display.
final class CallStackLocalsViewController: NSViewController, NSMenuItemValidation {
    /// Row height at the standard font size.
    static let baseRowHeight: CGFloat = 20

    struct VariableIdentity: Hashable {
        let depthFromBottom: Int
        let function: String
        let name: String
    }

    final class FrameNode {
        let frame: StackFrame
        let children: [VariableNode]
        var name: String { frame.function ?? "??" }
        var valueText: String { DebugValueFormatter.hex32(frame.address) }
        var typeText: String { "frame" }

        init(frame: StackFrame, children: [VariableNode]) {
            self.frame = frame
            self.children = children
        }
    }

    final class VariableNode {
        let key: String
        let name: String
        var rawValue: String?
        let rawType: String?
        let displayType: String
        let frameLevel: Int
        let isChanged: Bool
        var children: [VariableNode]
        let identity: VariableIdentity?

        init(
            key: String, name: String, rawValue: String?, rawType: String?, displayType: String,
            frameLevel: Int = 0, isChanged: Bool = false, children: [VariableNode] = [],
            identity: VariableIdentity? = nil
        ) {
            self.key = key
            self.name = name
            self.rawValue = rawValue
            self.rawType = rawType
            self.displayType = displayType
            self.frameLevel = frameLevel
            self.isChanged = isChanged
            self.children = children
            self.identity = identity
        }
    }

    let outlineView = NSOutlineView()
    private(set) var frameNodes: [FrameNode] = []
    /// Variable keys (`"<level>:<name>"`) whose value changed on the most recent stop.
    private(set) var changedKeys: Set<String> = []
    private var previousValues: [VariableIdentity: String] = [:]
    private var expandedPointers: Set<VariableIdentity> = []
    private var isUpdating = false
    /// When the values last changed, so their cells flash only then.
    private var updatedAt: Date?
    private var handledSelectionRow: Int?
    private var selectionNotifyGeneration = 0

    /// When true (the default), integers are formatted in two's complement hex.
    var useHexadecimal = true {
        didSet {
            if isViewLoaded { outlineView.reloadData() }
        }
    }

    /// Called when the user selects a stack frame row.
    var onSelectFrame: ((StackFrame) -> Void)?
    /// Evaluates `*name` when the user expands a pointer variable.
    var onDereference: ((String) async -> String?)?
    /// Evaluates `*name` in the variable's stack frame level when the user expands a
    /// pointer variable. Falls back to `onDereference` when `nil`.
    var onDereferenceInFrame: ((String, Int) async -> String?)?

    init() {
        super.init(nibName: nil, bundle: nil)
        title = "Call Stack + Locals"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("CallStackLocalsViewController is created in code, not from a nib")
    }

    override func loadView() {
        addColumn(identifier: "name", title: "Name", width: 110)
        addColumn(identifier: "value", title: "Location/Value", width: 120)
        addColumn(identifier: "type", title: "Type", width: 100)
        outlineView.outlineTableColumn = outlineView.tableColumns.first
        outlineView.dataSource = self
        outlineView.delegate = self
        // No alternating stripes: AppKit paints them below the last row too,
        // and a stack only a frame or two deep looked like a list of empty rows.
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.rowHeight = DebugTableStyle.rowHeight(base: Self.baseRowHeight)
        outlineView.target = self
        outlineView.action = #selector(rowClicked(_:))

        let menu = NSMenu()
        let hexItem = NSMenuItem(
            title: "Hexadecimal Display",
            action: #selector(toggleHexadecimalDisplay(_:)),
            keyEquivalent: ""
        )
        hexItem.target = self
        menu.addItem(hexItem)
        outlineView.menu = menu

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        view = scrollView
    }

    private func addColumn(identifier: String, title: String, width: CGFloat) {
        let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        tableColumn.title = title
        tableColumn.width = width
        outlineView.addTableColumn(tableColumn)
    }

    /// Updates the call stack hierarchy and local variables for each frame.
    func update(
        frames: [StackFrame],
        variablesByFrame: [Int: [DebugVariable]],
        dereferencedValues: [String: String] = [:]
    ) {
        loadViewIfNeeded()
        syncExpandedPointers()

        var currentValues: [VariableIdentity: String] = [:]
        var changed: Set<String> = []
        let totalFrames = frames.count

        frameNodes = frames.enumerated().map { index, frame in
            let depthFromBottom = totalFrames - 1 - index
            let vars = variablesByFrame[frame.level] ?? []
            let children = vars.map { variable -> VariableNode in
                let key = "\(frame.level):\(variable.name)"
                let identity = VariableIdentity(
                    depthFromBottom: depthFromBottom,
                    function: frame.function ?? "",
                    name: variable.name
                )
                let raw = variable.value ?? ""
                currentValues[identity] = raw
                if let old = previousValues[identity], old != raw {
                    changed.insert(key)
                }
                let deref = dereferencedValues["\(frame.level):*\(variable.name)"]
                    ?? dereferencedValues["*\(variable.name)"]
                return makeVariableNode(
                    variable,
                    frameLevel: frame.level,
                    identity: identity,
                    isChanged: changed.contains(key),
                    dereferenced: deref
                )
            }
            return FrameNode(frame: frame, children: children)
        }
        previousValues = currentValues
        changedKeys = changed
        updatedAt = Date()
        reloadAndRestoreExpansion()
    }

    private func syncExpandedPointers() {
        for frameNode in frameNodes {
            for variableNode in frameNode.children where !variableNode.children.isEmpty {
                guard let identity = variableNode.identity else { continue }
                if outlineView.isItemExpanded(variableNode) {
                    expandedPointers.insert(identity)
                } else {
                    expandedPointers.remove(identity)
                }
            }
        }
    }

    private func reloadAndRestoreExpansion() {
        isUpdating = true
        outlineView.reloadData()
        for node in frameNodes {
            outlineView.expandItem(node)
        }
        isUpdating = false
        for frameNode in frameNodes {
            for variableNode in frameNode.children where !variableNode.children.isEmpty {
                if let identity = variableNode.identity, expandedPointers.contains(identity) {
                    outlineView.expandItem(variableNode)
                }
            }
        }
    }

    func clear() {
        frameNodes = []
        previousValues = [:]
        changedKeys = []
        expandedPointers = []
        handledSelectionRow = nil
        if isViewLoaded {
            isUpdating = true
            outlineView.reloadData()
            isUpdating = false
        }
    }

    private func makeVariableNode(
        _ variable: DebugVariable, frameLevel: Int, identity: VariableIdentity,
        isChanged: Bool, dereferenced: String?
    ) -> VariableNode {
        let key = "\(frameLevel):\(variable.name)"
        var children: [VariableNode] = []
        if DebugValueFormatter.isPointer(variable) {
            let targetType = DebugValueFormatter.dereferencedType(variable.type)
            children.append(VariableNode(
                key: "\(key):deref", name: "*\(variable.name)", rawValue: dereferenced,
                rawType: targetType, displayType: targetType, frameLevel: frameLevel
            ))
        }
        return VariableNode(
            key: key, name: variable.name, rawValue: variable.value, rawType: variable.type,
            displayType: DebugValueFormatter.displayType(for: variable),
            frameLevel: frameLevel, isChanged: isChanged, children: children, identity: identity
        )
    }

    private func containsNode(_ target: VariableNode) -> Bool {
        frameNodes.contains { frame in
            frame.children.contains { $0 === target || $0.children.contains { $0 === target } }
        }
    }

    private func dereferenceHandler() -> ((String, Int) async -> String?)? {
        if let onDereferenceInFrame { return onDereferenceInFrame }
        if let onDereference { return { expr, _ in await onDereference(expr) } }
        return nil
    }

    @objc func toggleHexadecimalDisplay(_ sender: Any?) { useHexadecimal.toggle() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleHexadecimalDisplay(_:)) {
            menuItem.state = useHexadecimal ? .on : .off
        }
        return true
    }

    @objc func rowClicked(_ sender: Any?) {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        guard row >= 0, let frameNode = outlineView.item(atRow: row) as? FrameNode else { return }
        if handledSelectionRow == row {
            handledSelectionRow = nil
            return
        }
        onSelectFrame?(frameNode.frame)
    }
}

extension CallStackLocalsViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return frameNodes.count }
        if let frame = item as? FrameNode { return frame.children.count }
        if let variable = item as? VariableNode { return variable.children.count }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return frameNodes[index] }
        if let frame = item as? FrameNode { return frame.children[index] }
        if let variable = item as? VariableNode { return variable.children[index] }
        return frameNodes[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if let frame = item as? FrameNode { return !frame.children.isEmpty }
        if let variable = item as? VariableNode { return !variable.children.isEmpty }
        return false
    }

    // MARK: - NSOutlineViewDelegate

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isUpdating else { return }
        let row = outlineView.selectedRow
        guard row >= 0, let frameNode = outlineView.item(atRow: row) as? FrameNode else { return }
        handledSelectionRow = row
        selectionNotifyGeneration += 1
        let generation = selectionNotifyGeneration
        Task { @MainActor [weak self] in
            if self?.selectionNotifyGeneration == generation {
                self?.handledSelectionRow = nil
            }
        }
        onSelectFrame?(frameNode.frame)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let variable = notification.userInfo?["NSObject"] as? VariableNode else { return }
        if let identity = variable.identity { expandedPointers.insert(identity) }
        guard let child = variable.children.first,
              child.rawValue == nil,
              let dereference = dereferenceHandler()
        else { return }
        let expression = child.name
        let frameLevel = variable.frameLevel
        Task { @MainActor [weak self] in
            let value = await dereference(expression, frameLevel)
            guard let self, self.containsNode(child) else { return }
            child.rawValue = value ?? "<unavailable>"
            self.outlineView.reloadItem(child)
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isUpdating,
              let variable = notification.userInfo?["NSObject"] as? VariableNode,
              let identity = variable.identity
        else { return }
        expandedPointers.remove(identity)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let identifier = tableColumn?.identifier else { return nil }
        let text: String
        var isChanged = false

        if let frame = item as? FrameNode {
            switch identifier.rawValue {
            case "name": text = frame.name
            case "value": text = frame.valueText
            default: text = frame.typeText
            }
        } else if let variable = item as? VariableNode {
            switch identifier.rawValue {
            case "name": text = variable.name
            case "value":
                text = DebugValueFormatter.format(
                    variable.rawValue, type: variable.rawType, hexadecimal: useHexadecimal
                )
                isChanged = variable.isChanged
            default: text = variable.displayType
            }
        } else {
            return nil
        }

        return makeCell(outlineView: outlineView, identifier: identifier, text: text, isChanged: isChanged)
    }

    private func makeCell(
        outlineView: NSOutlineView, identifier: NSUserInterfaceItemIdentifier, text: String, isChanged: Bool
    ) -> NSTableCellView {
        let cell: NSTableCellView
        let label: NSTextField
        if let reused = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView,
           let existingLabel = reused.textField {
            (cell, label) = (reused, existingLabel)
        } else {
            label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            cell = NSTableCellView()
            cell.identifier = identifier
            cell.textField = label
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        label.layer?.removeAnimation(forKey: "changedFlash")
        label.layer?.backgroundColor = NSColor.clear.cgColor
        label.drawsBackground = false
        label.backgroundColor = .clear
        let isValue = identifier.rawValue == "value"
        DebugTableStyle.applyValue(
            text,
            to: label,
            isChanged: isValue && isChanged,
            flash: isValue && DebugTableStyle.shouldFlash(since: updatedAt),
            styleHex: isValue
        )
        return cell
    }
}
