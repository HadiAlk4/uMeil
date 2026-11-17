# uMeil

uMeil is an embedded IDE for macOS, built specifically for the **Texas Instruments Tiva TM4C129** microcontroller. Think Keil µVision, but native to the Mac.

## Goals

- Write and build code for the TM4C129 on macOS
- Flash programs to the board directly from your Mac
- Debug on the board (breakpoints, stepping, inspecting registers and memory)
- Be easy for anyone to download and install on their Mac

## Status

Early development. Only the Tiva TM4C129 is supported for now. The reference board is the **EK-TM4C1294XL LaunchPad**.

uMeil runs on **Apple Silicon Macs only**. Intel Macs are not supported.

## Building

You need an Apple Silicon Mac with Xcode 16 or later. The app targets macOS 14 and up.

Open `uMeil.xcodeproj` in Xcode and press Run, or build and test from the terminal:

```sh
xcodebuild test -project uMeil.xcodeproj -scheme uMeil -destination 'platform=macOS,arch=arm64'
```

Code style is checked with [SwiftLint](https://github.com/realm/SwiftLint) (`brew install swiftlint`, then `swiftlint lint --strict`). CI runs the tests and the linter on every push and pull request.

## Tech stack at a glance

| Area | What we use |
|---|---|
| App | Swift + AppKit (`NSTextView`, `NSOutlineView`, `NSTableView`), with SwiftUI only for settings and simple panels. Xcode, Apple Silicon only |
| Compiler | [Arm GNU Toolchain](https://developer.arm.com/downloads/-/arm-gnu-toolchain-downloads) (`arm-none-eabi-gcc`, `-mcpu=cortex-m4 -mfpu=fpv4-sp-d16 -mfloat-abi=hard`). Arm's official archive, downloaded on first launch, or the user's own install |
| Build system | Built into the app: it runs `arm-none-eabi-gcc` directly and uses `-MMD` dependency files for incremental builds. No Make, CMake, or Ninja |
| Chip support | A trimmed TI TivaWare: TM4C129 headers, a prebuilt `driverlib`, startup code, and linker script only |
| Flashing | OpenOCD (`ti_icdi` adapter) |
| Debugging | `arm-none-eabi-gdb` over the GDB Machine Interface (MI), connected to OpenOCD's GDB server |
| Peripheral registers | CMSIS-SVD file for the TM4C1294, generated from TivaWare's BSD-licensed register header (`Vendor/TivaWare/generate-svd.py`) |
| Code intelligence | `clangd` over the Language Server Protocol (LSP), using the copy from Xcode or the Command Line Tools when present, downloaded on demand otherwise |
| Distribution | Signed and notarized `.app` in a DMG on GitHub Releases, a download website on GitHub Pages, plus a Homebrew cask |
| Tests | Swift Testing / XCTest, XCUITest, hardware-in-the-loop on a real LaunchPad, GitHub Actions (macOS runners) |

---

## Milestones

Each milestone ends with something that works on its own and can be demoed.

### M0: Project setup

Set up the Xcode project, folder layout, CI, and coding conventions.

- **What we use:** Xcode, Swift Package Manager for dependencies, SwiftLint, GitHub Actions on `macos-latest`.
- **How we test it:** CI builds the app and runs an empty test target on every push and pull request. Done when a fresh clone builds with no manual steps.

### M1: Toolchain manager

Find, download, and check the compiler and tools (`arm-none-eabi-gcc`, `gdb`, OpenOCD). Tools are not bundled in the app: uMeil uses ones the user already installed (for example, through Homebrew), or downloads the official Apple Silicon archives on first launch: Arm's full GNU toolchain (about 142 MB to download, 1 GB on disk) and xPack OpenOCD. Each download is pinned to an exact version and SHA-256. Trimming the toolchain down to the Cortex-M4 hard-float libraries is a possible later optimisation.

- **What we use:** Swift `Process` to run tools, `URLSession` for downloads, SHA-256 checks with CryptoKit, Apple Silicon builds of each tool.
- **How we test it:**
  - Unit tests (Swift Testing) for path discovery and version parsing, using fake tool folders.
  - Integration test that runs `arm-none-eabi-gcc --version` and `openocd --version` from the app's tool path.
  - Manual test on a clean macOS user account with nothing installed.

### M2: Project model and templates

Define what a uMeil project is: source files, include paths, compiler flags, chip and board settings. Ship a "Blinky" template for the EK-TM4C1294XL.

- **What we use:** A `Codable` project file (JSON) and a trimmed TivaWare: TM4C129 headers, a prebuilt `driverlib`, the startup file, and the linker script. The rest of the SDK (examples and support for other boards) is not shipped.
- **How we test it:**
  - Unit tests for reading and writing the project file, including older versions of the format.
  - Snapshot tests: a new project from the template must match the expected files.

### M3: Build system

Turn a project into a firmware image (`.elf` and `.bin`). Show compiler errors and warnings in the app and link them to the line of code.

- **What we use:** A build engine inside the app that runs `arm-none-eabi-gcc` directly, with `-MMD` dependency files to decide what to recompile. No Make, CMake, or Ninja. Also `arm-none-eabi-objcopy`, `arm-none-eabi-size`, and a parser for GCC's diagnostic output. The same engine writes `compile_commands.json` for `clangd`.
- **How we test it:**
  - Unit tests for the diagnostic parser, using saved GCC output.
  - Integration tests that build the Blinky template and some intentionally broken projects in CI, then check the output files and reported errors.
  - Check that incremental builds only recompile the files that changed.

### M4: Code editor

An editor with syntax highlighting, line numbers, error markers, find and replace, and a file navigator.

- **What we use:** A plain AppKit `NSTextView` for the editor and `NSOutlineView` for the file navigator, with tree-sitter for C syntax highlighting. No web views and no third-party editor package.
- **How we test it:**
  - Unit tests for highlighting and error marker positions.
  - XCUITest for opening, editing, and saving files.
  - Performance test: typing must stay smooth in a 10,000-line file.

### M5: Flashing

One button to build and flash the board, with a progress bar and clear errors (board not connected, wrong chip, flash failed).

- **What we use:** OpenOCD with its `board/ek-tm4c1294xl.cfg` script (the ICDI probe, `interface/ti-icdi.cfg`, plus the Tiva target, `target/stellaris.cfg`), run with `Process`. IOKit to detect when a board is plugged in over USB.
- **How we test it:**
  - Unit tests for parsing OpenOCD output, using saved logs (including failures).
  - **Hardware-in-the-loop (HIL):** a LaunchPad connected to a Mac (a self-hosted CI runner). It flashes a test firmware that prints a known message over UART, and the test reads that message to confirm the flash worked.
  - Manual tests: unplug the board while flashing, flash a locked chip, use a bad USB cable.

### M6: Debugger

Start a debug session: breakpoints, step over, step into, step out, continue, pause, call stack, local variables, and a CPU register view.

- **What we use:** OpenOCD as the GDB server, `arm-none-eabi-gdb` controlled through GDB/MI. A Swift parser for MI output. AppKit `NSTableView` and `NSOutlineView` for the call stack, variables, and register views.
- **How we test it:**
  - Unit tests for the GDB/MI parser, using saved GDB output.
  - HIL tests on the LaunchPad: set a breakpoint in Blinky, run to it, check the line, a variable value, and the program counter.
  - Optional: run some debugger tests without hardware using QEMU's `lm3s6965evb` machine (a Cortex-M3 Stellaris chip, close to the TM4C129 but not the same).

### M7: Memory and peripheral views

A memory viewer (hex view) and a peripheral register view that shows named registers and bit fields, like Keil's peripheral windows.

- **What we use:** CMSIS-SVD file for the TM4C129, generated from TivaWare's `tm4c1294ncpdt.h` rather than copied from a vendor device pack, a Swift SVD parser, GDB/MI memory read and write commands.
- **How we test it:**
  - Unit tests for the SVD parser and for decoding bit fields.
  - HIL test: write a GPIO register from the app and check that the LED on the LaunchPad changes, then read the register back.

### M8: Serial monitor

A built-in UART console for the LaunchPad's virtual COM port.

- **What we use:** POSIX `termios` APIs directly (no serial port package), IOKit to list serial ports.
- **How we test it:**
  - Unit tests with a pseudo-terminal (`openpty`) in place of a real port.
  - HIL test: an echo firmware on the board must return what the app sends.

### M9: Code intelligence

Autocomplete, go to definition, and inline errors while typing.

Edit > Code Intelligence turns all three off, which stops `clangd`, and back on. It is on by default, and uMeil remembers the choice between launches.

- **What we use:** `clangd` over LSP, with a `compile_commands.json` file generated by the build system. uMeil uses the `clangd` from Xcode or the Command Line Tools when present, and downloads it on demand otherwise.
- **How we test it:**
  - Integration tests that start `clangd` on the Blinky project and check that completion and go-to-definition work for `driverlib` functions.

### M10: Packaging and distribution

Make uMeil easy to download and install.

- **What we use:** Developer ID signing, Apple notarization (`notarytool`), a DMG, Sparkle for automatic updates, and a Homebrew cask. The app is Apple Silicon only. Toolchains are not bundled; they are downloaded on first launch. Signing and notarization need an Apple Developer Program membership.
- **Website:** A one-page static site (plain HTML and CSS, no framework) on GitHub Pages, deployed from this repo with GitHub Actions. It says what uMeil is, shows a screenshot and the system requirements, and has a download button that links to the latest DMG on GitHub Releases. It also hosts Sparkle's `appcast.xml` update feed.
- **How to release:** see [`docs/releasing.md`](docs/releasing.md). `Scripts/make-release.sh` builds the DMG, and pushing a `v*` tag publishes it. Signing, notarization and Sparkle's update signature switch on as their secrets are added; until then releases are ad-hoc signed.
- **How we test it:**
  - CI builds, signs, and notarizes every release, then checks the result with `spctl --assess` and `stapler validate`.
  - Manual install test on a clean Mac (or a fresh macOS VM, for example with Tart or UTM) on Apple Silicon.
  - Test that updating from the previous version works.
  - Check that the website's download button points at the latest release and that `appcast.xml` is valid.

### M11: Beta and v1.0

Polish, write documentation, gather beta feedback, and fix bugs.

- **What we use:** TestFlight-style beta through GitHub Releases, GitHub Issues for bug reports, and documentation in `docs/`.
- **How we test it:**
  - Full end-to-end run on real hardware: new project → build → flash → debug → serial output.
  - Beta testers with their own LaunchPads.
  - A release checklist that must pass before each release.

---

## Testing strategy

| Level | Tool | Runs where |
|---|---|---|
| Unit tests | Swift Testing / XCTest | Every push, GitHub Actions |
| Integration tests (real toolchain) | Swift Testing + `Process` | Every push, GitHub Actions |
| UI tests | XCUITest | Every pull request |
| Hardware-in-the-loop | EK-TM4C1294XL on a self-hosted Mac runner | Nightly and before each release |
| Install and release tests | Clean macOS VM (Tart/UTM), `spctl`, `stapler` | Before each release |

## License

See [LICENSE](LICENSE).
