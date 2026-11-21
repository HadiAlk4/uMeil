import AppKit

/// The panel under the editor that lists the errors and warnings from the
/// last build, and shows how a flash is going. Clicking a message takes the
/// editor to that line.
final class IssuesViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    /// Called when the user picks a message that points at a file.
    var onSelect: ((Diagnostic) -> Void)?
    /// Called with each change of status, for the toolbar to show.
    var onActivity: ((Activity) -> Void)?

    private(set) var diagnostics: [Diagnostic] = []

    let tableView = NSTableView()
    let statusLabel = NSTextField(labelWithString: "No build yet")
    private let spinner = NSProgressIndicator()
    /// Fills up as a flash moves through its stages. Hidden otherwise.
    let progressBar = NSProgressIndicator()

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
        // Hidden from the start, not just once the view loads.
        progressBar.isHidden = true
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

        progressBar.style = .bar
        progressBar.controlSize = .small
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.widthAnchor.constraint(equalToConstant: 160).isActive = true
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let statusBar = NSStackView(views: [spinner, statusLabel, NSView(), progressBar])
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
        onActivity?(Activity(text: "Building…", kind: .working(progress: nil)))
    }

    /// Shows the outcome of a build. Notes are listed under the message they belong to.
    func show(_ result: BuildResult) {
        show(status: BuildSummary.statusText(for: result), diagnostics: result.diagnostics)
        publish(Activity.outcome(of: result.diagnostics))
    }

    /// Shows a build that could not start at all, such as a missing compiler.
    func show(failure message: String) {
        show(status: "Build failed", diagnostics: [Diagnostic(severity: .error, message: message)])
        publish(.failed)
    }

    /// Empties the list, for work that has nothing to do with the last build.
    func clear() {
        show(status: "", diagnostics: [])
        onActivity?(.idle)
    }

    /// Shows that a flash has reached `stage`. The messages from the build
    /// that came before it stay listed.
    func showFlashing(_ stage: FlashStage) {
        loadViewIfNeeded()
        spinner.stopAnimation(nil)
        statusLabel.stringValue = stage.title
        progressBar.isHidden = false
        progressBar.doubleValue = stage.progress
        onActivity?(Activity(text: stage.title, kind: .working(progress: stage.progress)))
    }

    /// Shows the outcome of a flash. A failure is listed first, above any
    /// warnings from the build.
    func show(_ result: FlashResult) {
        var diagnostics = self.diagnostics
        if let failure = result.failure {
            diagnostics.insert(Diagnostic(severity: .error, message: failure.localizedDescription), at: 0)
        }
        show(status: FlashSummary.statusText(for: result), diagnostics: diagnostics)
        publish(result.failure == nil ? .succeeded : .failed)
    }

    /// Shows what the debugger is doing. The messages from the build that
    /// came before it stay listed.
    func showDebugging(_ status: String, isBusy: Bool = false) {
        show(status: status, diagnostics: diagnostics)
        if isBusy {
            spinner.startAnimation(nil)
        }
        publish(isBusy ? .working(progress: nil) : .info)
    }

    /// Shows something the debugger could not do, listed first, above any
    /// warnings from the build.
    func show(debugFailure message: String, status: String) {
        show(status: status, diagnostics: [Diagnostic(severity: .error, message: message)] + diagnostics)
        publish(.failed)
    }

    /// Tells the toolbar about the status just shown.
    private func publish(_ kind: Activity.Kind) {
        onActivity?(Activity(text: statusLabel.stringValue, kind: kind))
    }

    private func show(status: String, diagnostics: [Diagnostic]) {
        loadViewIfNeeded()
        spinner.stopAnimation(nil)
        progressBar.isHidden = true
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
