import Foundation

/// Whether a TM4C129 peripheral's clock is on.
///
/// A peripheral whose clock is off does not refuse the debugger's reads:
/// every register reads as 0, which looks like a real value. The System
/// Control `PRxxx` (peripheral ready) registers say which peripherals are
/// on, one bit per instance, so the `Peripherals` panel can say so instead.
enum PeripheralClock {
    struct Gate: Equatable, Sendable {
        /// The `SYSCTL` register that says the peripheral is ready, such as `PRUART`.
        var readyRegister: String
        /// The instance's bit in it, and in `gateRegister`.
        var bit: Int

        /// The register the program sets to turn the clock on, such as `RCGCUART`.
        var gateRegister: String {
            "RCGC" + readyRegister.dropFirst(2)
        }
    }

    /// The GPIO ports in bit order. There is no port I or O.
    private static let portLetters = Array("ABCDEFGHJKLMNPQ")

    /// Peripheral names without their instance number, and their ready register.
    private static let readyRegisters: [(prefix: String, register: String)] = [
        ("WATCHDOG", "PRWD"), ("SSI", "PRSSI"), ("UART", "PRUART"), ("I2C", "PRI2C"),
        ("PWM", "PRPWM"), ("QEI", "PRQEI"), ("TIMER", "PRTIMER"), ("ADC", "PRADC"),
        ("COMP", "PRACMP"), ("CAN", "PRCAN"), ("USB", "PRUSB"), ("EEPROM", "PREEPROM"),
        ("EPI", "PREPI"), ("EMAC", "PREMAC"), ("UDMA", "PRDMA"), ("CCM", "PRCCM"), ("HIB", "PRHIB")
    ]

    /// The ready bit for `peripheral`, or `nil` for one that is always on
    /// (System Control, the NVIC, the flash controller).
    static func gate(for peripheral: SVDPeripheral) -> Gate? {
        let name = peripheral.name.uppercased()
        if name.hasPrefix("GPIO_PORT") {
            let letter = name.dropFirst("GPIO_PORT".count).first
            guard let letter, let bit = portLetters.firstIndex(of: letter) else { return nil }
            return Gate(readyRegister: "PRGPIO", bit: bit)
        }
        for (prefix, register) in readyRegisters where name.hasPrefix(prefix) {
            let number = name.dropFirst(prefix.count)
            if number.isEmpty { return Gate(readyRegister: register, bit: 0) }
            guard let bit = Int(number), 0..<64 ~= bit else { continue }
            return Gate(readyRegister: register, bit: bit)
        }
        return nil
    }

    /// Whether `peripheral`'s clock is on. `nil` when that cannot be told:
    /// it has no ready bit, or the bit cannot be read.
    @MainActor
    static func isOn(_ peripheral: SVDPeripheral, in device: SVDDevice, memory: some TargetMemory) async -> Bool? {
        guard let gate = gate(for: peripheral),
              0..<64 ~= gate.bit,
              let sysctl = device.peripheral(named: "SYSCTL"),
              let ready = sysctl.register(named: gate.readyRegister),
              case .value(let value) = await PeripheralAccess.read(ready, of: sysctl, from: memory)
        else { return nil }
        return value & (1 << UInt64(gate.bit)) != 0
    }

    /// What the panel says about a peripheral whose clock is off.
    static func offMessage(for peripheral: SVDPeripheral, gate: Gate) -> String {
        "\(peripheral.name)'s clock is off, so its registers read as 0. "
            + "The program turns it on with SYSCTL \(gate.gateRegister) bit \(gate.bit)."
    }
}
