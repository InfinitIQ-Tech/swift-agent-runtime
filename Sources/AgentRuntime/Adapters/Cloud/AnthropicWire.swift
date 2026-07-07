import Foundation

// Wire types for the Anthropic Messages API (anthropic-version 2023-06-01).
// Raw HTTP is the sanctioned integration path for Swift; there is no official
// Swift SDK. Shapes follow the current Messages API documentation.

enum AnthropicWire {
    static let apiVersion = "2023-06-01"
    static let defaultBaseURL = URL(string: "https://api.anthropic.com/v1/messages")!

    struct Request: Encodable {
        let model: String
        let maxTokens: Int
        let system: String?
        let messages: [Message]
        let tools: [Tool]?
        let stream: Bool
        var outputConfig: OutputConfig?

        enum CodingKeys: String, CodingKey {
            case model
            case maxTokens = "max_tokens"
            case system
            case messages
            case tools
            case stream
            case outputConfig = "output_config"
        }
    }

    /// Structured-output request parameter (`output_config.format` with
    /// `type: "json_schema"`), mapped 1:1 from the manifest's `output` section.
    struct OutputConfig: Encodable {
        let format: OutputFormat
    }

    struct OutputFormat: Encodable {
        let type: String
        let schema: [String: JSONValue]
    }

    struct Tool: Encodable {
        let name: String
        let description: String
        let inputSchema: [String: JSONValue]

        enum CodingKeys: String, CodingKey {
            case name
            case description
            case inputSchema = "input_schema"
        }
    }

    struct Message: Codable {
        let role: String
        let content: [ContentBlock]
    }

    enum ContentBlock: Codable {
        case text(String)
        case toolUse(id: String, name: String, input: [String: JSONValue])
        case toolResult(toolUseId: String, content: String, isError: Bool)

        enum CodingKeys: String, CodingKey {
            case type
            case text
            case id
            case name
            case input
            case toolUseId = "tool_use_id"
            case content
            case isError = "is_error"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "text":
                self = .text(try container.decode(String.self, forKey: .text))
            case "tool_use":
                self = .toolUse(
                    id: try container.decode(String.self, forKey: .id),
                    name: try container.decode(String.self, forKey: .name),
                    input: try container.decodeIfPresent([String: JSONValue].self, forKey: .input) ?? [:]
                )
            case "tool_result":
                self = .toolResult(
                    toolUseId: try container.decode(String.self, forKey: .toolUseId),
                    content: try container.decodeIfPresent(String.self, forKey: .content) ?? "",
                    isError: try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
                )
            default:
                // Unknown block types (thinking, server tools, ...) are
                // preserved as empty text so decoding a response never fails.
                self = .text("")
            }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let text):
                try container.encode("text", forKey: .type)
                try container.encode(text, forKey: .text)
            case .toolUse(let id, let name, let input):
                try container.encode("tool_use", forKey: .type)
                try container.encode(id, forKey: .id)
                try container.encode(name, forKey: .name)
                try container.encode(input, forKey: .input)
            case .toolResult(let toolUseId, let content, let isError):
                try container.encode("tool_result", forKey: .type)
                try container.encode(toolUseId, forKey: .toolUseId)
                try container.encode(content, forKey: .content)
                if isError {
                    try container.encode(true, forKey: .isError)
                }
            }
        }
    }

    /// Non-streaming response envelope.
    struct Response: Decodable {
        let content: [ContentBlock]
        let stopReason: String?

        enum CodingKeys: String, CodingKey {
            case content
            case stopReason = "stop_reason"
        }
    }

    struct APIErrorEnvelope: Decodable {
        struct APIError: Decodable {
            let type: String
            let message: String
        }
        let error: APIError
    }
}
