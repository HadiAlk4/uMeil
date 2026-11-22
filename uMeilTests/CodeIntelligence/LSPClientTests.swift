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

/// Records each payload only once its (slow) write completes, so a later
/// write that is not made to wait would be recorded first.
private final class SlowWriteTransport: LSPTransporting, @unchecked Sendable {
    let incoming = AsyncStream<Data> { _ in }
    private let written = OSAllocatedUnfairLock(initialState: [String]())

    var writtenMethods: [String] { written.withLock { $0 } }

    func send(_ payload: Data) async throws {
        let json = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        let method = json?["method"] as? String ?? ""
        if json?["id"] != nil {
            try await Task.sleep(for: .milliseconds(150))
        }
        written.withLock { $0.append(method) }
    }

    func close() async {}
}

struct LSPClientTests {
    @Test func aNotificationNeverOvertakesAnEarlierRequest() async throws {
        let transport = SlowWriteTransport()
        let client = LSPClient(transport: transport)
        let file = URL(filePath: "/tmp/Blinky/src/main.c")

        let completion = Task { try await client.completion(url: file, position: LSPPosition(line: 0, character: 0)) }
        try await Task.sleep(for: .milliseconds(30))
        try await client.didChange(url: file, version: 2, text: "int x;\n")

        #expect(transport.writtenMethods == ["textDocument/completion", "textDocument/didChange"])
        completion.cancel()
    }

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

        // Writes go out in order on their own task, so wait for the reply
        // rather than for a fixed time that a busy machine can overrun.
        let replied = await eventually {
            transport.sentPayloads.contains { payload in
                guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
                    return false
                }
                return (json["id"] as? Int) == 99 && json["result"] is NSNull
            }
        }
        #expect(replied)
        // The diagnostics are handled after the reply has been written.
        #expect(await eventually { !received.withLock { $0 }.isEmpty })

        let messages = received.withLock { $0 }
        #expect(messages.count == 1)
        #expect(messages.first?.diagnostics.first?.message == "expected ';'")

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

    @Test func advertisesCodeActionCapabilitiesInInitialize() async throws {
        let transport = MockLSPTransport()
        let client = LSPClient(transport: transport)
        let capturedInit = OSAllocatedUnfairLock(initialState: Data?.none)

        transport.onSend = { payload, mock in
            guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let method = json["method"] as? String,
                  let requestID = json["id"] as? Int
            else { return }
            if method == "initialize" {
                capturedInit.withLock { $0 = payload }
                mock.emit(["jsonrpc": "2.0", "id": requestID, "result": ["capabilities": [:]]])
            } else if method == "shutdown" {
                mock.emit(["jsonrpc": "2.0", "id": requestID, "result": NSNull()])
            }
        }

        try await client.initialize(rootURL: URL(filePath: "/tmp/Blinky", directoryHint: .isDirectory))
        let initData = try #require(capturedInit.withLock { $0 })
        let initRequest = try #require(JSONSerialization.jsonObject(with: initData) as? [String: Any])
        let initParams = try #require(initRequest["params"] as? [String: Any])
        let capabilities = try #require(initParams["capabilities"] as? [String: Any])
        let textDoc = try #require(capabilities["textDocument"] as? [String: Any])
        let codeActionCap = try #require(textDoc["codeAction"] as? [String: Any])
        let literalSupport = try #require(codeActionCap["codeActionLiteralSupport"] as? [String: Any])
        let kindSupport = try #require(literalSupport["codeActionKind"] as? [String: Any])
        let valueSet = try #require(kindSupport["valueSet"] as? [String])
        #expect(valueSet.contains("quickfix"))
        #expect(codeActionCap["isPreferredSupport"] as? Bool == true)

        await client.shutdown()
    }

    @Test func requestsAndDecodesCodeActions() async throws {
        let transport = MockLSPTransport()
        let client = LSPClient(transport: transport)
        let file = URL(filePath: "/tmp/Blinky/src/main.c")
        let fileURI = file.standardizedFileURL.absoluteString
        let diagRange = LSPRange(start: LSPPosition(line: 1, character: 4), end: LSPPosition(line: 1, character: 10))
        let diagnostic = LSPDiagnostic(
            range: diagRange, severity: .error, code: "-Wimplicit-function-declaration",
            source: "clang", message: "Call to undeclared library function 'printf'"
        )
        let capturedRequest = OSAllocatedUnfairLock(initialState: Data?.none)

        transport.onSend = { payload, mock in
            guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let method = json["method"] as? String, let requestID = json["id"] as? Int
            else { return }
            if method == "shutdown" {
                mock.emit(["jsonrpc": "2.0", "id": requestID, "result": NSNull()])
            } else if method == "textDocument/codeAction", let params = json["params"] as? [String: Any] {
                let diagnostics = (params["context"] as? [String: Any])?["diagnostics"] as? [[String: Any]] ?? []
                if !diagnostics.isEmpty { capturedRequest.withLock { $0 = payload } }
                let quickFixResult: [[String: Any]] = [[
                    "title": "Include <stdio.h> for symbol printf", "kind": "quickfix", "isPreferred": true,
                    "edit": ["changes": [fileURI: [[
                        "range": ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 0]],
                        "newText": "#include <stdio.h>\n"
                    ]]]]
                ]]
                let result: Any = diagnostics.isEmpty ? NSNull() : quickFixResult
                mock.emit(["jsonrpc": "2.0", "id": requestID, "result": result])
            }
        }

        let actions = try await client.codeAction(url: file, range: diagRange, diagnostics: [diagnostic])
        let emptyActions = try await client.codeAction(url: file, range: diagRange, diagnostics: [])

        #expect(actions.count == 1)
        #expect(actions.first?.title == "Include <stdio.h> for symbol printf")
        #expect(actions.first?.isPreferred == true)
        #expect(actions.first?.quickFixEdits(targeting: file)?.first?.newText == "#include <stdio.h>\n")
        #expect(emptyActions.isEmpty)

        let reqData = try #require(capturedRequest.withLock { $0 })
        let reqJSON = try #require(JSONSerialization.jsonObject(with: reqData) as? [String: Any])
        let caParams = try #require(reqJSON["params"] as? [String: Any])
        let caContext = try #require(caParams["context"] as? [String: Any])
        #expect(caContext["only"] as? [String] == ["quickfix"])
        let sentDiags = try #require(caContext["diagnostics"] as? [[String: Any]])
        #expect(sentDiags.first?["message"] as? String == diagnostic.message)

        await client.shutdown()
    }
}
