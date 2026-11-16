import Foundation

/// Manages a `clangd` process for one workspace folder, keeping open C/H
/// buffers synchronized and serving completions, definitions, and diagnostics.
actor ClangdSession {
    let clangdExecutable: URL
    let workspaceDirectory: URL
    let compileCommandsDirectory: URL?
    let changeDebounce: Duration
    private let onDiagnostics: @Sendable (LSPPublishDiagnosticsParams) async -> Void

    private var client: LSPClient?
    private var startTask: Task<LSPClient, Error>?

    private var versions: [URL: Int] = [:]
    private var openDocuments: Set<URL> = []
    private var lastSyncedText: [URL: String] = [:]
    private var pendingChanges: [URL: (version: Int, text: String)] = [:]
    private var debounceTasks: [URL: Task<Void, Never>] = [:]

    init(
        clangdExecutable: URL,
        workspaceDirectory: URL,
        compileCommandsDirectory: URL? = nil,
        changeDebounce: Duration = .milliseconds(100),
        onDiagnostics: @escaping @Sendable (LSPPublishDiagnosticsParams) async -> Void
    ) {
        self.clangdExecutable = clangdExecutable
        self.workspaceDirectory = workspaceDirectory.resolvingSymlinksInPath().standardizedFileURL
        self.compileCommandsDirectory = compileCommandsDirectory?.resolvingSymlinksInPath().standardizedFileURL
        self.changeDebounce = changeDebounce
        self.onDiagnostics = onDiagnostics
    }

    /// Builds the command-line flags used to start `clangd`.
    static func launchArguments(compileCommandsDirectory: URL?) -> [String] {
        var arguments: [String] = []
        if let compileCommandsDirectory {
            arguments.append("--compile-commands-dir=\(compileCommandsDirectory.path(percentEncoded: false))")
        }
        // Let clangd query arm-none-eabi-gcc for its built-in target and newlib include paths.
        arguments.append("--query-driver=**/\(Tool.compiler.executableName)")
        // Keep completions pure so accepting a function does not insert headers unexpectedly.
        arguments.append("--header-insertion=never")
        // Bound background worker threads and keep PCHs in memory for responsiveness.
        arguments.append("-j=2")
        arguments.append("--pch-storage=memory")
        return arguments
    }

    /// Starts `clangd` if it is not already running.
    func start() async throws {
        _ = try await ensureClient()
    }

    /// Gracefully stops `clangd` and cancels any pending document updates.
    func stop() async {
        for (_, task) in debounceTasks {
            task.cancel()
        }
        debounceTasks.removeAll()
        pendingChanges.removeAll()
        openDocuments.removeAll()
        lastSyncedText.removeAll()
        versions.removeAll()

        let pendingStart = startTask
        let existingClient = client
        startTask = nil
        client = nil

        pendingStart?.cancel()
        if let pendingStart, let started = try? await pendingStart.value {
            await started.shutdown()
        }
        await existingClient?.shutdown()
    }

    // MARK: - Document synchronization

    func openDocument(url: URL, text: String) async throws {
        let normalized = Self.normalize(url)
        let client = try await ensureClient()

        debounceTasks[normalized]?.cancel()
        debounceTasks[normalized] = nil
        pendingChanges[normalized] = nil

        if openDocuments.contains(normalized) {
            if lastSyncedText[normalized] == text { return }
            try? await client.didClose(url: normalized)
        }
        let version = 1
        versions[normalized] = version
        openDocuments.insert(normalized)
        lastSyncedText[normalized] = text
        try await client.didOpen(url: normalized, languageID: "c", version: version, text: text)
    }

    func updateDocument(url: URL, text: String) async {
        let normalized = Self.normalize(url)
        let version = (versions[normalized] ?? 0) + 1
        versions[normalized] = version
        pendingChanges[normalized] = (version, text)

        debounceTasks[normalized]?.cancel()
        let delay = changeDebounce
        debounceTasks[normalized] = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            try? await self?.flushPendingChange(for: normalized)
        }
    }

    func saveDocument(url: URL, text: String) async throws {
        let normalized = Self.normalize(url)
        try await ensureSynced(url: normalized, currentText: text)
        let client = try await ensureClient()
        try await client.didSave(url: normalized, text: text)
    }

    func closeDocument(url: URL) async {
        let normalized = Self.normalize(url)
        debounceTasks[normalized]?.cancel()
        debounceTasks[normalized] = nil
        pendingChanges[normalized] = nil
        lastSyncedText[normalized] = nil
        guard openDocuments.remove(normalized) != nil else { return }
        if let client {
            try? await client.didClose(url: normalized)
        }
    }

    // MARK: - Intelligence requests

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

    // MARK: - Helpers

    private func ensureClient() async throws -> LSPClient {
        if let client { return client }
        if let startTask { return try await startTask.value }

        let forwarder: @Sendable (LSPPublishDiagnosticsParams) async -> Void = { [weak self] params in
            // TivaWare headers require main.c to include <stdint.h> and <stdbool.h>
            // before driverlib/*.h; clangd's unused-includes check flags them as unused
            // even though removing them breaks GCC compilation.
            var filtered = params
            filtered.diagnostics.removeAll { $0.code == "unused-includes" }
            await self?.forwardDiagnostics(filtered)
        }
        let task = Task { [clangdExecutable, workspaceDirectory, compileCommandsDirectory, forwarder] in
            try Task.checkCancellation()
            let transport = try ProcessLSPTransport(
                executable: clangdExecutable,
                arguments: Self.launchArguments(compileCommandsDirectory: compileCommandsDirectory),
                currentDirectory: workspaceDirectory
            )
            let client = LSPClient(transport: transport, onDiagnostics: forwarder)
            do {
                try await withTaskCancellationHandler {
                    try await client.initialize(rootURL: workspaceDirectory)
                } onCancel: {
                    Task { await transport.close() }
                }
                return client
            } catch {
                if Task.isCancelled {
                    await transport.close()
                } else {
                    await client.shutdown()
                }
                throw error
            }
        }
        startTask = task
        do {
            let started = try await task.value
            client = started
            startTask = nil
            return started
        } catch {
            startTask = nil
            throw error
        }
    }

    private func ensureSynced(url: URL, currentText: String?) async throws {
        if !openDocuments.contains(url), let currentText {
            try await openDocument(url: url, text: currentText)
            return
        }
        if let currentText,
           pendingChanges[url] == nil,
           lastSyncedText[url] != currentText {
            let version = (versions[url] ?? 0) + 1
            versions[url] = version
            pendingChanges[url] = (version, currentText)
        }
        try await flushPendingChange(for: url)
    }

    private func flushPendingChange(for url: URL) async throws {
        debounceTasks[url]?.cancel()
        debounceTasks[url] = nil
        guard let pending = pendingChanges.removeValue(forKey: url) else { return }
        let client = try await ensureClient()
        lastSyncedText[url] = pending.text
        if !openDocuments.contains(url) {
            openDocuments.insert(url)
            try await client.didOpen(url: url, languageID: "c", version: pending.version, text: pending.text)
        } else {
            try await client.didChange(url: url, version: pending.version, text: pending.text)
        }
    }

    private func forwardDiagnostics(_ params: LSPPublishDiagnosticsParams) async {
        if let url = params.url,
           let publishedVersion = params.version,
           let currentVersion = versions[Self.normalize(url)],
           publishedVersion < currentVersion {
            return
        }
        await onDiagnostics(params)
    }

    static func normalize(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }
}
