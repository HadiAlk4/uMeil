import AppKit

/// Lays out a debug panel: a bar of controls along one edge and a scrolling
/// list that fills the rest.
///
/// A vertical `NSStackView` sizes a scroll view to what it holds rather
/// than to the space it is given, which left the lists in the debugger's
/// tabs a sliver wide and no rows tall. Plain constraints pin them instead.
@MainActor
enum PanelLayout {
    enum BarEdge {
        case top
        case bottom
    }

    static func view(bar: NSView, content: NSScrollView, barAt edge: BarEdge = .top) -> NSView {
        let container = NSView()
        for subview in [bar, content] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(subview)
        }
        // The bar keeps its own height; the list takes everything else.
        bar.setContentHuggingPriority(.required, for: .vertical)
        bar.setContentCompressionResistancePriority(.required, for: .vertical)
        content.setContentHuggingPriority(.defaultLow, for: .vertical)

        var constraints = [
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ]
        switch edge {
        case .top:
            constraints += [
                bar.topAnchor.constraint(equalTo: container.topAnchor),
                content.topAnchor.constraint(equalTo: bar.bottomAnchor),
                content.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ]
        case .bottom:
            constraints += [
                content.topAnchor.constraint(equalTo: container.topAnchor),
                bar.topAnchor.constraint(equalTo: content.bottomAnchor),
                bar.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ]
        }
        NSLayoutConstraint.activate(constraints)
        return container
    }
}
