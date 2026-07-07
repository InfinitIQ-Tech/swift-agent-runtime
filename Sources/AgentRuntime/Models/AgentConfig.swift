import Foundation

// The Codable surface below mirrors the public AgentConfig JSON Schema
// (InfinitIQ-Tech/agent-config-spec, schema_version "2") using its exact
// snake_case wire keys. `AgentConfigSchemaDriftTests` fails when these types
// and the vendored schema diverge. These types intentionally do not depend on
// AgentFactoryDTO, which imports Vapor and cannot be linked from iOS apps.

/// The `schema_version` values this runtime can execute.
public enum SupportedSchemaVersion {
    public static let all: Set<String> = ["2"]
}

/// Execution limits for the agent loop.
public struct AgentRuntimeConfig: Codable, Equatable, Sendable {
    public let streaming: Bool
    public let maxTurns: Int?
    public let maxConcurrentTools: Int?

    public enum CodingKeys: String, CodingKey {
        case streaming
        case maxTurns = "max_turns"
        case maxConcurrentTools = "max_concurrent_tools"
    }

    public init(streaming: Bool, maxTurns: Int? = nil, maxConcurrentTools: Int? = nil) {
        self.streaming = streaming
        self.maxTurns = maxTurns
        self.maxConcurrentTools = maxConcurrentTools
    }
}

/// One model the agent may run on, referenced as "provider:model".
public struct AgentModelCandidate: Codable, Equatable, Sendable {
    public let name: String
    public let model: String

    public enum CodingKeys: String, CodingKey {
        case name
        case model
    }

    public init(name: String, model: String) {
        self.name = name
        self.model = model
    }

    /// The "provider" half of the `provider:model` reference.
    public var provider: String {
        guard let colon = model.firstIndex(of: ":") else { return model }
        return String(model[..<colon])
    }

    /// The "model" half of the `provider:model` reference.
    public var modelIdentifier: String {
        guard let colon = model.firstIndex(of: ":") else { return "" }
        return String(model[model.index(after: colon)...])
    }
}

/// Model selection strategy and candidates.
public struct AgentModelConfig: Codable, Equatable, Sendable {
    public let strategy: String
    public let candidates: [AgentModelCandidate]
    public let routingPolicy: [String: JSONValue]?

    public enum CodingKeys: String, CodingKey {
        case strategy
        case candidates
        case routingPolicy = "routing_policy"
    }

    public init(strategy: String, candidates: [AgentModelCandidate], routingPolicy: [String: JSONValue]? = nil) {
        self.strategy = strategy
        self.candidates = candidates
        self.routingPolicy = routingPolicy
    }
}

/// Conversation memory policy. Pass-through for adapters that manage their own transcript.
public struct AgentMemoryConfig: Codable, Equatable, Sendable {
    public let type: String?
    public let windowTurns: Int?

    public enum CodingKeys: String, CodingKey {
        case type
        case windowTurns = "window_turns"
    }

    public init(type: String? = nil, windowTurns: Int? = nil) {
        self.type = type
        self.windowTurns = windowTurns
    }
}

/// Retrieval-augmented generation settings. Pass-through metadata in this runtime.
public struct AgentRetrievalConfig: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let corpusIds: [String]?
    public let topK: Int?
    public let rerank: Bool?
    public let filters: [String: JSONValue]?

    public enum CodingKeys: String, CodingKey {
        case enabled
        case corpusIds = "corpus_ids"
        case topK = "top_k"
        case rerank
        case filters
    }

    public init(enabled: Bool, corpusIds: [String]? = nil, topK: Int? = nil, rerank: Bool? = nil, filters: [String: JSONValue]? = nil) {
        self.enabled = enabled
        self.corpusIds = corpusIds
        self.topK = topK
        self.rerank = rerank
        self.filters = filters
    }
}

/// Optional HTTP execution endpoint for a tool.
public struct ToolEndpoint: Codable, Equatable, Sendable {
    public let url: String
    public let method: String?
    public let headers: [String: String]?

    public enum CodingKeys: String, CodingKey {
        case url
        case method
        case headers
    }

    public init(url: String, method: String? = nil, headers: [String: String]? = nil) {
        self.url = url
        self.method = method
        self.headers = headers
    }
}

/// An LLM-native tool schema, plus an optional execution endpoint.
public struct ToolDefinition: Codable, Equatable, Sendable {
    public let name: String
    public let description: String
    public let parameters: [String: JSONValue]
    public let endpoint: ToolEndpoint?

    public enum CodingKeys: String, CodingKey {
        case name
        case description
        case parameters
        case endpoint
    }

    public init(name: String, description: String, parameters: [String: JSONValue], endpoint: ToolEndpoint? = nil) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.endpoint = endpoint
    }
}

/// Constraints on tool execution.
public struct AgentToolPolicy: Codable, Equatable, Sendable {
    public let requireUserConfirmation: [String]?
    public let maxTotalRuntimeMs: Int?
    public let maxToolsPerTurn: Int?

    public enum CodingKeys: String, CodingKey {
        case requireUserConfirmation = "require_user_confirmation"
        case maxTotalRuntimeMs = "max_total_runtime_ms"
        case maxToolsPerTurn = "max_tools_per_turn"
    }

