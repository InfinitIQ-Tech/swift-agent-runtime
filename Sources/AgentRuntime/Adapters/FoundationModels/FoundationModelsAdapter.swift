import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device adapter backed by Apple's Foundation Models framework.
///
/// The adapter type itself is not OS-gated so hosts with lower deployment
/// targets can construct it and query availability anywhere; every Foundation
/// Models touchpoint inside is gated on iOS 26 / macOS 26.
public struct FoundationModelsAdapter: AgentRuntimeAdapter {
    public let identifier = "foundation-models"

    public init() {}

    public func supports(candidate: AgentModelCandidate) -> Bool {
        candidate.model == "apple:foundation-models"
    }

    public func availability(
        for candidate: AgentModelCandidate,
        configuration: AgentSessionConfiguration
    ) -> AgentRuntimeAvailability {
        guard supports(candidate: candidate) else {
            return .unavailable(.unsupportedModel)
        }
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *) else {
            return .unavailable(.osTooOld)
        }
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .unavailable(.deviceNotEligible)
            case .appleIntelligenceNotEnabled:
                return .unavailable(.appleIntelligenceNotEnabled)
            case .modelNotReady:
                return .unavailable(.modelNotReady)
            @unknown default:
                return .unavailable(.other("Foundation Models unavailable"))
            }
        }
        #else
        return .unavailable(.osTooOld)
        #endif
    }

    public func makeSession(
        manifest: AgentManifest,
        candidate: AgentModelCandidate,
        configuration: AgentSessionConfiguration
    ) throws -> any AgentSession {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *) else {
            throw AgentRuntimeError.modelUnavailable(.osTooOld)
        }
        guard case .available = availability(for: candidate, configuration: configuration) else {
            if case .unavailable(let reason) = availability(for: candidate, configuration: configuration) {
                throw AgentRuntimeError.modelUnavailable(reason)
            }
            throw AgentRuntimeError.modelUnavailable(.other("Foundation Models unavailable"))
        }
        return try FoundationModelsSession(
            manifest: manifest,
            candidate: candidate,
            configuration: configuration
        )
        #else
        throw AgentRuntimeError.modelUnavailable(.osTooOld)
        #endif
    }
}

#if canImport(FoundationModels)

/// Relays tool events emitted by Foundation Models tool calls (which happen
/// inside the framework's generation loop) onto the active turn's stream.
actor ToolEventRelay {
    private var continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation?
    private var results: [AgentToolResult] = []

    func beginTurn(_ continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation) {
        self.continuation = continuation
        results = []
    }

    func endTurn() -> [AgentToolResult] {
        continuation = nil
        let collected = results
        results = []
        return collected
    }

    func emitCall(_ call: AgentToolCall) {
        continuation?.yield(.toolCall(call))
    }

    func emitResult(_ result: AgentToolResult) {
        guard let continuation else { return }
        results.append(result)
        continuation.yield(.toolResult(result))
    }
}

/// Bridges one manifest `ToolDefinition` into the Foundation Models `Tool`
/// protocol. Execution flows through the shared `ToolExecutionEngine`, so
/// allow-list and policy semantics are identical to the cloud lane.
@available(iOS 26.0, macOS 26.0, *)
struct ManifestBridgedTool: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema
    let engine: ToolExecutionEngine
    let relay: ToolEventRelay

    /// The exact registration surface supplied to LanguageModelSession.
    /// Kept independent of model availability so normalization is testable
    /// without starting a generation or downloading a model.
    static func makeTools(
        toolbox: AgentToolbox,
        engine: ToolExecutionEngine,
        relay: ToolEventRelay
    ) throws -> [ManifestBridgedTool] {
        try toolbox.tools.map { definition in
            ManifestBridgedTool(
                name: definition.name,
                description: definition.description,
                parameters: try GenerationSchemaBuilder.makeSchema(
                    toolName: definition.name,
                    parameters: definition.parameters
                ),
                engine: engine,
                relay: relay
            )
        }
    }

    func call(arguments: GeneratedContent) async throws -> String {
        let args = Self.decodeArguments(arguments)
        let call = AgentToolCall(toolId: name, callId: UUID().uuidString, args: args)
        await relay.emitCall(call)
        let results = await engine.execute([call])
        guard let result = results.first else {
            throw AgentRuntimeError.generationFailed("Tool \(name) produced no result")
        }
        await relay.emitResult(result)
        return result.output
    }

    static func decodeArguments(_ content: GeneratedContent) -> [String: JSONValue] {
        let json = content.jsonString
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let members) = decoded else {
            return [:]
        }
        return members
    }
}

