import Foundation

/// A zero-based position in a text document, using UTF-16 code units as LSP specifies.
struct LSPPosition: Codable, Equatable, Hashable, Sendable {
    var line: Int
    var character: Int
}

/// A half-open range `[start, end)` in a text document.
struct LSPRange: Codable, Equatable, Hashable, Sendable {
    var start: LSPPosition
    var end: LSPPosition
}

/// A location in a file on disk returned by `textDocument/definition`.
struct LSPLocation: Codable, Equatable, Hashable, Sendable {
    var uri: String
    var range: LSPRange

    /// Resolves the `file://` URI to a standardized file URL, or `nil` for non-file URIs.
    var url: URL? {
        guard let parsed = URL(string: uri), parsed.isFileURL else { return nil }
        return parsed.standardizedFileURL
    }
}

/// An LSP `LocationLink`, returned by servers that advertise `linkSupport`.
struct LSPLocationLink: Codable, Equatable, Sendable {
    var targetUri: String
    var targetRange: LSPRange
    var targetSelectionRange: LSPRange

    var location: LSPLocation {
        LSPLocation(uri: targetUri, range: targetSelectionRange)
    }
}

/// A text replacement returned inside a completion item.
struct LSPTextEdit: Codable, Equatable, Sendable {
    var range: LSPRange
    var newText: String

    private enum CodingKeys: String, CodingKey {
        case range, insert, newText
    }

    init(range: LSPRange, newText: String) {
        self.range = range
        self.newText = newText
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        newText = try container.decode(String.self, forKey: .newText)
        if let standard = try container.decodeIfPresent(LSPRange.self, forKey: .range) {
            range = standard
        } else {
            range = try container.decode(LSPRange.self, forKey: .insert)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(range, forKey: .range)
        try container.encode(newText, forKey: .newText)
    }
}

/// One candidate from `textDocument/completion`.
struct LSPCompletionItem: Codable, Equatable, Sendable {
    enum Kind: Int, Codable, Sendable {
        case text = 1
        case method = 2
        case function = 3
        case constructor = 4
        case field = 5
        case variable = 6
        case `class` = 7
        case interface = 8
        case module = 9
        case property = 10
        case unit = 11
        case value = 12
        case `enum` = 13
        case keyword = 14
        case snippet = 15
        case color = 16
        case file = 17
        case reference = 18
        case folder = 19
        case enumMember = 20
        case constant = 21
        case `struct` = 22
        case event = 23
        case `operator` = 24
        case typeParameter = 25

        /// A compact single-letter badge shown beside the item in the completion popup.
        var badge: String {
            switch self {
            case .function, .method, .constructor: "f"
            case .variable, .field, .property: "v"
            case .class, .struct, .interface, .enum, .typeParameter: "T"
            case .constant, .enumMember, .value: "C"
            case .keyword: "K"
            case .file, .folder, .module: "H"
            default: "•"
            }
        }
    }

    var label: String
    var kind: Kind?
    var detail: String?
    var documentation: String?
    var insertText: String?
    var filterText: String?
    var sortText: String?
    var textEdit: LSPTextEdit?
    /// `2` when `insertionText` is an LSP snippet with `${1:…}` placeholders.
    var insertTextFormat: Int?

    /// Whether accepting this item inserts placeholders to Tab between.
    var isSnippet: Bool { insertTextFormat == 2 }

    /// The text to insert and its placeholders. Plain items have none.
    var snippet: LSPSnippet {
        isSnippet
            ? LSPSnippet(parsing: insertionText)
            : LSPSnippet(text: insertionText, placeholders: [], finalOffset: nil)
    }

    /// `clangd` prepends a space to labels when aligning icons; trim it for display.
    var displayLabel: String {
        label.trimmingCharacters(in: .whitespaces)
    }

    /// The string matched while the user continues typing after the popup opens.
    var filterKey: String {
        filterText ?? displayLabel
    }

    /// The text inserted when the user accepts this item.
    var insertionText: String {
        textEdit?.newText ?? insertText ?? displayLabel
    }

    private enum CodingKeys: String, CodingKey {
        case label, kind, detail, documentation, insertText, filterText, sortText, textEdit, insertTextFormat
    }

