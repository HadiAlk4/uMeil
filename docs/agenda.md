# Agenda

Open work that is not yet scheduled in the README milestones, and when it is recommended to do each item. Last updated 17 November 2026.

Status today: M0 to M9 are merged. M10 (packaging and distribution) is on the `m10-packaging` branch; Developer ID signing and notarization wait on an Apple Developer Program membership (see `docs/releasing.md`). Still open from M5: item 7, and the CI runner for item 9.

## Summary

| # | Item | Belongs to | Do it |
|---|---|---|---|
| 1 | Decide how to handle the course library | Keil support | Done 17 November |
| 2 | Ask the course for the library source or a GCC build | Keil support | Optional |
| 3 | Check the licence of `TM4C129.h` | Keil support | Done 17 November |
| 4 | Real flash of Blinky on the board | M5 | Done 16 November |
| 5 | Replace reconstructed OpenOCD logs with real captures | M5 | Done 16 November, except two logs that could not be captured |
| 6 | Locked-chip error message | M5 | Done 17 November |
| 7 | Check USB plug and unplug detection | M5 | With the board, before closing M5 |
| 8 | Look at the board status dot in the running app | M5 | Done 17 November |
| 9 | Hardware-in-the-loop flash test | M5 | Test done 17 November; the CI runner is still to set up |
| 10 | Check the "no board" test passes in CI | M5 | Done 16 November |
| 11 | Flash an existing image (`.axf` / `.elf`) | M5 | Done 16 November |
| 23 | Fix the timing test that fails in CI | M5 | Done 16 November |
| 12 | Keil project import (`.uvprojx` to `.umeil`) | M2 | Done 17 November |
| 13 | GNU startup file and linker script for Keil projects | M2, M3 | Done 17 November |
| 14 | Ship or download `TM4C129.h` | M2 | Done 17 November |
| 15 | Link the course library | M3 | Done 17 November |
| 16 | Build output reports Code, RO-data, RW-data, ZI-data | M3 | Done 17 November |
| 17 | Decide `-O0` or `-Og` for debug builds | M2 | Done 17 November |
| 18 | XCUITest target and typing performance test | M4 | Before M6 |
| 19 | Tabbed source viewer | M4 | Before M6 |
| 20 | Gutter: clicks, breakpoints, program counter arrow | M4 | Start of M6 |
| 21 | Reword FR-7.2 (`States` and `Sec` counters) | Spec | Done 17 November |
| 22 | Command window showing build, flash and debug logs | M3, M5 | During M6 |
| 24 | Integrated terminal panel (`⌘J`) | IDE | After M6 |

## Now: decisions and checks, no code

**1. Decide how to handle the course library.**
The Keil projects link a prebuilt library (`ES_Library.lib`, `Lib4.lib`) built with Arm Compiler 6. The GNU linker cannot read it: the objects inside start with `.ORC` instead of the ELF header, and the rest of the layout is packed differently too. There are three routes:

1. Reimplement the library in uMeil (recommended). It is small: serial setup, `ES_printf`, `ES_getchar`, `ES_putchar`, `readDec`, `msDelay`, the 80 MHz clock setup, and a few port helpers. Behaviour can be matched against the code inside the Keil-built `.axf` files. The catch: each lab's library can add functions, so uMeil's copy has to keep up, and it means shipping our own version of the instructor's library.
2. Get the source or a GCC build from the course. Cleanest if they will give it.
3. Write a converter for the `.ORC` format. It would handle future labs automatically, but it is reverse-engineering an undocumented format and may not work.

**2. Ask the course for the library source or a GCC build.**
Worth asking now even if route 1 is chosen, because the answer may take a while and would make route 1 unnecessary.

**3. Check the licence of `TM4C129.h`.**
`main.c` and the library headers include it. It comes from Keil's TM4C device pack (`Keil.TM4C_DFP.1.1.0`), not from TivaWare. Find out whether uMeil may ship it, or must download it on demand like the toolchains.

