import Foundation

/// A JSON value tree used for pass-through sections of an `AgentConfig`
/// manifest and for preserving the complete raw document on round-trip.
///
/// Integers and floating-point numbers are kept distinct so a re-encoded
/// manifest stays canonically equal to its source document.
public enum JSONValue: Codable, Equatable, Hashable, Sendable {
    case string(String)
    case integer(Int)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
            return
        }
        if let b = try? container.decode(Bool.self) {
            self = .bool(b)
            return
        }
        if let i = try? container.decode(Int.self) {
            self = .integer(i)
            return
        }
        if let d = try? container.decode(Double.self) {
            self = .number(d)
            return
        }
        if let s = try? container.decode(String.self) {
            self = .string(s)
            return
        }
        if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
            return
        }
        if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
            return
        }
        throw DecodingError.typeMismatch(
            JSONValue.self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Unsupported JSON value"
            )
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .integer(let i): try container.encode(i)
        case .number(let n): try container.encode(n)
        case .bool(let b): try container.encode(b)
        case .object(let o): try container.encode(o)
        case .array(let a): try container.encode(a)
        case .null: try container.encodeNil()
        }
    }
}

extension JSONValue {
    /// The member names of an object value; empty for non-objects.
    public var objectKeys: Set<String> {
        if case .object(let members) = self { return Set(members.keys) }
        return []
    }

    /// Looks up a member of an object value.
    public subscript(member: String) -> JSONValue? {
        if case .object(let members) = self { return members[member] }
        return nil
    }

    /// The string content of a string value.
    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}
