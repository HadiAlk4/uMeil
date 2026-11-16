# Debugger Functional Requirements Specification

This document outlines the debugger features demonstrated in the Keil µVision reference video (debugging an ARM Cortex-M target) and defines the detailed functional requirements for the uMeil debugger.

---

## 1. Overview of Demonstrated Debugger Features

1. **Pre-Debug Build & Validation:** Compiling the C source code into an executable binary (`.axf` / `.elf`) and verifying 0 errors before launching the debug session.
2. **Debug Session Management:** Toggling between the Editor/Build workspace and the Debug workspace via the "Start/Stop Debug Session" (`Ctrl+F5`) button.
3. **Automatic Startup to `main()`:** Running target startup code (`Startup.s`) automatically upon session launch and halting at the entry point of `main()`.
4. **Execution Flow Control:** Resetting the CPU, running continuously, halting execution, single-stepping (`Step` / `F11`), stepping over functions (`Step Over` / `F10`), stepping out of functions (`Step Out` / `Ctrl+F11`), and running to the cursor line (`Run to Cursor Line`).
5. **Source & Disassembly Synchronization:** Viewing high-level C source code alongside processor-specific assembly instructions (Disassembly window) with visual program counter (`PC`) and cursor indicators.
6. **CPU Register Inspection:** Viewing core general-purpose registers (`R0`–`R12`), bank/stack pointers (`SP`, `LR`, `PC`), program status registers (`xPSR`), and system/internal state (`States`, `Sec`).
7. **Call Stack & Local Variable Inspection:** Real-time tracking of active stack frames (`main`, `add`), function parameters, local variables, data types, memory locations/registers, and values.
8. **Pointer Dereferencing & Value Formatting:** Expanding pointer variables (`int *p`) to inspect both the memory address stored and the dereferenced target value (`*p`), and toggling between Hexadecimal and Decimal (Integer) display formats.
9. **Raw Memory Inspection:** Querying specific hexadecimal memory addresses (e.g., `0x20000258`) in a hex-dump view and observing byte-level storage (little-endian byte ordering).
10. **Breakpoint Management:** Setting and toggling execution breakpoints on specific source lines and halting execution automatically when hit.
11. **Command Line & Watch Windows:** Providing a debug command console (`Command` window) and expression watch panels (`Watch 1`).

---

## 2. Detailed Debugger Functional Requirements

### FR-1: Build Verification & Session Lifecycle
* **FR-1.1 — Pre-Debug Compilation Check:**
  * **Description:** The IDE/Debugger must require a valid, compiled executable image (e.g., `.axf` / `.elf`) with **zero compilation/linking errors** before allowing a debug session to start.
  * **Details:** Compiler warnings are permissible and must not block the debug session, while build output must report program size metrics (`Code`, `RO-data`, `RW-data`, `ZI-data`).
* **FR-1.2 — Start/Stop Debug Session Toggle:**
  * **Description:** The system shall provide a dedicated toolbar control (magnifying glass with a `'d'` icon) and shortcut (`Ctrl+F5`) to enter and exit the debug mode.
  * **Details:** Entering debug mode must transition the UI layout from the standard editing view to the multi-pane debugging perspective. Exiting debug mode must terminate target emulation/connection and restore the editing layout.
* **FR-1.3 — Automatic Run to `main()`:**
  * **Description:** Upon initializing a debug session, the debugger shall load the executable, execute reset/startup assembly routines (e.g., `Startup.s`), and automatically halt at the first executable statement of `main()`.

---

### FR-2: Execution Control
* **FR-2.1 — CPU Reset (`Reset`):**
  * **Description:** The debugger shall provide a `Reset` action that emulates a hardware reset on the target CPU.
  * **Details:** Resets the Program Counter (`PC`) and CPU registers to their initial reset vector states and halts at the program entry point.
