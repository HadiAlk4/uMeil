import Foundation

enum LSPError: Error, Equatable, LocalizedError {
    case disconnected
    case invalidResponse
    case serverError(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .disconnected: "The language server disconnected."
        case .invalidResponse: "The language server sent an unreadable reply."
        case .serverError(_, let message): message
        }
    }
}

/// JSON-RPC 2.0 client speaking LSP over an `LSPTransporting` channel.
actor LSPClient {
    private let transport: any LSPTransporting
    private let onDiagnostics: (@Sendable (LSPPublishDiagnosticsParams) async -> Void)?

    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var isShutDown = false
    /// The most recent write to the server. Each write waits for the one
    /// before it, so messages reach `clangd` in the order they were made: a
    /// request never overtakes the `didChange` that came before it.
    private var lastWrite: Task<Void, Never>?

    private let decoder = JSONDecoder()

    init(
        transport: any LSPTransporting,
        onDiagnostics: (@Sendable (LSPPublishDiagnosticsParams) async -> Void)? = nil
    ) {
        self.transport = transport
        self.onDiagnostics = onDiagnostics
        let stream = transport.incoming
        Task { [weak self] in
            await self?.readLoop(stream: stream)
        }
    }

    // MARK: - Lifecycle

    /// Performs the LSP `initialize` / `initialized` handshake.
    func initialize(rootURL: URL) async throws {
        let params: [String: Any] = [
            "processId": ProcessInfo.processInfo.processIdentifier,
            "rootUri": rootURL.standardizedFileURL.absoluteString,
            "capabilities": [
                "textDocument": [
                    "synchronization": [
                        "didSave": true
                    ],
                    "completion": [
                        "completionItem": [
                            "snippetSupport": true,
                            "documentationFormat": ["plaintext"]
                        ]
                    ],
                    "definition": [
                        "linkSupport": true
                    ],
                    "publishDiagnostics": [
                        "versionSupport": true
                    ]
                ]
            ]
        ]
        _ = try await sendRequest(method: "initialize", params: params)
        try await sendNotification(method: "initialized", params: [:])
    }

    /// Gracefully ends the LSP session and closes the underlying transport.
    func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true

        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = try? await self.sendRequest(method: "shutdown", params: nil) }
            group.addTask { try? await Task.sleep(for: .milliseconds(250)) }
            await group.next()
            group.cancelAll()
        }
        try? await sendNotification(method: "exit", params: nil)
        await transport.close()
        failAllPending(with: LSPError.disconnected)
    }

    // MARK: - Document synchronization

    func didOpen(url: URL, languageID: String = "c", version: Int, text: String) async throws {
        try await sendNotification(method: "textDocument/didOpen", params: [
            "textDocument": [
                "uri": url.standardizedFileURL.absoluteString,
                "languageId": languageID,
                "version": version,
                "text": text
            ]
        ])
    }

    func didChange(url: URL, version: Int, text: String) async throws {
        try await sendNotification(method: "textDocument/didChange", params: [
            "textDocument": [
                "uri": url.standardizedFileURL.absoluteString,
                "version": version
            ],
            "contentChanges": [
                ["text": text]
            ]
        ])
    }

    func didSave(url: URL, text: String? = nil) async throws {
        var params: [String: Any] = [
            "textDocument": [
                "uri": url.standardizedFileURL.absoluteString
            ]
        ]
        if let text {
            params["text"] = text
        }
        try await sendNotification(method: "textDocument/didSave", params: params)
    }

    func didClose(url: URL) async throws {
        try await sendNotification(method: "textDocument/didClose", params: [
            "textDocument": [
                "uri": url.standardizedFileURL.absoluteString
            ]
        ])
    }

    // MARK: - Requests

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

    // MARK: - JSON-RPC plumbing

    private struct CompletionListResponse: Decodable {
        var items: [LSPCompletionItem]
    }

    private func sendRequest(method: String, params: Any?) async throws -> Data {
        guard !isShutDown || method == "shutdown" else {
            throw LSPError.disconnected
        }

        let requestID = nextRequestID
        nextRequestID += 1

        var message: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestID,
            "method": method
        ]
        if let params {
            message["params"] = params
        } else {
            message["params"] = NSNull()
        }
        let payload = try JSONSerialization.data(withJSONObject: message)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[requestID] = continuation
                let write = enqueueWrite(payload)
                Task { [weak self] in
                    do {
                        try await write.value
                    } catch {
                        await self?.failPending(requestID: requestID, error: error)
                    }
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.failPending(requestID: requestID, error: CancellationError())
            }
        }
    }

    private func sendNotification(method: String, params: Any?) async throws {
        var message: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method
        ]
        if let params {
            message["params"] = params
        }
        let payload = try JSONSerialization.data(withJSONObject: message)
        try await enqueueWrite(payload).value
    }

    private func sendResponse(requestID: Any, result: Any) async {
        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestID,
            "result": result
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: message) else { return }
        try? await enqueueWrite(payload).value
    }

    private func readLoop(stream: AsyncStream<Data>) async {
        for await payload in stream {
            await handleIncoming(payload)
        }
        failAllPending(with: LSPError.disconnected)
    }

    private func handleIncoming(_ payload: Data) async {
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return
        }

        // Server-to-client request: reply with null so the server never stalls.
        if json["method"] is String, let requestID = json["id"] {
            await sendResponse(requestID: requestID, result: NSNull())
            return
        }

        // Response to one of our requests.
        if let requestID = json["id"] as? Int, let continuation = pending.removeValue(forKey: requestID) {
            if let errorDict = json["error"] as? [String: Any] {
                let code = errorDict["code"] as? Int ?? -1
                let message = errorDict["message"] as? String ?? "Unknown language server error"
                continuation.resume(throwing: LSPError.serverError(code: code, message: message))
                return
            }
            let resultObject = json["result"] ?? NSNull()
            if resultObject is NSNull {
                continuation.resume(returning: Data("null".utf8))
            } else if let data = try? JSONSerialization.data(withJSONObject: resultObject, options: .fragmentsAllowed) {
                continuation.resume(returning: data)
            } else {
                continuation.resume(throwing: LSPError.invalidResponse)
            }
            return
        }

        // Notification from the server.
        if let method = json["method"] as? String,
           method == "textDocument/publishDiagnostics",
           let paramsObject = json["params"],
           let paramsData = try? JSONSerialization.data(withJSONObject: paramsObject),
           let diagnostics = try? decoder.decode(LSPPublishDiagnosticsParams.self, from: paramsData) {
            await onDiagnostics?(diagnostics)
        }
    }

    private func failPending(requestID: Int, error: Error) {
        pending.removeValue(forKey: requestID)?.resume(throwing: error)
    }

    private func failAllPending(with error: Error) {
        let waiting = pending
        pending.removeAll()
        for (_, continuation) in waiting {
            continuation.resume(throwing: error)
        }
    }

    private func isJSONNull(_ data: Data) -> Bool {
        data == Data("null".utf8)
    }
}

extension LSPClient {
    /// Queues `payload` behind every earlier write. The queue position is
    /// taken now, synchronously on the actor, so ordering follows call order
    /// even though the write itself happens later.
    private func enqueueWrite(_ payload: Data) -> Task<Void, Error> {
        let previous = lastWrite
        let write = Task { [transport] in
            await previous?.value
            try await transport.send(payload)
        }
        lastWrite = Task { _ = try? await write.value }
        return write
    }
}
