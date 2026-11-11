import Foundation

/// Reads and writes project files: JSON with a `formatVersion` number next to
/// the `Project` fields.
///
/// Files written by an older uMeil are upgraded in memory when they are read,
/// one version at a time. Files from a newer uMeil are refused instead of
/// being read wrongly.
enum ProjectFile {
    static let fileExtension = "umeil"

    /// The format version this build writes.
    static let currentVersion = 1

    /// Upgrades the raw JSON of a project file by one format version.
    typealias Migration = @Sendable (inout [String: Any]) throws -> Void

    /// `migrations[n]` turns a version `n` file into version `n + 1`.
    /// When the format changes, raise `currentVersion` and add the step here.
    static let migrations: [Int: Migration] = [:]

    private static let versionKey = "formatVersion"

    static func load(from url: URL) throws -> Project {
        try decode(Data(contentsOf: url))
    }

    static func save(_ project: Project, to url: URL) throws {
        try encode(project).write(to: url, options: .atomic)
    }

    /// The `currentVersion` and `migrations` parameters exist so tests can
    /// exercise upgrades before the real format has any.
    static func decode(
        _ data: Data,
        currentVersion: Int = currentVersion,
        migrations: [Int: Migration] = migrations
    ) throws -> Project {
        guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProjectFileError.notAProjectFile
        }
        guard var version = json[versionKey] as? Int, version >= 1 else {
            throw ProjectFileError.notAProjectFile
        }
        guard version <= currentVersion else {
            throw ProjectFileError.newerFormat(found: version, supported: currentVersion)
        }

        while version < currentVersion {
            guard let migrate = migrations[version] else {
                throw ProjectFileError.noMigration(from: version)
            }
            try migrate(&json)
            version += 1
        }
        json[versionKey] = nil

        do {
            let upgraded = try JSONSerialization.data(withJSONObject: json)
            return try JSONDecoder().decode(Project.self, from: upgraded)
        } catch let error as DecodingError {
            throw ProjectFileError.invalid(describe(error))
        }
    }

    /// Keys are sorted and the output is indented so project files produce
    /// small, readable diffs in version control.
    static func encode(_ project: Project) throws -> Data {
        let fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(project))
        guard var json = fields as? [String: Any] else {
            throw ProjectFileError.notAProjectFile
        }
        json[versionKey] = currentVersion

        var data = try JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        data.append(contentsOf: "\n".utf8)
        return data
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map(\.stringValue).joined(separator: ".")
        }

        switch error {
        case .keyNotFound(let key, let context):
            return "\"\((context.codingPath + [key]).map(\.stringValue).joined(separator: "."))\" is missing"
        case .valueNotFound(_, let context), .typeMismatch(_, let context):
            return "\"\(path(context))\" has the wrong kind of value"
        case .dataCorrupted(let context):
            return "\"\(path(context))\" has a value uMeil does not support"
        @unknown default:
            return "the file could not be read"
        }
    }
}

enum ProjectFileError: Error, Equatable, LocalizedError {
    /// Not JSON, or JSON without a usable `formatVersion`.
    case notAProjectFile
    case newerFormat(found: Int, supported: Int)
    case noMigration(from: Int)
    /// A field is missing or has a value uMeil does not understand.
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .notAProjectFile:
            "This is not a uMeil project file."
        case .newerFormat(let found, let supported):
            "This project uses format version \(found), but this copy of uMeil only reads up to version "
                + "\(supported). Update uMeil to open it."
        case .noMigration(let version):
            "This project uses format version \(version), which uMeil can no longer upgrade."
        case .invalid(let reason):
            "The project file is not valid: \(reason)."
        }
    }
}
