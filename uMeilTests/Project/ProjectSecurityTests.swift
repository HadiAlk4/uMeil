import Foundation
import Testing
@testable import uMeil

struct ProjectSecurityTests {
    @Test func containmentResolvesSymlinksAndBlocksPrefixTraps() throws {
        let folder = try TemporaryFolder()
        let root = folder.url.appending(path: "Blinky", directoryHint: .isDirectory)
        let sibling = folder.url.appending(path: "Blinky2", directoryHint: .isDirectory)
        let outside = folder.url.appending(path: "Outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "escape"),
            withDestinationURL: outside
        )
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "dangling"),
            withDestinationURL: folder.url.appending(path: "Outside/missing.c")
        )

        #expect(ProjectSecurity.isContained(root, in: root))
        #expect(ProjectSecurity.isContained(root.appending(path: "src/main.c"), in: root))
        #expect(ProjectSecurity.isContained(root.resolvingSymlinksInPath().appending(path: "main.c"), in: root))

        #expect(!ProjectSecurity.isContained(sibling.appending(path: "main.c"), in: root))
        #expect(!ProjectSecurity.isContained(root.appending(path: "../Outside/secret.c"), in: root))
        #expect(!ProjectSecurity.isContained(root.appending(path: "escape/secret.c"), in: root))
        #expect(!ProjectSecurity.isContained(root.appending(path: "escape/nonexistent.c"), in: root))
        #expect(!ProjectSecurity.isContained(root.appending(path: "dangling"), in: root))
        #expect(!ProjectSecurity.isContained(root.appending(path: "escape/../Outside/secret.c"), in: root))
    }

    @Test func containmentRejectsSymlinkLoops() throws {
        let folder = try TemporaryFolder()
        let root = folder.url
        let loopA = root.appending(path: "loopA")
        let loopB = root.appending(path: "loopB")
        try FileManager.default.createSymbolicLink(at: loopA, withDestinationURL: loopB)
        try FileManager.default.createSymbolicLink(at: loopB, withDestinationURL: loopA)

        #expect(!ProjectSecurity.isContained(loopA, in: root))
        #expect(ProjectSecurity.safeRelativeURL(for: "loopA/main.c", in: root) == nil)
    }

    @Test func safeRelativeURLAllowsValidPathsAndBlocksUnsafeForms() throws {
        let folder = try TemporaryFolder()
        let root = folder.url
        let outside = try TemporaryFolder()
        try FileManager.default.createDirectory(at: root.appending(path: "src"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "link_out"),
            withDestinationURL: outside.url
        )

        #expect(ProjectSecurity.safeRelativeURL(for: ".", in: root) == root.standardizedFileURL)
        #expect(ProjectSecurity.safeRelativeURL(for: "src/main.c", in: root)?.lastPathComponent == "main.c")
        #expect(ProjectSecurity.safeRelativeURL(for: "./src/main.c", in: root)?.lastPathComponent == "main.c")

        let unsafePaths = [
            "", "   ", "/etc/passwd", "~/secret.c", "C:/Windows/win.ini", "d:\\temp\\x.c",
            "-o", "-Wall", "@response.rsp", "..", "../secret.c", "src/../../secret.c",
            "src\\main.c", "src\0main.c", "src\nmain.c", "src\rmain.c", "src\tmain.c",
            "src\u{7F}main.c", "link_out/secret.c", "link_out/nonexistent.c",
            "link_out/../\(root.lastPathComponent)/main.c"
        ]
        for path in unsafePaths {
            #expect(ProjectSecurity.safeRelativeURL(for: path, in: root) == nil, "Expected \(path) to be rejected")
        }
    }

    @Test func ensureSafeSubdirectoryCreatesDirectoriesAndRefusesSymlinks() throws {
        let folder = try TemporaryFolder()
        let root = folder.url
        let outside = try TemporaryFolder()

        let created = try ProjectSecurity.ensureSafeSubdirectory(named: "build/obj", in: root)
        #expect(FileManager.default.fileExists(atPath: created.path))
        // Idempotent on real directory.
        _ = try ProjectSecurity.ensureSafeSubdirectory(named: "build/obj", in: root)

        let symlinkedDir = root.appending(path: "uMeil")
        try FileManager.default.createSymbolicLink(at: symlinkedDir, withDestinationURL: outside.url)
        #expect(throws: ProjectSecurityError.symlinkNotAllowed(symlinkedDir)) {
            try ProjectSecurity.ensureSafeSubdirectory(named: "uMeil", in: root)
        }

        let insideTarget = root.appending(path: "realDir")
        try FileManager.default.createDirectory(at: insideTarget, withIntermediateDirectories: true)
        let internalSymlink = root.appending(path: "symInside")
        try FileManager.default.createSymbolicLink(at: internalSymlink, withDestinationURL: insideTarget)
        #expect(throws: ProjectSecurityError.symlinkNotAllowed(internalSymlink)) {
            try ProjectSecurity.ensureSafeSubdirectory(named: "symInside", in: root)
        }

        try Data("not a dir".utf8).write(to: root.appending(path: "regularFile"))
        #expect(throws: ProjectSecurityError.unsafePath("regularFile")) {
            try ProjectSecurity.ensureSafeSubdirectory(named: "regularFile", in: root)
        }
        #expect(throws: ProjectSecurityError.unsafePath("../escape")) {
            try ProjectSecurity.ensureSafeSubdirectory(named: "../escape", in: root)
        }
    }
}