/// Converts a JSON Schema object into a Foundation Models `GenerationSchema`
/// via `DynamicGenerationSchema`. Used for both tool `parameters` schemas and
/// the manifest's `output.format.schema` (guided generation).
@available(iOS 26.0, macOS 26.0, *)
enum GenerationSchemaBuilder {
    static func makeSchema(toolName: String, parameters: [String: JSONValue]) throws -> GenerationSchema {
        let root = try buildObject(name: "schema_" + encodedName(toolName), schema: .object(parameters))
        return try GenerationSchema(root: root, dependencies: [])
    }

    // Hex preserves every UTF-8 byte without introducing JSON Pointer syntax
    // into $defs names. Segment delimiters prevent a.b and a_b collisions.
    private static func encodedName(_ name: String) -> String {
        name.utf8.map { String(format: "%02x", $0) }.joined()
    }

    private static func buildObject(name: String, schema: JSONValue) throws -> DynamicGenerationSchema {
        let required: Set<String>
        if case .array(let values)? = schema["required"] {
            required = Set(values.compactMap(\.stringValue))
        } else {
            required = []
        }

        var properties: [DynamicGenerationSchema.Property] = []
        if case .object(let props)? = schema["properties"] {
            for (propertyName, propertySchema) in props.sorted(by: { $0.key < $1.key }) {
                let child = try build(name: "\(name)_p\(encodedName(propertyName))", schema: propertySchema)
                properties.append(
                    DynamicGenerationSchema.Property(
                        name: propertyName,
                        description: propertySchema["description"]?.stringValue,
                        schema: child,
                        isOptional: !required.contains(propertyName)
                    )
                )
            }
        }
        return DynamicGenerationSchema(
            name: name,
            description: schema["description"]?.stringValue,
            properties: properties
        )
    }

    private static func build(name: String, schema: JSONValue) throws -> DynamicGenerationSchema {
        if case .array(let choices)? = schema["enum"] {
            let values = choices.compactMap(\.stringValue)
            if !values.isEmpty {
                return DynamicGenerationSchema(name: name, anyOf: values)
            }
        }

        let type = schema["type"]?.stringValue ?? "object"
        switch type {
        case "string":
            return DynamicGenerationSchema(type: String.self)
        case "integer":
            return DynamicGenerationSchema(type: Int.self)
        case "number":
            return DynamicGenerationSchema(type: Double.self)
        case "boolean":
            return DynamicGenerationSchema(type: Bool.self)
        case "array":
            let item = try build(name: "\(name)_item", schema: schema["items"] ?? .object([:]))
            return DynamicGenerationSchema(arrayOf: item)
        default:
            return try buildObject(name: name, schema: schema)
        }
    }
}

/// Internal injection seam for deterministic session tests. Production
/// closures call the framework session directly in the active turn's task.
@available(iOS 26.0, macOS 26.0, *)
struct FoundationModelsOperations: Sendable {
    var prewarm: @Sendable () async -> Void
    var respond: @Sendable (String, GenerationSchema) async throws -> String
    var respondText: @Sendable (String) async throws -> String
    // nil represents a framework null placeholder, never the text "null".
    var streamText: @Sendable (String, @Sendable (String?) async throws -> Void) async throws -> Void

    init(
        prewarm: @escaping @Sendable () async -> Void = {},
        respond: @escaping @Sendable (String, GenerationSchema) async throws -> String = { _, _ in
            throw AgentRuntimeError.generationFailed("No structured response operation supplied")
        },
        respondText: @escaping @Sendable (String) async throws -> String = { _ in
            throw AgentRuntimeError.generationFailed("No text response operation supplied")
        },
        streamText: @escaping @Sendable (String, @Sendable (String?) async throws -> Void) async throws -> Void = { _, _ in
            throw AgentRuntimeError.generationFailed("No text streaming operation supplied")
        }
    ) {
        self.prewarm = prewarm
        self.respond = respond
        self.respondText = respondText
        self.streamText = streamText
    }

    /// Raw null is a tool placeholder; a generated string containing "null"
    /// is ordinary text and must survive streaming unchanged.
    static func textSnapshot(_ content: String, rawContent: GeneratedContent) -> String? {
        if case .null = rawContent.kind { return nil }
        return content
    }