    private struct MarkupContent: Decodable {
        var value: String
    }

    init(
        label: String,
        kind: Kind? = nil,
        detail: String? = nil,
        documentation: String? = nil,
        insertText: String? = nil,
        filterText: String? = nil,
        sortText: String? = nil,
        textEdit: LSPTextEdit? = nil,
        insertTextFormat: Int? = nil
    ) {
        self.label = label
        self.kind = kind
        self.detail = detail
        self.documentation = documentation
        self.insertText = insertText
        self.filterText = filterText
        self.sortText = sortText
        self.textEdit = textEdit
        self.insertTextFormat = insertTextFormat
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decode(String.self, forKey: .label)
        if let rawKind = try container.decodeIfPresent(Int.self, forKey: .kind) {
            kind = Kind(rawValue: rawKind)
        }
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        if let plain = try? container.decodeIfPresent(String.self, forKey: .documentation) {
            documentation = plain
        } else if let markup = try? container.decodeIfPresent(MarkupContent.self, forKey: .documentation) {
            documentation = markup.value
        }
        insertText = try container.decodeIfPresent(String.self, forKey: .insertText)
        filterText = try container.decodeIfPresent(String.self, forKey: .filterText)
        sortText = try container.decodeIfPresent(String.self, forKey: .sortText)
        textEdit = try container.decodeIfPresent(LSPTextEdit.self, forKey: .textEdit)
        insertTextFormat = try container.decodeIfPresent(Int.self, forKey: .insertTextFormat)
    }
}

/// An inline error, warning, or hint published by the language server.
struct LSPDiagnostic: Codable, Equatable, Hashable, Sendable {
    enum Severity: Int, Codable, Comparable, Sendable {
        case error = 1
        case warning = 2
        case information = 3
        case hint = 4

        static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    var range: LSPRange
    var severity: Severity?
    var code: String?
    var source: String?
    var message: String

    /// Converts to uMeil's gutter severity (`Diagnostic.Severity`).
    var diagnosticSeverity: Diagnostic.Severity {
        switch severity {
        case .error, nil: .error
        case .warning: .warning
        case .information, .hint: .note
        }
    }

    private enum CodingKeys: String, CodingKey {
        case range, severity, code, source, message
    }

    init(
        range: LSPRange,
        severity: Severity? = nil,
        code: String? = nil,
        source: String? = nil,
        message: String
    ) {
        self.range = range
        self.severity = severity
        self.code = code
        self.source = source
        self.message = message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        range = try container.decode(LSPRange.self, forKey: .range)
        if let raw = try container.decodeIfPresent(Int.self, forKey: .severity) {
            severity = Severity(rawValue: raw)
        }
        if let stringCode = try? container.decodeIfPresent(String.self, forKey: .code) {
            code = stringCode
        } else if let intCode = try? container.decodeIfPresent(Int.self, forKey: .code) {
            code = String(intCode)
        }
        source = try container.decodeIfPresent(String.self, forKey: .source)
        message = try container.decode(String.self, forKey: .message)
    }
}

/// Notification payload for `textDocument/publishDiagnostics`.
struct LSPPublishDiagnosticsParams: Codable, Equatable, Sendable {
    var uri: String
    var version: Int?
    var diagnostics: [LSPDiagnostic]

    var url: URL? {
        guard let parsed = URL(string: uri), parsed.isFileURL else { return nil }
        return parsed.standardizedFileURL
    }

    /// Summarizes the most serious diagnostic severity per 1-based line number for the gutter.
    var lineMarkers: [Int: Diagnostic.Severity] {
        var markers: [Int: Diagnostic.Severity] = [:]
        for diagnostic in diagnostics {
            let severity = diagnostic.diagnosticSeverity
            guard severity != .note else { continue }
            let line = diagnostic.range.start.line + 1
            if markers[line] != .error {
                markers[line] = severity
            }
        }
        return markers
    }
}

extension LineIndex {
    /// Converts a UTF-16 character offset in `NSTextView` to a 0-based LSP position.
    func lspPosition(atUTF16Offset offset: Int) -> LSPPosition {
        let clamped = min(max(offset, 0), length)
        let lineNumber = lineNumber(atOffset: clamped)
        let lineStart = self.offset(ofLine: lineNumber) ?? 0
        return LSPPosition(line: lineNumber - 1, character: clamped - lineStart)
    }