## With the board: finish M5

**4. Real flash of Blinky.** Done on 16 November: Blinky was written to an EK-TM4C1294XL and verified.

**5. Replace reconstructed logs.** Done on 16 November for the success, verify-failed and "no board" logs in `uMeilTests/Flashing/FlashTestSupport.swift`. Two are still partly written from OpenOCD's message formats: wrong-chip (no TM4C123 board was to hand) and write-failed (could not be provoked on a healthy board).

**6. Locked-chip message.** Done on 17 November: captured the real OpenOCD output on the EK-TM4C1294XL with volatile page protection in `FMPPE0`, and added `FlashFailure.chipLocked` for write-protected flash pages and locked debug ports.

**7. USB detection.** A plugged-in board is detected (checked by `HardwareInTheLoopTests` on 17 November). The toolbar's "Board connected" status has still never seen a real plug or unplug event while the app is running.

**8. Status dot.** Done on 17 November: verified in the running app window with an EK-TM4C1294XL connected (`Board connected` with the green circle dot in the unified toolbar).

**9. Hardware-in-the-loop test.** The test is written and passes on an EK-TM4C1294XL: `HardwareInTheLoopTests` builds firmware that prints a one-off message over UART0, flashes it with the real OpenOCD, and reads the message back from the board's serial port. It only runs when `UMEIL_HIL=1` is set (`TEST_RUNNER_UMEIL_HIL=1` with `xcodebuild`), because it writes to the board. Still to do: register a Mac with a board as a self-hosted runner labelled `launchpad` and set the repository variable `HIL_RUNNER` to `true`; the CI job is in place and skipped until then.

**10. CI check.** Done: `RealOpenOCDWithoutABoardTests` passes in CI against Homebrew's OpenOCD.

**11. Flash an existing image.** Done on 16 November: Product > Flash Image… writes a Keil-built `.axf` or any `.elf` straight to the board, without a uMeil project. A file that is not a 32-bit Arm program is refused before anything is sent. Checked on the board with `L4Q1`'s `Template.axf`.

**23. Timing test that fails in CI.** Done on 16 November: `StreamingProcessRunnerTests/reportsLinesWhileTheProcessIsStillRunning()` now measures the gap between its two lines instead of timing from launch.

## After M5, before M6: Keil project support

Recommended here because the debugger requirements (`docs/debugger-functional-requirements.md`) are written around debugging this kind of course project, so M6 needs to be able to build them. These items extend M2 (project model) and M3 (build system).

**12. Keil project import.** Done on 17 November: File > Import Keil Project… reads a `.uvprojx` (source files, include paths, defines, chip, optimisation, C standard) and writes a `.umeil` project alongside it, leaving the Keil files untouched and listing anything that had to be skipped or is still missing. A `.uvprojx` can also be opened directly: File > Open… (⌘O, which also takes folders and `.umeil` files), Finder's Open With, the Dock icon, or `open -a uMeil`. The first open imports it; later opens reuse the `.umeil` and its settings, and write the generated files in `uMeil/` again so an older import picks up a newer library (a generated file the user has edited is left alone). Building a folder that only has a Keil project imports it first.

**13. GNU startup file and linker script.** Done on 17 November: importing a Keil project writes `uMeil/startup_gcc.c`, generated from the handler names in Keil's `startup_TM4C129.s` and calling `SystemInit` before `main()`, plus `uMeil/tm4c1294ncpdt.ld`.

**14. `TM4C129.h`.** Done on 17 November: `KeilImporter` writes a clean-room `uMeil/TM4C129.h` register header (Cortex-M4 core structs and TM4C1294 peripheral structs from the datasheet and BSD TivaWare offsets) and adds `uMeil` to the project's include paths.