    init(session: LanguageModelSession) {
        prewarm = { session.prewarm() }
        respond = { text, schema in
            let response = try await session.respond(to: text, schema: schema, includeSchemaInPrompt: true)
            return response.content.jsonString
        }
        respondText = { text in
            try await session.respond(to: text).content
        }
        streamText = { text, receive in
            for try await snapshot in session.streamResponse(to: text) {
                try Task.checkCancellation()
                try await receive(Self.textSnapshot(snapshot.content, rawContent: snapshot.rawContent))
            }
        }
    }
}

/// Converts the framework's cumulative text snapshots into event deltas.
/// Tool placeholders and segment restarts preserve the existing adapter behavior.
private actor FoundationModelsTextAccumulator {
    let continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation
    var segments: [String] = []
    var current = ""

    init(continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation) {
        self.continuation = continuation
    }

    func append(_ content: String?) throws {
        try Task.checkCancellation()
        guard let content, !content.isEmpty else {
            if !current.isEmpty {
                segments.append(current)
                current = ""
            }
            return
        }
        if content.hasPrefix(current) {
            let delta = String(content.dropFirst(current.count))
            if !delta.isEmpty { continuation.yield(.chunk(delta)) }
        } else {
            if !current.isEmpty { segments.append(current) }
            continuation.yield(.chunk(content))
        }
        current = content
    }

    func text() -> String {
        (segments + [current]).joined()
    }
}

