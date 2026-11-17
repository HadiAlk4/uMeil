import Foundation
import Testing
@testable import uMeil

enum ClangdTestEnvironment {
    static let canRunClangd = ProcessInfo.processInfo.environment["UMEIL_REQUIRE_TOOLS"] == "1"
        || ToolLocator.standard().locate(.clangd) != nil
}

/// Real `clangd` integration tests against the Blinky template project.
@Suite(.enabled(if: ClangdTestEnvironment.canRunClangd))
struct ClangdIntegrationTests {
    private struct Harness {
        let temp: TemporaryDirectory
        let folder: URL
        let mainC: URL
        let originalText: String
        let session: ClangdSession
        let diagnostics: AsyncStream<LSPPublishDiagnosticsParams>
        let continuation: AsyncStream<LSPPublishDiagnosticsParams>.Continuation

        func close() async {
            await session.stop()
            continuation.finish()
        }
    }

    private func startBlinkySession() async throws -> Harness {
        let clangd = try #require(ToolLocator.standard().locate(.clangd))
        let temp = try TemporaryDirectory()
        let template = try #require(try ProjectTemplate.all().first { $0.identifier == "Blinky" })
        let projectFile = try template.createProject(named: "Blinky", in: temp.url)
        try BuildEngine.prepareCompileCommands(forProjectFile: projectFile)

        let folder = projectFile.deletingLastPathComponent()
        let mainC = folder.appending(path: "src/main.c")
        let originalText = try String(contentsOf: mainC, encoding: .utf8)

        let (stream, continuation) = AsyncStream.makeStream(of: LSPPublishDiagnosticsParams.self)
        let session = ClangdSession(
            clangdExecutable: clangd,
            workspaceDirectory: folder,
            compileCommandsDirectory: folder.appending(path: "build"),
            changeDebounce: .zero
        ) { params in
            continuation.yield(params)
        }
        try await session.openDocument(url: mainC, text: originalText)
        let harness = Harness(
            temp: temp,
            folder: folder,
            mainC: mainC,
            originalText: originalText,
            session: session,
            diagnostics: stream,
            continuation: continuation
        )
        // Wait until clangd finishes indexing the preamble for main.c.
        let initial = try await waitForDiagnostics(in: harness) { _ in true }
        #expect(initial.diagnostics.isEmpty)
        return harness
    }

    private func waitForDiagnostics(
        in harness: Harness,
        matching predicate: @Sendable (LSPPublishDiagnosticsParams) -> Bool
    ) async throws -> LSPPublishDiagnosticsParams {
        let wanted = ClangdSession.normalize(harness.mainC)
        for await params in harness.diagnostics {
            if params.url.map(ClangdSession.normalize) == wanted, predicate(params) {
                return params
            }
        }
        throw LSPError.disconnected
    }

    @Test(.timeLimit(.minutes(1)))
    func navigatesToDriverLibDefinitionFromBlinky() async throws {
        let harness = try await startBlinkySession()

        let index = LineIndex(harness.originalText)
        let callRange = (harness.originalText as NSString).range(of: "GPIOPinWrite(")
        let position = index.lspPosition(atUTF16Offset: callRange.location + 2)
        let definitions = try await harness.session.definition(at: position, in: harness.mainC)

        let target = try #require(definitions.first)
        #expect(target.url?.lastPathComponent == "gpio.h")
        #expect(target.url?.pathComponents.contains("driverlib") == true)
        await harness.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func completesDriverLibFunctionsInBlinky() async throws {
        let harness = try await startBlinkySession()

        let edited = harness.originalText.replacingOccurrences(
            of: "GPIOPinWrite(GPIO_PORTN_BASE, GPIO_PIN_1, 0);",
            with: "GPIOPin"
        )
        await harness.session.updateDocument(url: harness.mainC, text: edited)
        let prefixRange = (edited as NSString).range(of: "        GPIOPin\n")
        let cursor = LineIndex(edited).lspPosition(atUTF16Offset: prefixRange.location + "        GPIOPin".utf16.count)
        let completions = try await harness.session.completion(at: cursor, in: harness.mainC, currentText: edited)

        #expect(completions.contains { $0.insertionText == "GPIOPinWrite" })
        #expect(completions.contains { $0.insertionText == "GPIOPinTypeGPIOOutput" })
        await harness.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func publishesAndClearsLiveDiagnosticsWhileTyping() async throws {
        let harness = try await startBlinkySession()

        let broken = harness.originalText.replacingOccurrences(
            of: "GPIOPinWrite(GPIO_PORTN_BASE, GPIO_PIN_1, 0);",
            with: "undeclared_blinky_symbol();"
        )
        await harness.session.updateDocument(url: harness.mainC, text: broken)
        let brokenDiagnostics = try await waitForDiagnostics(in: harness) { !$0.diagnostics.isEmpty }
        #expect(brokenDiagnostics.diagnostics.contains { $0.message.contains("undeclared_blinky_symbol") })

        await harness.session.updateDocument(url: harness.mainC, text: harness.originalText)
        let cleared = try await waitForDiagnostics(in: harness) { $0.diagnostics.isEmpty }
        #expect(cleared.diagnostics.isEmpty)
        await harness.close()
    }
}
