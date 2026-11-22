import Foundation

/// The answer to `textDocument/signatureHelp`: the function being called at
/// the cursor and which of its arguments the cursor is in.
struct LSPSignatureHelp: Decodable, Equatable, Sendable {
    typealias Signature = LSPSignatureInformation
    typealias Parameter = LSPParameterInformation

    var signatures: [Signature]
    var activeSignature: Int?
    var activeParameter: Int?

    init(signatures: [Signature], activeSignature: Int? = nil, activeParameter: Int? = nil) {
        self.signatures = signatures
        self.activeSignature = activeSignature
        self.activeParameter = activeParameter
    }

    /// The signature to show: the one the server picked, or the first.
    var active: Signature? {
        let index = activeSignature ?? 0
        return signatures.indices.contains(index) ? signatures[index] : signatures.first
    }

    /// The argument the cursor is in, per signature or overall.
    var activeParameterIndex: Int {
        active?.activeParameter ?? activeParameter ?? 0
    }

    /// The name of the argument the cursor is in, such as `ui32Peripheral`.
    var activeParameterName: String? {
        active?.parameterName(at: activeParameterIndex)
    }
}

/// Decodes LSP fields that are either a plain string or `MarkupContent`.
enum LSPMarkup {
    private struct Content: Decodable {
        var value: String
    }

    static func decode<Key: CodingKey>(_ container: KeyedDecodingContainer<Key>, forKey key: Key) -> String? {
        if let plain = try? container.decodeIfPresent(String.self, forKey: key) {
            return plain
        }
        return (try? container.decodeIfPresent(Content.self, forKey: key))?.value
    }
}

/// One function signature in a signature-help answer.
struct LSPSignatureInformation: Decodable, Equatable, Sendable {
    var label: String
    var documentation: String?
    var parameters: [LSPParameterInformation]
    var activeParameter: Int?

    private enum CodingKeys: String, CodingKey {
        case label, documentation, parameters, activeParameter
    }

    init(
        label: String,
        documentation: String? = nil,
        parameters: [LSPParameterInformation],
        activeParameter: Int? = nil
    ) {
        self.label = label
        self.documentation = documentation
        self.parameters = parameters
        self.activeParameter = activeParameter
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decode(String.self, forKey: .label)
        documentation = LSPMarkup.decode(container, forKey: .documentation)
        parameters = try container.decodeIfPresent([LSPParameterInformation].self, forKey: .parameters) ?? []
        activeParameter = try container.decodeIfPresent(Int.self, forKey: .activeParameter)
    }

    /// Where parameter `index` sits in `label` (UTF-16), for highlighting it.
    func parameterRange(at index: Int) -> NSRange? {
        guard parameters.indices.contains(index) else { return nil }
        switch parameters[index].label {
        case .offsets(let start, let end):
            let length = (label as NSString).length
            guard start >= 0, end >= start, end <= length else { return nil }
            return NSRange(location: start, length: end - start)
        case .text(let text):
            let found = (label as NSString).range(of: text)
            return found.location == NSNotFound ? nil : found
        }
    }

    /// The name of parameter `index`, such as `ui32Port`.
    func parameterName(at index: Int) -> String? {
        guard let range = parameterRange(at: index) else { return nil }
        return LSPSnippet.shortParameterName((label as NSString).substring(with: range))
    }
}

/// One parameter of an `LSPSignatureInformation`.
struct LSPParameterInformation: Decodable, Equatable, Sendable {
    enum Label: Equatable, Sendable {
        case text(String)
        /// Start and end offsets in the signature's label.
        case offsets(Int, Int)
    }

    var label: Label

    init(label: Label) {
        self.label = label
    }

    private enum CodingKeys: String, CodingKey { case label }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try? container.decode(String.self, forKey: .label) {
            label = .text(text)
        } else {
            let offsets = try container.decode([Int].self, forKey: .label)
            guard offsets.count == 2 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .label, in: container, debugDescription: "Expected [start, end]"
                )
            }
            label = .offsets(offsets[0], offsets[1])
        }
    }
}
