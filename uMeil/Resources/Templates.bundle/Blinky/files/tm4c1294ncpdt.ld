/* Linker script for the TM4C1294NCPDT: 1 MB of flash and 256 KB of RAM. */

MEMORY
{
    FLASH (rx)  : ORIGIN = 0x00000000, LENGTH = 1024K
    SRAM  (rwx) : ORIGIN = 0x20000000, LENGTH = 256K
}

ENTRY(Reset_Handler)

SECTIONS
{
    /* Code. The vector table must come first. */
    .text :
    {
        KEEP(*(.isr_vector))
        *(.text*)
        . = ALIGN(4);
    } > FLASH

    /* Constants. A section of their own, so the build can report code and
       read-only data separately. */
    .rodata :
    {
        *(.rodata*)
        . = ALIGN(4);
    } > FLASH

    .ARM.exidx :
    {
        *(.ARM.exidx*)
    } > FLASH

    /* Variables with a starting value. They live in RAM, but their starting
       values are stored in flash and copied over by Reset_Handler. */
    .data :
    {
        __data_start = .;
        *(vtable)   /* driverlib's RAM vector table, used by IntRegister() */
        *(.data*)
        . = ALIGN(4);
        __data_end = .;
    } > SRAM AT > FLASH

    __data_load = LOADADDR(.data);

    /* Variables without a starting value. Reset_Handler sets them to zero. */
    .bss (NOLOAD) :
    {
        __bss_start = .;
        *(.bss*)
        *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > SRAM

    /* The stack starts at the end of RAM and grows down. */
    __stack_top = ORIGIN(SRAM) + LENGTH(SRAM);
}
