import Foundation

/// Replaces the prebuilt Arm Compiler course libraries (`ES_Library.lib`,
/// `Lib4.lib`) with C source that the GNU toolchain can compile.
///
/// The `.lib` archives shipped with the course labs contain `.ORC` objects
/// from Arm Compiler 6, which the GNU linker cannot read. This file writes
/// `uMeil/es_lib.c` implementing the serial, delay, clock, and Port N helpers
/// declared in `ES_Lib.h` and `Lib4.h`.
enum KeilCourseLibrary {
    static let fileName = "es_lib.c"

    /// Whether `path` names one of the course's prebuilt `.lib` files, such as
    /// `ES_Library.lib` or `Lib4.lib`.
    static func isCourseLibrary(_ path: String) -> Bool {
        let name = URL(filePath: path).lastPathComponent.lowercased()
        return name == "es_library.lib"
            || name.wholeMatch(of: #/lib\d*\.lib/#) != nil
    }

    static var source: String {
        [serialAndDelaySource, printfAndClockSource]
            .joined(separator: "\n")
    }

    private static let serialAndDelaySource = """
    // Course support library for the GNU toolchain, written by uMeil to
    // replace Arm Compiler's ES_Library.lib / Lib4.lib.

    #include <stdarg.h>
    #include <stdbool.h>
    #include <stdint.h>

    #include "TM4C129.h"

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

    void msDelay(int msec)
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

    char ES_getchar(int number)
    {
        UART0_Type *uart = es_uarts[number & 7].uart;
        while ((uart->FR & 0x10u) != 0u) {
        }
        return (char)(uart->DR & 0xFFu);
    }

    void ES_putchar(int number, char c)
    {
        UART0_Type *uart = es_uarts[number & 7].uart;
        while ((uart->FR & 0x20u) != 0u) {
        }
        uart->DR = (uint32_t)(uint8_t)c;
    }

    char ES_echo(int number)
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

    void ES_Serial(int number, char line_format[20])
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
        uint32_t lcrh = (bits << 5u) + (stop << 3u) + (parityBits << 1u) - 168u;
        float brd = (float)SystemCoreClock / 16.0f / (float)baud;
        uint32_t ibrd = (uint32_t)brd;
        uint32_t fbrd = (uint32_t)((brd - (float)(int32_t)brd) * 64.0f);

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
        cfg->uart->IBRD = ibrd;
        cfg->uart->FBRD = fbrd;
        cfg->uart->LCRH = lcrh;
        cfg->uart->CC   = 0u;
        cfg->uart->CTL  = 0x301u;
        msDelay(1);
    }
    """
}

extension KeilCourseLibrary {
    fileprivate static let printfAndClockSource = """
    static void es_putc_cooked(char c)
    {
        if (c == '\\r' || c == '\\n' || c == 27) {
            ES_putchar(0, '\\r');
            ES_putchar(0, '\\n');
        } else {
            ES_putchar(0, c);
        }
    }

    static void es_print_uint(uint32_t value, uint32_t base, bool uppercase)
    {
        char digits[32];
        int count = 0;
        if (value == 0u) {
            ES_putchar(0, '0');
            return;
        }
        const char *alphabet = uppercase ? "0123456789ABCDEF" : "0123456789abcdef";
        while (value > 0u) {
            digits[count++] = alphabet[value % base];
            value /= base;
        }
        while (count > 0) {
            ES_putchar(0, digits[--count]);
        }
    }

    static void es_print_int(int32_t value)
    {
        if (value < 0) {
            ES_putchar(0, '-');
            uint32_t magnitude = (uint32_t)(-(value + 1)) + 1u;
            es_print_uint(magnitude, 10u, false);
        } else {
            es_print_uint((uint32_t)value, 10u, false);
        }
    }

    void ES_printf(const char *format, ...)
    {
        va_list args;
        va_start(args, format);
        for (const char *p = format; *p != '\\0'; p++) {
            if (*p != '%') {
                es_putc_cooked(*p);
                continue;
            }
            p++;
            if (*p == 'l') {
                p++;
            }
            switch (*p) {
            case 'd':
            case 'i':
                es_print_int(va_arg(args, int));
                break;
            case 'u':
                es_print_uint(va_arg(args, unsigned int), 10u, false);
                break;
            case 'x':
            case 'p':
                es_print_uint(va_arg(args, unsigned int), 16u, false);
                break;
            case 'X':
                es_print_uint(va_arg(args, unsigned int), 16u, true);
                break;
            case 'c':
                es_putc_cooked((char)va_arg(args, int));
                break;
            case 's': {
                const char *s = va_arg(args, const char *);
                if (s != 0) {
                    while (*s != '\\0') {
                        es_putc_cooked(*s++);
                    }
                }
                break;
            }
            case '%':
                ES_putchar(0, '%');
                break;
            case '\\0':
                va_end(args);
                return;
            default:
                ES_putchar(0, '%');
                es_putc_cooked(*p);
                break;
            }
        }
        va_end(args);
    }

    char *ES_utob(uint32_t value)
    {
        static char buf[42];
        char *out = buf;
        for (int bit = 31; bit >= 0; bit--) {
            *out++ = (char)('0' + ((value >> (uint32_t)bit) & 1u));
            if (bit % 4 == 0) {
                *out++ = ' ';
            }
        }
        *out = '\\0';
        return buf;
    }

    int readDec(void)
    {
        int value = 0;
        int sign = 1;
        char c;
        do {
            c = ES_echo(0);
        } while (c == ' ' || c == '\\t' || c == '\\r' || c == '\\n' || c == '\\v' || c == '\\f');

        if (c == '-') {
            sign = -1;
            c = ES_echo(0);
        } else if (c == '+') {
            c = ES_echo(0);
        }
        while (c >= '0' && c <= '9') {
            value = value * 10 + (c - '0');
            c = ES_echo(0);
        }
        return sign * value;
    }

    void setSysClk80MHz(void)
    {
        SYSCTL->MOSCCTL |= 0x10u;
        SYSCTL->MOSCCTL &= ~0x04u;
        SYSCTL->MOSCCTL &= ~0x08u;
        while ((SYSCTL->RIS & 0x100u) == 0u) {
        }
        SYSCTL->RSCLKCFG = (SYSCTL->RSCLKCFG & ~0x0FF00000u) | 0x03300000u;
        SYSCTL->PLLFREQ0 = 0x60u;
        SYSCTL->PLLFREQ1 = 0x04u;
        SYSCTL->PLLFREQ0 |= 0x00800000u;
        SYSCTL->MEMTIM0  = 0x01030103u | 0x00100010u;
        while ((SYSCTL->PLLSTAT & 0x01u) == 0u) {
        }
        SYSCTL->RSCLKCFG |= 0xD0000005u;
        SystemCoreClock = 80000000u;
    }

    void enablePN(void)
    {
        SYSCTL->RCGCGPIO |= 0x1000u;
        while ((SYSCTL->PRGPIO & 0x1000u) == 0u) {
        }
    }

    void setPNOutput(uint8_t pins)
    {
        GPION->DEN |= pins;
        GPION->DIR |= pins;
    }

    void setPNInput(uint8_t pins)
    {
        GPION->DEN |= pins;
        GPION->DIR &= ~(uint32_t)pins;
        GPION->PUR &= ~(uint32_t)pins;
    }

    void writePNData(uint8_t data)
    {
        GPION->DATA = data;
    }

    uint8_t readPNData(void)
    {
        return (uint8_t)GPION->DATA;
    }

    void PortN_LEDs(void)
    {
        enablePN();
        setPNOutput(0x03u);
        writePNData(0x03u);
        msDelay(250);
        writePNData(0x00u);
    }
    """
}