* **FR-2.2 — Continuous Execution (`Run` / `F5`):**
  * **Description:** The debugger shall allow the program to execute continuously at full speed until a breakpoint is encountered, an exception occurs, or the user manually halts execution.
* **FR-2.3 — Halt Execution (`Stop`):**
  * **Description:** While the target is running, the debugger shall enable a `Stop` button (red circle with an `'X'`) allowing the user to asynchronously interrupt and pause execution at the current instruction.
  * **Details:** When paused (e.g., inside an infinite `while(1)` spin-lock), the source window must update to show the exact line where execution stopped.
* **FR-2.4 — Step Into (`Step` / `F11`):**
  * **Description:** The debugger shall execute a single source line (or instruction). If the line contains a function call (e.g., `add(num, num)`), the debugger must step **into** the called function's first executable line.
* **FR-2.5 — Step Over (`Step Over` / `F10`):**
  * **Description:** The debugger shall execute the current source line in its entirety. If the line contains a function call, the function is executed completely at full speed and the debugger halts at the next line in the calling function.
* **FR-2.6 — Step Out (`Step Out` / `Ctrl+F11`):**
  * **Description:** When paused inside a sub-function, the debugger shall allow executing the remainder of the current function and halting immediately upon returning to the caller.
* **FR-2.7 — Run to Cursor Line (`Run to Cursor Line`):**
  * **Description:** The debugger shall allow the user to place the editor cursor on a specific source line (indicated by a blue marker) and execute continuously until reaching that line.

---

### FR-3: Source Code & Disassembly Visualization
* **FR-3.1 — Multi-Tab Source Code Viewer:**
  * **Description:** The debugger shall display open source and startup files (e.g., `Startup.s`, `main.c`) in a tabbed read-only/debug editor view with line numbers and syntax highlighting.
* **FR-3.2 — Execution & Cursor Line Indicators:**
  * **Description:** The source margin (gutter) and code lines must visually distinguish:
    * **Current Execution Point (Program Counter):** A **yellow arrow** in the margin and **green highlight** on the next line to be executed.
    * **Executable Lines:** Grey blocks in the left margin indicating lines that have associated machine instructions where breakpoints can be placed.
    * **Current Cursor Position:** A **blue arrow/highlight** indicating the user-selected line.
* **FR-3.3 — Synchronized Disassembly View:**
  * **Description:** The debugger shall provide a `Disassembly` window showing memory addresses, raw machine opcodes, assembly mnemonics (e.g., `MOVS`, `STR`, `LDR`, `BL`), and interleaved C source lines.
  * **Details:** The disassembly view must stay synchronized with the current Program Counter (`PC`) as the user steps through code.
* **FR-3.4 — Inline Hover Data Tooltips:**
  * **Description:** Hovering the mouse cursor over a variable in the source editor during a debug session shall display a tooltip showing the variable's current runtime value (e.g., `result = 0xFFFFFF9D` or `-99`).

---

### FR-4: Breakpoint Management
* **FR-4.1 — Line Breakpoint Toggling:**
  * **Description:** Users shall be able to set or remove a breakpoint by clicking in the left margin (gutter) next to any executable source line or via toolbar/context menu controls.
  * **Details:** Active breakpoints must be visually represented by a **solid red circle** in the margin.
* **FR-4.2 — Breakpoint Halt Behavior:**
  * **Description:** During continuous execution (`Run` or `Run to Cursor`), the debugger must immediately halt execution *before* executing the instruction at the breakpoint address and update all inspection windows (`Call Stack + Locals`, `Registers`, `Memory`, `Watch`).

---

### FR-5: Call Stack & Variable Inspection (`Call Stack + Locals`)
* **FR-5.1 — Active Call Stack Hierarchy:**
  * **Description:** The debugger shall display a hierarchical tree of active function stack frames (e.g., `main` and `add`), showing the function name, entry/return address, and frame type.
  * **Details:** When stepping into a function (`add`), a new stack frame block must be dynamically pushed to the top of the view; when returning to `main`, the frame must be popped.
