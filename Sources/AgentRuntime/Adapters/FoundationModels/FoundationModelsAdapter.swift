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
        candidate.provider == "apple"
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
        results.append(result)
        continuation?.yield(.toolResult(result))
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
        let root = try buildObject(name: toolName, schema: .object(parameters))
        return try GenerationSchema(root: root, dependencies: [])
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
                let child = try build(name: "\(name)_\(propertyName)", schema: propertySchema)
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
    private let relay = ToolEventRelay()
    private let structuredSchemaStorage: (any Sendable)?
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
        configuration: AgentSessionConfiguration
    ) throws {
        self.manifest = manifest
        self.candidate = candidate

        let toolbox = AgentToolbox.resolve(config: manifest.config)
        let engine = ToolExecutionEngine(toolbox: toolbox, configuration: configuration)
        // Only normalized-allowed tools are ever registered with the model.
        // An agent with no tools configured registers zero tools.
        var bridgedTools: [any Tool] = []
        let relay = self.relay
        for definition in toolbox.tools {
            let schema = try GenerationSchemaBuilder.makeSchema(
                toolName: definition.name,
                parameters: definition.parameters
            )
            bridgedTools.append(
                ManifestBridgedTool(
                    name: definition.name,
                    description: definition.description,
                    parameters: schema,
                    engine: engine,
                    relay: relay
                )
            )
        }

        if let format = manifest.config.output?.format {
            guard format.type == AgentOutputFormat.jsonSchemaType else {
                throw AgentRuntimeError.unsupportedOutputFormat(format.type)
            }
            self.structuredSchemaStorage = try GenerationSchemaBuilder.makeSchema(
                toolName: "structured_output",
                parameters: format.schema
            )
        } else {
            self.structuredSchemaStorage = nil
        }

        self.sessionStorage = LanguageModelSession(
            tools: bridgedTools,
            instructions: manifest.config.systemPrompt
        )
        self.engine = engine
    }

    /// Preloads Foundation Models session state so the first token of the
    /// first turn arrives faster. Safe to call once at conversation entry.
    func prewarm() {
        session.prewarm()
    }

    private let engine: ToolExecutionEngine

    func send(_ text: String) async -> AsyncThrowingStream<AgentStreamEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<AgentStreamEvent, Error>.makeStream()
        if let limit = manifest.config.runtime.maxTurns, usedTurns >= limit {
            continuation.finish(throwing: AgentRuntimeError.maxTurnsExceeded(limit: limit))
            return stream
        }
        usedTurns += 1
        let turnIndex = usedTurns

        let task = Task {
            do {
                try await self.runTurn(text: text, turnIndex: turnIndex, continuation: continuation)
                continuation.finish()
            } catch is CancellationError {
                continuation.finish(throwing: AgentRuntimeError.cancelled)
            } catch let error as AgentRuntimeError {
                continuation.finish(throwing: error)
            } catch {
                continuation.finish(throwing: Self.mapGenerationError(error))
            }
        }
        activeTurn = task
        continuation.onTermination = { termination in
            if case .cancelled = termination {
                task.cancel()
            }
        }
        return stream
    }

    private func runTurn(
        text: String,
        turnIndex: Int,
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation
    ) async throws {
        continuation.yield(.start(AgentTurnStart(
            turn: turnIndex,
            candidate: candidate.name,
            model: candidate.model
        )))
        await engine.beginTurn()
        await relay.beginTurn(continuation)
        history.append(AgentMessage(role: .user, content: text))

        let finalText: String
        var structuredPayload: JSONValue?
        if let schema = structuredSchema, let format = manifest.config.output?.format {
            // Structured turns run guided generation and deliver the payload
            // on the end frame; no chunk frames are emitted.
            let response = try await session.respond(
                to: text,
                schema: schema,
                includeSchemaInPrompt: true
            )
            let json = response.content.jsonString
            structuredPayload = try format.decodeStructuredPayload(from: json)
            finalText = json
        } else if manifest.config.runtime.streaming {
            // Snapshots are cumulative within a segment, but the stream can
            // restart after an in-generation tool call, and a literal "null"
            // placeholder can precede text while a tool call is pending.
            var segments: [String] = []
            var current = ""
            let stream = session.streamResponse(to: text)
            for try await snapshot in stream {
                try Task.checkCancellation()
                let content = snapshot.content
                if content == "null" || content.isEmpty {
                    if !current.isEmpty {
                        segments.append(current)
                        current = ""
                    }
                    continue
                }
                if content.hasPrefix(current) {
                    let delta = String(content.dropFirst(current.count))
                    if !delta.isEmpty {
                        continuation.yield(.chunk(delta))
                    }
                } else {
                    // Restarted segment: close the previous one, emit fresh.
                    if !current.isEmpty {
                        segments.append(current)
                    }
                    continuation.yield(.chunk(content))
                }
                current = content
            }
            if !current.isEmpty {
                segments.append(current)
            }
            finalText = segments.joined()
        } else {
            let response = try await session.respond(to: text)
            finalText = response.content
        }

        let toolResults = await relay.endTurn()
        history.append(AgentMessage(role: .assistant, content: finalText))
        let remaining = manifest.config.runtime.maxTurns.map { max(0, $0 - usedTurns) }
        continuation.yield(.end(AgentTurnResult(
            text: finalText,
            toolResults: toolResults,
            remainingTurns: remaining,
            structured: structuredPayload
        )))
    }

    func cancel() {
        activeTurn?.cancel()
        activeTurn = nil
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
