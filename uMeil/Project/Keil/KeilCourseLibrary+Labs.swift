import Foundation

extension KeilCourseLibrary {
    /// `lib3.lib`, for Experiment 3 (GPIO interrupts).
    static let lab3Source = """
    // ---- Experiment 3 (lib3.lib) ----

    // UART0 at 115200 baud, 8 bits, no parity, 1 stop bit.
    ES_WEAK void Setup_UART(void) { es_serial_setup(0, "115200,8,N,1"); }
    ES_WEAK char Read_UART(void) { return ES_getchar(0); }
    ES_WEAK void Write_UART(char c) { ES_putchar(0, c); }

    static void es_lab3_print(const char *text)
    {
        while (*text != '\\0') {
            Write_UART(*text++);
        }
    }

    // Prints a message, then echoes what is typed until ESC is pressed.
    ES_WEAK void Test_UART(void)
    {
        es_lab3_print("\\r\\nLab 3: UART0 is working (115200,8,N,1).\\r\\n");
        es_lab3_print("Type to see the keys echoed. Press ESC to continue.\\r\\n");
        for (;;) {
            char c = Read_UART();
            if (c == 27) {
                break;
            }
            Write_UART(c);
        }
        es_lab3_print("\\r\\n");
    }

    // LED D4 is PF0.
    ES_WEAK void Configure_Led_D4(void)
    {
        es_enable_port(1u << 5);
        es_set_output(GPIOF_AHB, 0x01u);
    }

    // Toggles PK2 and LED D4 six times a second, making a 3 Hz square wave.
    void TIMER0A_Handler(void)
    {
        TIMER0->ICR = 0x01u;
        GPIOK->DATA ^= 0x04u;
        GPIOF_AHB->DATA ^= 0x01u;
    }

    // Starts a 3 Hz square wave on PK2, from Timer 0A's interrupt. Also
    // blinks LED D4.
    ES_WEAK void PK2_3Hz_Clock(void)
    {
        es_enable_port(1u << 9);
        es_set_output(GPIOK, 0x04u);
        GPIOK->DR2R |= 0x04u;
        Configure_Led_D4();

        SYSCTL->RCGCTIMER |= 0x01u;
        while ((SYSCTL->PRTIMER & 0x01u) == 0u) {
        }
        TIMER0->CTL  &= ~0x01u;
        TIMER0->CFG   = 0x0u;                     // one 32-bit timer
        TIMER0->TAMR  = 0x2u;                     // periodic, counting down
        TIMER0->TAILR = SystemCoreClock / 6u - 1u;
        TIMER0->ICR   = 0x01u;
        TIMER0->IMR  |= 0x01u;                    // time-out interrupt
        NVIC_EnableIRQ(TIMER0A_IRQn);
        __enable_irq();
        TIMER0->CTL  |= 0x01u;
    }

    """

    /// `Lab2_Wed.lib`, for Experiment 2 on Wednesday (UART3).
    static let lab2WednesdaySource = """
    // ---- Experiment 2, Wednesday (Lab2_Wed.lib) ----
    //
    // UART3 (PA4 receive, PA5 transmit) at 38400 baud, 7 bits, no parity,
    // 2 stop bits, from the 80 MHz system clock. UART3 is wired to UART4
    // (PK0 receive, PK1 transmit), and RedirectOutput() passes characters
    // between UART4 and UART0, the LaunchPad's USB serial port.

    ES_WEAK void setup_GPIO(void)
    {
        es_enable_port(1u << 0);
        GPIOA_AHB->AFSEL |= 0x30u;
        GPIOA_AHB->PCTL = (GPIOA_AHB->PCTL & ~0x00FF0000u) | 0x00110000u;
        GPIOA_AHB->DEN |= 0x30u;
    }

    ES_WEAK void setup_UART(void)
    {
        SYSCTL->RCGCUART |= 1u << 3;
        while ((SYSCTL->PRUART & (1u << 3)) == 0u) {
        }
        UART3->CTL &= ~0x01u;
        UART3->IBRD = 130u;                       // 80 MHz / (16 * 38400) = 130.208
        UART3->FBRD = 13u;                        // 0.208 * 64 = 13.3
        UART3->LCRH = 0x48u;                      // 7 bits, 2 stop bits, no FIFO
        UART3->CC = 0u;
        UART3->CTL |= 0x301u;
    }

    ES_WEAK char read_UART(void)
    {
        while ((UART3->FR & 0x10u) != 0u) {
        }
        return (char)(UART3->DR & 0x7Fu);
    }

    ES_WEAK void write_UART(char c)
    {
        while ((UART3->FR & 0x20u) != 0u) {
        }
        UART3->DR = (uint8_t)c;
    }

    ES_WEAK void banner(char str[])
    {
        const char *lines[] = { "\\r\\nGO\\r\\n", str, "\\r\\n" };
        for (int i = 0; i < 3; i++) {
            for (const char *p = lines[i]; *p != '\\0'; p++) {
                write_UART(*p);
            }
        }
    }

    static void es_forward(UART0_Type *from, UART0_Type *to)
    {
        while ((from->FR & 0x10u) == 0u) {
            uint32_t c = from->DR & 0xFFu;
            while ((to->FR & 0x20u) != 0u) {
            }
            to->DR = c;
        }
        from->ICR = 0x50u;
    }

    void UART0_Handler(void) { es_forward(UART0, UART4); }
    void UART4_Handler(void) { es_forward(UART4, UART0); }

    ES_WEAK void RedirectOutput(void)
    {
        es_serial_setup(0, "38400,7,N,2");
        es_serial_setup(4, "38400,7,N,2");
        UART0->IM |= 0x50u;                       // receive and receive time-out
        UART4->IM |= 0x50u;
        NVIC_EnableIRQ(UART0_IRQn);
        NVIC_EnableIRQ(UART4_IRQn);
        __enable_irq();
    }

    """
}
