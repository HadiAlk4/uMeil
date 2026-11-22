import Foundation

/// Replaces Keil's startup file with one the GNU toolchain can build.
///
/// Keil's `startup_<chip>.s` is written for Keil's assembler and ends by
/// jumping to `__main`, a routine inside Keil's C library. Neither exists in
/// the GNU toolchain. What a project relies on is the names in the vector
/// table: a lab that defines `SysTick_Handler` or `GPIOJ_Handler` expects
/// that function to be called. So the table's names are read from the Keil
/// file and written out again as C.
enum KeilStartup {
    /// How many vectors a Cortex-M chip always has before its own interrupts.
    static let coreVectorCount = 16

    /// The Cortex-M exceptions, used when the Keil file cannot be read.
    /// Entry 0 is the starting stack pointer and entry 1 the reset handler.
    static let coreVectors: [String?] = [
        "__initial_sp", "Reset_Handler", "NMI_Handler", "HardFault_Handler",
        "MemManage_Handler", "BusFault_Handler", "UsageFault_Handler", nil,
        nil, nil, nil, "SVC_Handler",
        "DebugMon_Handler", nil, "PendSV_Handler", "SysTick_Handler"
    ]

    /// The names in a Keil startup file's vector table, in order. `nil`
    /// marks a reserved entry.
    ///
    /// The table is the run of `DCD` lines from the `__Vectors` label to
    /// `__Vectors_End`. Returns `nil` if no such table is found.
    static func vectorNames(inKeilStartup source: String) -> [String?]? {
        var names: [String?] = []
        var isInTable = false

        for line in source.split(whereSeparator: \.isNewline) {
            // Drop the comment, then split "label DCD value" into words.
            let code = line.prefix { $0 != ";" }
            let words = code.split(whereSeparator: \.isWhitespace)
            guard let first = words.first else { continue }

            if first == "__Vectors_End" { break }
            if first == "__Vectors" { isInTable = true }
            guard isInTable, let directive = words.firstIndex(of: "DCD"), directive + 1 < words.count else {
                continue
            }
            let value = String(words[directive + 1])
            if value == "0" {
                names.append(nil)
            } else {
                names.append(isValidIdentifier(value) ? value : "Default_Handler")
            }
        }
        return names.count >= coreVectorCount ? names : nil
    }

    /// Whether `name` is a safe C identifier (`^[A-Za-z_][A-Za-z0-9_]*$`).
    static func isValidIdentifier(_ name: String) -> Bool {
        name.wholeMatch(of: #/[A-Za-z_][A-Za-z0-9_]*/#) != nil
    }

    /// C source for a startup file with `vectors` as its vector table.
    ///
    /// `interruptCount` pads the table when `vectors` is shorter than the
    /// chip's real one, so an interrupt nobody named still has somewhere safe
    /// to go.
    static func gnuSource(vectors: [String?], interruptCount: Int, basedOn original: String?) -> String {
        var table = vectors.map { name -> String? in
            guard let name else { return nil }
            return isValidIdentifier(name) ? name : "Default_Handler"
        }
        while table.count < coreVectorCount + interruptCount {
            table.append("Default_Handler")
        }

        // Every name in the table can be replaced by a function of the same
        // name in the project. Reset_Handler is defined below.
        var seen: Set<String> = ["Reset_Handler", "Default_Handler"]
        let handlers = table.dropFirst(2).compactMap { $0 }.filter { seen.insert($0).inserted }
        let aliases = handlers.map { "void \($0)(void) __attribute__((weak, alias(\"Default_Handler\")));" }

        let entries = table.enumerated().map { index, name -> String in
            let value: String
            switch (index, name) {
            case (0, _): value = "(vector_t)&__stack_top"
            case (1, _): value = "Reset_Handler"
            case (_, let name?): value = name
            case (_, nil): value = "0"
            }
            let label = index < coreVectorCount ? "" : " // Interrupt \(index - coreVectorCount)"
            return "    \(value),\(label)"
        }

        let origin = sanitizedOrigin(original).map { "from the vector table in \($0)" } ?? "for the Cortex-M4"
        return """
        // Startup code for the GNU toolchain, written by uMeil \(origin).
        //
        // Keil's own startup file is left untouched: Keil still uses it. It
        // cannot be built here because it is written for Keil's assembler and
        // hands over to Keil's C library.
        //
        // Holds the interrupt vector table and the code that runs after
        // reset, before main().

        \(declarations)
        // Each of these ends up in Default_Handler unless the program defines
        // a function with the same name.
        \(aliases.joined(separator: "\n"))

        // The linker script puts this table at address 0, where the chip looks
        // for it after reset.
        __attribute__((section(".isr_vector"), used))
        const vector_t vector_table[\(table.count)] = {
        \(entries.joined(separator: "\n"))
        };

        \(resetCode)
        """
    }

    private static func sanitizedOrigin(_ original: String?) -> String? {
        guard let original else { return nil }
        let base = original
            .split { $0 == "/" || $0 == "\\" }
            .last
            .map(String.init) ?? ""
        var cleaned = String(base.unicodeScalars.filter { scalar in
            scalar.value >= 0x20
                && !(scalar.value >= 0x7F && scalar.value <= 0x9F)
                && scalar != "\u{2028}"
                && scalar != "\u{2029}"
        })
        while cleaned.contains("*/") {
            cleaned = cleaned.replacing("*/", with: "_")
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// The part of the startup file before the vector table.
    private static let declarations = """
    #include <stdint.h>

    // Coprocessor Access Control Register. Bits 20-23 give access to the FPU.
    #define CPACR (*(volatile uint32_t *)0xE000ED88u)

    typedef void (*vector_t)(void);

    // Defined by the linker script.
    extern uint32_t __stack_top;
    extern uint32_t __data_load;
    extern uint32_t __data_start;
    extern uint32_t __data_end;
    extern uint32_t __bss_start;
    extern uint32_t __bss_end;

    extern int main(void);
    // From the project's system file. Skipped if the project has none.
    extern void SystemInit(void) __attribute__((weak));

    void Reset_Handler(void);
    void Default_Handler(void);

    """

    /// The part of the startup file after the vector table.
    private static let resetCode = """
    void Reset_Handler(void)
    {
        // The project is built for the hardware FPU, so switch it on before
        // any code that might use it.
        CPACR |= 0xFu << 20;

        // Copy the starting values of initialised variables from flash to RAM.
        uint32_t *source = &__data_load;
        for (uint32_t *target = &__data_start; target < &__data_end;) {
            *target++ = *source++;
        }

        // Variables without a starting value begin at zero.
        for (uint32_t *target = &__bss_start; target < &__bss_end;) {
            *target++ = 0;
        }

        if (SystemInit) {
            SystemInit();
        }
        main();

        // main() should never return. Stop here if it does.
        for (;;) {
        }
    }

    // Catches every exception and interrupt without a handler. Stopping
    // here keeps the chip's state intact for the debugger.
    void Default_Handler(void)
    {
        for (;;) {
        }
    }

    """
}
