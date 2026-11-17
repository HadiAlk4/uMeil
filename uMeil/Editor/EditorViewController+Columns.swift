import Foundation

extension EditorViewController {
    /// How a column passed to `goTo` counts characters.
    enum ColumnUnit {
        /// UTF-16 code units, as `clangd` and the text view count them.
        case utf16
        /// UTF-8 bytes, as GCC reports them with `-fdiagnostics-column-unit=byte`.
        case utf8
    }

    /// Converts a 1-based column counted in UTF-8 bytes into one counted in
    /// UTF-16 code units, so `µ` (2 bytes, 1 unit) does not shift the cursor.
    nonisolated static func utf16Column(fromUTF8Column column: Int, in line: String) -> Int {
        var bytes = 0
        var units = 0
        for scalar in line.unicodeScalars {
            guard bytes < column - 1 else { break }
            bytes += UTF8.width(scalar)
            units += UTF16.width(scalar)
        }
        return units + 1
    }
}
