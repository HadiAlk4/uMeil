import Foundation

// The C source of the course library: ES_printf() and friends, the system
// clock, and the Port F, J and N helpers.
extension KeilCourseLibrary {
    static let printfAndClockSource = """
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

    ES_WEAK void ES_printf(const char *format, ...)
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

    ES_WEAK char *ES_utob(uint32_t value)
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

    ES_WEAK int readDec(void)
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

    ES_WEAK void setSysClk80MHz(void)
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

    ES_WEAK uint32_t getSysClk(void)
    {
        return SystemCoreClock;
    }

    """

    /// Port F, J and N helpers (`Lab1A.lib`, `ES_Library.lib`) and the
    /// UART0 serial functions of `Lab1A.lib`.
    static let portSource = """
    // Turns on the clock for the GPIO port with run-mode bit `bit`, and waits
    // until the port is ready.
    static void es_enable_port(uint32_t bit)
    {
        SYSCTL->RCGCGPIO |= bit;
        while ((SYSCTL->PRGPIO & bit) == 0u) {
        }
    }

    static void es_set_output(GPIOA_Type *port, uint8_t pins)
    {
        port->AFSEL &= ~(uint32_t)pins;
        port->AMSEL &= ~(uint32_t)pins;
        port->DIR   |= pins;
        port->DEN   |= pins;
    }

    static void es_set_input(GPIOA_Type *port, uint8_t pins, bool pullUp)
    {
        port->AFSEL &= ~(uint32_t)pins;
        port->AMSEL &= ~(uint32_t)pins;
        port->DIR   &= ~(uint32_t)pins;
        if (pullUp) {
            port->PUR |= pins;
        } else {
            port->PUR &= ~(uint32_t)pins;
        }
        port->DEN   |= pins;
    }

    ES_WEAK void enablePF(void) { es_enable_port(1u << 5); }
    ES_WEAK void setPFOutput(uint8_t pins) { es_set_output(GPIOF_AHB, pins); }
    ES_WEAK void setPFInput(uint8_t pins) { es_set_input(GPIOF_AHB, pins, false); }
    ES_WEAK void writePFData(uint8_t value) { GPIOF_AHB->DATA = value; }
    ES_WEAK uint8_t readPFData(void) { return (uint8_t)GPIOF_AHB->DATA; }

    // SW1 and SW2 on PJ0 and PJ1 connect to ground when pressed, so Port J
    // inputs get pull-up resistors: a switch reads 1 until it is pressed.
    ES_WEAK void enablePJ(void) { es_enable_port(1u << 8); }
    ES_WEAK void setPJOutput(uint8_t pins) { es_set_output(GPIOJ_AHB, pins); }
    ES_WEAK void setPJInput(uint8_t pins) { es_set_input(GPIOJ_AHB, pins, true); }
    ES_WEAK void writePJData(uint8_t value) { GPIOJ_AHB->DATA = value; }
    ES_WEAK uint8_t readPJData(void) { return (uint8_t)GPIOJ_AHB->DATA; }

    ES_WEAK void enablePN(void) { es_enable_port(1u << 12); }
    ES_WEAK void setPNOutput(uint8_t pins) { es_set_output(GPION, pins); }
    ES_WEAK void setPNInput(uint8_t pins) { es_set_input(GPION, pins, false); }
    ES_WEAK void writePNData(uint8_t value) { GPION->DATA = value; }
    ES_WEAK uint8_t readPNData(void) { return (uint8_t)GPION->DATA; }

    ES_WEAK void PortN_LEDs(void)
    {
        enablePN();
        setPNOutput(0x03u);
        writePNData(0x03u);
        msDelay(250);
        writePNData(0x00u);
    }

    // UART0, the LaunchPad's USB serial port, at 115200 baud, 8 bits, no
    // parity, 1 stop bit.
    ES_WEAK void enableSerial(void) { es_serial_setup(0, "115200,8,N,1"); }
    ES_WEAK void setBaudRate115200(void) { es_serial_setup(0, "115200,8,N,1"); }
    ES_WEAK char serialRead(void) { return ES_getchar(0); }
    ES_WEAK void serialWrite(char c) { ES_putchar(0, c); }

    """
}
