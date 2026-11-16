# Agenda

Open work that is not yet scheduled in the README milestones, and when it is recommended to do each item. Last updated 16 November 2026.

Status today: M0 to M4 are merged. M5 (flashing) is on the `m5-flashing` branch and has flashed a real board. Still open before M5 closes: items 6 to 9, 11 and 23.

## Summary

| # | Item | Belongs to | Do it |
|---|---|---|---|
| 1 | Decide how to handle the course library | Keil support | Now (decision only) |
| 2 | Ask the course for the library source or a GCC build | Keil support | Now (long wait) |
| 3 | Check the licence of `TM4C129.h` | Keil support | Now (check only) |
| 4 | Real flash of Blinky on the board | M5 | Done 16 November |
| 5 | Replace reconstructed OpenOCD logs with real captures | M5 | Done 16 November, except two logs that could not be captured |
| 6 | Locked-chip error message | M5 | With the board, before closing M5 |
| 7 | Check USB plug and unplug detection | M5 | With the board, before closing M5 |
| 8 | Look at the board status dot in the running app | M5 | With the board, before closing M5 |
| 9 | Hardware-in-the-loop flash test | M5 | With the board, before closing M5 |
| 10 | Check the "no board" test passes in CI | M5 | Done 16 November |
| 11 | Flash an existing image (`.axf` / `.elf`) | M5 | Before closing M5 |
| 23 | Fix the timing test that fails in CI | M5 | Before merging `m5-flashing` |
| 12 | Keil project import (`.uvprojx` to `.umeil`) | M2 | After M5, before M6 |
| 13 | GNU startup file and linker script for Keil projects | M2, M3 | After M5, before M6 |
| 14 | Ship or download `TM4C129.h` | M2 | After M5, before M6 |
| 15 | Link the course library | M3 | After M5, before M6 |
| 16 | Build output reports Code, RO-data, RW-data, ZI-data | M3 | Before M6 |
| 17 | Decide `-O0` or `-Og` for debug builds | M2 | Before M6 |
| 18 | XCUITest target and typing performance test | M4 | Before M6 |
| 19 | Tabbed source viewer | M4 | Before M6 |
| 20 | Gutter: clicks, breakpoints, program counter arrow | M4 | Start of M6 |
| 21 | Reword FR-7.2 (`States` and `Sec` counters) | Spec | Before M6 |
| 22 | Command window showing build, flash and debug logs | M3, M5 | During M6 |

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

**6. Locked-chip message.** Still missing: nothing in `uMeil/Flashing` handles a locked chip, so it falls through to OpenOCD's own first error line. Capture the real output and add a plain-language message.

**7. USB detection.** The toolbar's "Board connected" status has never seen a real plug or unplug event.

**8. Status dot.** The dot was changed to draw green when connected and was not looked at again afterwards.

**9. Hardware-in-the-loop test.** The README's M5 test: flash a firmware that prints a known message over UART and read it back, on a self-hosted Mac runner. Not written yet, and CI has no self-hosted runner job.

**10. CI check.** Done: `RealOpenOCDWithoutABoardTests` passes in CI against Homebrew's OpenOCD.

**11. Flash an existing image.** A command that writes a Keil-built `.axf` or any `.elf` straight to the board, without a uMeil project. It is small, it reuses the M5 flasher, and it already covers the `L4` lab folders, which contain built images. Recommended inside M5 because it is flashing work and gives Keil users something useful before the importer exists.

**23. Timing test that fails in CI.** `StreamingProcessRunnerTests/reportsLinesWhileTheProcessIsStillRunning()` has failed in the last three CI runs on `m5-flashing`. It expects the first line within 0.7 s of launch, which does not hold on a loaded CI runner. Change it to check that the early line arrives well before the late one, instead of timing from launch.

## After M5, before M6: Keil project support

Recommended here because the debugger requirements (`docs/debugger-functional-requirements.md`) are written around debugging this kind of course project, so M6 needs to be able to build them. These items extend M2 (project model) and M3 (build system).

**12. Keil project import.** uMeil only builds folders with a `.umeil` project file. Read the `.uvprojx` (source files, include paths, defines, chip) and create a `.umeil` project from it, leaving the Keil files untouched.

**13. GNU startup file and linker script.** Keil's `startup_TM4C129.s` uses Keil's assembler syntax and jumps to Keil's `__main`, so the GNU assembler cannot use it. Substitute a GNU startup with the same handler names (the labs define `SysTick_Handler` and others) that calls `SystemInit`, plus a linker script.

**14. `TM4C129.h`.** Ship it or download it, depending on item 3.

**15. Course library.** Carry out whichever route was chosen in item 1. Also needs a way for a project to name an extra library; today that takes hand-written linker flags.

Note: the `Template` folder's `main.c` has a stray `}` after `while(true) {}` and will not compile in any toolchain until it is removed. That is a fix in the course file, not in uMeil.

## Before M6: gaps the debugger requirements expose in earlier milestones

**16. Size metrics (FR-1.1, M3).** The build reports flash and RAM totals from `size`'s text, data and bss. The requirement asks for Code, RO-data, RW-data and ZI-data, which needs the per-section output to split code from read-only data.

**17. Optimisation level for debugging (FR-5.2, M2).** The Blinky template builds with `-Og`, where some locals can show as optimised out. Decide whether debug builds should use `-O0`.

**18. Missing M4 tests.** The README's M4 test plan lists an XCUITest for opening, editing and saving files, and a typing performance test on a 10,000-line file. Neither was found in the repo. Recommended before items 19 and 20 change the editor.

**19. Tabbed source viewer (FR-3.1, M4).** The editor shows one file at a time; opening another replaces it. Stepping between `main.c` and the startup file needs tabs.

**20. Gutter (FR-3.2, FR-4.1, M4).** The gutter only draws error and warning markers and does not handle clicks. The debugger needs clicks to toggle breakpoints, a red circle for breakpoints, an arrow for the program counter, and marks for executable lines. Recommended as the first piece of M6.

**21. Reword FR-7.2.** The `States` and `Sec` counters come from Keil's simulator and are probably not available on real hardware through the LaunchPad's ICDI probe. The requirement likely needs rewording rather than code.

## During M6

**22. Command window (FR-8.2).** Builds and flashes both keep a full log, but nothing in the window shows it. Add a console that shows build, flash and debugger output.

Already satisfied by M0 to M5, for reference: a build with errors blocks the next step and warnings do not (FR-1.1); every build compiles with `-g`; GDB is installed and checked by the toolchain manager; the M5 toolbar has room for the Start/Stop Debug button (FR-1.2).
