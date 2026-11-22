import AppKit
import Foundation
import Testing
@testable import uMeil

struct ClangdSecurityTests {
    @Test func launchArgumentsPinCanonicalQueryDriverAndDisableConfig() throws {
        let temp = try TemporaryDirectory()
        let bin = try temp.directory("bin")
        let realCompiler = bin.appending(path: "arm-none-eabi-gcc-real", directoryHint: .notDirectory)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: realCompiler)
        let symlinkCompiler = bin.appending(path: "arm-none-eabi-gcc", directoryHint: .notDirectory)
        try FileManager.default.createSymbolicLink(at: symlinkCompiler, withDestinationURL: realCompiler)
        let buildDir = try temp.directory("build")

        let args = ClangdSession.launchArguments(
            compileCommandsDirectory: buildDir,
            queryDriver: symlinkCompiler
        )
        let canonical = realCompiler.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)

        #expect(args.contains("--compile-commands-dir=\(buildDir.path(percentEncoded: false))"))
        #expect(args.contains("--query-driver=\(canonical)"))
        #expect(args.contains("--enable-config=false"))
        #expect(!args.contains("--query-driver=**/\(Tool.compiler.executableName)"))
        #expect(args.filter { $0.hasPrefix("--query-driver=") }.count == 1)
    }

    @Test func launchArgumentsOmitQueryDriverWhenNilAndNeverUseWildcards() {
        let args = ClangdSession.launchArguments(compileCommandsDirectory: nil, queryDriver: nil)

        #expect(args.contains("--enable-config=false"))
        #expect(!args.contains { $0.hasPrefix("--query-driver") })
        #expect(!args.contains { $0.hasPrefix("--compile-commands-dir") })
        #expect(!args.contains("--query-driver=**/\(Tool.compiler.executableName)"))
    }

    @Test func launchArgumentsSkipQueryDriverWithUnsafeCharacters() throws {
        let unsafeNames = [
            "gcc,extra",
            "gcc*glob",
            "gcc?glob",
            "gcc\nnewline",
            "gcc\rcarriage",
            "gcc\r\ncrlf",
            "gcc\0nul"
        ]

        for name in unsafeNames {
            let unsafeURL = URL(filePath: "/tmp/\(name)/arm-none-eabi-gcc", directoryHint: .notDirectory)
            let args = ClangdSession.launchArguments(compileCommandsDirectory: nil, queryDriver: unsafeURL)
            #expect(!args.contains { $0.hasPrefix("--query-driver") })
            #expect(args.contains("--enable-config=false"))
        }

        let percentNulURL = try #require(URL(string: "file:///tmp/gcc%00nul/arm-none-eabi-gcc"))
        let percentNulArgs = ClangdSession.launchArguments(compileCommandsDirectory: nil, queryDriver: percentNulURL)
        #expect(!percentNulArgs.contains { $0.hasPrefix("--query-driver") })

        let temp = try TemporaryDirectory()
        let unsafeDir = try temp.directory("bad,dir")
        let unsafeTarget = unsafeDir.appending(path: "arm-none-eabi-gcc", directoryHint: .notDirectory)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: unsafeTarget)
        let safeSymlink = temp.url.appending(path: "arm-none-eabi-gcc", directoryHint: .notDirectory)
        try FileManager.default.createSymbolicLink(at: safeSymlink, withDestinationURL: unsafeTarget)
        let symlinkArgs = ClangdSession.launchArguments(compileCommandsDirectory: nil, queryDriver: safeSymlink)
        #expect(!symlinkArgs.contains { $0.hasPrefix("--query-driver") })
    }

    @Test func launchArgumentsSkipNonFileQueryDriverURL() throws {
        let remote = try #require(URL(string: "https://example.com/arm-none-eabi-gcc"))
        let args = ClangdSession.launchArguments(compileCommandsDirectory: nil, queryDriver: remote)

        #expect(!args.contains { $0.hasPrefix("--query-driver") })
        #expect(args.contains("--enable-config=false"))
    }

    @MainActor
    @Test func controllerIgnoresUntrustedCompileCommandsWithoutUmeilProject() async throws {
        let temp = try TemporaryDirectory()
        let bin = try temp.directory("bin")
        let clangd = try FakeTool.install(.clangd, in: bin, script: "exit 0")
        let compiler = try FakeTool.install(.compiler, in: bin, script: "exit 0")

        let workspace = try temp.directory("untrusted")
        let buildDir = try temp.directory("untrusted/build")
        try Data("[{\"directory\":\"/tmp\",\"command\":\"/evil\",\"file\":\"main.c\"}]\n".utf8)
            .write(to: buildDir.appending(path: "compile_commands.json"))
        let srcDir = try temp.directory("untrusted/src")
        try Data("int main(void) { return 0; }\n".utf8).write(to: srcDir.appending(path: "main.c"))

        let editor = EditorViewController()
        editor.loadViewIfNeeded()
        let controller = CodeIntelligenceController(
            makeToolLocator: { ToolLocator(searchDirectories: [bin]) },
            editor: editor,
            onNavigateToLocation: { _ in }
        )

        controller.folderOpened(workspace)
        let session = try #require(controller.session)
        #expect(await session.clangdExecutable == clangd)
        #expect(await session.compileCommandsDirectory == nil)
        #expect(await session.queryDriver == compiler.resolvingSymlinksInPath().standardizedFileURL)
        controller.stop()
    }

    @MainActor
    @Test func controllerIgnoresPreExistingCompileCommandsWhenUmeilProjectFailsToLoad() async throws {
        let temp = try TemporaryDirectory()
        let bin = try temp.directory("bin")
        _ = try FakeTool.install(.clangd, in: bin, script: "exit 0")

        let workspace = try temp.directory("corrupt")
        try Data("{not valid json".utf8).write(to: workspace.appending(path: "Broken.umeil"))
        let buildDir = try temp.directory("corrupt/build")
        try Data("[{\"directory\":\"/tmp\",\"command\":\"/evil\",\"file\":\"main.c\"}]\n".utf8)
            .write(to: buildDir.appending(path: "compile_commands.json"))

        let editor = EditorViewController()
        editor.loadViewIfNeeded()
        let controller = CodeIntelligenceController(
            makeToolLocator: { ToolLocator(searchDirectories: [bin]) },
            editor: editor,
            onNavigateToLocation: { _ in }
        )

        controller.folderOpened(workspace)
        let session = try #require(controller.session)
        #expect(await session.compileCommandsDirectory == nil)
        #expect(await session.queryDriver == nil)
        controller.stop()
    }

    @MainActor
    @Test func controllerUsesPreparedCompileCommandsAndOmitsQueryDriverWhenCompilerAbsent() async throws {
        let temp = try TemporaryDirectory()
        let bin = try temp.directory("bin")
        _ = try FakeTool.install(.clangd, in: bin, script: "exit 0")

        let workspaceRoot = try temp.directory("projects")
        let template = try #require(try ProjectTemplate.all().first { $0.identifier == "Blinky" })
        let projectFile = try template.createProject(named: "Blinky", in: workspaceRoot)
        let folder = projectFile.deletingLastPathComponent()

        let editor = EditorViewController()
        editor.loadViewIfNeeded()
        let controller = CodeIntelligenceController(
            makeToolLocator: { ToolLocator(searchDirectories: [bin]) },
            editor: editor,
            onNavigateToLocation: { _ in }
        )

        controller.folderOpened(folder)
        let session = try #require(controller.session)
        let expectedBuildDir = ClangdSession.normalize(folder.appending(path: "build", directoryHint: .isDirectory))
        #expect(await session.compileCommandsDirectory == expectedBuildDir)
        #expect(await session.queryDriver == nil)
        controller.stop()
    }

    private func installMockClangd(in temp: TemporaryDirectory, bin: URL, argsLog: URL) throws -> URL {
        let serverScript = temp.url.appending(path: "fake_clangd.py")
        let pythonCode = """
        import json, sys
        with open(sys.argv[1], "w", encoding="utf-8") as handle:
            for arg in sys.argv[2:]:
                handle.write(arg + "\\n")
        while True:
            headers = {}
            while True:
                line = sys.stdin.buffer.readline()
                if not line:
                    sys.exit(0)
                if line in (b"\\r\\n", b"\\n"):
                    break
                if b":" in line:
                    key, val = line.decode("ascii").split(":", 1)
                    headers[key.strip().lower()] = val.strip()
            body = sys.stdin.buffer.read(int(headers.get("content-length", "0")))
            msg = json.loads(body.decode("utf-8"))
            method, req_id = msg.get("method"), msg.get("id")
            if method == "initialize" and req_id is not None:
                payload = {"jsonrpc": "2.0", "id": req_id, "result": {"capabilities": {}}}
            elif method == "shutdown" and req_id is not None:
                payload = {"jsonrpc": "2.0", "id": req_id, "result": None}
            elif method == "exit":
                sys.exit(0)
            else:
                continue
            resp = json.dumps(payload).encode("utf-8")
            sys.stdout.buffer.write(f"Content-Length: {len(resp)}\\r\\n\\r\\n".encode("ascii") + resp)
            sys.stdout.buffer.flush()
        """
        try Data(pythonCode.utf8).write(to: serverScript)
        let shellWrapper = "exec /usr/bin/python3 '\(serverScript.path(percentEncoded: false))' "
            + "'\(argsLog.path(percentEncoded: false))' \"$@\""
        return try FakeTool.install(.clangd, in: bin, script: shellWrapper)
    }

    @Test(.timeLimit(TestTiming.minutes(1)))
    func spawnedClangdReceivesPinnedQueryDriverAndEnableConfigFalse() async throws {
        let temp = try TemporaryDirectory()
        let bin = try temp.directory("bin")
        let workspace = try temp.directory("workspace")
        let buildDir = try temp.directory("workspace/build")
        let argsLog = temp.url.appending(path: "clangd-args.txt")
        let compiler = try FakeTool.install(.compiler, in: bin, script: "exit 0")
        let fakeClangd = try installMockClangd(in: temp, bin: bin, argsLog: argsLog)

        let session = ClangdSession(
            clangdExecutable: fakeClangd,
            workspaceDirectory: workspace,
            compileCommandsDirectory: buildDir,
            queryDriver: compiler,
            changeDebounce: .zero
        ) { _ in }
        try await session.start()
        await session.stop()

        let recordedArgs = try String(contentsOf: argsLog, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        let canonicalBuild = ClangdSession.normalize(buildDir).path(percentEncoded: false)
        let canonicalCompiler = compiler.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
        #expect(recordedArgs.contains("--compile-commands-dir=\(canonicalBuild)"))
        #expect(recordedArgs.contains("--query-driver=\(canonicalCompiler)"))
        #expect(recordedArgs.contains("--enable-config=false"))
        #expect(!recordedArgs.contains("--query-driver=**/\(Tool.compiler.executableName)"))
    }

    @Test(.timeLimit(TestTiming.minutes(1)))
    func spawnedClangdOmitsQueryDriverAndCompileCommandsWhenNil() async throws {
        let temp = try TemporaryDirectory()
        let bin = try temp.directory("bin")
        let workspace = try temp.directory("workspace")
        let argsLog = temp.url.appending(path: "clangd-args.txt")
        let fakeClangd = try installMockClangd(in: temp, bin: bin, argsLog: argsLog)

        let session = ClangdSession(
            clangdExecutable: fakeClangd,
            workspaceDirectory: workspace,
            compileCommandsDirectory: nil,
            queryDriver: nil,
            changeDebounce: .zero
        ) { _ in }
        try await session.start()
        await session.stop()

        let recordedArgs = try String(contentsOf: argsLog, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        #expect(recordedArgs.contains("--enable-config=false"))
        #expect(!recordedArgs.contains { $0.hasPrefix("--query-driver") })
        #expect(!recordedArgs.contains { $0.hasPrefix("--compile-commands-dir") })
    }
}
