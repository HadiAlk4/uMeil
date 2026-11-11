import AppKit

/// The panel under the editor that lists the errors and warnings from the
/// last build. Clicking one takes the editor to that line.
final class IssuesViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    /// Called when the user picks a message that points at a file.
    var onSelect: ((Diagnostic) -> Void)?

    private(set) var diagnostics: [Diagnostic] = []

    let tableView = NSTableView()
    let statusLabel = NSTextField(labelWithString: "No build yet")
    private let spinner = NSProgressIndicator()

    private enum Column: String, CaseIterable {
        case message, location

        var title: String {
            switch self {
            case .message: "Issue"
            case .location: "Location"
            }
        }
    }

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("IssuesViewController is created in code, not from a nib")
    }

    override func loadView() {
        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column == .message ? 520 : 160
            tableView.addTableColumn(tableColumn)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsEmptySelection = true
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.target = self
        tableView.action = #selector(rowClicked(_:))

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let statusBar = NSStackView(views: [spinner, statusLabel, NSView()])
        statusBar.orientation = .horizontal
        statusBar.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)

        let stack = NSStackView(views: [statusBar, scrollView])
        stack.orientation = .vertical
        stack.spacing = 0

        // Without a background of its own the status line shows whatever is
        // behind the panel, which is not the same in light and dark mode.
        let background = NSVisualEffectView()
        background.material = .windowBackground
        background.blendingMode = .withinWindow
        background.state = .followsWindowActiveState
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor)
        ])
        view = background
    }

    /// Shows that a build is running.
    func showBuilding() {
        loadViewIfNeeded()
        statusLabel.stringValue = "Building…"
        spinner.startAnimation(nil)
    }

    /// Shows the outcome of a build. Notes are listed under the message they belong to.
    func show(_ result: BuildResult) {
        show(status: BuildSummary.statusText(for: result), diagnostics: result.diagnostics)
    }

    /// Shows a build that could not start at all, such as a missing compiler.
    func show(failure message: String) {
        show(status: "Build failed", diagnostics: [Diagnostic(severity: .error, message: message)])
    }

    private func show(status: String, diagnostics: [Diagnostic]) {
        loadViewIfNeeded()
        spinner.stopAnimation(nil)
        statusLabel.stringValue = status
        self.diagnostics = diagnostics
        tableView.reloadData()
    }

    @objc private func rowClicked(_ sender: Any?) {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard diagnostics.indices.contains(row), diagnostics[row].file != nil else { return }
        onSelect?(diagnostics[row])
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        diagnostics.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier, let column = Column(rawValue: identifier.rawValue) else {
            return nil
        }
        let diagnostic = diagnostics[row]

        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? Self.makeCell(identifier: identifier, hasIcon: column == .message)

        switch column {
        case .message:
            cell.textField?.stringValue = diagnostic.message
            cell.imageView?.image = Self.icon(for: diagnostic.severity)
            cell.imageView?.contentTintColor = Self.color(for: diagnostic.severity)
        case .location:
            cell.textField?.stringValue = BuildSummary.locationText(for: diagnostic)
        }
        cell.toolTip = diagnostic.message
        return cell
    }

    static func color(for severity: Diagnostic.Severity) -> NSColor {
        switch severity {
        case .error: .systemRed
        case .warning: .systemYellow
        case .note: .secondaryLabelColor
        }
    }

    private static func icon(for severity: Diagnostic.Severity) -> NSImage? {
        let name = switch severity {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .note: "info.circle"
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: severity.rawValue)
    }

    private static func makeCell(identifier: NSUserInterfaceItemIdentifier, hasIcon: Bool) -> NSTableCellView {
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        let cell = NSTableCellView()
        cell.identifier = identifier
        cell.textField = label
        cell.addSubview(label)

        var leading = cell.leadingAnchor
        var spacing: CGFloat = 2
        if hasIcon {
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            cell.imageView = icon
            cell.addSubview(icon)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 14),
                icon.heightAnchor.constraint(equalToConstant: 14)
            ])
            leading = icon.trailingAnchor
            spacing = 6
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leading, constant: spacing),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}
