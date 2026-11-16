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
            "Lib4.h": libraryHeader,
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

    static let libraryHeader = """
        #ifndef ES_LIB_H
        #define ES_LIB_H

        #include "TM4C129.h"
        #include <stdint.h>
        #include <stdlib.h>
        #include <stdbool.h>
        #include <string.h>

        extern void ES_Serial(int number, char line_format[20]);
        extern char ES_getchar(int number);
        extern void ES_putchar(int number, char c);
        extern void ES_printf(const char *format, ...);
        extern int readDec(void);
        extern void msDelay(int msec);

        #endif
        """

    static let systemSource = """
        #include <stdint.h>
        #include "TM4C129.h"

        uint32_t SystemCoreClock = 16000000ul;

        void SystemInit(void)
        {
        #if (__FPU_USED == 1)
            SCB->CPACR |= ((3UL << 10*2) | (3UL << 11*2));
        #endif
            SystemCoreClock = 16000000ul;
        }

        """
}

extension KeilFixture {
    /// Firmware shaped like `L4Q1`: includes `<TM4C129.h>` and `"Lib4.h"`,
    /// configures `GPION` and `SysTick` through the CMSIS register structs,
    /// and prints `message` over UART0 with `ES_Serial` and `ES_printf`.
    static func mainSource(message: String) -> String {
        """
        #include <TM4C129.h>
        #include <stdbool.h>
        #include <stdint.h>
        #include <stdlib.h>

        #include "Lib4.h"

        static volatile uint32_t ticks;

        void SysTick_Handler(void)
        {
            ticks++;
        }

        int main(void)
        {
            ES_Serial(0, "115200,8,N,1");

            SYSCTL->RCGCGPIO |= (1u << 12);
            while ((SYSCTL->PRGPIO & (1u << 12)) == 0u) {
            }
            GPION->DIR |= (1u << 0);
            GPION->DEN |= (1u << 0);
            GPION->AFSEL &= ~(1u << 0);

            SysTick->CTRL = 0;
            SysTick->LOAD = SystemCoreClock / 10 - 1;
            SysTick->VAL  = 0;
            SysTick->CTRL = 7;

            uint32_t sent = 0;
            while (true) {
                if (ticks != sent) {
                    sent = ticks;
                    ES_printf("\(message)\\n");
                }
            }
        }

        """
    }
}
