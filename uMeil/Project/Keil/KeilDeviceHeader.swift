import Foundation

/// Writes a clean-room `TM4C129.h` register header for imported Keil projects.
///
/// Keil's course projects include `<TM4C129.h>` and access peripherals through
/// struct pointers (`SYSCTL->RCGCGPIO`, `GPION->DIR`, `GPIOF_AHB->DATA`,
/// `SysTick->CTRL`, `SCB->CPACR`). In Keil on Windows that header comes from
/// `Keil.TM4C_DFP`, which is not part of the project folder. Writing this
/// header into `uMeil/TM4C129.h` lets those projects build with the GNU
/// toolchain on macOS out of the box.
enum KeilDeviceHeader {
    static let fileName = "TM4C129.h"

    static var source: String {
        [preamble, coreRegisters, peripheralRegisters, sysctlRegisters]
            .joined(separator: "\n")
    }

    private static let preamble = """
    // Register definitions for the TM4C1294NCPDT, written by uMeil for
    // imported Keil projects.
    //
    // Addresses and register offsets follow the TM4C1294NCPDT datasheet and
    // the Cortex-M4 architecture reference manual.

    #ifndef UMEIL_TM4C129_H
    #define UMEIL_TM4C129_H

    #include <stdint.h>

    #ifdef __cplusplus
    extern "C" {
    #endif

    #define __FPU_PRESENT 1
    #define __FPU_USED    1
    #define __MPU_PRESENT 1
    #define __NVIC_PRIO_BITS 3

    #define __ASM           __asm
    #define __INLINE        inline
    #define __STATIC_INLINE static inline
    #define __I             volatile const
    #define __O             volatile
    #define __IO            volatile

    extern uint32_t SystemCoreClock;
    extern void SystemInit(void);
    extern void SystemCoreClockUpdate(void);

    typedef enum {
        NonMaskableInt_IRQn = -14, HardFault_IRQn = -13, MemoryManagement_IRQn = -12,
        BusFault_IRQn = -11, UsageFault_IRQn = -10, SVCall_IRQn = -5, DebugMonitor_IRQn = -4,
        PendSV_IRQn = -2, SysTick_IRQn = -1,
        GPIOA_IRQn = 0, GPIOB_IRQn = 1, GPIOC_IRQn = 2, GPIOD_IRQn = 3, GPIOE_IRQn = 4,
        UART0_IRQn = 5, UART1_IRQn = 6, SSI0_IRQn = 7, I2C0_IRQn = 8,
        PWM0_FAULT_IRQn = 9, PWM0_0_IRQn = 10, PWM0_1_IRQn = 11, PWM0_2_IRQn = 12,
        QEI0_IRQn = 13, ADC0SS0_IRQn = 14, ADC0SS1_IRQn = 15, ADC0SS2_IRQn = 16, ADC0SS3_IRQn = 17,
        WATCHDOG0_IRQn = 18, TIMER0A_IRQn = 19, TIMER0B_IRQn = 20, TIMER1A_IRQn = 21, TIMER1B_IRQn = 22,
        TIMER2A_IRQn = 23, TIMER2B_IRQn = 24, COMP0_IRQn = 25, COMP1_IRQn = 26, COMP2_IRQn = 27,
        SYSCTL_IRQn = 28, FLASH_CTRL_IRQn = 29, GPIOF_IRQn = 30, GPIOG_IRQn = 31, GPIOH_IRQn = 32,
        UART2_IRQn = 33, SSI1_IRQn = 34, TIMER3A_IRQn = 35, TIMER3B_IRQn = 36, I2C1_IRQn = 37,
        CAN0_IRQn = 38, CAN1_IRQn = 39, EMAC0_IRQn = 40, HIB_IRQn = 41, USB0_IRQn = 42,
        PWM0_3_IRQn = 43, UDMA_IRQn = 44, UDMAERR_IRQn = 45,
        ADC1SS0_IRQn = 46, ADC1SS1_IRQn = 47, ADC1SS2_IRQn = 48, ADC1SS3_IRQn = 49,
        EPI0_IRQn = 50, GPIOJ_IRQn = 51, GPIOK_IRQn = 52, GPIOL_IRQn = 53,
        SSI2_IRQn = 54, SSI3_IRQn = 55, UART3_IRQn = 56, UART4_IRQn = 57, UART5_IRQn = 58,
        UART6_IRQn = 59, UART7_IRQn = 60, I2C2_IRQn = 61, I2C3_IRQn = 62,
        TIMER4A_IRQn = 63, TIMER4B_IRQn = 64, TIMER5A_IRQn = 65, TIMER5B_IRQn = 66,
        SYSEXC_IRQn = 67, I2C4_IRQn = 68, I2C5_IRQn = 69, GPIOM_IRQn = 70, GPION_IRQn = 71,
        GPIOP0_IRQn = 72, TAMPER0_IRQn = 73,
        GPIOP1_IRQn = 74, GPIOP2_IRQn = 75, GPIOP3_IRQn = 76, GPIOP4_IRQn = 77,
        GPIOP5_IRQn = 78, GPIOP6_IRQn = 79, GPIOP7_IRQn = 80,
        GPIOQ0_IRQn = 81, GPIOQ1_IRQn = 82, GPIOQ2_IRQn = 83, GPIOQ3_IRQn = 84,
        GPIOQ4_IRQn = 85, GPIOQ5_IRQn = 86, GPIOQ6_IRQn = 87, GPIOQ7_IRQn = 88,
        TIMER6A_IRQn = 98, TIMER6B_IRQn = 99, TIMER7A_IRQn = 100, TIMER7B_IRQn = 101
    } IRQn_Type;
    """

