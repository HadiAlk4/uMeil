import AppKit

/// Shows whether each tool uMeil needs is installed, with its version and
/// location, and offers to download the ones that are missing.
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

    /// Builds a fresh checker for every check, because installing a
    /// toolchain adds a new folder to the list of places to search.
    private let makeChecker: () -> ToolchainChecker
    private let installer: ToolchainInstaller
    private var statuses: [Tool: ToolStatus] = [:]
    private var rows: [ToolStatusRow] = ToolStatusRow.rows(for: [:])

    private let tableView = NSTableView()
    private let spinner = NSProgressIndicator()
    private let summaryLabel = NSTextField(labelWithString: "Checking tools…")
    private lazy var checkButton = NSButton(title: "Check Again", target: self, action: #selector(checkAgain(_:)))
    private lazy var installButton = NSButton(
        title: "Install Missing Tools",
        target: self,
        action: #selector(installMissingTools(_:))
    )

    init(
        makeChecker: @escaping () -> ToolchainChecker = { ToolchainChecker(locator: .standard()) },
        installer: ToolchainInstaller = ToolchainInstaller()
    ) {
        self.makeChecker = makeChecker
        self.installer = installer
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

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        installButton.isHidden = true
        installButton.keyEquivalent = "\r"

        let bottomBar = NSStackView(views: [spinner, summaryLabel, NSView(), checkButton, installButton])
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

    /// Downloads and installs the packages for every tool that is not working.
    @objc private func installMissingTools(_ sender: Any?) {
        let needed = ToolchainCatalog.entriesNeeded(for: statuses)
        guard !needed.isEmpty else { return }
        setBusy(true)

        Task {
            do {
                for entry in needed {
                    summaryLabel.stringValue = "Downloading and installing \(entry.displayNameWithSize)…"
                    try await installer.install(entry.package)
                }
            } catch {
                presentInstallError(error)
            }
            refresh()
        }
    }

    /// Looks for every tool again and updates the table when done.
    private func refresh() {
        setBusy(true)
        summaryLabel.stringValue = "Checking tools…"

        Task {
            statuses = await makeChecker().checkAll()
            rows = ToolStatusRow.rows(for: statuses)
            summaryLabel.stringValue = ToolStatusRow.summary(for: statuses)
            installButton.isHidden = ToolchainCatalog.entriesNeeded(for: statuses).isEmpty
            tableView.reloadData()
            setBusy(false)
        }
    }

    private func setBusy(_ busy: Bool) {
        checkButton.isEnabled = !busy
        installButton.isEnabled = !busy
        if busy {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
    }

    private func presentInstallError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The tools could not be installed"
        alert.informativeText = error.localizedDescription
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
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
