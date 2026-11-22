import Foundation
import Testing
@testable import uMeil

struct ArgumentHintTests {
    private func macro(_ name: String, sortText: String = "5") -> LSPCompletionItem {
        LSPCompletionItem(label: " " + name, kind: .text, insertText: name, filterText: name, sortText: sortText)
    }

    @Test func picksMacrosThatFitEachTivaWareArgument() throws {
        let port = try #require(ArgumentHint(function: "GPIOPinWrite", parameter: "ui32Port"))
        #expect(port.tier(for: "GPIO_PORTN_BASE") == 0)
        #expect(port.tier(for: "GPIO_PIN_1") == 1)
        #expect(port.tier(for: "UART0_BASE") == 2)

        let pins = try #require(ArgumentHint(function: "ROM_GPIOPinWrite", parameter: "ui8Pins"))
        #expect(pins.tier(for: "GPIO_PIN_1") == 0)
        #expect(pins.tier(for: "GPIO_PORTN_BASE") == 1)

        let peripheral = try #require(ArgumentHint(function: "SysCtlPeripheralEnable", parameter: "ui32Peripheral"))
        #expect(peripheral.tier(for: "SYSCTL_PERIPH_GPION") == 0)
        #expect(peripheral.tier(for: "SYSCTL_XTAL_25MHZ") == 1)

        let clock = try #require(ArgumentHint(function: "SysCtlClockFreqSet", parameter: "ui32Config"))
        #expect(clock.tier(for: "SYSCTL_XTAL_25MHZ") == 0)
        #expect(clock.tier(for: "SYSCTL_PERIPH_GPION") == 1)

        let timer = try #require(ArgumentHint(function: "TimerConfigure", parameter: "ui32Base"))
        #expect(timer.tier(for: "TIMER0_BASE") == 0)
        #expect(timer.tier(for: "GPIO_PORTN_BASE") == 2)

        let padType = try #require(ArgumentHint(function: "GPIOPadConfigSet", parameter: "ui32PinType"))
        #expect(padType.tier(for: "GPIO_PIN_TYPE_STD_WPU") == 0)

        let interrupt = try #require(ArgumentHint(function: "IntEnable", parameter: "ui32Interrupt"))
        #expect(interrupt.tier(for: "INT_GPION") == 0)
    }

    @Test func ignoresFunctionsOutsideDriverLib() {
        #expect(ArgumentHint(function: "blink", parameter: "count") == nil)
        #expect(ArgumentHint(function: "printf", parameter: "format") == nil)
    }

    @Test func readsTheFunctionAndArgumentFromSignatureHelp() throws {
        let label = "void GPIOPinWrite(uint32_t ui32Port, uint8_t ui8Pins, uint8_t ui8Val)"
        #expect(ArgumentHint.functionName(inSignature: label) == "GPIOPinWrite")
        #expect(ArgumentHint.functionName(inSignature: "no call here") == nil)

        let help = LSPSignatureHelp(
            signatures: [LSPSignatureHelp.Signature(label: label, parameters: [
                .init(label: .offsets(18, 35)), .init(label: .offsets(37, 52)), .init(label: .offsets(54, 68))
            ])],
            activeParameter: 1
        )
        #expect(ArgumentHint(signatureHelp: help) == ArgumentHint(function: "GPIOPinWrite", parameter: "ui8Pins"))
    }

    @Test func listsWhatFitsTheArgumentFirstThenFollowsClangdsOrder() throws {
        let items = [
            macro("GPIO_PORTN_BASE", sortText: "1"),
            macro("GPIO_PIN_1", sortText: "3"),
            macro("GPIO_PIN_0", sortText: "2"),
            macro("GPIO_FALLING_EDGE", sortText: "0"),
            macro("SYSCTL_PERIPH_GPION", sortText: "0")
        ]
        let pins = try #require(ArgumentHint(function: "GPIOPinWrite", parameter: "ui8Pins"))

        let ranked = CompletionPanelController.filterAndRank(items, prefix: "GPIO", hint: pins)
        // SYSCTL_PERIPH_GPION only contains "GPIO", so it stays after every prefix match.
        #expect(ranked.map(\.filterKey)
            == ["GPIO_PIN_0", "GPIO_PIN_1", "GPIO_FALLING_EDGE", "GPIO_PORTN_BASE", "SYSCTL_PERIPH_GPION"])

        let unhinted = CompletionPanelController.filterAndRank(items, prefix: "")
        #expect(unhinted.map(\.filterKey).prefix(2) == ["GPIO_FALLING_EDGE", "SYSCTL_PERIPH_GPION"])
    }
}
