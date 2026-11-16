import Foundation
@testable import uMeil

/// A small Keil µVision project on disk, shaped like the course's lab
/// projects: one C file, a header, a prebuilt library, and the startup and
/// system files Keil copies in from its device pack.
enum KeilFixture {
    /// The message the fixture's firmware sends over UART0, ten times a second.
    static let defaultMessage = "uMeil Keil import"

    /// Writes the project into `folder` and returns its `.uvprojx` file.
    @discardableResult
    static func make(
        in folder: URL,
        device: String = "TM4C1294NCPDT",
        message: String = defaultMessage
    ) throws -> URL {
        let files: [String: String] = [
            "Template.uvprojx": projectFile(device: device),
            "main.c": mainSource(message: message),
            "Lib4.h": "#ifndef ES_LIB_H\n#define ES_LIB_H\nextern void msDelay(int msec);\n#endif\n",
            "Lib4.lib": "!<arch>\nnot a library the GNU linker can read\n",
            "RTE/_Target_1/RTE_Components.h": "#define CMSIS_device_header \"TM4C129.h\"\n",
            "RTE/Device/TM4C1294NCPDT/startup_TM4C129.s": keilStartup,
            "RTE/Device/TM4C1294NCPDT/system_TM4C129.c": systemSource
        ]
        for (path, text) in files {
            let url = folder.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Keil writes Windows line endings.
            try text.replacing("\n", with: "\r\n").write(to: url, atomically: true, encoding: .utf8)
        }
        return folder.appending(path: "Template.uvprojx")
    }

