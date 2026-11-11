import Foundation

/// The trimmed copy of TI's TivaWare that ships inside the app: the register
/// headers for the TM4C129, the `driverlib` headers, and a prebuilt
/// `driverlib`. Projects with `useDriverLib` turned on build against it.
enum TivaWare {
    static let version = "2.2.0.295"

    /// The folder in the app bundle that holds TivaWare.
    static var bundledDirectory: URL {
        Bundle.main.resourceURL?.appending(path: "TivaWare.bundle", directoryHint: .isDirectory)
            ?? URL(filePath: "TivaWare.bundle", directoryHint: .isDirectory)
    }

    /// The folder to pass to the compiler with `-I`. Sources include the
    /// headers as `"inc/hw_memmap.h"` and `"driverlib/gpio.h"`.
    static func includeDirectory(in directory: URL = bundledDirectory) -> URL {
        directory
    }

    /// The prebuilt library to link, built for the Cortex-M4 with hard float.
    static func library(in directory: URL = bundledDirectory) -> URL {
        directory.appending(path: "driverlib/libdriver.a")
    }
}
