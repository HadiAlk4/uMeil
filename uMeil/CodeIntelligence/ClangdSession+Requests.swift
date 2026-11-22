import Foundation

/// Language requests, each sent once `clangd` has the latest text.
extension ClangdSession {
    func completion(
        at position: LSPPosition,
        in url: URL,
        currentText: String? = nil
    ) async throws -> [LSPCompletionItem] {
        let normalized = Self.normalize(url)
        try await ensureSynced(url: normalized, currentText: currentText)
        let client = try await ensureClient()
        return try await client.completion(url: normalized, position: position)
    }

    func definition(at position: LSPPosition, in url: URL, currentText: String? = nil) async throws -> [LSPLocation] {
        let normalized = Self.normalize(url)
        try await ensureSynced(url: normalized, currentText: currentText)
        let client = try await ensureClient()
        return try await client.definition(url: normalized, position: position)
    }

    func codeAction(
        url: URL,
        range: LSPRange,
        diagnostics: [LSPDiagnostic],
        currentText: String? = nil
    ) async throws -> [LSPCodeAction] {
        let normalized = Self.normalize(url)
        try await ensureSynced(url: normalized, currentText: currentText)
        let client = try await ensureClient()
        return try await client.codeAction(url: normalized, range: range, diagnostics: diagnostics)
    }

    func signatureHelp(
        at position: LSPPosition,
        in url: URL,
        currentText: String? = nil
    ) async throws -> LSPSignatureHelp? {
        let normalized = Self.normalize(url)
        try await ensureSynced(url: normalized, currentText: currentText)
        let client = try await ensureClient()
        return try await client.signatureHelp(url: normalized, position: position)
    }

    func hover(at position: LSPPosition, in url: URL, currentText: String? = nil) async throws -> LSPHover? {
        let normalized = Self.normalize(url)
        try await ensureSynced(url: normalized, currentText: currentText)
        let client = try await ensureClient()
        return try await client.hover(url: normalized, position: position)
    }

    func prepareRename(at position: LSPPosition, in url: URL, currentText: String? = nil) async throws -> LSPRange? {
        let normalized = Self.normalize(url)
        try await ensureSynced(url: normalized, currentText: currentText)
        let client = try await ensureClient()
        return try await client.prepareRename(url: normalized, position: position)
    }

    func rename(
        at position: LSPPosition,
        in url: URL,
        to newName: String,
        currentText: String? = nil
    ) async throws -> LSPWorkspaceEdit {
        let normalized = Self.normalize(url)
        try await ensureSynced(url: normalized, currentText: currentText)
        let client = try await ensureClient()
        return try await client.rename(url: normalized, position: position, newName: newName)
    }
}