    static func projectFile(device: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="no" ?>
        <Project xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="project_projx.xsd">
          <SchemaVersion>2.1</SchemaVersion>
          <Targets>
            <Target>
              <TargetName>Target 1</TargetName>
              <uAC6>1</uAC6>
              <TargetOption>
                <TargetCommonOption>
                  <Device>\(device)</Device>
                  <Vendor>Texas Instruments</Vendor>
                  <OutputName>Template</OutputName>
                </TargetCommonOption>
                <TargetArmAds>
                  <Cads>
                    <Optim>1</Optim>
                    <v6Lang>5</v6Lang>
                    <VariousControls>
                      <MiscControls></MiscControls>
                      <Define>LAB=4, USE_SERIAL</Define>
                      <Undefine></Undefine>
                      <IncludePath>.\\inc;C:\\Course\\Common</IncludePath>
                    </VariousControls>
                  </Cads>
                  <Aads>
                    <VariousControls>
                      <Define>ASM_ONLY</Define>
                      <IncludePath>.\\asm</IncludePath>
                    </VariousControls>
                  </Aads>
                </TargetArmAds>
              </TargetOption>
        \(projectGroupsAndRTE)
        """
    }

    private static let projectGroupsAndRTE = """
              <Groups>
                <Group>
                  <GroupName>Source Group 1</GroupName>
                  <Files>
                    <File>
                      <FileName>main.c</FileName>
                      <FileType>1</FileType>
                      <FilePath>.\\main.c</FilePath>
                    </File>
                    <File>
                      <FileName>Lib4.h</FileName>
                      <FileType>5</FileType>
                      <FilePath>.\\Lib4.h</FilePath>
                    </File>
                    <File>
                      <FileName>Lib4.lib</FileName>
                      <FileType>4</FileType>
                      <FilePath>.\\Lib4.lib</FilePath>
                    </File>
                    <File>
                      <FileName>old.c</FileName>
                      <FileType>1</FileType>
                      <FilePath>.\\old.c</FilePath>
                      <FileOption>
                        <CommonProperty>
                          <IncludeInBuild>0</IncludeInBuild>
                        </CommonProperty>
                      </FileOption>
                    </File>
                  </Files>
                </Group>
                <Group>
                  <GroupName>::Device</GroupName>
                </Group>
              </Groups>
            </Target>
          </Targets>
          <RTE>
            <files>
              <file attr="config" category="source" name="Device\\Source\\ARM\\startup_TM4C129.s" version="1.0.0">
                <instance index="0">RTE\\Device\\TM4C1294NCPDT\\startup_TM4C129.s</instance>
              </file>
              <file attr="config" category="source" name="Device\\Source\\system_TM4C129.c" version="1.0.0">
                <instance index="0">RTE\\Device\\TM4C1294NCPDT\\system_TM4C129.c</instance>
              </file>
            </files>
          </RTE>
        </Project>
        """

    /// The top of Keil's startup file for the TM4C129, cut down to the
    /// Cortex-M4 exceptions and three interrupts.
    static let keilStartup = """
        ; <h> Stack Configuration
        Stack_Size      EQU     0x00000200

                        AREA    STACK, NOINIT, READWRITE, ALIGN=3
        Stack_Mem       SPACE   Stack_Size
        __initial_sp

                        PRESERVE8
                        THUMB

        ; Vector Table Mapped to Address 0 at Reset

                        AREA    RESET, DATA, READONLY
                        EXPORT  __Vectors
                        EXPORT  __Vectors_End

        __Vectors       DCD     __initial_sp              ; Top of Stack
                        DCD     Reset_Handler             ; Reset Handler
                        DCD     NMI_Handler               ; NMI Handler
                        DCD     HardFault_Handler         ; Hard Fault Handler
                        DCD     MemManage_Handler         ; MPU Fault Handler
                        DCD     BusFault_Handler          ; Bus Fault Handler
                        DCD     UsageFault_Handler        ; Usage Fault Handler
                        DCD     0                         ; Reserved
                        DCD     0                         ; Reserved
                        DCD     0                         ; Reserved
                        DCD     0                         ; Reserved
                        DCD     SVC_Handler               ; SVCall Handler
                        DCD     DebugMon_Handler          ; Debug Monitor Handler
                        DCD     0                         ; Reserved
                        DCD     PendSV_Handler            ; PendSV Handler
                        DCD     SysTick_Handler           ; SysTick Handler

                        ; External Interrupts

                        DCD     GPIOA_Handler             ;   0: GPIO Port A
                        DCD     GPIOB_Handler             ;   1: GPIO Port B
                        DCD     0                         ;   2: Reserved
                        DCD     UART0_Handler             ;   3: UART0 Rx and Tx
        __Vectors_End

        __Vectors_Size  EQU     __Vectors_End - __Vectors

                        AREA    |.text|, CODE, READONLY

        Reset_Handler   PROC
                        EXPORT  Reset_Handler             [WEAK]
                        IMPORT  SystemInit
                        IMPORT  __main
                        LDR     R0, =SystemInit
                        BLX     R0
                        LDR     R0, =__main
                        BX      R0
                        ENDP

                        END

        """

    static let systemSource = """
        #include <stdint.h>

        uint32_t SystemCoreClock;

        void SystemInit(void)
        {
            SystemCoreClock = 16000000ul;
        }

        """
}

extension KeilFixture {
    /// Firmware that only talks when its `SysTick_Handler` is being called
    /// and `SystemInit` has run, so a message on the serial port proves the
    /// imported startup file wired both up. It uses register addresses
    /// directly, because Keil's register header is not part of the fixture.
    static func mainSource(message: String) -> String {
        """
        \(uartRegistersAndSetup)
        static const char message[] = "\(message)\\r\\n";
        static volatile uint32_t ticks;

        void SysTick_Handler(void)
        {
            ticks++;
        }

        int main(void)
        {
            startUART0();

            // An interrupt every 100 ms, as long as SystemInit set the clock.
            SYSTICK_CTRL = 0;
            SYSTICK_LOAD = SystemCoreClock / 10 - 1;
            SYSTICK_VAL = 0;
            SYSTICK_CTRL = 7;

            uint32_t sent = 0;
            while (true) {
                if (ticks != sent) {
                    sent = ticks;
                    for (const char *next = message; *next != 0; next++) {
                        while ((UART0_FR & 0x20) != 0) {
                        }
                        UART0_DR = (uint32_t)*next;
                    }
                }
            }
        }

        """
    }

    private static let uartRegistersAndSetup = """
        #include <stdbool.h>
        #include <stdint.h>

        #include "Lib4.h"

        #define REGISTER(address) (*(volatile uint32_t *)(address))

        #define SYSCTL_RCGCGPIO REGISTER(0x400FE608)
        #define SYSCTL_RCGCUART REGISTER(0x400FE618)
        #define SYSCTL_PRGPIO   REGISTER(0x400FEA08)
        #define SYSCTL_PRUART   REGISTER(0x400FEA18)
        #define GPIOA_AFSEL     REGISTER(0x40058420)
        #define GPIOA_DEN       REGISTER(0x4005851C)
        #define GPIOA_PCTL      REGISTER(0x4005852C)
        #define UART0_DR        REGISTER(0x4000C000)
        #define UART0_FR        REGISTER(0x4000C018)
        #define UART0_IBRD      REGISTER(0x4000C024)
        #define UART0_FBRD      REGISTER(0x4000C028)
        #define UART0_LCRH      REGISTER(0x4000C02C)
        #define UART0_CTL       REGISTER(0x4000C030)
        #define UART0_CC        REGISTER(0x4000CFC8)
        #define SYSTICK_CTRL    REGISTER(0xE000E010)
        #define SYSTICK_LOAD    REGISTER(0xE000E014)
        #define SYSTICK_VAL     REGISTER(0xE000E018)

        extern uint32_t SystemCoreClock;

        static void startUART0(void)
        {
            SYSCTL_RCGCGPIO |= 1u << 0;
            SYSCTL_RCGCUART |= 1u << 0;
            while ((SYSCTL_PRGPIO & 1u) == 0 || (SYSCTL_PRUART & 1u) == 0) {
            }
            GPIOA_AFSEL |= 0x3;
            GPIOA_PCTL = (GPIOA_PCTL & ~0xFFu) | 0x11;
            GPIOA_DEN |= 0x3;

            UART0_CTL = 0;
            UART0_CC = 0x5;    // Clocked by the 16 MHz internal oscillator.
            UART0_IBRD = 8;    // 115200 baud
            UART0_FBRD = 44;
            UART0_LCRH = 0x70; // 8 data bits, no parity, 1 stop bit
            UART0_CTL = 0x301;
        }
        """
}