    private static let coreRegisters = """
    typedef struct {
        volatile uint32_t CTRL, LOAD, VAL;
        volatile const uint32_t CALIB;
    } SysTick_Type;

    typedef struct {
        volatile uint32_t ISER[8], RESERVED0[24], ICER[8], RESERVED1[24];
        volatile uint32_t ISPR[8], RESERVED2[24], ICPR[8], RESERVED3[24];
        volatile uint32_t IABR[8], RESERVED4[56];
        volatile uint8_t  IP[240];
        uint32_t RESERVED5[644];
        volatile uint32_t STIR;
    } NVIC_Type;

    typedef struct {
        volatile const uint32_t CPUID;
        volatile uint32_t ICSR, VTOR, AIRCR, SCR, CCR;
        volatile uint8_t  SHP[12];
        volatile uint32_t SHCSR, CFSR, HFSR, DFSR, MMFAR, BFAR, AFSR;
        volatile const uint32_t PFR[2], DFR, ADR, MMFR[4], ISAR[5];
        uint32_t RESERVED0[5];
        volatile uint32_t CPACR;
    } SCB_Type;

    #define SCB_CCR_UNALIGN_TRP_Pos 3U
    #define SCB_CCR_UNALIGN_TRP_Msk (1UL << SCB_CCR_UNALIGN_TRP_Pos)

    #define SysTick ((SysTick_Type *)0xE000E010UL)
    #define NVIC    ((NVIC_Type *)0xE000E100UL)
    #define SCB     ((SCB_Type *)0xE000ED00UL)

    static inline void __enable_irq(void)  { __asm volatile ("cpsie i" : : : "memory"); }
    static inline void __disable_irq(void) { __asm volatile ("cpsid i" : : : "memory"); }
    static inline void __NOP(void)         { __asm volatile ("nop"); }
    static inline void __WFI(void)         { __asm volatile ("wfi"); }
    static inline void __WFE(void)         { __asm volatile ("wfe"); }
    static inline void __DSB(void)         { __asm volatile ("dsb 0xF" : : : "memory"); }
    static inline void __ISB(void)         { __asm volatile ("isb 0xF" : : : "memory"); }

    static inline void NVIC_EnableIRQ(IRQn_Type irq) {
        if ((int32_t)irq >= 0) { NVIC->ISER[(uint32_t)irq >> 5U] = 1UL << ((uint32_t)irq & 0x1FU); }
    }
    static inline void NVIC_DisableIRQ(IRQn_Type irq) {
        if ((int32_t)irq >= 0) { NVIC->ICER[(uint32_t)irq >> 5U] = 1UL << ((uint32_t)irq & 0x1FU); }
    }
    static inline void NVIC_ClearPendingIRQ(IRQn_Type irq) {
        if ((int32_t)irq >= 0) { NVIC->ICPR[(uint32_t)irq >> 5U] = 1UL << ((uint32_t)irq & 0x1FU); }
    }
    static inline void NVIC_SetPriority(IRQn_Type irq, uint32_t priority) {
        uint8_t shifted = (uint8_t)((priority << (8U - __NVIC_PRIO_BITS)) & 0xFFUL);
        if ((int32_t)irq >= 0) { NVIC->IP[(uint32_t)irq] = shifted; }
        else { SCB->SHP[(((uint32_t)irq) & 0xFUL) - 4UL] = shifted; }
    }
    """
}