* **FR-5.2 — Local Variable & Parameter Tracking:**
  * **Description:** Under each active stack frame, the debugger shall list all function arguments (e.g., `a`, `b`) and local variables (e.g., `result`, `num`, `p`, `c`) along with three attributes:
    1. **Name:** Identifier of the variable.
    2. **Location/Value:** Register (e.g., `R1`, `<not in scope>`) or stack memory address where the variable resides, and its current value.
    3. **Type:** C data type and storage class (e.g., `auto int`, `auto int *`, `param int`).
* **FR-5.3 — Recent Value Change Highlighting:**
  * **Description:** When a step operation causes a variable or register value to change, the debugger shall highlight the updated value cell (e.g., in **teal/dark green**) to draw immediate attention to state mutations.
* **FR-5.4 — Pointer Expansion & Dereferencing:**
  * **Description:** Pointer variables (e.g., `int *p`) shall display an expandable tree node (`+` / `-`).
  * **Details:**
    * The parent row displays the pointer's own value (the target memory address, e.g., `0x20000258`).
    * Expanding the node reveals the dereferenced child row (`*p`), displaying the value stored at that memory address (e.g., `-99`).
* **FR-5.5 — Number Base Formatting (Hexadecimal vs. Decimal):**
  * **Description:** Users shall be able to right-click variables in the `Call Stack + Locals` window and toggle `Hexadecimal Display` on or off.
  * **Details:**
    * When **Hexadecimal Display** is enabled (default), signed negative integers like `-99` are shown in 32-bit two's complement hex (`0xFFFFFF9D`).
    * When **Hexadecimal Display** is disabled, values are formatted according to their C data type (e.g., signed decimal `-99` for `int`).

---

### FR-6: Memory Inspection (`Memory` Window)
* **FR-6.1 — Address-Based Memory Lookup:**
  * **Description:** The debugger shall provide one or more `Memory` tabs (e.g., `Memory 1`) featuring an `Address:` input field where users can enter a hexadecimal address (e.g., `0x20000258`) or symbolic expression.
* **FR-6.2 — Hex Dump & Endianness Visualization:**
  * **Description:** The memory view shall display a grid of contiguous memory addresses and their raw byte contents in hexadecimal.
  * **Details:** Demonstrates target endianness (e.g., storing 32-bit `0xFFFFFF9D` at `0x20000258` in little-endian byte order as `9D FF FF FF`).

---

### FR-7: CPU Register & System State Inspection (`Regs` Window)
* **FR-7.1 — Core Register Display:**
  * **Description:** The debugger shall provide a dedicated `Regs` pane listing all CPU registers and their real-time 32-bit hexadecimal values:
    * General Purpose Registers: `R0` through `R12`
    * Stack Pointer (`SP` / `R13`), Link Register (`LR` / `R14`), Program Counter (`PC` / `R15`)
    * Program Status Register (`xPSR`) with expandable bitfields
    * Special-purpose registers (`MSP`, `PSP`, `PRIMASK`, `BASEPRI`, `FAULTMASK`, `CONTROL`)
* **FR-7.2 — Processor Execution State & Timing:**
  * **Description:** The `Regs` window shall also report internal processor states (`Handler`/`Thread` mode, `Privileged`/`Unprivileged`, active stack pointer) and elapsed instruction states/execution time (`States`, `Sec`).

---

### FR-8: Auxiliary Debug Windows
* **FR-8.1 — Watch Windows (`Watch 1`):**
  * **Description:** The debugger shall provide a customizable `Watch` tab where users can manually add global/local expressions to monitor across function boundaries.
* **FR-8.2 — Debug Command Console (`Command` Window):**
  * **Description:** The debugger shall provide a command-line interface logging debugger initialization, DLL versions, loaded symbols (`Load "...\\Debug.axf"`), and allowing text-based debugger commands.
