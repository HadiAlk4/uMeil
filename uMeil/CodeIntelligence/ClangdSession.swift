import Foundation

/// Manages a `clangd` process for one workspace folder, keeping open C/H
/// buffers synchronized and serving completions, definitions, and diagnostics.
actor ClangdSession {
    let clangdExecutable: URL
    let workspaceDirectory: URL
    let compileCommandsDirectory: URL?
    let queryDriver: URL?
    let changeDebounce: Duration
    private let onDiagnostics: @Sendable (LSPPublishDiagnosticsParams) async -> Void

    private var client: LSPClient?
    private var startTask: Task<LSPClient, Error>?

    private var versions: [URL: Int] = [:]
    private var generations: [URL: Int] = [:]
    private var openDocuments: Set<URL> = []
    private var lastSyncedText: [URL: String] = [:]
    private var pendingChanges: [URL: (version: Int, text: String)] = [:]
    private var debounceTasks: [URL: Task<Void, Never>] = [:]

    init(
        clangdExecutable: URL,
        workspaceDirectory: URL,
        compileCommandsDirectory: URL? = nil,
        queryDriver: URL? = nil,
        changeDebounce: Duration = .milliseconds(100),
        onDiagnostics: @escaping @Sendable (LSPPublishDiagnosticsParams) async -> Void
    ) {
        self.clangdExecutable = clangdExecutable
        self.workspaceDirectory = workspaceDirectory.resolvingSymlinksInPath().standardizedFileURL
        self.compileCommandsDirectory = compileCommandsDirectory?.resolvingSymlinksInPath().standardizedFileURL
        self.queryDriver = Self.canonicalQueryDriver(for: queryDriver)
        self.changeDebounce = changeDebounce
        self.onDiagnostics = onDiagnostics
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
        generations.removeAll()

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

    func openDocument(url: URL, text: String, version: Int? = nil) async throws {
        let normalized = Self.normalize(url)
        if let existing = versions[normalized], let version, version < existing {
            return
        }
        let generation = nextGeneration(for: normalized)
        let resolvedVersion = resolveVersion(for: normalized, requested: version)
        debounceTasks[normalized]?.cancel()
        debounceTasks[normalized] = nil
        pendingChanges[normalized] = nil

        let client = try await ensureClient()
        // If an edit or close arrived while clangd was booting, do not overwrite it with stale text.
        guard generations[normalized] == generation else { return }

        if openDocuments.contains(normalized) {
            if lastSyncedText[normalized] == text { return }
            openDocuments.remove(normalized)
            lastSyncedText[normalized] = nil
            try? await client.didClose(url: normalized)
            guard generations[normalized] == generation else { return }
        }
        openDocuments.insert(normalized)
        lastSyncedText[normalized] = text
        try await client.didOpen(url: normalized, languageID: "c", version: resolvedVersion, text: text)
    }

    func updateDocument(url: URL, text: String, version: Int? = nil) async {
        let normalized = Self.normalize(url)
        if let existing = versions[normalized], let version, version < existing {
            return
        }
        _ = nextGeneration(for: normalized)
        let resolvedVersion = resolveVersion(for: normalized, requested: version)
        pendingChanges[normalized] = (resolvedVersion, text)

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

    func saveDocument(url: URL, text: String, version: Int? = nil) async throws {
        let normalized = Self.normalize(url)
        try await ensureSynced(url: normalized, currentText: text, version: version)
        let client = try await ensureClient()
        try await client.didSave(url: normalized, text: text)
    }

    func closeDocument(url: URL, version: Int? = nil) async {
        let normalized = Self.normalize(url)
        if let version {
            versions[normalized] = max(versions[normalized] ?? 0, version)
        }
        _ = nextGeneration(for: normalized)
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
        let task = Task { [clangdExecutable, workspaceDirectory, compileCommandsDirectory, queryDriver, forwarder] in
            try Task.checkCancellation()
            let transport = try ProcessLSPTransport(
                executable: clangdExecutable,
                arguments: Self.launchArguments(
                    compileCommandsDirectory: compileCommandsDirectory,
                    queryDriver: queryDriver
                ),
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

    private func ensureSynced(url: URL, currentText: String?, version: Int? = nil) async throws {
        if !openDocuments.contains(url), let currentText {
            try await openDocument(url: url, text: currentText, version: version)
            return
        }
        if let currentText,
           pendingChanges[url] == nil,
           lastSyncedText[url] != currentText {
            let resolvedVersion = resolveVersion(for: url, requested: version)
            pendingChanges[url] = (resolvedVersion, currentText)
        }
        try await flushPendingChange(for: url)
    }

    private func flushPendingChange(for url: URL) async throws {
        debounceTasks[url]?.cancel()
        debounceTasks[url] = nil
        guard pendingChanges[url] != nil else { return }
        let client = try await ensureClient()
        guard let pending = pendingChanges.removeValue(forKey: url) else { return }
        lastSyncedText[url] = pending.text
        if !openDocuments.contains(url) {
            openDocuments.insert(url)
            try await client.didOpen(url: url, languageID: "c", version: pending.version, text: pending.text)
        } else {
            try await client.didChange(url: url, version: pending.version, text: pending.text)
        }
    }

    private func resolveVersion(for url: URL, requested: Int?) -> Int {
        let next = requested ?? ((versions[url] ?? 0) + 1)
        versions[url] = max(versions[url] ?? 0, next)
        return next
    }

    private func nextGeneration(for url: URL) -> Int {
        let next = (generations[url] ?? 0) + 1
        generations[url] = next
        return next
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

extension ClangdSession {
    /// Builds the command-line flags used to start `clangd`.
    static func launchArguments(compileCommandsDirectory: URL?, queryDriver: URL? = nil) -> [String] {
        var arguments: [String] = []
        if let compileCommandsDirectory {
            arguments.append("--compile-commands-dir=\(compileCommandsDirectory.path(percentEncoded: false))")
        }
        if let queryDriverArg = queryDriverArgument(for: queryDriver) {
            arguments.append(queryDriverArg)
        }
        // Disable workspace and user `.clangd` configs so untrusted folders cannot override tools or flags.
        arguments.append("--enable-config=false")
        // Keep completions pure so accepting a function does not insert headers unexpectedly.
        arguments.append("--header-insertion=never")
        // One entry per function with its full parameter list, so the list
        // shows what each argument is and snippets fill them all in.
        arguments.append("--completion-style=detailed")
        // Bound background worker threads and keep PCHs in memory for responsiveness.
        arguments.append("-j=2")
        arguments.append("--pch-storage=memory")
        return arguments
    }

    private static func queryDriverArgument(for queryDriver: URL?) -> String? {
        guard let resolved = canonicalQueryDriver(for: queryDriver) else { return nil }
        return "--query-driver=\(resolved.path(percentEncoded: false))"
    }

    private static func canonicalQueryDriver(for queryDriver: URL?) -> URL? {
        guard let queryDriver, queryDriver.isFileURL else { return nil }
        let rawPath = queryDriver.path(percentEncoded: false)
        guard isSafeQueryDriverPath(rawPath) else { return nil }
        let resolved = queryDriver.resolvingSymlinksInPath().standardizedFileURL
        let canonicalPath = resolved.path(percentEncoded: false)
        guard isSafeQueryDriverPath(canonicalPath),
              !resolved.path(percentEncoded: true).contains("%00")
        else {
            return nil
        }
        return resolved
    }

    private static func isSafeQueryDriverPath(_ path: String) -> Bool {
        !path.isEmpty && !path.unicodeScalars.contains { scalar in
            switch scalar {
            case ",", "*", "?", "\n", "\r", "\0": true
            default: false
            }
        }
    }
}