    /// Converts a 0-based LSP position to a clamped UTF-16 offset in `NSTextView`.
    func utf16Offset(for position: LSPPosition) -> Int {
        let lineNumber = position.line + 1
        if lineNumber < 1 { return 0 }
        guard let lineRange = range(ofLine: lineNumber) else { return length }
        let lineLengthWithoutNewline = offset(line: lineNumber, column: position.character + 1) ?? lineRange.location
        return min(max(lineLengthWithoutNewline, lineRange.location), length)
    }

    /// Converts an `LSPRange` to a UTF-16 `NSRange` clamped to the document bounds.
    func utf16Range(for range: LSPRange) -> NSRange {
        let start = utf16Offset(for: range.start)
        let end = max(start, utf16Offset(for: range.end))
        return NSRange(location: start, length: end - start)
    }
}

/// Identifies a specific version of a text document in `documentChanges`.
struct LSPVersionedTextDocumentIdentifier: Codable, Equatable, Sendable {
    var uri: String
    var version: Int?
}

/// Text edits targeting one document inside `LSPWorkspaceEdit.documentChanges`.
struct LSPTextDocumentEdit: Codable, Equatable, Sendable {
    var textDocument: LSPVersionedTextDocumentIdentifier
    var edits: [LSPTextEdit]
}

/// An entry in `LSPWorkspaceEdit.documentChanges`: either text edits or a file operation.
enum LSPDocumentChange: Codable, Equatable, Sendable {
    case textDocumentEdit(LSPTextDocumentEdit)
    case resourceOperation(kind: String)

    private enum CodingKeys: String, CodingKey {
        case kind
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let kind = try container.decodeIfPresent(String.self, forKey: .kind) {
            self = .resourceOperation(kind: kind)
            return
        }
        self = .textDocumentEdit(try LSPTextDocumentEdit(from: decoder))
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .textDocumentEdit(let edit):
            try edit.encode(to: encoder)
        case .resourceOperation(let kind):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(kind, forKey: .kind)
        }
    }
}

/// Text edits returned by a code action. Only edits confined to the open document are accepted.
struct LSPWorkspaceEdit: Codable, Equatable, Sendable {
    var changes: [String: [LSPTextEdit]]?
    var documentChanges: [LSPDocumentChange]?
}

/// Request context sent with `textDocument/codeAction`.
struct LSPCodeActionContext: Codable, Equatable, Sendable {
    var diagnostics: [LSPDiagnostic]
    var only: [String]?
}

/// A diagnostic quick-fix or refactoring returned by `textDocument/codeAction`.
struct LSPCodeAction: Codable, Equatable, Sendable {
    struct Disabled: Codable, Equatable, Sendable {
        var reason: String
    }

    static let quickFixKind = "quickfix"

    var title: String
    var kind: String?
    var diagnostics: [LSPDiagnostic]?
    var isPreferred: Bool?
    var disabled: Disabled?
    var edit: LSPWorkspaceEdit?

    var isQuickFix: Bool {
        guard let kind else { return false }
        return kind == Self.quickFixKind || kind.hasPrefix(Self.quickFixKind + ".")
    }

    /// Returns the single-document edits if this is an enabled quick-fix targeting `documentURL`.
    func quickFixEdits(targeting documentURL: URL) -> [LSPTextEdit]? {
        guard disabled == nil, isQuickFix, let edit else { return nil }
        return edit.edits(targeting: documentURL)
    }

    /// Picks the best auto-applicable quick-fix for `documentURL`, preferring `isPreferred == true`.
    static func preferredQuickFix(from actions: [LSPCodeAction], targeting documentURL: URL) -> LSPCodeAction? {
        let applicable = actions.filter { $0.quickFixEdits(targeting: documentURL) != nil }
        return applicable.first { $0.isPreferred == true } ?? applicable.first
    }
}
