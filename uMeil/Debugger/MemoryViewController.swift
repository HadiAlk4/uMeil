import AppKit

/// The `Memory 1` panel: lets the user enter a hex address or expression
/// (`0x20000258` or `&result`) and shows a 16-byte-per-row hex dump with
/// little-endian byte ordering and ASCII decoding. While the program is
/// stopped, typing over a row's bytes writes them to the chip.
final class MemoryViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    /// Row height at the standard font size.
    static let baseRowHeight: CGFloat = 19

    let addressField = NSTextField()
    let lengthPopUp = NSPopUpButton()
    let messageLabel = NSTextField(labelWithString: "")
    let tableView = NSTableView()

    /// How many bytes the view can show at once.
    static let lengths = [64, 256, 1024]

    private(set) var currentAddress: UInt64?
    private(set) var rows: [DebugValueFormatter.MemoryRow] = []
    /// Addresses whose byte differs from the last time it was shown.
    private(set) var changedAddresses: Set<UInt64> = []
    private var previousBytes: [UInt64: UInt8] = [:]
    /// When the bytes last changed, so their cells flash only then.
    private var updatedAt: Date?
    /// Failure message from the most recent address resolution or read, if any.
    private(set) var statusMessage = ""
    /// How many bytes to read from `currentAddress`.
    private(set) var byteCount = 64
    /// Bytes can be typed only while the program is stopped.
    var isEditable = false {
        didSet {
            if isViewLoaded, isEditable != oldValue { tableView.reloadData() }
        }
    }

    /// Called when the user enters an address or expression to inspect.
    var onRequestAddress: ((String) -> Void)?
    /// Called when the user picks a length; read `byteCount` bytes again.
    var onLengthChange: (() -> Void)?
    /// Called with bytes the user typed and the address of the first one.
    var onWriteBytes: ((UInt64, [UInt8]) -> Void)?

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

        lengthPopUp.controlSize = .small
        lengthPopUp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        lengthPopUp.addItems(withTitles: Self.lengths.map { "\($0) bytes" })
        lengthPopUp.selectItem(at: Self.lengths.firstIndex(of: byteCount) ?? 0)
        lengthPopUp.target = self
        lengthPopUp.action = #selector(lengthChosen(_:))

        let topBar = NSStackView(views: [prompt, addressField, lengthPopUp])
        topBar.orientation = .horizontal
        topBar.spacing = 6
        topBar.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

        messageLabel.textColor = .secondaryLabelColor
        messageLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        messageLabel.isHidden = true

        let headerBar = NSStackView(views: [topBar, messageLabel])
        headerBar.orientation = .vertical
        headerBar.alignment = .leading
        headerBar.spacing = 2
        headerBar.detachesHiddenViews = true
        topBar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor)
        ])

        addColumn(identifier: "address", title: "Address", width: 95)
        addColumn(identifier: "hex", title: "Data (Hex)", width: 340)
        addColumn(identifier: "ascii", title: "ASCII", width: 130)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = DebugTableStyle.rowHeight(base: Self.baseRowHeight)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        view = PanelLayout.view(bar: headerBar, content: scrollView)
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
        statusMessage = ""
        messageLabel.stringValue = ""
        messageLabel.toolTip = nil
        messageLabel.isHidden = true
        if addressField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
            addressField.stringValue = DebugValueFormatter.hex32(address)
        }
        rows = DebugValueFormatter.memoryRows(from: bytes, baseAddress: address)
        var shown: [UInt64: UInt8] = [:]
        for (offset, byte) in bytes.enumerated() {
            shown[address + UInt64(offset)] = byte
        }
        // Only bytes seen before can have changed; a new address starts clean.
        changedAddresses = Set(shown.compactMap { address, byte in
            previousBytes[address].map { $0 != byte } == true ? address : nil
        })
        previousBytes = shown
        updatedAt = Date()
        tableView.reloadData()
    }

    /// The positions in `row` of bytes that changed, counting from 0.
    func changedOffsets(inRow row: Int) -> Set<Int> {
        guard rows.indices.contains(row) else { return [] }
        let start = rows[row].address
        return Set(rows[row].bytes.indices.filter { changedAddresses.contains(start + UInt64($0)) })
    }

    /// Clears stale rows and displays a failure message when inspecting an
    /// address or reading memory fails.
    func showError(_ message: String) {
        loadViewIfNeeded()
        currentAddress = nil
        rows = []
        changedAddresses = []
        previousBytes = [:]
        updatedAt = nil
        statusMessage = message
        messageLabel.stringValue = message
        messageLabel.toolTip = message
        messageLabel.isHidden = message.isEmpty
        tableView.reloadData()
    }

    /// Reverts any uncommitted text typed into table cells back to `rows`.
    func revertEdits() {
        if isViewLoaded {
            tableView.reloadData()
        }
    }

    func clear() {
        currentAddress = nil
        rows = []
        changedAddresses = []
        previousBytes = [:]
        isEditable = false
        statusMessage = ""
        addressField.stringValue = ""
        if isViewLoaded {
            messageLabel.stringValue = ""
            messageLabel.toolTip = nil
            messageLabel.isHidden = true
            tableView.reloadData()
        }
    }

    @objc func addressSubmitted(_ sender: Any?) {
        let text = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onRequestAddress?(text)
    }

    /// Changes how many bytes are shown, as the length menu does.
    func setByteCount(_ count: Int) {
        guard count > 0, count != byteCount else { return }
        byteCount = count
        if isViewLoaded, let index = Self.lengths.firstIndex(of: count) {
            lengthPopUp.selectItem(at: index)
        }
        onLengthChange?()
    }

    @objc private func lengthChosen(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard Self.lengths.indices.contains(index) else { return }
        setByteCount(Self.lengths[index])
    }

    /// Writes what was typed over row `row`'s bytes: the run from the first
    /// changed byte to the last. Returns false, writing nothing, when the panel
    /// is not editable or the text is not exactly the row's number of hex bytes.
    @discardableResult
    func commitEdit(_ text: String, inRow row: Int) -> Bool {
        guard isEditable,
              rows.indices.contains(row),
              let typed = DebugValueFormatter.parseHexBytes(text),
              typed.count == rows[row].bytes.count
        else { return false }
        if let run = DebugValueFormatter.changedRun(from: rows[row].bytes, to: typed) {
            onWriteBytes?(rows[row].address + UInt64(run.offset), run.bytes)
        }
        return true
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

        let cell: NSTableCellView
        let label: NSTextField
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView,
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

        label.layer?.removeAnimation(forKey: "changedFlash")
        label.layer?.backgroundColor = NSColor.clear.cgColor
        label.textColor = .labelColor
        label.font = DebugTableStyle.font
        label.lineBreakMode = .byTruncatingTail
        label.stringValue = text
        if identifier.rawValue == "hex" {
            let changed = changedOffsets(inRow: row)
            if !changed.isEmpty {
                // Only the changed bytes are red, not the whole row.
                label.attributedStringValue = DebugTableStyle.hexBytes(text, changedOffsets: changed)
                if DebugTableStyle.shouldFlash(since: updatedAt) {
                    DebugTableStyle.flash(label)
                }
            }
        }
        let editable = identifier.rawValue == "hex" && isEditable
        label.isEditable = editable
        label.delegate = editable ? self : nil
        return cell
    }

    // MARK: - Typing bytes

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        let row = tableView.row(for: field)
        if !commitEdit(field.stringValue, inRow: row) {
            NSSound.beep()
            if rows.indices.contains(row) {
                field.stringValue = rows[row].hexText
            }
        }
    }
}
