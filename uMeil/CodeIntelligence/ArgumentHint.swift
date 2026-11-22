import Foundation

/// Which TivaWare macros fit the argument being typed, so they come first
/// in the completion list: `GPIO_PORTN_BASE` for `GPIOPinWrite`'s
/// `ui32Port`, `SYSCTL_PERIPH_*` for `SysCtlPeripheralEnable`'s
/// `ui32Peripheral`, `GPIO_PIN_*` for `ui8Pins`.
///
/// TivaWare passes these as plain integers, so `clangd`'s own ranking by
/// expected type cannot tell them apart; the names of the function and
/// parameter can.
struct ArgumentHint: Equatable, Sendable {
    /// A label shape that fits the argument well, such as `GPIO_PORT…_BASE`.
    struct Pattern: Equatable, Sendable {
        var prefix: String
        var suffix: String = ""

        func matches(_ label: String) -> Bool {
            label.hasPrefix(prefix) && label.hasSuffix(suffix) && label.count > prefix.count
        }
    }

    /// The best fits for the argument.
    var patterns: [Pattern]
    /// The macro prefix of the function's driverlib module, such as `TIMER_`;
    /// these come next.
    var modulePrefix: String?

    /// `0` for a strong fit, `1` for a macro from the same module, `2` otherwise.
    func tier(for label: String) -> Int {
        if patterns.contains(where: { $0.matches(label) }) { return 0 }
        if let modulePrefix, label.hasPrefix(modulePrefix) { return 1 }
        return 2
    }

    /// The hint for the argument the cursor is in, or `nil` outside a
    /// driverlib call.
    init?(signatureHelp: LSPSignatureHelp) {
        guard let signature = signatureHelp.active,
              let parameter = signatureHelp.activeParameterName,
              let function = Self.functionName(inSignature: signature.label)
        else { return nil }
        self.init(function: function, parameter: parameter)
    }

    /// The hint for `parameter` of driverlib `function`, or `nil` when
    /// `function` is not from driverlib.
    init?(function: String, parameter: String) {
        var name = function
        for wrapper in ["ROM_", "MAP_"] where name.hasPrefix(wrapper) {
            name.removeFirst(wrapper.count)
        }
        guard let module = Self.modules.first(where: { name.hasPrefix($0.function) })?.macro else { return nil }
        modulePrefix = module + "_"
        patterns = Self.patterns(forParameter: parameter.lowercased(), module: module)
    }

    /// The first rule whose word appears in the (lowercased) parameter
    /// name decides; order matters, as `ui32PinType` also contains `pin`.
    private static func patterns(forParameter parameter: String, module: String) -> [Pattern] {
        if parameter.hasSuffix("port") || parameter.hasSuffix("base") {
            return [Pattern(prefix: module == "GPIO" ? "GPIO_PORT" : module, suffix: "_BASE")]
        }
        if parameter.contains("config") {
            return configPatterns[module]
                ?? [Pattern(prefix: module + "_CONFIG_"), Pattern(prefix: module + "_CFG_")]
        }
        return wordRules.first { parameter.contains($0.word) }.map { [Pattern(prefix: $0.prefix)] } ?? []
    }

    private static let wordRules: [(word: String, prefix: String)] = [
        ("peripheral", "SYSCTL_PERIPH_"),
        ("interrupt", "INT_"),
        ("pintype", "GPIO_PIN_TYPE_"),
        ("padtype", "GPIO_PIN_TYPE_"),
        ("strength", "GPIO_STRENGTH_"),
        ("pin", "GPIO_PIN_")
    ]

    private static let configPatterns: [String: [Pattern]] = [
        "TIMER": [Pattern(prefix: "TIMER_CFG_")],
        "UART": [Pattern(prefix: "UART_CONFIG_")],
        "SYSCTL": [
            Pattern(prefix: "SYSCTL_XTAL_"), Pattern(prefix: "SYSCTL_OSC_"),
            Pattern(prefix: "SYSCTL_USE_"), Pattern(prefix: "SYSCTL_CFG_VCO_")
        ]
    ]

    /// `void GPIOPinWrite(uint32_t ui32Port, …)` → `GPIOPinWrite`.
    static func functionName(inSignature label: String) -> String? {
        guard let paren = label.firstIndex(of: "(") else { return nil }
        let head = label[..<paren].trimmingCharacters(in: .whitespaces)
        let name = head.reversed().prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return name.isEmpty ? nil : String(name.reversed())
    }

    /// Driverlib function prefixes and the prefix their macros share,
    /// longest first so `SysCtl` is not mistaken for `Sys…`.
    private static let modules: [(function: String, macro: String)] = [
        ("Comparator", "COMP"), ("Hibernate", "HIBERNATE"), ("Watchdog", "WATCHDOG"),
        ("SHAMD5", "SHAMD5"), ("OneWire", "ONEWIRE"), ("SysTick", "NVIC_ST"), ("EEPROM", "EEPROM"),
        ("SysCtl", "SYSCTL"), ("Timer", "TIMER"), ("Flash", "FLASH"), ("uDMA", "UDMA"),
        ("EMAC", "EMAC"), ("GPIO", "GPIO"), ("UART", "UART"), ("I2C", "I2C"), ("ADC", "ADC"),
        ("SSI", "SSI"), ("PWM", "PWM"), ("QEI", "QEI"), ("USB", "USB"), ("CAN", "CAN"),
        ("EPI", "EPI"), ("LCD", "LCD"), ("CRC", "CRC"), ("AES", "AES"), ("DES", "DES"), ("Int", "INT")
    ]
}
