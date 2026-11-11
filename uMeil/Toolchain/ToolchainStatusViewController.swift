import AppKit

/// Shows whether each tool uMeil needs is installed, with its version and location.
final class ToolchainStatusViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private enum Column: String, CaseIterable {
        case name, state, version, location

        var title: String {
            switch self {
            case .name: "Tool"
            case .state: "Status"
            case .version: "Version"
            case .location: "Location"
            }
        }

        var width: CGFloat {
            switch self {
            case .name: 150
            case .state: 190
            case .version: 80
            case .location: 420
            }
        }

        func text(in row: ToolStatusRow) -> String {
            switch self {
            case .name: row.name
            case .state: row.state
            case .version: row.version
            case .location: row.location
            }
        }
    }

    private let checker: ToolchainChecker
    private var rows: [ToolStatusRow] = ToolStatusRow.rows(for: [:])

    private let tableView = NSTableView()
    private let summaryLabel = NSTextField(labelWithString: "Checking tools…")
    private lazy var checkButton = NSButton(title: "Check Again", target: self, action: #selector(checkAgain(_:)))

    init(checker: ToolchainChecker = ToolchainChecker(locator: .standard())) {
        self.checker = checker
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ToolchainStatusViewController is created in code, not from a nib")
    }

    override func loadView() {
        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableView.addTableColumn(tableColumn)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsEmptySelection = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let bottomBar = NSStackView(views: [summaryLabel, NSView(), checkButton])
        bottomBar.orientation = .horizontal
        bottomBar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

        let stack = NSStackView(views: [scrollView, bottomBar])
        stack.orientation = .vertical
        stack.spacing = 0
        view = stack
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        refresh()
    }

    @objc private func checkAgain(_ sender: Any?) {
        refresh()
    }

    /// Looks for every tool again and updates the table when done.
    private func refresh() {
        checkButton.isEnabled = false
        summaryLabel.stringValue = "Checking tools…"

        Task {
            let statuses = await checker.checkAll()
            rows = ToolStatusRow.rows(for: statuses)
            summaryLabel.stringValue = ToolStatusRow.summary(for: statuses)
            checkButton.isEnabled = true
            tableView.reloadData()
        }
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier, let column = Column(rawValue: identifier.rawValue) else {
            return nil
        }

        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? Self.makeCell(identifier: identifier)
        let text = column.text(in: rows[row])
        cell.textField?.stringValue = text
        cell.toolTip = text
        return cell
    }

    private static func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false

        let cell = NSTableCellView()
        cell.identifier = identifier
        cell.textField = label
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}
