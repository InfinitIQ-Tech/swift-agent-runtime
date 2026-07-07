import Foundation

/// Metadata emitted when a turn starts.
public struct AgentTurnStart: Equatable, Sendable {
    /// 1-based index of this turn within the session.
    public let turn: Int
    /// The `AgentModelCandidate.name` executing this turn.
    public let candidate: String
    /// The `provider:model` reference executing this turn.
    public let model: String

    public init(turn: Int, candidate: String, model: String) {
        self.turn = turn
        self.candidate = candidate
        self.model = model
    }
}

/// A tool invocation requested by the model.
public struct AgentToolCall: Equatable, Sendable {
    public let toolId: String
    public let callId: String?
    public let args: [String: JSONValue]

    public init(toolId: String, callId: String? = nil, args: [String: JSONValue]) {
        self.toolId = toolId
        self.callId = callId
        self.args = args
    }
}

/// The outcome of one executed tool call.
public struct AgentToolResult: Equatable, Sendable {
    public let toolId: String
    public let callId: String?
    public let output: String
    public let success: Bool
    public let durationMs: Int?

    public init(toolId: String, callId: String? = nil, output: String, success: Bool, durationMs: Int? = nil) {
        self.toolId = toolId
        self.callId = callId
        self.output = output
        self.success = success
        self.durationMs = durationMs
    }
}

/// Terminal payload of a turn.
public struct AgentTurnResult: Equatable, Sendable {
    /// The complete assistant text for the turn. For structured-output turns
    /// this is the JSON text of the structured payload.
    public let text: String
    /// Tool calls executed during the turn, in execution order.
    public let toolResults: [AgentToolResult]
    /// Turns remaining under `runtime.max_turns`, when a limit is configured.
    public let remainingTurns: Int?
    /// Decoded structured payload when the manifest declares an `output`
    /// section; nil for unstructured manifests. Identical across adapters.
    public let structured: JSONValue?

    public init(text: String, toolResults: [AgentToolResult] = [], remainingTurns: Int? = nil, structured: JSONValue? = nil) {
        self.text = text
        self.toolResults = toolResults
        self.remainingTurns = remainingTurns
        self.structured = structured
    }
}

/// One frame of a streamed turn.
///
/// The frame sequence mirrors the control-plane SSE contract (`start`,
/// `chunk`, `tool_call`, `tool_result`, `end`) so callers experience the
/// cloud and on-device lanes identically. Non-streaming execution emits the
/// same sequence without intermediate `chunk` frames.
public enum AgentStreamEvent: Equatable, Sendable {
    case start(AgentTurnStart)
    case chunk(String)
    case toolCall(AgentToolCall)
    case toolResult(AgentToolResult)
    case end(AgentTurnResult)
}

/// A single message in a session transcript.
public struct AgentMessage: Equatable, Sendable {
    public enum Role: String, Sendable {
        case user
        case assistant
        case tool
    }

    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}
