# uMeil

uMeil is an embedded IDE for macOS, built for the **Texas Instruments Tiva TM4C129** microcontroller. Think Keil µVision, but native to the Mac.

It supports the **EK-TM4C1294XL LaunchPad** and runs on **Apple Silicon Macs only** (macOS 14 or later).

## Install

Download the latest DMG from [the website](https://hadialk4.github.io/uMeil/) or [GitHub Releases](https://github.com/HadiAlk4/uMeil/releases), open it, and drag uMeil to Applications. Or use Homebrew:

```sh
brew tap hadialk4/umeil https://github.com/HadiAlk4/uMeil
brew install --cask umeil
```

Until uMeil is notarized, macOS warns you the first time you open it. Open it once, then choose **Open Anyway** in System Settings › Privacy & Security.

On first launch uMeil finds the Arm toolchain and OpenOCD if you already have them, or downloads them for you (about 1 GB on disk). After that, uMeil updates itself.

## Features

- **Editor:** C syntax highlighting, tabs, multiple windows, Quick Open, Go to Line, and error markers linked to the line of code.
- **Code intelligence** (through `clangd`): completion with fill-in placeholders, parameter hints, go to definition, hover, Rename Symbol, and Format Selection. Completion ranks TivaWare macros that fit the argument first. Turn it off in Edit › Code Intelligence.
- **Build:** one button builds the project with Arm GCC and shows the flash and RAM used. Only changed files are recompiled.
- **Flash:** one button builds and flashes the board, with clear errors when the board is not connected or flashing fails.
- **Debug on the board:** breakpoints, stepping, call stack, local variables, watch expressions, CPU registers, disassembly, a memory viewer, and peripheral registers with named bit fields. While stopped, variable values show next to the code.
- **Serial monitor:** a console for the LaunchPad's USB serial port, with any speed, data bits, parity and stop bits the course uses (such as `115200,8,N,1` or `38400,7,N,2`). Send a line at a time, or turn on **Send Each Key** to send keys as you type, including Escape, as in Tera Term.
- **Keil projects:** open a course `.uvprojx` directly. uMeil builds it with GCC and supplies the course libraries (`ES_Library.lib` and the lab libraries) as source.
- **Terminal:** a built-in terminal in the bottom panel.

## Building from source

You need an Apple Silicon Mac with Xcode 16 or later.

Open `uMeil.xcodeproj` in Xcode and press Run, or build from the terminal:

```sh
xcodebuild build -project uMeil.xcodeproj -scheme uMeil -destination 'platform=macOS,arch=arm64'
```

Code style is checked with [SwiftLint](https://github.com/realm/SwiftLint) (`brew install swiftlint`, then `swiftlint lint --strict`).

To make a release, see [`docs/releasing.md`](docs/releasing.md).

## Tech stack

| Area | What we use |
|---|---|
| App | Swift and AppKit. Xcode, Apple Silicon only |
| Editor | `NSTextView`, with [tree-sitter](https://tree-sitter.github.io/) for C highlighting |
| Compiler | [Arm GNU Toolchain](https://developer.arm.com/downloads/-/arm-gnu-toolchain-downloads) (`arm-none-eabi-gcc`, `-mcpu=cortex-m4 -mfpu=fpv4-sp-d16 -mfloat-abi=hard`), downloaded on first launch or the user's own install |
| Build system | Built into the app: it runs `arm-none-eabi-gcc` directly and uses `-MMD` dependency files for incremental builds. No Make, CMake, or Ninja |
| Chip support | A trimmed TI TivaWare: TM4C129 headers, a prebuilt `driverlib`, startup code, and linker script |
| Flashing | OpenOCD (`ti_icdi` adapter) |
| Debugging | `arm-none-eabi-gdb` over the GDB Machine Interface (MI), connected to OpenOCD's GDB server |
| Peripheral registers | CMSIS-SVD file for the TM4C1294, generated from TivaWare's BSD-licensed register header (`Vendor/TivaWare/generate-svd.py`) |
| Code intelligence | `clangd` over the Language Server Protocol, using the copy from Xcode or the Command Line Tools when present, downloaded on demand otherwise |
| Serial monitor | POSIX `termios` and IOKit |
| Terminal | [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) |
| Updates and distribution | [Sparkle](https://sparkle-project.org/), a DMG on GitHub Releases, a Homebrew cask, and a website on GitHub Pages |

## License

See [LICENSE](LICENSE).
