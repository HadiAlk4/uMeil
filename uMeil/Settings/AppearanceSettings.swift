import AppKit

/// The font the editor, the terminal and the debugger's tables share,
/// whether the app is light, dark, or follows the system, and whether the
/// editor indents with spaces or tabs. Kept in user defaults, so they last
/// between launches.
///
/// ⌘+ and ⌘− change the size, which helps when the screen is projected in
/// class. Everything that shows code listens for `didChange`.
@MainActor
final class AppearanceSettings {
    /// Light, dark, or whatever the system is set to.
    enum Theme: String, CaseIterable {
        case system, light, dark

        var title: String {
            switch self {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }

        var appearance: NSAppearance? {
            switch self {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
    }

    static let didChange = Notification.Name("uMeilAppearanceSettingsDidChange")

    static let defaultSize: CGFloat = 13
    static let sizes: ClosedRange<CGFloat> = 9...36

    static let fontNameKey = "EditorFontName"
    static let fontSizeKey = "EditorFontSize"
    static let themeKey = "AppearanceTheme"
    static let indentUsingSpacesKey = "EditorIndentUsingSpaces"

    /// The settings the app uses. The unit tests get their own, so running
    /// them leaves the user's choices alone.
    static let shared: AppearanceSettings = {
        guard AppDelegate.isTestHost else { return AppearanceSettings(defaults: .standard) }
        let suite = "uMeilTests-AppearanceSettings"
        UserDefaults().removePersistentDomain(forName: suite)
        return AppearanceSettings(defaults: UserDefaults(suiteName: suite) ?? .standard)
    }()

    let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    // MARK: - Font

    /// The PostScript name of the chosen font, or `nil` for the system's
    /// monospaced font (SF Mono).
    var fontName: String? {
        get { defaults.string(forKey: Self.fontNameKey) }
        set {
            guard newValue != fontName else { return }
            defaults.set(newValue, forKey: Self.fontNameKey)
            notify()
        }
    }

    /// The editor's font size in points. The debugger's tables use a point less.
    var fontSize: CGFloat {
        get {
            let stored = defaults.double(forKey: Self.fontSizeKey)
            return stored > 0 ? Self.clamped(stored) : Self.defaultSize
        }
        set {
            let size = Self.clamped(newValue)
            guard size != fontSize else { return }
            defaults.set(Double(size), forKey: Self.fontSizeKey)
            notify()
        }
    }

    /// The editor's font. A font that has been uninstalled falls back to
    /// the system's monospaced one.
    var font: NSFont { font(ofSize: fontSize) }

    func font(ofSize size: CGFloat) -> NSFont {
        if let fontName, let chosen = NSFont(name: fontName, size: size) {
            return chosen
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    func makeFontBigger() { fontSize += 1 }
    func makeFontSmaller() { fontSize -= 1 }
    func resetFontSize() { fontSize = Self.defaultSize }

    var canMakeFontBigger: Bool { fontSize < Self.sizes.upperBound }
    var canMakeFontSmaller: Bool { fontSize > Self.sizes.lowerBound }

    private static func clamped(_ size: CGFloat) -> CGFloat {
        min(max(size.rounded(), sizes.lowerBound), sizes.upperBound)
    }

    /// Fixed-width fonts installed on this Mac, by PostScript name, for the
    /// Settings window to offer. Fonts where every letter is the same width
    /// keep columns of code and register values lined up.
    static func monospacedFontNames() -> [String] {
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        // Regular faces only: bold and italic are for highlighting, not body text.
        return names.filter { name in
            guard let font = NSFont(name: name, size: defaultSize) else { return false }
            let traits = NSFontManager.shared.traits(of: font)
            return !traits.contains(.boldFontMask) && !traits.contains(.italicFontMask)
        }
        .sorted { displayName(for: $0).localizedStandardCompare(displayName(for: $1)) == .orderedAscending }
    }

    /// "Menlo Regular" for `Menlo-Regular`.
    static func displayName(for fontName: String) -> String {
        NSFont(name: fontName, size: defaultSize)?.displayName ?? fontName
    }

    // MARK: - Theme

    var theme: Theme {
        get { defaults.string(forKey: Self.themeKey).flatMap(Theme.init(rawValue:)) ?? .system }
        set {
            guard newValue != theme else { return }
            defaults.set(newValue.rawValue, forKey: Self.themeKey)
            applyTheme()
            notify()
        }
    }

    /// Makes the whole app light or dark, or lets it follow the system.
    func applyTheme(to application: NSApplication? = nil) {
        (application ?? NSApp)?.appearance = theme.appearance
    }

    // MARK: - Indentation

    /// Whether Tab and automatic indentation insert spaces (the default)
    /// or tab characters.
    var indentUsingSpaces: Bool {
        get { defaults.object(forKey: Self.indentUsingSpacesKey) as? Bool ?? true }
        set {
            guard newValue != indentUsingSpaces else { return }
            defaults.set(newValue, forKey: Self.indentUsingSpacesKey)
            notify()
        }
    }

    /// One level of indentation, as wide as a tab is drawn.
    var indentStyle: IndentStyle {
        IndentStyle(usesSpaces: indentUsingSpaces, width: EditorTheme.tabWidth)
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
