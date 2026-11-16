import AppKit

/// The `Memory 1` panel: lets the user enter a hex address or expression
/// (`0x20000258` or `&result`) and shows a 16-byte-per-row hex dump with
/// little-endian byte ordering and ASCII decoding.
final class MemoryViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let addressField = NSTextField()
    let tableView = NSTableView()

    private(set) var currentAddress: UInt64?
    private(set) var rows: [DebugValueFormatter.MemoryRow] = []

    /// Called when the user enters an address or expression to inspect.
    var onRequestAddress: ((String) -> Void)?

    init() {
        super.init(nibName: nil, bundle: nil)
        title = "Memory 1"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MemoryViewController is created in code, not from a nib")
    }

    override func loadView() {
        let prompt = NSTextField(labelWithString: "Address:")
        addressField.placeholderString = "0x20000000"
        addressField.font = EditorTheme.font
        addressField.target = self
        addressField.action = #selector(addressSubmitted(_:))

        let topBar = NSStackView(views: [prompt, addressField])
        topBar.orientation = .horizontal
        topBar.spacing = 6
        topBar.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

        addColumn(identifier: "address", title: "Address", width: 95)
        addColumn(identifier: "hex", title: "Data (Hex)", width: 340)
        addColumn(identifier: "ascii", title: "ASCII", width: 130)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 19

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        let stack = NSStackView(views: [topBar, scrollView])
        stack.orientation = .vertical
        stack.spacing = 0
        view = stack
    }

    private func addColumn(identifier: String, title: String, width: CGFloat) {
        let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        tableColumn.title = title
        tableColumn.width = width
        tableView.addTableColumn(tableColumn)
    }

    /// Displays `bytes` starting at `address` as 16-byte hex dump rows.
    func showMemory(at address: UInt64, bytes: [UInt8]) {
        loadViewIfNeeded()
        currentAddress = address
        if addressField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
            addressField.stringValue = DebugValueFormatter.hex32(address)
        }
        rows = DebugValueFormatter.memoryRows(from: bytes, baseAddress: address)
        tableView.reloadData()
    }

    func clear() {
        currentAddress = nil
        rows = []
        if isViewLoaded {
            tableView.reloadData()
        }
    }

    @objc func addressSubmitted(_ sender: Any?) {
        let text = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onRequestAddress?(text)
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let identifier = tableColumn?.identifier else { return nil }
        let item = rows[row]
        let text = switch identifier.rawValue {
        case "address": item.addressText
        case "hex": item.hexText
        default: item.asciiText
        }

        let label = NSTextField(labelWithString: text)
        label.font = EditorTheme.font
        label.lineBreakMode = .byTruncatingTail

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