/// A live on-device session. One `LanguageModelSession` per agent session;
/// Foundation Models owns the transcript and runs allowed tools natively
/// through `ManifestBridgedTool`.
@available(iOS 26.0, macOS 26.0, *)
actor FoundationModelsSession: AgentSession {
    nonisolated let manifest: AgentManifest
    private let candidate: AgentModelCandidate
    // Foundation Models values are stored type-erased: this class's field
    // layout must reference no weak-linked FoundationModels metadata, or
    // eager class realization on OS versions without the framework (for
    // example objc_copyClassList during XCTest discovery on iOS < 26)
    // faults resolving those symbols. The typed accessors below restore the
    // concrete types inside this @available-gated context.
    private let sessionStorage: AnyObject
    private let relay: ToolEventRelay
    private let structuredSchemaStorage: (any Sendable)?
    private let operationsStorage: any Sendable

    private var operations: FoundationModelsOperations {
        guard let operations = operationsStorage as? FoundationModelsOperations else {
            fatalError("FoundationModelsSession.operationsStorage must hold FoundationModelsOperations")
        }
        return operations
    }
    private var history: [AgentMessage] = []
    private var usedTurns = 0
    private var activeTurn: Task<Void, Never>?

    private var session: LanguageModelSession {
        guard let session = sessionStorage as? LanguageModelSession else {
            fatalError("FoundationModelsSession.sessionStorage must hold a LanguageModelSession")
        }
        return session
    }

    /// Guided-generation schema built from `output.format.schema` when the
    /// manifest declares structured output.
    private var structuredSchema: GenerationSchema? {
        structuredSchemaStorage as? GenerationSchema
    }

    init(
        manifest: AgentManifest,
        candidate: AgentModelCandidate,
        configuration: AgentSessionConfiguration,
        operations: FoundationModelsOperations? = nil,
        relay: ToolEventRelay = ToolEventRelay()
    ) throws {
        self.manifest = manifest
        self.candidate = candidate
        self.relay = relay

        let toolbox = AgentToolbox.resolve(config: manifest.config)
        let engine = ToolExecutionEngine(toolbox: toolbox, configuration: configuration)
        // Only normalized-allowed tools are ever registered with the model.
        // An agent with no tools configured registers zero tools.
        let bridgedTools = try ManifestBridgedTool.makeTools(
            toolbox: toolbox, engine: engine, relay: relay
        )

        if let format = manifest.config.output?.format {
            _ = try format.validatedSchema()
            self.structuredSchemaStorage = try GenerationSchemaBuilder.makeSchema(
                toolName: "structured_output",
                parameters: format.schema
            )
        } else {
            self.structuredSchemaStorage = nil
        }

        let session = LanguageModelSession(
            tools: bridgedTools,
            instructions: manifest.config.systemPrompt
        )
        self.sessionStorage = session
        self.operationsStorage = operations ?? FoundationModelsOperations(session: session)
        self.engine = engine
    }

    /// Preloads Foundation Models session state so the first token of the
    /// first turn arrives faster. Safe to call once at conversation entry.
    func prewarm() async {
        await operations.prewarm()
    }

    private let engine: ToolExecutionEngine

    func send(_ text: String) async -> AsyncThrowingStream<AgentStreamEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<AgentStreamEvent, Error>.makeStream()
        guard activeTurn == nil else {
            continuation.finish(throwing: AgentRuntimeError.generationFailed("A turn is already in progress"))
            return stream
        }
        if let limit = manifest.config.runtime.maxTurns, usedTurns >= limit {
            continuation.finish(throwing: AgentRuntimeError.maxTurnsExceeded(limit: limit))
            return stream
        }
        usedTurns += 1
        let turnIndex = usedTurns

        let task = Task {
            let failure: AgentRuntimeError?
            do {
                let result = try await self.runTurn(text: text, turnIndex: turnIndex, continuation: continuation)
                try publishTurnResult(result, to: continuation)
                failure = nil
            } catch {
                // Keep the active slot occupied until generation and relay
                // cleanup unwind, including when an operation ignores cancel.
                _ = await relay.endTurn()
                if Task.isCancelled || error is CancellationError {
                    failure = .cancelled
                } else {
                    failure = (error as? AgentRuntimeError) ?? Self.mapGenerationError(error)
                }
            }
            activeTurn = nil
            continuation.finish(throwing: failure)
        }
        activeTurn = task
        continuation.onTermination = { termination in
            if case .cancelled = termination {
                task.cancel()
            }
        }
        return stream
    }

    /// Commits assistant history only when the terminal frame is accepted.
    /// Consumer termination can race the cancellation check from another executor,
    /// so yield's result is the publication boundary, with no suspension afterward.
    func publishTurnResult(
        _ result: AgentTurnResult,
        to continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation
    ) throws {
        try Task.checkCancellation()
        switch continuation.yield(.end(result)) {
        case .enqueued:
            history.append(AgentMessage(role: .assistant, content: result.text))
        case .terminated:
            throw AgentRuntimeError.cancelled
        case .dropped:
            // Production streams are unbounded; fail explicitly if that changes.
            throw AgentRuntimeError.generationFailed("Terminal event was dropped")
        @unknown default:
            throw AgentRuntimeError.generationFailed("Terminal event was not accepted")
        }
    }

    private func runTurn(
        text: String,
        turnIndex: Int,
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation
    ) async throws -> AgentTurnResult {
        try Task.checkCancellation()
        continuation.yield(.start(AgentTurnStart(
            turn: turnIndex,
            candidate: candidate.name,
            model: candidate.model
        )))
        await engine.beginTurn()
        try Task.checkCancellation()
        await relay.beginTurn(continuation)
        try Task.checkCancellation()
        history.append(AgentMessage(role: .user, content: text))

        let finalText: String
        var structuredPayload: JSONValue?
        if let schema = structuredSchema, let format = manifest.config.output?.format {
            // Structured turns run guided generation and deliver the payload
            // on the end frame; no chunk frames are emitted.
            let json = try await operations.respond(text, schema)
            structuredPayload = try format.decodeStructuredPayload(from: json)
            finalText = json
        } else if manifest.config.runtime.streaming {
            // Snapshots are cumulative within a segment, but the stream can
            // restart after an in-generation tool call. The operations bridge
            // distinguishes true null placeholders from the literal text "null".
            let accumulator = FoundationModelsTextAccumulator(continuation: continuation)
            try await operations.streamText(text) { content in
                try Task.checkCancellation()
                try await accumulator.append(content)
            }
            finalText = await accumulator.text()
        } else {
            finalText = try await operations.respondText(text)
        }

        try Task.checkCancellation()
        let toolResults = await relay.endTurn()
        try Task.checkCancellation()
        let remaining = manifest.config.runtime.maxTurns.map { max(0, $0 - usedTurns) }
        return AgentTurnResult(
            text: finalText,
            toolResults: toolResults,
            remainingTurns: remaining,
            structured: structuredPayload
        )
    }

    func cancel() {
        activeTurn?.cancel()
    }

    func transcript() -> [AgentMessage] {
        history
    }

    func turnsUsed() -> Int {
        usedTurns
    }

    /// Maps Foundation Models generation errors onto the typed taxonomy.
    static func mapGenerationError(_ error: any Error) -> AgentRuntimeError {
        guard let generationError = error as? LanguageModelSession.GenerationError else {
            return .generationFailed(String(describing: error))
        }
        switch generationError {
        case .exceededContextWindowSize:
            return .contextWindowExceeded
        case .guardrailViolation:
            return .guardrailViolation
        case .refusal:
            return .guardrailViolation
        case .assetsUnavailable:
            return .modelUnavailable(.modelNotReady)
        case .rateLimited:
            return .generationFailed("Rate limited by the on-device model")
        default:
            return .generationFailed(String(describing: generationError))
        }
    }
}

#endif
