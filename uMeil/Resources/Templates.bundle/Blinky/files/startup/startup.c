// Startup code for the TM4C1294NCPDT.
//
// Holds the interrupt vector table and the code that runs after reset,
// before main().

#include <stdint.h>

// 16 Cortex-M4 exceptions followed by the chip's 114 interrupts.
#define VECTOR_COUNT 130

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

void Reset_Handler(void);
void Default_Handler(void);

// The Cortex-M4 exceptions end up in Default_Handler unless the program
// defines a function with the same name.
void NMI_Handler(void) __attribute__((weak, alias("Default_Handler")));
void HardFault_Handler(void) __attribute__((weak, alias("Default_Handler")));
void MemManage_Handler(void) __attribute__((weak, alias("Default_Handler")));
void BusFault_Handler(void) __attribute__((weak, alias("Default_Handler")));
void UsageFault_Handler(void) __attribute__((weak, alias("Default_Handler")));
void SVC_Handler(void) __attribute__((weak, alias("Default_Handler")));
void DebugMon_Handler(void) __attribute__((weak, alias("Default_Handler")));
void PendSV_Handler(void) __attribute__((weak, alias("Default_Handler")));
void SysTick_Handler(void) __attribute__((weak, alias("Default_Handler")));

// The linker script puts this table at address 0, where the chip looks for
// it after reset. Entries left out are zero (reserved).
__attribute__((section(".isr_vector"), used))
const vector_t vector_table[VECTOR_COUNT] = {
    [0] = (vector_t)&__stack_top, // Initial stack pointer
    [1] = Reset_Handler,
    [2] = NMI_Handler,
    [3] = HardFault_Handler,
    [4] = MemManage_Handler,
    [5] = BusFault_Handler,
    [6] = UsageFault_Handler,
    [11] = SVC_Handler,
    [12] = DebugMon_Handler,
    [14] = PendSV_Handler,
    [15] = SysTick_Handler,

    // Chip interrupts. Interrupt number n from the datasheet is entry 16 + n.
    // To handle one, either call IntRegister() from driverlib at run time, or
    // split this range around its entry. For Timer 0A (interrupt 19):
    //
    //     [16 ... 34] = Default_Handler,
    //     [35] = Timer0A_Handler,
    //     [36 ... 129] = Default_Handler,
    [16 ... 129] = Default_Handler,
};

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

    main();

    // main() should never return. Stop here if it does.
    for (;;) {
    }
}

// Catches every exception and interrupt without a handler. Stopping here
// keeps the chip's state intact for the debugger.
void Default_Handler(void)
{
    for (;;) {
    }
}