    public init(requireUserConfirmation: [String]? = nil, maxTotalRuntimeMs: Int? = nil, maxToolsPerTurn: Int? = nil) {
        self.requireUserConfirmation = requireUserConfirmation
        self.maxTotalRuntimeMs = maxTotalRuntimeMs
        self.maxToolsPerTurn = maxToolsPerTurn
    }
}

/// Tool surface for the agent.
///
/// `allowed == nil` means no allow-list is declared; `allowed == []` is an
/// explicit allow-list enabling no tools. Normalization semantics live in
/// `AgentToolbox` and match the control-plane sidecar.
public struct AgentToolsConfig: Codable, Equatable, Sendable {
    public let allowed: [String]?
    public let definitions: [ToolDefinition]?
    public let toolPolicy: AgentToolPolicy?

    public enum CodingKeys: String, CodingKey {
        case allowed
        case definitions
        case toolPolicy = "tool_policy"
    }

    public init(allowed: [String]? = nil, definitions: [ToolDefinition]? = nil, toolPolicy: AgentToolPolicy? = nil) {
        self.allowed = allowed
        self.definitions = definitions
        self.toolPolicy = toolPolicy
    }
}

/// One per-turn response format, mirroring the Anthropic Messages API
/// `output_config.format` shape. `type == "json_schema"` constrains each
/// assistant turn's structured payload to the declared JSON Schema.
public struct AgentOutputFormat: Codable, Equatable, Sendable {
    /// Recognized `type` discriminator for JSON-Schema-constrained output.
    public static let jsonSchemaType = "json_schema"

    public let type: String
    public let schema: [String: JSONValue]

    public enum CodingKeys: String, CodingKey {
        case type
        case schema
    }

    public init(type: String, schema: [String: JSONValue]) {
        self.type = type
        self.schema = schema
    }
}

extension AgentOutputFormat {
    /// Decodes provider output text as the structured payload for a
    /// `json_schema` format, enforcing the schema's top-level type. Full
    /// JSON Schema conformance is the provider's guarantee (guided
    /// generation on-device, `output_config` in the cloud); this guards the
    /// contract the caller depends on and surfaces violations as a typed error.
    public func decodeStructuredPayload(from text: String) throws -> JSONValue {
        guard let data = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw AgentRuntimeError.structuredOutputInvalid(
                "Provider returned non-JSON output for a json_schema format"
            )
        }
        if let expected = schema["type"]?.stringValue {
            let matches: Bool
            switch expected {
            case "object":
                if case .object = decoded { matches = true } else { matches = false }
            case "array":
                if case .array = decoded { matches = true } else { matches = false }
            default:
                matches = true
            }
            guard matches else {
                throw AgentRuntimeError.structuredOutputInvalid(
                    "Provider returned a payload whose top-level type is not \"\(expected)\""
                )
            }
        }
        return decoded
    }
}

/// Per-turn structured output declaration. Absent means unstructured text
/// output (the default behavior).
public struct AgentOutputConfig: Codable, Equatable, Sendable {
    public let format: AgentOutputFormat

    public enum CodingKeys: String, CodingKey {
        case format
    }

    public init(format: AgentOutputFormat) {
        self.format = format
    }
}

/// Safety and content policy switches. Semantics are runtime-defined.
public struct AgentGuardrailsConfig: Codable, Equatable, Sendable {
    public let piiRedaction: Bool?
    public let jailbreakDetection: Bool?
    public let blockedTopics: [String]?

    public enum CodingKeys: String, CodingKey {
        case piiRedaction = "pii_redaction"
        case jailbreakDetection = "jailbreak_detection"
        case blockedTopics = "blocked_topics"
    }

    public init(piiRedaction: Bool? = nil, jailbreakDetection: Bool? = nil, blockedTopics: [String]? = nil) {
        self.piiRedaction = piiRedaction
        self.jailbreakDetection = jailbreakDetection
        self.blockedTopics = blockedTopics
    }
}

/// Portable agent manifest (schema_version "2").
public struct AgentConfig: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let version: String
    public let schemaVersion: String
    public let systemPrompt: String
    public let description: String?
    public let tags: [String]?
    public let runtime: AgentRuntimeConfig
    public let model: AgentModelConfig
    public let memory: AgentMemoryConfig?
    public let retrieval: AgentRetrievalConfig?
    public let tools: AgentToolsConfig?
    public let guardrails: AgentGuardrailsConfig?
    public let output: AgentOutputConfig?

    public enum CodingKeys: String, CodingKey {
        case id
        case name
        case version
        case schemaVersion = "schema_version"
        case systemPrompt = "system_prompt"
        case description
        case tags
        case runtime
        case model
        case memory
        case retrieval
        case tools
        case guardrails
        case output
    }

    public init(
        id: String,
        name: String,
        version: String,
        schemaVersion: String,
        systemPrompt: String,
        description: String? = nil,
        tags: [String]? = nil,
        runtime: AgentRuntimeConfig,
        model: AgentModelConfig,
        memory: AgentMemoryConfig? = nil,
        retrieval: AgentRetrievalConfig? = nil,
        tools: AgentToolsConfig? = nil,
        guardrails: AgentGuardrailsConfig? = nil,
        output: AgentOutputConfig? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.schemaVersion = schemaVersion
        self.systemPrompt = systemPrompt
        self.description = description
        self.tags = tags
        self.runtime = runtime
        self.model = model
        self.memory = memory
        self.retrieval = retrieval
        self.tools = tools
        self.guardrails = guardrails
        self.output = output
    }
}
