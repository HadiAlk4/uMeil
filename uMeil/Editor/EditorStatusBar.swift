import AppKit

/// The line under the editor: where the cursor is, how full flash and RAM
/// were after the last build, the chip, and whether a board is plugged in.
final class EditorStatusBar: NSView {
    let positionLabel = NSTextField(labelWithString: "")
    let chipLabel = NSTextField(labelWithString: "")
    let boardLabel = NSTextField(labelWithString: "")
    let boardDot = NSImageView()
    /// Holds the Flash and RAM meters, which show after a successful build.
    private let memorySlot = NSStackView()

    static let height: CGFloat = 22
    static var font: NSFont { .systemFont(ofSize: 11) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("EditorStatusBar is created in code, not from a nib")
    }

    private func setUp() {
        for label in [positionLabel, chipLabel, boardLabel] {
            label.font = Self.font
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
        }
        positionLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        positionLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        chipLabel.toolTip = "The chip this project is built for"
        boardDot.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 7, weight: .regular)

        let board = NSStackView(views: [boardDot, boardLabel])
        board.orientation = .horizontal
        board.spacing = 4

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [positionLabel, NSView(), memorySlot, chipLabel, board])
        stack.orientation = .horizontal
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(separator)
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: separator.bottomAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        showPosition(line: nil, column: nil)
        showChip(nil)
        showBoard(isConnected: false)
    }

    /// Puts the Flash and RAM meters in the line, between the cursor
    /// position and the chip. They keep showing and hiding themselves.
    func embed(_ memoryBar: MemoryUsageBar) {
        memoryBar.showsSeparator = false
        memorySlot.addArrangedSubview(memoryBar)
    }

    /// Runs along the bottom edge of `container`, full width.
    func pinToBottom(of container: NSView) {
        NSLayoutConstraint.activate([
            bottomAnchor.constraint(equalTo: container.bottomAnchor),
            leadingAnchor.constraint(equalTo: container.leadingAnchor),
            trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
    }

    /// "Ln 12, Col 4", or nothing while no file is open.
    func showPosition(line: Int?, column: Int?) {
        guard let line, let column else {
            positionLabel.stringValue = ""
            return
        }
        positionLabel.stringValue = "Ln \(line), Col \(column)"
    }

    func showChip(_ chip: Chip?) {
        chipLabel.stringValue = chip?.rawValue ?? ""
        chipLabel.isHidden = chip == nil
    }

    /// "Board connected" with a green dot, or "No board" with a gray one.
    func showBoard(isConnected: Bool) {
        boardLabel.stringValue = isConnected ? "Board connected" : "No board"
        boardLabel.textColor = isConnected ? .labelColor : .secondaryLabelColor
        boardDot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        boardDot.contentTintColor = isConnected ? .systemGreen : .tertiaryLabelColor
        boardDot.setAccessibilityLabel(boardLabel.stringValue)
    }
}
