import Foundation

/// Reads CMSIS-SVD files: the part of the format the peripheral view needs.
///
/// Handles inherited `size`, `access` and `resetValue`, peripherals
/// `derivedFrom` another, `cluster`s, `dim` arrays (`GPIO%s`, `DATA[%s]`),
/// and all three ways of giving a field's bits (`bitOffset`/`bitWidth`,
/// `lsb`/`msb`, `bitRange`).
enum SVDParser {
    enum Failure: Error, Equatable, LocalizedError {
        case notSVD
        case unknownBase(peripheral: String, derivedFrom: String)

        var errorDescription: String? {
            switch self {
            case .notSVD:
                "The file is not a CMSIS-SVD device description."
            case let .unknownBase(peripheral, base):
                "Peripheral \(peripheral) is derived from \(base), which the file does not describe."
            }
        }
    }

    /// What a register inherits from the elements around it.
    private struct Defaults {
        var size = 32
        var access = SVDAccess.readWrite
        var resetValue: UInt64?

        func reading(_ element: XMLElement) -> Defaults {
            var copy = self
            if let size = element.childText("size").flatMap(SVDParser.number) {
                copy.size = Int(size)
            }
            if let access = element.childText("access").flatMap(SVDAccess.init(rawValue:)) {
                copy.access = access
            }
            if let reset = element.childText("resetValue").flatMap(SVDParser.number) {
                copy.resetValue = reset
            }
            return copy
        }
    }

    static func parse(contentsOf url: URL) throws -> SVDDevice {
        try parse(Data(contentsOf: url))
    }

    static func parse(_ data: Data) throws -> SVDDevice {
        let document = try XMLDocument(data: data)
        guard let root = document.rootElement(), root.name == "device" else { throw Failure.notSVD }
        let defaults = Defaults().reading(root)

        var parsed: [SVDPeripheral] = []
        var byName: [String: SVDPeripheral] = [:]
        for element in root.child("peripherals")?.children(named: "peripheral") ?? [] {
            for peripheral in try Self.peripherals(from: element, defaults: defaults, derivedFrom: byName) {
                parsed.append(peripheral)
                byName[peripheral.name] = peripheral
            }
        }
        return SVDDevice(name: root.childText("name") ?? "", peripherals: parsed)
    }

    // MARK: - Peripherals

    private static func peripherals(
        from element: XMLElement,
        defaults: Defaults,
        derivedFrom known: [String: SVDPeripheral]
    ) throws -> [SVDPeripheral] {
        let name = element.childText("name") ?? ""
        var base: SVDPeripheral?
        if let baseName = element.attribute(forName: "derivedFrom")?.stringValue {
            guard let found = known[baseName] else {
                throw Failure.unknownBase(peripheral: name, derivedFrom: baseName)
            }
            base = found
        }

        let defaults = defaults.reading(element)
        let registers: [SVDRegister]
        if let block = element.child("registers") {
            registers = Self.registers(in: block, defaults: defaults, offset: 0, prefix: "")
                .sorted { $0.addressOffset < $1.addressOffset }
        } else {
            registers = base?.registers ?? []
        }
        let address = element.childText("baseAddress").flatMap(number) ?? base?.baseAddress ?? 0
        let template = SVDPeripheral(
            name: name,
            description: element.childText("description") ?? base?.description,
            groupName: element.childText("groupName") ?? base?.groupName,
            baseAddress: address,
            registers: registers
        )

        return expand(element).map { index, step in
            var copy = template
            copy.name = substitute(name, index)
            copy.baseAddress = address + step
            return copy
        }
    }

    // MARK: - Registers

    private static func registers(
        in parent: XMLElement,
        defaults: Defaults,
        offset: UInt64,
        prefix: String
    ) -> [SVDRegister] {
        var result: [SVDRegister] = []
        for child in parent.children?.compactMap({ $0 as? XMLElement }) ?? [] {
            switch child.name {
            case "register":
                result += registers(from: child, defaults: defaults, offset: offset, prefix: prefix)
            case "cluster":
                let clusterDefaults = defaults.reading(child)
                let clusterOffset = child.childText("addressOffset").flatMap(number) ?? 0
                let clusterName = child.childText("name") ?? ""
                for (index, step) in expand(child) {
                    let name = substitute(clusterName, index)
                    result += registers(
                        in: child,
                        defaults: clusterDefaults,
                        offset: offset + clusterOffset + step,
                        prefix: prefix + name + "_"
                    )
                }
            default:
                continue
            }
        }
        return result
    }

