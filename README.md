# uMeil

uMeil is an embedded IDE for macOS, built for the **Texas Instruments Tiva TM4C129** microcontroller. Think Keil µVision, but native to the Mac. It supports the **EK-TM4C1294XL LaunchPad** and runs on Apple Silicon Macs with macOS 14 or later.

## How it works

You write C in uMeil's editor. When you build, uMeil runs the Arm GCC compiler itself, recompiling only the files that changed, and makes a firmware image for the TM4C129. Flashing sends that image to the LaunchPad over USB through OpenOCD. Debugging runs GDB against OpenOCD, so you can stop the program on the board and look at its variables, registers and memory.

uMeil doesn't bundle these tools. On first launch it uses the copies already on your Mac, or downloads the official ones.

## Install

Download the latest DMG from [the website](https://hadialk4.github.io/uMeil/) or [GitHub Releases](https://github.com/HadiAlk4/uMeil/releases), open it, and drag uMeil to Applications. Or use Homebrew:

```sh
brew tap hadialk4/umeil https://github.com/HadiAlk4/uMeil
brew install --cask umeil
```

Until uMeil is notarized, macOS warns you the first time you open it. Open it once, then choose **Open Anyway** in System Settings › Privacy & Security.

On first launch uMeil finds the Arm toolchain and OpenOCD if you already have them, or downloads them for you (about 1 GB on disk).

## What it has

- **Editor:** C syntax highlighting, tabs, multiple windows, Quick Open, Go to Line, and errors marked on the line of code.
- **Code intelligence:** completion with fill-in placeholders, parameter hints, go to definition, hover, Rename Symbol, and Format Selection. TivaWare macros that fit the argument are suggested first.
- **Build:** one button, showing how much flash and RAM the program uses.
- **Flash:** one button builds and flashes the board.
- **Debugger:** breakpoints, stepping, call stack, local variables, watch expressions, CPU registers, disassembly, a memory viewer, and peripheral registers with named bit fields. Variable values show next to the code while stopped.
- **Serial monitor:** a console for the LaunchPad's USB serial port. You choose the speed, data bits, parity and stop bits (such as `115200,8,N,1`). It can send a line at a time, or, with **Send Each Key**, each key as you type it, including Escape, like Tera Term.
- **Keil projects:** opens course `.uvprojx` projects directly and supplies the course libraries.
- **Terminal:** a built-in terminal.
- **Updates:** uMeil updates itself.

## What it uses

| Area | What we use |
|---|---|
| App | Swift and AppKit |
| Syntax highlighting | [tree-sitter](https://tree-sitter.github.io/) |
| Compiler | [Arm GNU Toolchain](https://developer.arm.com/downloads/-/arm-gnu-toolchain-downloads) (`arm-none-eabi-gcc`) |
| Build system | Built into the app, using GCC's `-MMD` dependency files. No Make or CMake |
| Chip support | TI TivaWare headers, `driverlib`, startup code and linker script |
| Flashing | OpenOCD |
| Debugging | `arm-none-eabi-gdb` over GDB/MI, with OpenOCD as the GDB server |
| Peripheral registers | A CMSIS-SVD file generated from TivaWare's register header |
| Code intelligence | `clangd` |
| Serial monitor | POSIX `termios` and IOKit |
| Terminal | [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) |
| Updates | [Sparkle](https://sparkle-project.org/) |

## Building from source

You need an Apple Silicon Mac with Xcode 16 or later. Open `uMeil.xcodeproj` in Xcode and press Run, or build from the terminal:

```sh
xcodebuild build -project uMeil.xcodeproj -scheme uMeil -destination 'platform=macOS,arch=arm64'
```

Code style is checked with [SwiftLint](https://github.com/realm/SwiftLint) (`brew install swiftlint`, then `swiftlint lint --strict`).

To make a release, see [`docs/releasing.md`](docs/releasing.md).

## License

See [LICENSE](LICENSE).
