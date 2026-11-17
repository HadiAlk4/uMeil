import Foundation

// The C source of the course library: the start of the file, the UART
// table, msDelay(), and serial set-up.
extension KeilCourseLibrary {
    static let header = """
    // Course support library for the GNU toolchain, written by uMeil to
    // replace the course's Arm Compiler libraries (ES_Library.lib, Lib4.lib,
    // Lab1A.lib, lib3.lib, Lab2_Wed.lib).
    //
    // Every function is weak, so a function of the same name in your own
    // code is used instead, as with Keil's library. uMeil writes this file
    // again when the Keil project is opened; delete this comment to keep
    // your own changes.

    #include <stdarg.h>
    #include <stdbool.h>
    #include <stdint.h>

    #include "TM4C129.h"

    #define ES_WEAK __attribute__((weak))

    """

    static let serialAndDelaySource = """
    typedef struct {
        uint32_t rcgcUart;
        uint32_t rcgcGpio;
        uint32_t gpioPins;
        UART0_Type *uart;
        GPIOA_Type *gpio;
        uint32_t pctl;
    } es_uart_config_t;

    static const es_uart_config_t es_uarts[8] = {
        { 0x01u, 0x0001u, 0x03u, UART0, GPIOA_AHB, 0x00000011u },
        { 0x02u, 0x0002u, 0x03u, UART1, GPIOB_AHB, 0x00000011u },
        { 0x04u, 0x0001u, 0xC0u, UART2, GPIOA_AHB, 0x11000000u },
        { 0x08u, 0x0001u, 0x30u, UART3, GPIOA_AHB, 0x00110000u },
        { 0x10u, 0x0200u, 0x03u, UART4, GPIOK,     0x00000011u },
        { 0x20u, 0x0004u, 0xC0u, UART5, GPIOC_AHB, 0x11000000u },
        { 0x40u, 0x2000u, 0x03u, UART6, GPIOP,     0x00000011u },
        { 0x80u, 0x0004u, 0x30u, UART7, GPIOC_AHB, 0x00110000u }
    };

    // Like the course library's, this uses SysTick, so it stops a SysTick
    // interrupt the program set up itself.
    ES_WEAK void msDelay(int msec)
    {
        for (int i = 0; i < msec; i++) {
            // SysTick clocked by PIOSC / 4 (4 MHz): 4000 ticks is 1 ms.
            SysTick->LOAD = 3999u;
            SysTick->CTRL = 1u;
            SysTick->VAL  = 0u;
            while ((SysTick->CTRL & (1u << 16)) == 0u) {
            }
        }
    }

    ES_WEAK char ES_getchar(int number)
    {
        UART0_Type *uart = es_uarts[number & 7].uart;
        while ((uart->FR & 0x10u) != 0u) {
        }
        return (char)(uart->DR & 0xFFu);
    }

    ES_WEAK void ES_putchar(int number, char c)
    {
        UART0_Type *uart = es_uarts[number & 7].uart;
        while ((uart->FR & 0x20u) != 0u) {
        }
        uart->DR = (uint32_t)(uint8_t)c;
    }

    ES_WEAK char ES_echo(int number)
    {
        char c = ES_getchar(number);
        ES_putchar(0, c);
        return c;
    }

    static uint32_t es_parse_uint(const char **cursor)
    {
        uint32_t value = 0u;
        const char *p = *cursor;
        while (*p >= '0' && *p <= '9') {
            value = value * 10u + (uint32_t)(*p - '0');
            p++;
        }
        if (*p == ',') {
            p++;
        }
        *cursor = p;
        return value;
    }

    // Sets up UART `number` from a line format such as "115200,8,N,1", using
    // the system clock. Shared by the libraries' serial set-up functions.
    static void es_serial_setup(int number, const char *line_format)
    {
        const es_uart_config_t *cfg = &es_uarts[number & 7];
        const char *p = line_format;
        uint32_t baud = es_parse_uint(&p);
        uint32_t bits = es_parse_uint(&p);
        char parity = *p ? *p++ : 'N';
        if (*p == ',') {
            p++;
        }
        uint32_t stop = es_parse_uint(&p);
        if (baud == 0u) {
            baud = 115200u;
        }
        if (bits < 5u || bits > 8u) {
            bits = 8u;
        }
        if (stop < 1u || stop > 2u) {
            stop = 1u;
        }

        uint32_t parityBits = 0u;
        if (parity == 'E' || parity == 'e') {
            parityBits = 3u;
        } else if (parity == 'O' || parity == 'o') {
            parityBits = 1u;
        }
        uint32_t lcrh = ((bits - 5u) << 5u) | ((stop - 1u) << 3u) | (parityBits << 1u);
        // The divisor in 64ths, rounded: clock / (16 * baud) * 64.
        uint32_t divisor = (SystemCoreClock * 8u / baud + 1u) / 2u;

        SYSCTL->RCGCGPIO |= cfg->rcgcGpio;
        while ((SYSCTL->PRGPIO & cfg->rcgcGpio) == 0u) {
        }
        cfg->gpio->PCTL  |= cfg->pctl;
        cfg->gpio->AFSEL |= cfg->gpioPins;
        cfg->gpio->DEN   |= cfg->gpioPins;

        SYSCTL->RCGCUART |= cfg->rcgcUart;
        while ((SYSCTL->PRUART & cfg->rcgcUart) == 0u) {
        }
        cfg->uart->CTL  = 0u;
        cfg->uart->IBRD = divisor / 64u;
        cfg->uart->FBRD = divisor % 64u;
        cfg->uart->LCRH = lcrh;
        cfg->uart->CC   = 0u;
        cfg->uart->CTL  = 0x301u;
    }

    ES_WEAK void ES_Serial(int number, char line_format[20])
    {
        es_serial_setup(number, line_format);
        msDelay(1);
    }

    """
}
