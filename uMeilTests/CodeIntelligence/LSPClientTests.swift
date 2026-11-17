import Foundation
import os
import Testing
@testable import uMeil

private final class MockLSPTransport: LSPTransporting, @unchecked Sendable {
    let incoming: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let sentStorage = OSAllocatedUnfairLock(initialState: [Data]())
    var onSend: (@Sendable (Data, MockLSPTransport) -> Void)?

    init() {
        var streamContinuation: AsyncStream<Data>.Continuation!
        incoming = AsyncStream { streamContinuation = $0 }
        continuation = streamContinuation
    }

    var sentPayloads: [Data] {
        sentStorage.withLock { $0 }
    }

    func send(_ payload: Data) async throws {
        sentStorage.withLock { $0.append(payload) }
        onSend?(payload, self)
    }

    func emit(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        continuation.yield(data)
    }

    func close() async {
        continuation.finish()
    }
}

struct LSPClientTests {
    @Test func initializesAndMatchesOutOfOrderResponses() async throws {
        let transport = MockLSPTransport()
        let client = LSPClient(transport: transport)

        transport.onSend = { payload, mock in
            guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let method = json["method"] as? String,
                  let requestID = json["id"] as? Int
            else { return }

            switch method {
            case "initialize":
                mock.emit(["jsonrpc": "2.0", "id": requestID, "result": ["capabilities": [:]]])
            case "textDocument/completion":
                mock.emit([
                    "jsonrpc": "2.0",
                    "id": requestID,
                    "result": [
                        "isIncomplete": false,
                        "items": [["label": " GPIOPinWrite", "kind": 3, "insertText": "GPIOPinWrite"]]
                    ]
                ])
            case "textDocument/definition":
                mock.emit([
                    "jsonrpc": "2.0",
                    "id": requestID,
                    "result": [[
                        "targetUri": "file:///sdk/gpio.h",
                        "targetRange": ["start": ["line": 10, "character": 0], "end": ["line": 10, "character": 20]],
                        "targetSelectionRange": [
                            "start": ["line": 10, "character": 5],
                            "end": ["line": 10, "character": 17]
                        ]
                    ]]
                ])
            case "shutdown":
                mock.emit(["jsonrpc": "2.0", "id": requestID, "result": NSNull()])
            default:
                break
            }
        }

        try await client.initialize(rootURL: URL(filePath: "/tmp/Blinky", directoryHint: .isDirectory))
        let file = URL(filePath: "/tmp/Blinky/src/main.c")
        async let completions = client.completion(url: file, position: LSPPosition(line: 1, character: 4))
        async let definitions = client.definition(url: file, position: LSPPosition(line: 1, character: 4))

        let items = try await completions
        let locs = try await definitions
        #expect(items.map(\.insertionText) == ["GPIOPinWrite"])
        #expect(locs == [LSPLocation(
            uri: "file:///sdk/gpio.h",
            range: LSPRange(start: LSPPosition(line: 10, character: 5), end: LSPPosition(line: 10, character: 17))
        )])

        await client.shutdown()
    }

    @Test func forwardsDiagnosticsAndRepliesToServerRequests() async throws {
        let transport = MockLSPTransport()
        let received = OSAllocatedUnfairLock(initialState: [LSPPublishDiagnosticsParams]())
        let client = LSPClient(transport: transport) { params in
            received.withLock { $0.append(params) }
        }

        // Server asks client for configuration (request with id and method).
        transport.emit([
            "jsonrpc": "2.0",
            "id": 99,
            "method": "workspace/configuration",
            "params": ["items": []]
        ])
        // Server pushes diagnostics notification.
        transport.emit([
            "jsonrpc": "2.0",
            "method": "textDocument/publishDiagnostics",
            "params": [
                "uri": "file:///tmp/main.c",
                "diagnostics": [[
                    "range": ["start": ["line": 2, "character": 0], "end": ["line": 2, "character": 3]],
                    "severity": 1,
                    "message": "expected ';'"
                ]]
            ]
        ])

        try await Task.sleep(for: .milliseconds(50))
        let messages = received.withLock { $0 }
        #expect(messages.count == 1)
        #expect(messages.first?.diagnostics.first?.message == "expected ';'")

        let replies = transport.sentPayloads.compactMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        #expect(replies.contains { ($0["id"] as? Int) == 99 && $0["result"] is NSNull })

        await client.shutdown()
    }

    @Test func failsPendingRequestsWhenServerDisconnects() async throws {
        let transport = MockLSPTransport()
        let client = LSPClient(transport: transport)
        let file = URL(filePath: "/tmp/main.c")

        transport.onSend = { _, mock in
            Task { await mock.close() }
        }

        await #expect(throws: LSPError.disconnected) {
            try await client.completion(url: file, position: LSPPosition(line: 0, character: 0))
        }
    }
}