extension KeilDeviceHeader {
    fileprivate static let peripheralRegisters = """
    typedef struct {
        volatile uint32_t DATA_BITS[255], DATA, DIR, IS, IBE, IEV, IM, RIS, MIS, ICR, AFSEL;
        uint32_t RESERVED1[55];
        volatile uint32_t DR2R, DR4R, DR8R, ODR, PUR, PDR, SLR, DEN, LOCK, CR, AMSEL, PCTL, ADCCTL, DMACTL, SI;
        volatile uint32_t DR12R, WAKEPEN, WAKELVL, WAKESTAT;
        uint32_t RESERVED2[669];
        volatile uint32_t PP, PC;
    } GPIOA_Type;

    typedef GPIOA_Type GPIOA_AHB_Type;

    typedef struct {
        volatile uint32_t DR;
        union { volatile uint32_t ECR; volatile uint32_t RSR; };
        uint32_t RESERVED0[4];
        volatile uint32_t FR, RESERVED1, ILPR, IBRD, FBRD, LCRH, CTL, IFLS, IM, RIS, MIS, ICR, DMACTL;
        uint32_t RESERVED2[22];
        volatile uint32_t _9BITADDR, _9BITAMASK;
        uint32_t RESERVED3[965];
        volatile uint32_t PP, RESERVED4, CC;
    } UART0_Type;

    typedef struct {
        volatile uint32_t CFG, TAMR, TBMR, CTL, SYNC, RESERVED0, IMR, RIS, MIS, ICR, TAILR, TBILR;
        volatile uint32_t TAMATCHR, TBMATCHR, TAPR, TBPR, TAPMR, TBPMR, TAR, TBR, TAV, TBV, RTCPD, TAPS, TBPS;
        uint32_t RESERVED1[2];
        volatile uint32_t DMAEV, ADCEV;
        uint32_t RESERVED2[979];
        volatile uint32_t PP, RESERVED3, CC;
    } TIMER0_Type;

    typedef struct {
        volatile uint32_t ACTSS, RIS, IM, ISC, OSTAT, EMUX, USTAT, TSSEL, SSPRI, SPC, PSSI, RESERVED0, SAC, DCISC, CTL;
        uint32_t RESERVED1;
        volatile uint32_t SSMUX0, SSCTL0, SSFIFO0, SSFSTAT0, SSOP0, SSDC0, SSEMUX0, SSTSH0;
        volatile uint32_t SSMUX1, SSCTL1, SSFIFO1, SSFSTAT1, SSOP1, SSDC1, SSEMUX1, SSTSH1;
        volatile uint32_t SSMUX2, SSCTL2, SSFIFO2, SSFSTAT2, SSOP2, SSDC2, SSEMUX2, SSTSH2;
        volatile uint32_t SSMUX3, SSCTL3, SSFIFO3, SSFSTAT3, SSOP3, SSDC3, SSEMUX3, SSTSH3;
        uint32_t RESERVED2[784];
        volatile uint32_t DCRIC, RESERVED3[63];
        volatile uint32_t DCCTL0, DCCTL1, DCCTL2, DCCTL3, DCCTL4, DCCTL5, DCCTL6, DCCTL7, RESERVED4[8];
        volatile uint32_t DCCMP0, DCCMP1, DCCMP2, DCCMP3, DCCMP4, DCCMP5, DCCMP6, DCCMP7, RESERVED5[88];
        volatile uint32_t PP, PC, CC;
    } ADC0_Type;

    // As in Keil's TM4C129.h, ports A to J are only named with the _AHB
    // suffix (their fast, AHB aperture). Ports K to Q have no suffix.
    #define GPIOA_AHB ((GPIOA_Type *)0x40058000UL)
    #define GPIOB_AHB ((GPIOA_Type *)0x40059000UL)
    #define GPIOC_AHB ((GPIOA_Type *)0x4005A000UL)
    #define GPIOD_AHB ((GPIOA_Type *)0x4005B000UL)
    #define GPIOE_AHB ((GPIOA_Type *)0x4005C000UL)
    #define GPIOF_AHB ((GPIOA_Type *)0x4005D000UL)
    #define GPIOG_AHB ((GPIOA_Type *)0x4005E000UL)
    #define GPIOH_AHB ((GPIOA_Type *)0x4005F000UL)
    #define GPIOJ_AHB ((GPIOA_Type *)0x40060000UL)
    #define GPIOK     ((GPIOA_Type *)0x40061000UL)
    #define GPIOL     ((GPIOA_Type *)0x40062000UL)
    #define GPIOM     ((GPIOA_Type *)0x40063000UL)
    #define GPION     ((GPIOA_Type *)0x40064000UL)
    #define GPIOP     ((GPIOA_Type *)0x40065000UL)
    #define GPIOQ     ((GPIOA_Type *)0x40066000UL)
    #define UART0     ((UART0_Type *)0x4000C000UL)
    #define UART1     ((UART0_Type *)0x4000D000UL)
    #define UART2     ((UART0_Type *)0x4000E000UL)
    #define UART3     ((UART0_Type *)0x4000F000UL)
    #define UART4     ((UART0_Type *)0x40010000UL)
    #define UART5     ((UART0_Type *)0x40011000UL)
    #define UART6     ((UART0_Type *)0x40012000UL)
    #define UART7     ((UART0_Type *)0x40013000UL)
    #define TIMER0    ((TIMER0_Type *)0x40030000UL)
    #define TIMER1    ((TIMER0_Type *)0x40031000UL)
    #define TIMER2    ((TIMER0_Type *)0x40032000UL)
    #define TIMER3    ((TIMER0_Type *)0x40033000UL)
    #define TIMER4    ((TIMER0_Type *)0x40034000UL)
    #define TIMER5    ((TIMER0_Type *)0x40035000UL)
    #define TIMER6    ((TIMER0_Type *)0x400E0000UL)
    #define TIMER7    ((TIMER0_Type *)0x400E1000UL)
    #define ADC0      ((ADC0_Type *)0x40038000UL)
    #define ADC1      ((ADC0_Type *)0x40039000UL)
    """