    private static func registers(
        from element: XMLElement,
        defaults: Defaults,
        offset: UInt64,
        prefix: String
    ) -> [SVDRegister] {
        let defaults = defaults.reading(element)
        let name = element.childText("name") ?? ""
        let fields = (element.child("fields")?.children(named: "field") ?? [])
            .flatMap { fields(from: $0, access: defaults.access) }
            .sorted { $0.bitOffset < $1.bitOffset }
        let registerOffset = element.childText("addressOffset").flatMap(number) ?? 0

        return expand(element).map { index, step in
            SVDRegister(
                name: prefix + substitute(name, index),
                description: element.childText("description"),
                addressOffset: offset + registerOffset + step,
                size: defaults.size,
                access: defaults.access,
                resetValue: defaults.resetValue,
                readHasSideEffects: element.childText("readAction") != nil,
                fields: fields
            )
        }
    }

    // MARK: - Fields

    private static func fields(from element: XMLElement, access: SVDAccess) -> [SVDField] {
        guard let (offset, width) = bitRange(of: element), width > 0 else { return [] }
        let name = element.childText("name") ?? ""
        let access = element.childText("access").flatMap(SVDAccess.init(rawValue:)) ?? access
        let values = element.children(named: "enumeratedValues")
            .flatMap { $0.children(named: "enumeratedValue") }
            .compactMap(enumeratedValue)

        return expand(element).map { index, step in
            SVDField(
                name: substitute(name, index),
                description: element.childText("description"),
                bitOffset: offset + Int(step),
                bitWidth: width,
                access: access,
                enumeratedValues: values
            )
        }
    }

    private static func bitRange(of element: XMLElement) -> (offset: Int, width: Int)? {
        if let offset = element.childText("bitOffset").flatMap(number) {
            let width = element.childText("bitWidth").flatMap(number) ?? 1
            return (Int(offset), Int(width))
        }
        if let lsb = element.childText("lsb").flatMap(number),
           let msb = element.childText("msb").flatMap(number), msb >= lsb {
            return (Int(lsb), Int(msb - lsb + 1))
        }
        if let range = element.childText("bitRange") {
            // "[msb:lsb]"
            let parts = range.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                .split(separator: ":").compactMap { Int($0) }
            if parts.count == 2, parts[0] >= parts[1] {
                return (parts[1], parts[0] - parts[1] + 1)
            }
        }
        return nil
    }

    private static func enumeratedValue(_ element: XMLElement) -> SVDEnumeratedValue? {
        // `isDefault` entries name every value not listed, and have none of their own.
        guard let name = element.childText("name"),
              let value = element.childText("value").flatMap(number)
        else { return nil }
        return SVDEnumeratedValue(name: name, description: element.childText("description"), value: value)
    }

    // MARK: - Arrays

    /// The copies a `dim` element stands for: each one's index text and its
    /// distance from the first. One copy, with no index, without `dim`.
    private static func expand(_ element: XMLElement) -> [(index: String, step: UInt64)] {
        guard let count = element.childText("dim").flatMap(number), count > 0 else { return [("", 0)] }
        let increment = element.childText("dimIncrement").flatMap(number) ?? 0
        let indices = dimIndices(element.childText("dimIndex"), count: Int(count))
        return indices.enumerated().map { ($1, UInt64($0) * increment) }
    }

    /// `dimIndex` is a list (`A,B,C`), a range (`0-7`), or absent (counting from 0).
    private static func dimIndices(_ text: String?, count: Int) -> [String] {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            return (0..<count).map(String.init)
        }
        if text.contains(",") {
            return text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let bounds = text.split(separator: "-")
        if bounds.count == 2, let first = Int(bounds[0]), let last = Int(bounds[1]), last >= first {
            return (first...last).map(String.init)
        }
        if bounds.count == 2, let first = bounds[0].unicodeScalars.first, let last = bounds[1].unicodeScalars.first,
           bounds[0].count == 1, bounds[1].count == 1, last.value >= first.value {
            return (first.value...last.value).compactMap { Unicode.Scalar($0).map { String(Character($0)) } }
        }
        return (0..<count).map(String.init)
    }

    /// `GPIO%s` with `A` becomes `GPIOA`; `DATA[%s]` with `3` becomes `DATA3`.
    private static func substitute(_ name: String, _ index: String) -> String {
        guard !index.isEmpty || name.contains("%s") else { return name }
        return name.replacingOccurrences(of: "[%s]", with: index).replacingOccurrences(of: "%s", with: index)
    }

    // MARK: - Numbers

    /// SVD numbers: `0x1F`, `#0101` or `0b0101` (binary), or decimal.
    /// Binary values with `x` (don't care) bits are not supported.
    static func number(_ text: String) -> UInt64? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("0x") { return UInt64(text.dropFirst(2), radix: 16) }
        if text.hasPrefix("0b") { return UInt64(text.dropFirst(2), radix: 2) }
        if text.hasPrefix("#") { return UInt64(text.dropFirst(), radix: 2) }
        return UInt64(text)
    }
}

private extension XMLElement {
    func child(_ name: String) -> XMLElement? {
        elements(forName: name).first
    }

    func children(named name: String) -> [XMLElement] {
        elements(forName: name)
    }

    func childText(_ name: String) -> String? {
        child(name)?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
