import Foundation

/// The language features uMeil asks `clangd` for.
extension LSPClient {
    private struct CompletionListResponse: Decodable {
        var items: [LSPCompletionItem]
    }

    func completion(url: URL, position: LSPPosition) async throws -> [LSPCompletionItem] {
        let data = try await sendRequest(method: "textDocument/completion", params: [
            "textDocument": ["uri": url.standardizedFileURL.absoluteString],
            "position": ["line": position.line, "character": position.character]
        ])
        if isJSONNull(data) { return [] }
        if let list = try? decoder.decode(CompletionListResponse.self, from: data) {
            return list.items
        }
        if let array = try? decoder.decode([LSPCompletionItem].self, from: data) {
            return array
        }
        throw LSPError.invalidResponse
    }

    func definition(url: URL, position: LSPPosition) async throws -> [LSPLocation] {
        let data = try await sendRequest(method: "textDocument/definition", params: [
            "textDocument": ["uri": url.standardizedFileURL.absoluteString],
            "position": ["line": position.line, "character": position.character]
        ])
        if isJSONNull(data) { return [] }
        if let single = try? decoder.decode(LSPLocation.self, from: data) {
            return [single]
        }
        if let array = try? decoder.decode([LSPLocation].self, from: data) {
            return array
        }
        if let links = try? decoder.decode([LSPLocationLink].self, from: data) {
            return links.map(\.location)
        }
        throw LSPError.invalidResponse
    }

    /// The call around `position` and the argument it is in, or `nil` outside any call.
    func signatureHelp(url: URL, position: LSPPosition) async throws -> LSPSignatureHelp? {
        let data = try await sendRequest(method: "textDocument/signatureHelp", params: [
            "textDocument": ["uri": url.standardizedFileURL.absoluteString],
            "position": ["line": position.line, "character": position.character]
        ])
        if isJSONNull(data) { return nil }
        guard let help = try? decoder.decode(LSPSignatureHelp.self, from: data) else {
            throw LSPError.invalidResponse
        }
        return help.signatures.isEmpty ? nil : help
    }

    /// What the name at `position` is, or `nil` when there is nothing to say.
    func hover(url: URL, position: LSPPosition) async throws -> LSPHover? {
        let data = try await sendRequest(method: "textDocument/hover", params: [
            "textDocument": ["uri": url.standardizedFileURL.absoluteString],
            "position": ["line": position.line, "character": position.character]
        ])
        if isJSONNull(data) { return nil }
        guard let hover = try? decoder.decode(LSPHover.self, from: data) else {
            throw LSPError.invalidResponse
        }
        return hover.contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : hover
    }

    /// Checks that the name at `position` can be renamed. Returns the
    /// range of the name, or throws the server's reason when it cannot be.
    func prepareRename(url: URL, position: LSPPosition) async throws -> LSPRange? {
        let data = try await sendRequest(method: "textDocument/prepareRename", params: [
            "textDocument": ["uri": url.standardizedFileURL.absoluteString],
            "position": ["line": position.line, "character": position.character]
        ])
        if isJSONNull(data) { return nil }
        if let range = try? decoder.decode(LSPRange.self, from: data) { return range }
        struct WithPlaceholder: Decodable { var range: LSPRange }
        return try? decoder.decode(WithPlaceholder.self, from: data).range
    }

    /// The edits that rename the symbol at `position` to `newName` everywhere.
    func rename(url: URL, position: LSPPosition, newName: String) async throws -> LSPWorkspaceEdit {
        let data = try await sendRequest(method: "textDocument/rename", params: [
            "textDocument": ["uri": url.standardizedFileURL.absoluteString],
            "position": ["line": position.line, "character": position.character],
            "newName": newName
        ])
        if isJSONNull(data) { return LSPWorkspaceEdit(edits: [:]) }
        guard let edit = try? decoder.decode(LSPWorkspaceEdit.self, from: data) else {
            throw LSPError.invalidResponse
        }
        return edit
    }
}
