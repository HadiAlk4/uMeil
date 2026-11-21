import AppKit

/// The `Disassembly` panel: shows memory addresses, raw machine opcodes,
/// assembly mnemonics, interleaved C source lines when available, and the
/// current Program Counter (`PC`) indicator.
final class DisassemblyViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    enum Row: Equatable {
        case source(line: Int, text: String)
        case instruction(DisassembledInstruction, isProgramCounter: Bool)
    }

    let tableView = NSTableView()
    private(set) var rows: [Row] = []
    private(set) var programCounter: UInt64?

    init() {
        super.init(nibName: nil, bundle: nil)
        title = "Disassembly"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DisassemblyViewController is created in code, not from a nib")
    }

    override func loadView() {
        addColumn(identifier: "pc", title: "", width: 22)
        addColumn(identifier: "address", title: "Address", width: 95)
        addColumn(identifier: "opcodes", title: "Opcodes", width: 85)
        addColumn(identifier: "instruction", title: "Disassembly", width: 320)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 19

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        view = scrollView
    }

    private func addColumn(identifier: String, title: String, width: CGFloat) {
        let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        tableColumn.title = title
        tableColumn.width = width
        tableView.addTableColumn(tableColumn)
    }

    /// Updates the disassembly table and highlights the instruction at `programCounter`.
    func update(
        instructions: [DisassembledInstruction],
        programCounter: UInt64?,
        sourceLines: [Int: String] = [:]
    ) {
        loadViewIfNeeded()
        self.programCounter = programCounter
        var built: [Row] = []
        var lastLine: Int?
        var pcRowIndex: Int?

        for inst in instructions {
            if let line = inst.line, line != lastLine, let sourceText = sourceLines[line] {
                built.append(.source(line: line, text: sourceText))
                lastLine = line
            }
            let isPC = programCounter != nil && inst.address == programCounter
            if isPC {
                pcRowIndex = built.count
            }
            built.append(.instruction(inst, isProgramCounter: isPC))
        }
        rows = built
        tableView.reloadData()
        if let pcRowIndex {
            tableView.scrollRowToVisible(pcRowIndex)
        }
    }

    func clear() {
        rows = []
        programCounter = nil
        if isViewLoaded {
            tableView.reloadData()
        }
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let identifier = tableColumn?.identifier else { return nil }
        let item = rows[row]
        var text = ""
        var textColor: NSColor = .labelColor
        var isPC = false

        switch item {
        case .source(let line, let code):
            textColor = .secondaryLabelColor
            if identifier.rawValue == "address" {
                text = "Line \(line)"
            } else if identifier.rawValue == "instruction" {
                text = code.trimmingCharacters(in: .whitespaces)
            }
        case .instruction(let inst, let matchesPC):
            isPC = matchesPC
            switch identifier.rawValue {
            case "pc":
                text = matchesPC ? "▶" : ""
                textColor = .systemYellow
            case "address":
                text = DebugValueFormatter.hex32(inst.address)
            case "opcodes":
                text = inst.opcodes.uppercased()
                textColor = .secondaryLabelColor
            default:
                text = inst.instruction
            }
        }

        let label = NSTextField(labelWithString: text)
        label.font = DebugTableStyle.font
        label.textColor = textColor
        label.lineBreakMode = .byTruncatingTail

        let cell = NSTableCellView()
        cell.identifier = identifier
        cell.textField = label
        if isPC {
            cell.wantsLayer = true
            cell.layer?.backgroundColor = EditorTheme.executionLineColor.cgColor
        }
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
