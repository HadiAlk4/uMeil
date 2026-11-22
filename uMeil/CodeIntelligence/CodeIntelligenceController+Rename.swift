import Foundation

/// Why a rename did not happen, in words for the person who asked.
enum RenameError: Error, Equatable, LocalizedError {
    case unavailable
    case invalidName(String)
    case refused(String)
    case outsideProject([String])

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Code intelligence is not running for this file."
        case .invalidName(let name):
            "“\(name)” is not a valid C name. Use letters, digits and underscores, not starting with a digit."
        case .refused(let reason):
            reason
        case .outsideProject(let files):
            "This name is declared or used in \(files.joined(separator: ", ")), outside the project folder, "
                + "so nothing was renamed."
        }
    }
}

@MainActor
extension CodeIntelligenceController {
    /// Checks that the name at `position` can be renamed, returning its range.
    func prepareRename(in url: URL, text: String, position: LSPPosition) async throws -> LSPRange? {
        guard let session = await readySession() else { throw RenameError.unavailable }
        do {
            return try await session.prepareRename(at: position, in: url, currentText: text)
        } catch LSPError.serverError(_, let message) {
            throw RenameError.refused(message)
        }
    }

    /// The edits renaming the symbol at `position` to `newName`, by file.
    /// Throws instead of returning edits that reach outside the project,
    /// such as into TivaWare's headers.
    func rename(
        in url: URL,
        text: String,
        position: LSPPosition,
        to newName: String
    ) async throws -> [URL: [LSPTextEdit]] {
        guard Self.isValidCIdentifier(newName) else { throw RenameError.invalidName(newName) }
        guard let session = await readySession() else { throw RenameError.unavailable }
        // clangd only edits files it has indexed, so renaming a TivaWare
        // function would change its calls but not its header. Refuse
        // names that are declared outside the project.
        let declarations = (try? await session.definition(at: position, in: url, currentText: text)) ?? []
        let foreign = declarations.compactMap(\.url).filter { !isInsideWorkspace($0) }
        guard foreign.isEmpty else {
            throw RenameError.outsideProject(Set(foreign.map(\.lastPathComponent)).sorted())
        }
        let edit: LSPWorkspaceEdit
        do {
            edit = try await session.rename(at: position, in: url, to: newName, currentText: text)
        } catch LSPError.serverError(_, let message) {
            throw RenameError.refused(message)
        }
        let outside = edit.edits.keys.filter { !isInsideWorkspace($0) }
        guard outside.isEmpty else {
            throw RenameError.outsideProject(outside.map(\.lastPathComponent).sorted())
        }
        return edit.edits
    }

    private func isInsideWorkspace(_ file: URL) -> Bool {
        guard let folder = workspaceFolder else { return false }
        let root = ClangdSession.normalize(folder).path(percentEncoded: false)
        let path = ClangdSession.normalize(file).path(percentEncoded: false)
        return path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    nonisolated static func isValidCIdentifier(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, !("0"..."9").contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            scalar == "_" || ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
                || ("0"..."9").contains(scalar)
        }
    }
}