    fileprivate static let sysctlRegisters = """
    typedef struct {
        volatile uint32_t DID0, DID1, RESERVED0[12], PTBOCTL, RESERVED1[5];
        volatile uint32_t RIS, IMC, MISC, RESC, PWRTC, NMIC, RESERVED2[5], MOSCCTL, RESERVED3[12];
        volatile uint32_t RSCLKCFG, RESERVED4[3], MEMTIM0, RESERVED5[29], ALTCLKCFG, RESERVED6[2];
        volatile uint32_t DSCLKCFG, DIVSCLK, SYSPROP, PIOSCCAL, PIOSCSTAT, RESERVED7[2];
        volatile uint32_t PLLFREQ0, PLLFREQ1, PLLSTAT, RESERVED8[7], SLPPWRCFG, DSLPPWRCFG;
        volatile uint32_t RESERVED9[4], NVMSTAT, RESERVED10[4], LDOSPCTL, RESERVED11, LDODPCTL;
        volatile uint32_t RESERVED12[6], RESBEHAVCTL, RESERVED13[6], HSSR, RESERVED14[34];
        volatile uint32_t USBPDS, USBMPC, EMACPDS, EMACMPC, RESERVED15[28];
        volatile uint32_t PPWD, PPTIMER, PPGPIO, PPDMA, PPEPI, PPHIB, PPUART, PPSSI, PPI2C, RESERVED16;
        volatile uint32_t PPUSB, RESERVED17, PPEPHY, PPCAN, PPADC, PPACMP, PPPWM, PPQEI, PPLPC, RESERVED18;
        volatile uint32_t PPPECI, PPFAN, PPEEPROM, PPWTIMER, RESERVED19[4], PPRTS, PPCCM, RESERVED20[6];
        volatile uint32_t PPLCD, RESERVED21, PPOWIRE, PPEMAC, RESERVED22, PPHIM, RESERVED23[86];
        volatile uint32_t SRWD, SRTIMER, SRGPIO, SRDMA, SREPI, SRHIB, SRUART, SRSSI, SRI2C, RESERVED24;
        volatile uint32_t SRUSB, RESERVED25, SREPHY, SRCAN, SRADC, SRACMP, SRPWM, SRQEI, RESERVED26[4];
        volatile uint32_t SREEPROM, RESERVED27[6], SRCCM, RESERVED28[9], SREMAC, RESERVED29[24];
        volatile uint32_t RCGCWD, RCGCTIMER, RCGCGPIO, RCGCDMA, RCGCEPI, RCGCHIB, RCGCUART, RCGCSSI, RCGCI2C;
        volatile uint32_t RESERVED30, RCGCUSB, RESERVED31, RCGCEPHY, RCGCCAN, RCGCADC, RCGCACMP, RCGCPWM, RCGCQEI;
        volatile uint32_t RESERVED32[4], RCGCEEPROM, RESERVED33[6], RCGCCCM, RESERVED34[9], RCGCEMAC, RESERVED35[24];
        volatile uint32_t SCGCWD, SCGCTIMER, SCGCGPIO, SCGCDMA, SCGCEPI, SCGCHIB, SCGCUART, SCGCSSI, SCGCI2C;
        volatile uint32_t RESERVED36, SCGCUSB, RESERVED37, SCGCEPHY, SCGCCAN, SCGCADC, SCGCACMP, SCGCPWM, SCGCQEI;
        volatile uint32_t RESERVED38[4], SCGCEEPROM, RESERVED39[6], SCGCCCM, RESERVED40[9], SCGCEMAC, RESERVED41[24];
        volatile uint32_t DCGCWD, DCGCTIMER, DCGCGPIO, DCGCDMA, DCGCEPI, DCGCHIB, DCGCUART, DCGCSSI, DCGCI2C;
        volatile uint32_t RESERVED42, DCGCUSB, RESERVED43, DCGCEPHY, DCGCCAN, DCGCADC, DCGCACMP, DCGCPWM, DCGCQEI;
        volatile uint32_t RESERVED44[4], DCGCEEPROM, RESERVED45[6], DCGCCCM, RESERVED46[9], DCGCEMAC, RESERVED47[24];
        volatile uint32_t PCWD, PCTIMER, PCGPIO, PCDMA, PCEPI, PCHIB, PCUART, PCSSI, PCI2C;
        volatile uint32_t RESERVED48, PCUSB, RESERVED49, PCEPHY, PCCAN, PCADC, PCACMP, PCPWM, PCQEI;
        volatile uint32_t RESERVED50[4], PCEEPROM, RESERVED51[6], PCCCM, RESERVED52[9], PCEMAC, RESERVED53[24];
        volatile uint32_t PRWD, PRTIMER, PRGPIO, PRDMA, PREPI, PRHIB, PRUART, PRSSI, PRI2C;
        volatile uint32_t RESERVED54, PRUSB, RESERVED55, PREPHY, PRCAN, PRADC, PRACMP, PRPWM, PRQEI;
        volatile uint32_t RESERVED56[4], PREEPROM, RESERVED57[6], PRCCM, RESERVED58[9], PREMAC;
    } SYSCTL_Type;

    #define SYSCTL ((SYSCTL_Type *)0x400FE000UL)

    #ifdef __cplusplus
    }
    #endif

    #endif /* UMEIL_TM4C129_H */
    """
}
