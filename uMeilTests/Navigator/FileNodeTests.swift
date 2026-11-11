import Foundation
import Testing
@testable import uMeil

struct FileNodeTests {
    /// Creates empty files (and their folders) under `temp`.
    private func makeFiles(_ paths: [String], in temp: TemporaryDirectory) throws {
        for path in paths {
            let url = temp.url.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: url)
        }
    }

    @Test func listsFoldersFirstThenFilesInFinderOrder() throws {
        let temp = try TemporaryDirectory()
        try makeFiles(["main.c", "file10.c", "file2.c", "Makefile", "src/a.c", "inc/a.h"], in: temp)

        let root = FileNode(url: temp.url, isDirectory: true)

        #expect(root.children.map(\.name) == ["inc", "src", "file2.c", "file10.c", "main.c", "Makefile"])
        #expect(root.children.map(\.isDirectory) == [true, true, false, false, false, false])
    }

    @Test func leavesOutHiddenItems() throws {
        let temp = try TemporaryDirectory()
        try makeFiles([".git/config", ".DS_Store", "main.c"], in: temp)

        #expect(FileNode(url: temp.url, isDirectory: true).children.map(\.name) == ["main.c"])
    }

    @Test func filesHaveNoChildren() throws {
        let temp = try TemporaryDirectory()
        try makeFiles(["main.c"], in: temp)

        let file = try #require(FileNode(url: temp.url, isDirectory: true).children.first)

        #expect(!file.isDirectory)
        #expect(file.children.isEmpty)
    }

    @Test func keepsTheSameChildObjectsUntilReloaded() throws {
        let temp = try TemporaryDirectory()
        try makeFiles(["a.c"], in: temp)
        let root = FileNode(url: temp.url, isDirectory: true)

        // The outline view relies on getting the same objects back each time.
        let first = try #require(root.children.first)
        #expect(root.children.first === first)

        try makeFiles(["b.c"], in: temp)
        #expect(root.children.map(\.name) == ["a.c"]) // still cached

        root.reload()
        #expect(root.children.map(\.name) == ["a.c", "b.c"])
    }

    @Test func findsANodeByURLAtAnyDepth() throws {
        let temp = try TemporaryDirectory()
        try makeFiles(["main.c", "src/drivers/uart.c"], in: temp)
        let root = FileNode(url: temp.url, isDirectory: true)

        let uart = root.node(for: temp.url.appending(path: "src/drivers/uart.c"))
        #expect(uart?.name == "uart.c")
        #expect(root.node(for: temp.url) === root)
        #expect(root.node(for: temp.url.appending(path: "src/missing.c")) == nil)
        #expect(root.node(for: URL(filePath: "/somewhere/else.c")) == nil)
    }

    @Test func aFolderThatCannotBeReadIsEmpty() {
        let missing = FileNode(url: URL(filePath: "/no/such/folder"), isDirectory: true)

        #expect(missing.children.isEmpty)
    }
}
