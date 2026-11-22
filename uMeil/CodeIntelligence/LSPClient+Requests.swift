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
}
