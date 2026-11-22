import Foundation

extension LSPWorkspaceEdit {
    /// Returns all text edits if every change in this workspace edit targets `documentURL`
    /// (after symlink and path normalization) and performs no file-level resource operations.
    /// Returns `nil` if any URI points elsewhere, uses a non-file/remote URI, or has no edits.
    func edits(targeting documentURL: URL) -> [LSPTextEdit]? {
        guard documentURL.isFileURL else { return nil }
        let expected = documentURL.resolvingSymlinksInPath().standardizedFileURL

        if let documentChanges {
            var collected: [LSPTextEdit] = []
            for change in documentChanges {
                switch change {
                case .textDocumentEdit(let docEdit):
                    guard Self.matches(uri: docEdit.textDocument.uri, target: expected) else { return nil }
                    collected.append(contentsOf: docEdit.edits)
                case .resourceOperation:
                    return nil
                }
            }
            return collected.isEmpty ? nil : collected
        }

        if let changes {
            guard !changes.isEmpty else { return nil }
            var collected: [LSPTextEdit] = []
            for (uri, edits) in changes {
                guard Self.matches(uri: uri, target: expected) else { return nil }
                collected.append(contentsOf: edits)
            }
            return collected.isEmpty ? nil : collected
        }
        return nil
    }

    private static func matches(uri: String, target: URL) -> Bool {
        guard !uri.localizedCaseInsensitiveContains("%00"),
              let parsed = URL(string: uri),
              parsed.isFileURL,
              parsed.host == nil || parsed.host?.isEmpty == true || parsed.host == "localhost"
        else { return false }
        return parsed.resolvingSymlinksInPath().standardizedFileURL == target
    }
}
