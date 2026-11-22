import AppKit

/// File > Open Quickly (⌘⇧O): a search field over the project's files.
/// Typing a few letters of a name, such as "uah" for `uart.h`, lists the
/// best matches; Return opens the chosen one and Escape goes back.
@MainActor
final class QuickOpenController: NSObject, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate,
    NSWindowDelegate {
    /// Called with the file the user chose.
    var onOpen: ((URL) -> Void)?

    let panel: NSPanel
    let searchField = NSSearchField()
    let tableView = NSTableView()

    private(set) var folder: URL?
    private(set) var allPaths: [String] = []
    private(set) var results: [(path: String, match: FuzzyMatch.Result)] = []
    /// Files listed first when nothing is typed yet: the open tabs.
    private var recentPaths: [String] = []

    /// Folders that hold build output or tools rather than project sources.
    static let skippedFolders: Set<String> = ["build", "DerivedData", "node_modules", "Objects", "Listings"]
    /// More files than a course project has; stops a stray home folder from hanging the list.
    static let fileLimit = 20_000

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        super.init()
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentView = makeContent()
    }

    private func makeContent() -> NSView {
        searchField.placeholderString = "Open Quickly"
        searchField.font = .systemFont(ofSize: 18)
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.setAccessibilityLabel("Open Quickly")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 38
        tableView.style = .inset
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openSelected)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        for subview in [searchField, scrollView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: background.topAnchor, constant: 14),
            searchField.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: background.bottomAnchor)
        ])
        return background
    }

    // MARK: - Showing

    /// Lists the files under `folder` and shows the panel over `window`.
    /// `openFiles` are listed first before anything is typed.
    func show(folder: URL, openFiles: [URL], over window: NSWindow?) {
        // Read again each time: files may have been added since. It takes
        // a few milliseconds for a course project.
        self.folder = folder
        allPaths = Self.projectPaths(in: folder)
        recentPaths = openFiles.compactMap { Self.relativePath(of: $0, in: folder) }
        searchField.stringValue = ""
        updateResults()

        if let frame = window?.frame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 90))
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
    }

    func close() {
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    // MARK: - Searching

    func updateResults() {
        let query = searchField.stringValue
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            let rest = allPaths.filter { !recentPaths.contains($0) }
            let unmatched = FuzzyMatch.Result(score: 0, matchedIndices: [])
            results = (recentPaths + rest).prefix(50).map { (path: $0, match: unmatched) }
        } else {
            results = FuzzyMatch.rank(allPaths, for: query)
        }
        tableView.reloadData()
        if !results.isEmpty {
            tableView.selectRowIndexes([0], byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        updateResults()
    }

    /// Up and down move through the list without leaving the search field.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
        case #selector(NSResponder.insertNewline(_:)):
            openSelected()
        case #selector(NSResponder.cancelOperation(_:)):
            close()
        default:
            return false
        }
        return true
    }

    func moveSelection(by offset: Int) {
        guard !results.isEmpty else { return }
        let row = min(max(tableView.selectedRow + offset, 0), results.count - 1)
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    @objc func openSelected() {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard results.indices.contains(row), let folder else { return }
        close()
        onOpen?(folder.appending(path: results[row].path))
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard results.indices.contains(row) else { return nil }
        let result = results[row]
        let name = (result.path as NSString).lastPathComponent
        let directory = (result.path as NSString).deletingLastPathComponent

        let icon = FileIcon(name: name, isDirectory: false)
        let iconView = NSImageView(image: icon.image ?? NSImage())
        iconView.contentTintColor = icon.color
        iconView.symbolConfiguration = .init(pointSize: 15, weight: .regular)

        let nameLabel = NSTextField(labelWithAttributedString: Self.highlighted(
            name,
            matches: result.match.matchedIndices.map { $0 - (result.path.count - name.count) }.filter { $0 >= 0 }
        ))
        let pathLabel = NSTextField(labelWithString: directory.isEmpty ? "Project folder" : directory)
        pathLabel.font = .systemFont(ofSize: 11)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingHead

        let text = NSStackView(views: [nameLabel, pathLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let row = NSStackView(views: [iconView, text])
        row.spacing = 9
        row.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        row.setAccessibilityLabel(result.path)
        return row
    }

    /// `name` with the matched letters in bold.
    static func highlighted(_ name: String, matches: [Int]) -> NSAttributedString {
        let text = NSMutableAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 13)])
        for offset in Set(matches) where offset < name.count {
            let start = name.index(name.startIndex, offsetBy: offset)
            let range = NSRange(start..<name.index(after: start), in: name)
            text.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 13), range: range)
        }
        return text
    }

    // MARK: - Files

    /// Every file under `folder` that could be opened, as paths relative to
    /// it, leaving out hidden files and build output.
    static func projectPaths(in folder: URL) -> [String] {
        let root = folder.standardizedFileURL.resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var paths: [String] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                if skippedFolders.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true, let path = relativePath(of: url, in: root) else { continue }
            paths.append(path)
            if paths.count >= fileLimit { break }
        }
        return paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func relativePath(of file: URL, in folder: URL) -> String? {
        let parts = file.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard parts.count > base.count, parts.starts(with: base) else { return nil }
        return parts.dropFirst(base.count).joined(separator: "/")
    }
}
