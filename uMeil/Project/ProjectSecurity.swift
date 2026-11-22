import Foundation

enum ProjectSecurityError: Error, Equatable, LocalizedError {
    case unsafePath(String)
    case symlinkNotAllowed(URL)

    var errorDescription: String? {
        switch self {
        case .unsafePath(let path):
            "The path “\(path)” points outside the project folder or uses an unsupported form."
        case .symlinkNotAllowed(let url):
            "“\(url.lastPathComponent)” is a symbolic link, which uMeil does not allow here."
        }
    }
}

/// Validates project-relative paths and subdirectories so malicious project
/// files or symlinks cannot escape the project root.
enum ProjectSecurity {
    private static let maximumSymlinkDepth = 40

    private enum SymlinkLookup {
        case notSymlink
        case destination(String)
        case unreadable
    }

    /// Whether `string` contains NUL, newlines, or other ASCII/Unicode control characters.
    static func containsControlOrNewline(_ string: String) -> Bool {
        string.unicodeScalars.contains { scalar in
            scalar.value < 0x20
                || (scalar.value >= 0x7F && scalar.value <= 0x9F)
                || scalar == "\u{2028}"
                || scalar == "\u{2029}"
        }
    }

    /// Whether `url` resolves inside `root` (or equals `root`), comparing
    /// canonicalized path components after resolving symlinks component-by-component.
    static func isContained(_ url: URL, in root: URL) -> Bool {
        guard url.isFileURL, root.isFileURL,
              let rootComponents = canonicalPathComponents(of: root),
              let targetComponents = canonicalPathComponents(of: url)
        else {
            return false
        }
        return targetComponents.count >= rootComponents.count
            && targetComponents.starts(with: rootComponents)
    }

    /// Resolves a relative `path` against `root`, rejecting empty strings,
    /// control characters, absolute/home/Windows paths, leading `-` or `@`,
    /// backslashes, and any traversal or symlink that resolves outside `root`.
    static func safeRelativeURL(for path: String, in root: URL) -> URL? {
        guard root.isFileURL,
              isValidRelativePathSyntax(path),
              let rootComponents = canonicalPathComponents(of: root)
        else {
            return nil
        }

        let segments = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !segments.isEmpty else { return nil }

        var symlinksFollowed = 0
        guard let resolvedComponents = resolve(
            segments,
            from: rootComponents,
            confiningTo: rootComponents,
            symlinksFollowed: &symlinksFollowed
        ) else {
            return nil
        }

        let relativeSuffix = resolvedComponents.dropFirst(rootComponents.count)
        var result = root.standardizedFileURL
        for component in relativeSuffix {
            result.append(path: component)
        }
        return result.standardizedFileURL
    }

    /// Ensures `<root>/<name>` (and any intermediate subdirectories in `name`)
    /// exists as a real directory inside `root` and is not a symlink.
    @discardableResult
    static func ensureSafeSubdirectory(named name: String, in root: URL) throws -> URL {
        guard root.isFileURL,
              name != ".",
              isValidRelativePathSyntax(name)
        else {
            throw ProjectSecurityError.unsafePath(name)
        }

        let segments = name.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !segments.isEmpty, !segments.contains("."), !segments.contains("..") else {
            throw ProjectSecurityError.unsafePath(name)
        }

        var current = root.standardizedFileURL
        for segment in segments {
            current.append(path: segment, directoryHint: .notDirectory)
            try validateOrCreateDirectory(at: current, name: name, in: root)
        }
        guard let target = safeRelativeURL(for: name, in: root) else {
            throw ProjectSecurityError.unsafePath(name)
        }
        return target
    }

    /// Rejects `url` if it already exists as a symlink or resolves outside `root`.
    static func ensureSafeFileDestination(_ url: URL, in root: URL) throws {
        if isSymbolicLink(at: url) {
            throw ProjectSecurityError.symlinkNotAllowed(url)
        }
        guard isContained(url, in: root) else {
            throw ProjectSecurityError.unsafePath(url.lastPathComponent)
        }
    }

