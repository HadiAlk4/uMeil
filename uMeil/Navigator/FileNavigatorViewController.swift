import AppKit

/// The sidebar that shows the open folder as a tree of files.
final class FileNavigatorViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    /// Called when the user selects a file (not a folder).
    var onSelectFile: ((URL) -> Void)?

    /// The folder being shown, or `nil` when no folder is open.
    private(set) var root: FileNode?

    let outlineView = NSOutlineView()
    private static let cellIdentifier = NSUserInterfaceItemIdentifier("FileCell")

    /// True while the selection is being changed in code, so that it is not
    /// reported as the user choosing a file.
    private var isSelectingInCode = false

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("FileNavigatorViewController is created in code, not from a nib")
    }

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Name"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.allowsEmptySelection = true
        outlineView.allowsMultipleSelection = false

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        view = scrollView
    }

    /// Shows `folder` in the tree, replacing whatever was shown before.
    func showFolder(_ folder: URL?) {
        loadViewIfNeeded()
        root = folder.map { FileNode(url: $0, isDirectory: true) }
        outlineView.reloadData()
    }

    /// Re-reads the folder from disk, keeping the tree's root.
    func reloadFromDisk() {
        root?.reload()
        outlineView.reloadData()
    }

    /// Selects `file` in the tree (expanding its folders), or clears the
    /// selection for `nil`. Does not call `onSelectFile`.
    func select(_ file: URL?) {
        isSelectingInCode = true
        defer { isSelectingInCode = false }

        guard let file, let root, let node = root.node(for: file) else {
            outlineView.deselectAll(nil)
            return
        }
        // Expand each folder on the way down so the file's row exists.
        var ancestors: [FileNode] = []
        var current = root
        let components = file.standardizedFileURL.pathComponents
            .dropFirst(root.url.standardizedFileURL.pathComponents.count)
        for component in components.dropLast() {
            guard let next = current.children.first(where: { $0.name == component }) else { break }
            ancestors.append(next)
            current = next
        }
        ancestors.forEach { outlineView.expandItem($0) }

        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        outlineView.selectRowIndexes([row], byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
    }

    // MARK: - NSOutlineViewDataSource

    private func node(_ item: Any?) -> FileNode? {
        item == nil ? root : item as? FileNode
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        node(item)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        // AppKit only asks for indexes below the count reported above.
        node(item)?.children[index] as Any
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isDirectory ?? false
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }

        let cell = outlineView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? NSTableCellView
            ?? Self.makeCell()
        cell.textField?.stringValue = node.name
        let icon = FileIcon(name: node.name, isDirectory: node.isDirectory)
        cell.imageView?.image = icon.image
        cell.imageView?.contentTintColor = icon.color
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSelectingInCode,
              let node = outlineView.item(atRow: outlineView.selectedRow) as? FileNode,
              !node.isDirectory
        else { return }
        onSelectFile?(node.url)
    }

    private static func makeCell() -> NSTableCellView {
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false

        let cell = NSTableCellView()
        cell.identifier = cellIdentifier
        cell.imageView = icon
        cell.textField = label
        cell.addSubview(icon)
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}