**15. Course library.** Done on 17 November: when a Keil project links a course library, `KeilImporter` reads the library's `ar` symbol table to see which functions it provides, writes `uMeil/es_lib.c` implementing them, and includes it in the build. Covered: `ES_Library.lib` and `Lib4.lib` (`ES_Serial`, `ES_printf`, `readDec`, `msDelay`, `setSysClk80MHz`, Port N helpers), `Lab1A.lib` (Port F, J and N helpers, UART0 serial), `lib3.lib` (`Setup_UART`, `Read_UART`, `Write_UART`, `Test_UART`, and `PK2_3Hz_Clock` on Timer 0A), and `Lab2_Wed.lib` (`setup_GPIO`, `setup_UART`, `read_UART`, `write_UART`, `banner`, and `RedirectOutput`, which relays UART4 to UART0 by interrupts). Every function is weak, so a lab that writes its own function of the same name links as it does in Keil; interrupt handlers are only written when the library has them. Functions a library has that uMeil does not provide are listed in the import notes. All five labs' solutions were built with this and checked on an EK-TM4C1294XL (17 November).

Note: the `Template` folder's `main.c` has a stray `}` after `while(true) {}` and will not compile in any toolchain until it is removed. That is a fix in the course file, not in uMeil.

## Before M6: gaps the debugger requirements expose in earlier milestones

**16. Size metrics (FR-1.1, M3).** Done on 17 November: a build reports Code, RO-data, RW-data and ZI-data in the status line and the build log, read from the image's sections. The Blinky template's linker script now gives constants their own `.rodata` section so they count as RO-data; projects made before this, and Keil-built images, keep constants inside the code section, so theirs are counted as Code.

**17. Optimisation level for debugging (FR-5.2, M2).** Done on 17 November: the Blinky template now defaults to `-O0` (`Optimization.none`), matching imported Keil projects, so local variables and parameters are not optimised out when inspected in the debugger.

**18. Missing M4 tests.** The README's M4 test plan lists an XCUITest for opening, editing and saving files, and a typing performance test on a 10,000-line file. Neither was found in the repo. Recommended before items 19 and 20 change the editor.

**19. Tabbed source viewer (FR-3.1, M4).** The editor shows one file at a time; opening another replaces it. Stepping between `main.c` and the startup file needs tabs.

**20. Gutter (FR-3.2, FR-4.1, M4).** The gutter only draws error and warning markers and does not handle clicks. The debugger needs clicks to toggle breakpoints, a red circle for breakpoints, an arrow for the program counter, and marks for executable lines. Recommended as the first piece of M6.

**21. Reword FR-7.2.** Done on 17 November: FR-7.2 now specifies reporting processor mode (`Handler`/`Thread`), privilege level, and active stack pointer (`MSP`/`PSP`) from `xPSR` and `CONTROL`, and notes that Keil's software simulator `States` and `Sec` counters are not exposed by the LaunchPad's ICDI hardware probe.

## During M6

**22. Command window (FR-8.2).** Builds and flashes both keep a full log, but nothing in the window shows it. Add a console that shows build, flash and debugger output.

Already satisfied by M0 to M5, for reference: a build with errors blocks the next step and warnings do not (FR-1.1); every build compiles with `-g`; GDB is installed and checked by the toolchain manager; the M5 toolbar has room for the Start/Stop Debug button (FR-1.2).

## After M6

**24. Integrated terminal (`⌘J`).** Add a built-in shell terminal in the main window that toggles open and closed from the keyboard like other IDEs (`⌘J`, plus a menu item under a new `View` menu; `⌘J` is currently unused). Opening it should focus the terminal, and toggling it shut should return focus to the editor. Run the user's login shell in a pseudo-terminal (`openpty`) with the open project folder as its working directory, and keep it distinct from item 22's Command window (build, flash and debugger logs) and M8's Serial Monitor (board UART) — e.g. as tabs in `MainWindowController`'s collapsible bottom split (`editorSplit`, currently holding only `IssuesViewController`). Needs VT100/ANSI screen emulation (decide when picking this up whether to write a minimal AppKit terminal view or use a library such as SwiftTerm).
