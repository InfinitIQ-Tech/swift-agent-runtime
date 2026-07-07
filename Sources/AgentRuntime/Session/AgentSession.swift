import Foundation

/// A host-implemented native tool. Receives the model-supplied arguments and
/// returns the tool output as a string.
public typealias AgentToolHandler = @Sendable ([String: JSONValue]) async throws -> String

/// Per-request provider credentials. Never part of the manifest, never
/// persisted by the runtime, and redacted from any textual description.
public struct ProviderKeys: Sendable {
    private var storage: [String: String]

    public init(_ keys: [String: String] = [:]) {
        self.storage = keys
    }

    public static let anthropicProvider = "anthropic"
    public static let openAIProvider = "openai"

    public subscript(provider: String) -> String? {
        get { storage[provider] }
        set { storage[provider] = newValue }
    }

    public var isEmpty: Bool { storage.isEmpty }
    public var providers: Set<String> { Set(storage.keys) }
}

extension ProviderKeys: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "ProviderKeys(providers: \(providers.sorted()), keys: <redacted>)"
    }
    public var debugDescription: String { description }
}

/// Runtime-supplied configuration for a session. Everything here stays
/// outside the portable artifact by contract.
public struct AgentSessionConfiguration: Sendable {
    /// Cloud provider keys, keyed by provider ("anthropic", "openai", ...).
    public var providerKeys: ProviderKeys
    /// Host-implemented handlers for allowed tools without an HTTP endpoint.
    public var toolHandlers: [String: AgentToolHandler]
    /// Asked before executing a tool listed in `tool_policy.require_user_confirmation`.
    /// When nil, confirmation-required tools fail rather than execute silently.
    public var confirmToolExecution: (@Sendable (AgentToolCall) async -> Bool)?

    public init(
        providerKeys: ProviderKeys = ProviderKeys(),
        toolHandlers: [String: AgentToolHandler] = [:],
        confirmToolExecution: (@Sendable (AgentToolCall) async -> Bool)? = nil
    ) {
        self.providerKeys = providerKeys
        self.toolHandlers = toolHandlers
        self.confirmToolExecution = confirmToolExecution
    }
}

/// A live conversation bound to one manifest and one adapter.
///
/// Sessions are actors: turn state is isolated, and `send` returns a stream
/// that is safe to consume from the main actor.
public protocol AgentSession: Actor {
    /// The manifest this session executes.
    nonisolated var manifest: AgentManifest { get }

    /// Runs one turn. Frames arrive per the `AgentStreamEvent` contract; when
    /// `runtime.streaming` is false the stream carries no `chunk` frames.
    /// Throws `AgentRuntimeError.maxTurnsExceeded` once `runtime.max_turns`
    /// turns have run.
    func send(_ text: String) async -> AsyncThrowingStream<AgentStreamEvent, Error>

    /// Warms the underlying model so the first turn starts faster. Call at
    /// the UI entry point for the conversation, not on every appearance.
    /// On-device sessions preload Foundation Models state; cloud sessions
    /// have nothing to warm and treat this as a no-op.
    func prewarm() async

    /// Cancels the in-flight turn, if any.
    func cancel() async

    /// Completed transcript of the session so far.
    func transcript() async -> [AgentMessage]

    /// Turns already consumed against `runtime.max_turns`.
    func turnsUsed() async -> Int
}

/// Produces sessions for manifests whose model candidates it can serve.
public protocol AgentRuntimeAdapter: Sendable {
    /// Stable adapter identifier (for logs and demos).
    var identifier: String { get }

    /// Whether this adapter can execute the given candidate at all
    /// (provider match), regardless of current availability.
    func supports(candidate: AgentModelCandidate) -> Bool

    /// Current availability for a specific candidate. Cheap enough to call on
    /// every screen appearance.
    func availability(for candidate: AgentModelCandidate, configuration: AgentSessionConfiguration) -> AgentRuntimeAvailability

    /// Creates a session executing `candidate` from `manifest`.
    func makeSession(
        manifest: AgentManifest,
        candidate: AgentModelCandidate,
        configuration: AgentSessionConfiguration
    ) throws -> any AgentSession
}
