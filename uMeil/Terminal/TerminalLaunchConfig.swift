import Darwin
import Foundation

/// Resolves the shell executable, environment, and working directory for an
/// integrated terminal session.
struct TerminalLaunchConfig: Equatable, Sendable {
    let executable: String
    let arguments: [String]
    let execName: String
    let environment: [String]
    let workingDirectory: String

    static func make(
        folder: URL?,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        isExecutable: (String) -> Bool = Self.isRegularExecutableFile(atPath:),
        isDirectory: (String) -> Bool = Self.directoryExists(atPath:),
        passwdShell: () -> String? = Self.currentUserShell
    ) -> TerminalLaunchConfig {
        let executable = resolveShell(
            processEnvironment: processEnvironment,
            isExecutable: isExecutable,
            isDirectory: isDirectory,
            passwdShell: passwdShell
        )
        let shellName = URL(fileURLWithPath: executable).lastPathComponent
        // Prefixing argv[0] with '-' starts a POSIX login shell so user PATH
        // and profile scripts load when uMeil is launched from Finder.
        let execName = "-\(shellName)"
        let workingDirectory = resolveWorkingDirectory(
            folder: folder,
            homeDirectory: homeDirectory,
            isDirectory: isDirectory
        )
        let environment = buildEnvironment(from: processEnvironment)
        return TerminalLaunchConfig(
            executable: executable,
            arguments: [],
            execName: execName,
            environment: environment,
            workingDirectory: workingDirectory
        )
    }

    private static func resolveShell(
        processEnvironment: [String: String],
        isExecutable: (String) -> Bool,
        isDirectory: (String) -> Bool,
        passwdShell: () -> String?
    ) -> String {
        for candidate in [processEnvironment["SHELL"], passwdShell()] {
            if let path = candidate,
               !path.isEmpty,
               path.hasPrefix("/"),
               !path.unicodeScalars.contains("\0"),
               !isDirectory(path),
               isExecutable(path) {
                return path
            }
        }
        return "/bin/zsh"
    }

    private static func resolveWorkingDirectory(
        folder: URL?,
        homeDirectory: URL,
        isDirectory: (String) -> Bool
    ) -> String {
        if let folder {
            let path = folder.path(percentEncoded: false)
            if isDirectory(path) {
                return path
            }
        }
        return homeDirectory.path(percentEncoded: false)
    }

    private static func buildEnvironment(from processEnvironment: [String: String]) -> [String] {
        var env = processEnvironment
        for key in ["PWD", "OLDPWD", "SHLVL", "TERM_PROGRAM_VERSION"] {
            env.removeValue(forKey: key)
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "uMeil"
        if env["LANG"]?.isEmpty ?? true {
            env["LANG"] = "en_US.UTF-8"
        }
        return env.keys.sorted().map { "\($0)=\(env[$0] ?? "")" }
    }

    private static func isRegularExecutableFile(atPath path: String) -> Bool {
        var statInfo = stat()
        guard stat(path, &statInfo) == 0,
              (statInfo.st_mode & S_IFMT) == S_IFREG
        else { return false }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    private static func directoryExists(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func currentUserShell() -> String? {
        guard let passwd = getpwuid(getuid()), let shell = passwd.pointee.pw_shell else {
            return nil
        }
        return String(cString: shell)
    }
}
