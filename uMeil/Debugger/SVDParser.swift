import Foundation

/// Reads CMSIS-SVD files: the part of the format the peripheral view needs.
///
/// Handles inherited `size`, `access` and `resetValue`, peripherals
/// `derivedFrom` another, `cluster`s, `dim` arrays (`GPIO%s`, `DATA[%s]`),
/// and all three ways of giving a field's bits (`bitOffset`/`bitWidth`,
/// `lsb`/`msb`, `bitRange`).
enum SVDParser {
    static let maximumXMLBytes = 32 * 1024 * 1024
    static let maximumDimCount = 4096
    static let maximumClusterDepth = 16

    enum Failure: Error, Equatable, LocalizedError {
        case notSVD
        case fileTooLarge
        case unknownBase(peripheral: String, derivedFrom: String)

        var errorDescription: String? {
            switch self {
            case .notSVD:
                "The file is not a CMSIS-SVD device description."
            case .fileTooLarge:
                "The CMSIS-SVD file exceeds the 32 MiB size limit."
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
            if let size = element.childText("size").flatMap(SVDParser.number), (1...64).contains(size) {
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
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumXMLBytes + 1) ?? Data()
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> SVDDevice {
        guard data.count <= maximumXMLBytes else { throw Failure.fileTooLarge }
        let document = try XMLDocument(data: data, options: .nodeLoadExternalEntitiesNever)
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

        return expand(element).compactMap { index, step in
            let (baseAddress, overflow) = address.addingReportingOverflow(step)
            guard !overflow else { return nil }
            var copy = template
            copy.name = substitute(name, index)
            copy.baseAddress = baseAddress
            return copy
        }
    }

    // MARK: - Registers

    private static func registers(
        in parent: XMLElement,
        defaults: Defaults,
        offset: UInt64,
        prefix: String,
        depth: Int = 0
    ) -> [SVDRegister] {
        var result: [SVDRegister] = []
        for child in parent.children?.compactMap({ $0 as? XMLElement }) ?? [] {
            switch child.name {
            case "register":
                result += registers(from: child, defaults: defaults, offset: offset, prefix: prefix)
            case "cluster":
                guard depth < maximumClusterDepth else { continue }
                let clusterDefaults = defaults.reading(child)
                let clusterOffset = child.childText("addressOffset").flatMap(number) ?? 0
                let (clusterBase, baseOverflow) = offset.addingReportingOverflow(clusterOffset)
                guard !baseOverflow else { continue }
                let clusterName = child.childText("name") ?? ""
                for (index, step) in expand(child) {
                    let (childOffset, stepOverflow) = clusterBase.addingReportingOverflow(step)
                    guard !stepOverflow else { continue }
                    let name = substitute(clusterName, index)
                    result += registers(
                        in: child,
                        defaults: clusterDefaults,
                        offset: childOffset,
                        prefix: prefix + name + "_",
                        depth: depth + 1
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
        let registerFields = (element.child("fields")?.children(named: "field") ?? [])
            .flatMap { fields(from: $0, access: defaults.access) }
            .sorted { $0.bitOffset < $1.bitOffset }
        let registerOffset = element.childText("addressOffset").flatMap(number) ?? 0
        let (baseOffset, baseOverflow) = offset.addingReportingOverflow(registerOffset)
        guard !baseOverflow else { return [] }

        return expand(element).compactMap { index, step in
            let (addressOffset, stepOverflow) = baseOffset.addingReportingOverflow(step)
            guard !stepOverflow else { return nil }
            return SVDRegister(
                name: prefix + substitute(name, index),
                description: element.childText("description"),
                addressOffset: addressOffset,
                size: defaults.size,
                access: defaults.access,
                resetValue: defaults.resetValue,
                readHasSideEffects: element.childText("readAction") != nil,
                fields: registerFields
            )
        }
    }

    // MARK: - Fields

    private static func fields(from element: XMLElement, access: SVDAccess) -> [SVDField] {
        guard let (offset, width) = bitRange(of: element),
              (0..<64).contains(offset),
              (1...64).contains(width)
        else { return [] }
        let name = element.childText("name") ?? ""
        let access = element.childText("access").flatMap(SVDAccess.init(rawValue:)) ?? access
        let values = element.children(named: "enumeratedValues")
            .flatMap { $0.children(named: "enumeratedValue") }
            .compactMap(enumeratedValue)

        return expand(element).compactMap { index, step in
            let (rawOffset, overflow) = UInt64(offset).addingReportingOverflow(step)
            guard !overflow, rawOffset < 64 else { return nil }
            return SVDField(
                name: substitute(name, index),
                description: element.childText("description"),
                bitOffset: Int(rawOffset),
                bitWidth: width,
                access: access,
                enumeratedValues: values
            )
        }
    }

    private static func bitRange(of element: XMLElement) -> (offset: Int, width: Int)? {
        if let rawOffset = element.childText("bitOffset").flatMap(number) {
            guard rawOffset < 64 else { return nil }
            let rawWidth = element.childText("bitWidth").flatMap(number) ?? 1
            guard (1...64).contains(rawWidth) else { return nil }
            return (Int(rawOffset), Int(rawWidth))
        }
        if let lsb = element.childText("lsb").flatMap(number),
           let msb = element.childText("msb").flatMap(number) {
            guard lsb < 64, msb < 64, msb >= lsb else { return nil }
            let width = msb - lsb + 1
            guard (1...64).contains(width) else { return nil }
            return (Int(lsb), Int(width))
        }
        if let range = element.childText("bitRange") {
            // "[msb:lsb]"
            let parts = range.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                .split(separator: ":")
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 2,
               (0..<64).contains(parts[0]),
               (0..<64).contains(parts[1]),
               parts[0] >= parts[1] {
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
}

extension SVDParser {
    // MARK: - Arrays

    /// The copies a `dim` element stands for: each one's index text and its
    /// distance from the first. One copy, with no index, without `dim`.
    private static func expand(_ element: XMLElement) -> [(index: String, step: UInt64)] {
        guard let rawCount = element.childText("dim").flatMap(number), rawCount > 0 else { return [("", 0)] }
        let count = Int(min(rawCount, UInt64(maximumDimCount)))
        let increment = element.childText("dimIncrement").flatMap(number) ?? 0
        let indices = dimIndices(element.childText("dimIndex"), count: count)
        return indices.enumerated().compactMap { offset, index in
            let (step, overflow) = UInt64(offset).multipliedReportingOverflow(by: increment)
            guard !overflow else { return nil }
            return (index, step)
        }
    }

    /// `dimIndex` is a list (`A,B,C`), a range (`0-7` or `A-C`), a single
    /// token when `count == 1`, or absent (counting from 0). Always returns
    /// exactly `count` indices (capped at `maximumDimCount`).
    private static func dimIndices(_ text: String?, count: Int) -> [String] {
        let cappedCount = min(max(count, 0), maximumDimCount)
        guard cappedCount > 0 else { return [] }
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            return (0..<cappedCount).map(String.init)
        }
        if text.contains(",") {
            let items = text.split(separator: ",", maxSplits: cappedCount)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            return items.count >= cappedCount
                ? Array(items.prefix(cappedCount))
                : (0..<cappedCount).map(String.init)
        }
        let bounds = text.split(separator: "-", omittingEmptySubsequences: false)
        if bounds.count == 2 {
            let start = bounds[0].trimmingCharacters(in: .whitespaces)
            let end = bounds[1].trimmingCharacters(in: .whitespaces)
            if let first = Int(start), let last = Int(end), first >= 0, last >= first {
                let available = UInt64(last - first)
                return available >= UInt64(cappedCount - 1)
                    ? (0..<cappedCount).map { String(first + $0) }
                    : (0..<cappedCount).map(String.init)
            }
            if start.unicodeScalars.count == 1, end.unicodeScalars.count == 1,
               let first = start.unicodeScalars.first, let last = end.unicodeScalars.first,
               last.value >= first.value {
                if UInt64(last.value - first.value) >= UInt64(cappedCount - 1) {
                    let scalars = (0..<cappedCount).compactMap { Unicode.Scalar(first.value + UInt32($0)) }
                    if scalars.count == cappedCount {
                        return scalars.map { String(Character($0)) }
                    }
                }
                return (0..<cappedCount).map(String.init)
            }
        }
        if cappedCount == 1 {
            return [text]
        }
        return (0..<cappedCount).map(String.init)
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
