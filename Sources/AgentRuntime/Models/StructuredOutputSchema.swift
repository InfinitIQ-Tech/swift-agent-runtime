import Foundation

/// The portable intersection of JSON Schema supported by both adapters.
/// Unsupported constraints fail closed instead of being silently discarded
/// by Foundation Models or rejected only after a cloud request is sent.
indirect enum StructuredOutputSchema {
    case object(properties: [String: Self], required: Set<String>)
    case array(Self)
    case string(choices: [String]?)
    case integer
    case number
    case boolean

    init(_ schema: [String: JSONValue], path: String = "output.format.schema", root: Bool = true) throws {
        func invalid(_ reason: String) -> AgentManifestError {
            .invalidManifest("\(path): \(reason)")
        }
        guard let type = schema["type"]?.stringValue else {
            throw invalid("an explicit supported type is required")
        }
        if root, type != "object" {
            throw invalid("portable structured output requires an object root")
        }
        let keywords: Set<String>
        switch type {
        case "object": keywords = ["properties", "required", "additionalProperties"]
        case "array": keywords = ["items"]
        case "string": keywords = ["enum"]
        case "integer", "number", "boolean": keywords = []
        default: throw invalid("unsupported type \"\(type)\"")
        }
        let annotations: Set<String> = ["type", "title", "description", "$schema"]
        if let unsupported = Set(schema.keys).subtracting(keywords.union(annotations)).sorted().first {
            throw invalid("unsupported keyword \"\(unsupported)\"")
        }
        for key in ["title", "description", "$schema"] where schema[key] != nil {
            guard schema[key]?.stringValue != nil else { throw invalid("\(key) must be a string") }
        }
        switch type {
        case "object":
            guard schema["additionalProperties"] == .bool(false) else {
                throw invalid("objects require additionalProperties: false on both adapters")
            }
            guard case .object(let rawProperties)? = schema["properties"] else {
                throw invalid("objects require a properties object")
            }
            var properties: [String: Self] = [:]
            for (name, raw) in rawProperties.sorted(by: { $0.key < $1.key }) {
                guard case .object(let child) = raw else {
                    throw invalid("property \"\(name)\" must be a schema object")
                }
                properties[name] = try Self(child, path: "\(path).properties.\(name)", root: false)
            }
            var required: Set<String> = []
            if let raw = schema["required"] {
                guard case .array(let members) = raw else { throw invalid("required must be an array") }
                for member in members {
                    guard let name = member.stringValue, properties[name] != nil,
                          required.insert(name).inserted else {
                        throw invalid("required must name unique declared properties")
                    }
                }
            }
            self = .object(properties: properties, required: required)
        case "array":
            guard case .object(let items)? = schema["items"] else {
                throw invalid("arrays require an items schema object")
            }
            self = .array(try Self(items, path: "\(path).items", root: false))
        case "string":
            var choices: [String]?
            if let raw = schema["enum"] {
                guard case .array(let values) = raw, !values.isEmpty else {
                    throw invalid("enum must be a nonempty array of unique strings")
                }
                let strings = values.compactMap(\.stringValue)
                guard strings.count == values.count, Set(strings).count == values.count else {
                    throw invalid("enum must be a nonempty array of unique strings")
                }
                choices = strings
            }
            self = .string(choices: choices)
        case "integer": self = .integer
        case "number": self = .number
        default: self = .boolean
        }
    }

    func validate(_ value: JSONValue, path: String = "$") throws {
        func invalid(_ reason: String) -> AgentRuntimeError {
            .structuredOutputInvalid("\(path): \(reason)")
        }
        switch (self, value) {
        case (.object(let properties, let required), .object(let members)):
            if let missing = required.subtracting(members.keys).sorted().first {
                throw invalid("missing required property \"\(missing)\"")
            }
            if let extra = Set(members.keys).subtracting(properties.keys).sorted().first {
                throw invalid("unexpected property \"\(extra)\"")
            }
            for (name, child) in members.sorted(by: { $0.key < $1.key }) {
                try properties[name]?.validate(child, path: "\(path).\(name)")
            }
        case (.array(let item), .array(let values)):
            for (index, child) in values.enumerated() {
                try item.validate(child, path: "\(path)[\(index)]")
            }
        case (.string(let choices), .string(let text)):
            if let choices, !choices.contains(text) { throw invalid("value is outside the declared enum") }
        case (.integer, .integer), (.number, .integer), (.number, .number), (.boolean, .bool): break
        // JSON Schema considers a numeric value with no fractional part an integer.
        case (.integer, .number(let number)) where number.isFinite && number.rounded() == number: break
        default: throw invalid("value does not match the declared type")
        }
    }
}

extension AgentOutputFormat {
    func validatedSchema() throws -> StructuredOutputSchema {
        guard type == Self.jsonSchemaType else {
            throw AgentRuntimeError.unsupportedOutputFormat(type)
        }
        return try StructuredOutputSchema(schema)
    }
}