    /// Returns whether `url` itself (without following it) is a symbolic link.
    static func isSymbolicLink(at url: URL) -> Bool {
        let path = nonDirectoryPath(for: url)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let type = attrs[.type] as? FileAttributeType {
            return type == .typeSymbolicLink
        }
        let nonDirURL = URL(filePath: path, directoryHint: .notDirectory)
        return (try? nonDirURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
    }

    // MARK: - Private helpers

    private static func nonDirectoryPath(for url: URL) -> String {
        var path = url.path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    private static func isValidRelativePathSyntax(_ path: String) -> Bool {
        !path.isEmpty
            && !path.trimmingCharacters(in: .whitespaces).isEmpty
            && !containsControlOrNewline(path)
            && !path.hasPrefix("/")
            && !path.hasPrefix("~")
            && !path.hasPrefix("\\")
            && !path.hasPrefix("-")
            && !path.hasPrefix("@")
            && !path.contains("\\")
            && !isWindowsDrivePath(path)
    }

    private static func isWindowsDrivePath(_ path: String) -> Bool {
        let scalars = Array(path.unicodeScalars.prefix(2))
        guard scalars.count == 2 else { return false }
        let first = scalars[0]
        let isLetter = (first >= "A" && first <= "Z") || (first >= "a" && first <= "z")
        return isLetter && scalars[1] == ":"
    }

    private static func canonicalPathComponents(of url: URL) -> [String]? {
        guard url.isFileURL else { return nil }
        let rawSegments = url.path(percentEncoded: false)
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        var symlinksFollowed = 0
        return resolve(rawSegments, from: ["/"], confiningTo: nil, symlinksFollowed: &symlinksFollowed)
    }

    private static func resolve(
        _ segments: [String],
        from initialComponents: [String],
        confiningTo boundary: [String]?,
        symlinksFollowed: inout Int
    ) -> [String]? {
        var resolved = initialComponents
        for segment in segments where !segment.isEmpty && segment != "." {
            if segment == ".." {
                if resolved.count > 1 { resolved.removeLast() }
            } else {
                let candidatePath = "/" + (resolved.dropFirst() + [segment]).joined(separator: "/")
                guard let next = advance(
                    segment: segment,
                    candidatePath: candidatePath,
                    from: resolved,
                    symlinksFollowed: &symlinksFollowed
                ) else {
                    return nil
                }
                resolved = next
            }
            if let boundary, !resolved.starts(with: boundary) {
                return nil
            }
        }
        return resolved
    }

    private static func advance(
        segment: String,
        candidatePath: String,
        from resolved: [String],
        symlinksFollowed: inout Int
    ) -> [String]? {
        switch lookupSymlink(atPath: candidatePath) {
        case .notSymlink:
            return resolved + [segment]
        case .destination(let target):
            symlinksFollowed += 1
            guard symlinksFollowed <= maximumSymlinkDepth else { return nil }
            let targetSegments = target.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            let base = target.hasPrefix("/") ? ["/"] : resolved
            return resolve(targetSegments, from: base, confiningTo: nil, symlinksFollowed: &symlinksFollowed)
        case .unreadable:
            return nil
        }
    }

    private static func lookupSymlink(atPath path: String) -> SymlinkLookup {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let type = attrs[.type] as? FileAttributeType,
              type == .typeSymbolicLink
        else {
            return .notSymlink
        }
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else {
            return .unreadable
        }
        return .destination(target)
    }

    private static func validateOrCreateDirectory(at url: URL, name: String, in root: URL) throws {
        if isSymbolicLink(at: url) {
            throw ProjectSecurityError.symlinkNotAllowed(url)
        }
        let path = nonDirectoryPath(for: url)
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            let type = attrs[.type] as? FileAttributeType
            guard type == .typeDirectory, isContained(url, in: root) else {
                throw ProjectSecurityError.unsafePath(name)
            }
        } catch let error as ProjectSecurityError {
            throw error
        } catch {
            let nsError = error as NSError
            let notFound = (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError)
                || (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT))
            guard notFound else { throw error }
            guard isContained(url, in: root) else {
                throw ProjectSecurityError.unsafePath(name)
            }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
    }
}
