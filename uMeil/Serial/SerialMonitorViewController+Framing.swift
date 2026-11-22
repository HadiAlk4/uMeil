import AppKit

// The data bits, parity and stop bits menus beside the speed menu.
extension SerialMonitorViewController {
    /// The framing chosen in the menus.
    var framing: SerialFraming {
        get {
            SerialFraming(
                dataBits: dataBitsPopUp.selectedTag(),
                parity: (parityPopUp.selectedItem?.representedObject as? String)
                    .flatMap(SerialFraming.Parity.init(rawValue:)) ?? .none,
                stopBits: stopBitsPopUp.selectedTag()
            )
        }
        set {
            dataBitsPopUp.selectItem(withTag: newValue.dataBits)
            parityPopUp.selectItem(at: SerialFraming.Parity.allCases.firstIndex(of: newValue.parity) ?? 0)
            stopBitsPopUp.selectItem(withTag: newValue.stopBits)
        }
    }

    /// Fills the framing menus and selects what was chosen last time.
    func setUpFramingMenus() {
        for bits in SerialFraming.dataBitChoices {
            dataBitsPopUp.addItem(withTitle: "\(bits) Data Bits")
            dataBitsPopUp.lastItem?.tag = bits
        }
        for parity in SerialFraming.Parity.allCases {
            parityPopUp.addItem(withTitle: parity.title)
            parityPopUp.lastItem?.representedObject = parity.rawValue
        }
        for bits in SerialFraming.stopBitChoices {
            stopBitsPopUp.addItem(withTitle: bits == 1 ? "1 Stop Bit" : "\(bits) Stop Bits")
            stopBitsPopUp.lastItem?.tag = bits
        }
        dataBitsPopUp.toolTip = "Data bits. Most firmware uses 8."
        parityPopUp.toolTip = "Parity. Most firmware uses none."
        stopBitsPopUp.toolTip = "Stop bits. Most firmware uses 1."
        framing = savedFraming
    }

    /// The framing remembered from last time, or 8N1.
    private var savedFraming: SerialFraming {
        let standard = SerialFraming.standard
        let dataBits = defaults.object(forKey: DefaultsKey.dataBits) as? Int ?? standard.dataBits
        let stopBits = defaults.object(forKey: DefaultsKey.stopBits) as? Int ?? standard.stopBits
        let parity = defaults.string(forKey: DefaultsKey.parity).flatMap(SerialFraming.Parity.init(rawValue:))
        return SerialFraming(dataBits: dataBits, parity: parity ?? standard.parity, stopBits: stopBits)
    }

    func remember(_ framing: SerialFraming) {
        defaults.set(framing.dataBits, forKey: DefaultsKey.dataBits)
        defaults.set(framing.parity.rawValue, forKey: DefaultsKey.parity)
        defaults.set(framing.stopBits, forKey: DefaultsKey.stopBits)
    }
}
