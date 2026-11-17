import Foundation
import os

/// Coordinates `compile_commands.json` generation and the workspace `clangd`
/// session for one main window.
@MainActor
final class CodeIntelligenceController {
    private let makeToolLocator: () -> ToolLocator
    private weak var editor: EditorViewController?
    private let onNavigateToLocation: (LSPLocation) -> Void

    private var folder: URL?
    private var documentVersions: [URL: Int] = [:]
    private let sessionBox = OSAllocatedUnfairLock<ClangdSession?>(uncheckedState: nil)
    private let openFileTaskBox = OSAllocatedUnfairLock<Task<Void, Never>?>(uncheckedState: nil)

    private var session: ClangdSession? {
        get { sessionBox.withLockUnchecked { $0 } }
        set { sessionBox.withLockUnchecked { $0 = newValue } }
    }

    init(
        makeToolLocator: @escaping () -> ToolLocator,
        editor: EditorViewController,
        onNavigateToLocation: @escaping (LSPLocation) -> Void
    ) {
        self.makeToolLocator = makeToolLocator
        self.editor = editor
        self.onNavigateToLocation = onNavigateToLocation
    }

    deinit {
        openFileTaskBox.withLockUnchecked { task in
            task?.cancel()
            task = nil
        }
        let existing = sessionBox.withLockUnchecked { state -> ClangdSession? in
            let current = state
            state = nil
            return current
        }
        if let existing {
            Task { await existing.stop() }
        }
    }

    /// Rebuilds `compile_commands.json` (when a `.umeil` file exists) and
    /// restarts `clangd` for `folder`.
    func folderOpened(_ folder: URL) {
        self.folder = folder
        stop()
        prepareCompileCommands(in: folder)
        startSessionIfAvailable(in: folder)
    }

    func fileOpened(_ url: URL, text: String) {
        guard SourceLanguage(url: url) == .c else {
            editor?.clearLiveDiagnostics()
            return
        }
        if session == nil, let folder {
            startSessionIfAvailable(in: folder)
        }
        guard let session else { return }
        let version = bumpDocumentVersion(for: url)
        let task: Task<Void, Never> = Task {
            _ = try? await session.openDocument(url: url, text: text, version: version)
        }
        openFileTaskBox.withLockUnchecked { previous in
            previous?.cancel()
            previous = task
        }
    }

    func textChanged(in url: URL, text: String) {
        guard SourceLanguage(url: url) == .c, let session else { return }
        let version = bumpDocumentVersion(for: url)
        Task {
            await session.updateDocument(url: url, text: text, version: version)
        }
    }

    func fileSaved(_ url: URL, text: String) {
        if url.pathExtension == ProjectFile.fileExtension, let folder {
            folderOpened(folder)
            return
        }
        guard SourceLanguage(url: url) == .c, let session else { return }
        let version = documentVersions[ClangdSession.normalize(url)]
        Task {
            try? await session.saveDocument(url: url, text: text, version: version)
        }
    }

    func fileClosed(_ url: URL) {
        guard SourceLanguage(url: url) == .c, let session else { return }
        let version = bumpDocumentVersion(for: url)
        openFileTaskBox.withLockUnchecked { task in
            task?.cancel()
            task = nil
        }
        Task {
            await session.closeDocument(url: url, version: version)
        }
    }

    func buildFinished(in folder: URL) {
        if session == nil {
            startSessionIfAvailable(in: folder)
        }
    }

    func completion(in url: URL, text: String, position: LSPPosition) async -> [LSPCompletionItem] {
        let pendingOpen = openFileTaskBox.withLockUnchecked { $0 }
        await pendingOpen?.value
        guard let session else { return [] }
        return (try? await session.completion(at: position, in: url, currentText: text)) ?? []
    }

    func jumpToDefinition(in url: URL, text: String, position: LSPPosition) async {
        let pendingOpen = openFileTaskBox.withLockUnchecked { $0 }
        await pendingOpen?.value
        guard let session,
              let locations = try? await session.definition(at: position, in: url, currentText: text),
              let first = locations.first
        else { return }
        onNavigateToLocation(first)
    }

    func stop() {
        documentVersions.removeAll()
        openFileTaskBox.withLockUnchecked { task in
            task?.cancel()
            task = nil
        }
        let existing = sessionBox.withLockUnchecked { state -> ClangdSession? in
            let current = state
            state = nil
            return current
        }
        if let existing {
            Task { await existing.stop() }
        }
    }

    // MARK: - Helpers

    private func prepareCompileCommands(in folder: URL) {
        guard let projectFile = BuildSummary.projectFile(in: folder) else { return }
        _ = try? BuildEngine.prepareCompileCommands(forProjectFile: projectFile, locator: makeToolLocator())
    }

    private func startSessionIfAvailable(in folder: URL) {
        guard let clangd = makeToolLocator().locate(.clangd) else { return }
        let buildDir = folder.appending(path: BuildPlan.buildDirectoryName, directoryHint: .isDirectory)
        let compileDB = buildDir.appending(path: "compile_commands.json")
        let hasCompileDB = FileManager.default.fileExists(atPath: compileDB.path(percentEncoded: false))

        session = ClangdSession(
            clangdExecutable: clangd,
            workspaceDirectory: folder,
            compileCommandsDirectory: hasCompileDB ? buildDir : nil
        ) { [weak self] params in
            await self?.handlePublishedDiagnostics(params)
        }
    }

    private func handlePublishedDiagnostics(_ params: LSPPublishDiagnosticsParams) {
        guard let editor,
              let openURL = editor.document?.url,
              let targetURL = params.url
        else { return }
        let normalizedTarget = ClangdSession.normalize(targetURL)
        guard ClangdSession.normalize(openURL) == normalizedTarget else { return }
        if let publishedVersion = params.version,
           let currentVersion = documentVersions[normalizedTarget],
           publishedVersion != currentVersion {
            return
        }
        editor.applyLiveDiagnostics(params.diagnostics)
    }

    private func bumpDocumentVersion(for url: URL) -> Int {
        let normalized = ClangdSession.normalize(url)
        let next = (documentVersions[normalized] ?? 0) + 1
        documentVersions[normalized] = next
        return next
    }
}
