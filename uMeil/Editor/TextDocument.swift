import Foundation

enum TextDocumentError: Error, Equatable, LocalizedError {
    /// The file looks like a binary file (an object file, a firmware image…).
    case notText
    case fileTooLarge

    var errorDescription: String? {
        switch self {
        case .notText: "This file is not a text file, so it cannot be edited."
        case .fileTooLarge: "This file is too large to open in the editor (maximum 10 MB)."
        }
    }
}

/// A text file on disk and its contents.
struct TextDocument: Equatable {
    static let maximumFileSize = 10 * 1024 * 1024

    var url: URL
    var text: String
    /// The encoding the file was read with, used again when saving.
    var encoding: String.Encoding

    /// Reads a text file. UTF-8 is tried first; files that are not valid
    /// UTF-8 (older vendor sources often are not) are read as Latin-1, which
    /// accepts any bytes and writes them back unchanged.
    static func load(from url: URL) throws -> TextDocument {
        let values = try url.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = values.fileSize, fileSize > maximumFileSize {
            throw TextDocumentError.fileTooLarge
        }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumFileSize else { throw TextDocumentError.fileTooLarge }
        guard !data.contains(0) else { throw TextDocumentError.notText }

        if let text = String(data: data, encoding: .utf8) {
            return TextDocument(url: url, text: text, encoding: .utf8)
        }
        // Latin-1 maps every byte to a character, so this cannot fail.
        let text = String(data: data, encoding: .isoLatin1) ?? ""
        return TextDocument(url: url, text: text, encoding: .isoLatin1)
    }

    /// Writes the text back to `url`, replacing the file in one step so a
    /// crash mid-save cannot leave it half written.
    func save() throws {
        // Text typed into a Latin-1 file may not fit Latin-1; fall back to UTF-8.
        let data = text.data(using: encoding) ?? Data(text.utf8)
        try data.write(to: url, options: .atomic)
    }
}
