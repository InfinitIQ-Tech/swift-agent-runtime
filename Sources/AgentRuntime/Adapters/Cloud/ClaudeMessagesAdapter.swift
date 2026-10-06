import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Cloud adapter for the Anthropic Messages API, behind the same runtime
/// protocol as the on-device adapter. Provider keys are per-session
/// configuration: never part of the manifest, never persisted, never logged.
public struct ClaudeMessagesAdapter: AgentRuntimeAdapter {
    public let identifier = "anthropic-messages"

    /// Per-response output-token ceiling sent as `max_tokens`.
    public var maxTokens: Int
    /// Messages API endpoint; overridable for proxies and tests.
    public var endpoint: URL
    private let transport: HTTPStreamTransport

    public init(
        maxTokens: Int = 8192,
        endpoint: URL? = nil,
        transport: HTTPStreamTransport = URLSessionStreamTransport()
    ) {
        self.maxTokens = maxTokens
        self.endpoint = endpoint ?? AnthropicWire.defaultBaseURL
        self.transport = transport
    }

    public func supports(candidate: AgentModelCandidate) -> Bool {
        candidate.provider == ProviderKeys.anthropicProvider
            && !candidate.modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func availability(
        for candidate: AgentModelCandidate,
        configuration: AgentSessionConfiguration
    ) -> AgentRuntimeAvailability {
        guard supports(candidate: candidate) else {
            return .unavailable(.unsupportedModel)
        }
        guard let key = configuration.providerKeys[ProviderKeys.anthropicProvider],
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unavailable(.missingProviderKey(provider: ProviderKeys.anthropicProvider))
        }
        return .available
    }

    public func makeSession(
        manifest: AgentManifest,
        candidate: AgentModelCandidate,
        configuration: AgentSessionConfiguration
    ) throws -> any AgentSession {
        if case .unavailable(let reason) = availability(for: candidate, configuration: configuration) {
            throw AgentRuntimeError.modelUnavailable(reason)
        }
        guard let key = configuration.providerKeys[ProviderKeys.anthropicProvider] else {
            throw AgentRuntimeError.modelUnavailable(.missingProviderKey(provider: ProviderKeys.anthropicProvider))
        }
        _ = try manifest.config.output?.format.validatedSchema()
        return ClaudeMessagesSession(
            manifest: manifest,
            candidate: candidate,
            configuration: configuration,
            apiKey: key,
            maxTokens: maxTokens,
            endpoint: endpoint,
            transport: transport
        )
    }
}

/// A live cloud session running the agent loop against the Messages API:
/// stream a response, execute any requested tools through the shared
/// `ToolExecutionEngine`, feed results back, repeat until the model finishes.
actor ClaudeMessagesSession: AgentSession {
    nonisolated let manifest: AgentManifest
    private let candidate: AgentModelCandidate
    private let providerKeys: ProviderKeys
    private let maxTokens: Int
    private let endpoint: URL
    private let transport: HTTPStreamTransport
    private let engine: ToolExecutionEngine
    private let toolbox: AgentToolbox

    private var wireMessages: [AnthropicWire.Message] = []
    private var history: [AgentMessage] = []
    private var usedTurns = 0
    private var activeTurn: Task<Void, Never>?

    init(
        manifest: AgentManifest,
        candidate: AgentModelCandidate,
        configuration: AgentSessionConfiguration,
        apiKey: String,
        maxTokens: Int,
        endpoint: URL,
        transport: HTTPStreamTransport
    ) {
        self.manifest = manifest
        self.candidate = candidate
        self.providerKeys = ProviderKeys([ProviderKeys.anthropicProvider: apiKey])
        self.maxTokens = maxTokens
        self.endpoint = endpoint
        self.transport = transport
        self.toolbox = AgentToolbox.resolve(config: manifest.config)
        self.engine = ToolExecutionEngine(toolbox: toolbox, configuration: configuration)
    }

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
            let originalWireCount = wireMessages.count
            let failure: AgentRuntimeError?
            do {
                let result = try await runTurn(text: text, turnIndex: turnIndex, continuation: continuation)
                try publishTurnResult(result, to: continuation)
                failure = nil
            } catch {
                // Rejected/interrupted rounds must not contaminate later requests.
                // Host tool effects cannot be undone by rolling back conversation state.
                wireMessages.removeSubrange(originalWireCount...)
                failure = Self.safeError(error)
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

    /// Cloud sessions have no local model state to warm; no-op so hosts can
    /// call `prewarm()` uniformly across adapters.
    func prewarm() {}

    func cancel() {
        activeTurn?.cancel()
    }

    func transcript() -> [AgentMessage] {
        history
    }

    func turnsUsed() -> Int {
        usedTurns
    }

    /// No suspension between accepted terminal publication and history commit.
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
            throw AgentRuntimeError.generationFailed("Terminal event was dropped")
        @unknown default:
            throw AgentRuntimeError.generationFailed("Terminal event was not accepted")
        }
    }

    // MARK: - Agent loop

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
        history.append(AgentMessage(role: .user, content: text))
        wireMessages.append(AnthropicWire.Message(role: "user", content: [.text(text)]))

        var turnText = ""
        var finalRoundText = ""
        var turnToolResults: [AgentToolResult] = []
        // Bounds model<->tool rounds within one turn so a misbehaving loop
        // terminates; `runtime.max_turns` wins when configured.
        let roundCap = manifest.config.runtime.maxTurns ?? 8
        var round = 0

        while true {
            try Task.checkCancellation()
            round += 1
            let outcome = try await requestOnce(continuation: continuation)
            try Task.checkCancellation()
            if !outcome.text.isEmpty {
                turnText += outcome.text
            }
            finalRoundText = outcome.text

            let toolUses = outcome.toolUses
            guard outcome.stopReason == "tool_use", !toolUses.isEmpty else {
                // Previous tool-round text already exists in its own message.
                wireMessages.append(AnthropicWire.Message(role: "assistant", content: outcome.blocks))
                break
            }
            guard round < roundCap else {
                throw AgentRuntimeError.maxTurnsExceeded(limit: roundCap)
            }

            // Echo the assistant turn, then answer every tool_use in one user message.
            wireMessages.append(AnthropicWire.Message(role: "assistant", content: outcome.blocks))
            let calls = toolUses.map { use in
                AgentToolCall(toolId: use.name, callId: use.id, args: use.input)
            }
            for call in calls {
                continuation.yield(.toolCall(call))
            }
            try Task.checkCancellation()
            let results = await engine.execute(calls)
            try Task.checkCancellation()
            var resultBlocks: [AnthropicWire.ContentBlock] = []
            for result in results {
                continuation.yield(.toolResult(result))
                turnToolResults.append(result)
                resultBlocks.append(.toolResult(
                    toolUseId: result.callId ?? "",
                    content: result.output,
                    isError: !result.success
                ))
            }
            wireMessages.append(AnthropicWire.Message(role: "user", content: resultBlocks))
        }

        // The final round's text is the schema-conforming payload; earlier
        // rounds may carry interstitial text around tool calls.
        var structuredPayload: JSONValue?
        if let format = manifest.config.output?.format {
            structuredPayload = try format.decodeStructuredPayload(from: finalRoundText)
            turnText = finalRoundText
        }

        try Task.checkCancellation()
        let remaining = manifest.config.runtime.maxTurns.map { max(0, $0 - usedTurns) }
        return AgentTurnResult(
            text: turnText,
            toolResults: turnToolResults,
            remainingTurns: remaining,
            structured: structuredPayload
        )
    }

    private struct RoundOutcome {
        var text: String = ""
        var blocks: [AnthropicWire.ContentBlock] = []
        var toolUses: [(id: String, name: String, input: [String: JSONValue])] = []
        var stopReason: String?
    }

    private func makeRequest(streaming: Bool) throws -> URLRequest {
        let wireTools: [AnthropicWire.Tool]? = toolbox.isEmpty ? nil : toolbox.tools.map { definition in
            AnthropicWire.Tool(
                name: definition.name,
                description: definition.description,
                inputSchema: definition.parameters
            )
        }
        let outputConfig = manifest.config.output.map { output in
            AnthropicWire.OutputConfig(
                format: AnthropicWire.OutputFormat(
                    type: output.format.type,
                    schema: output.format.schema
                )
            )
        }
        let body = AnthropicWire.Request(
            model: candidate.modelIdentifier,
            maxTokens: maxTokens,
            system: manifest.config.systemPrompt,
            messages: wireMessages,
            tools: wireTools,
            stream: streaming,
            outputConfig: outputConfig
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(providerKeys[ProviderKeys.anthropicProvider], forHTTPHeaderField: "x-api-key")
        request.setValue(AnthropicWire.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private func requestOnce(
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation
    ) async throws -> RoundOutcome {
        // Structured turns execute non-streaming so no partial-JSON chunk
        // frames are emitted; the payload is delivered whole on the end
        // frame, matching the on-device lane.
        if manifest.config.runtime.streaming, manifest.config.output == nil {
            return try await streamRound(continuation: continuation)
        }
        return try await blockingRound()
    }

    private func blockingRound() async throws -> RoundOutcome {
        let request = try makeRequest(streaming: false)
        let (data, status): (Data, Int)
        do { (data, status) = try await transport.send(request) }
        catch { throw Self.transportError(error) }
        try Task.checkCancellation()
        guard status == 200 else {
            throw Self.mapHTTPError(status: status, body: data)
        }
        let response: AnthropicWire.Response
        do {
            response = try JSONDecoder().decode(AnthropicWire.Response.self, from: data)
        } catch {
            throw AgentRuntimeError.invalidProviderResponse("Undecodable Messages API response")
        }
        var outcome = RoundOutcome()
        outcome.stopReason = response.stopReason
        outcome.blocks = response.content
        for block in response.content {
            switch block {
            case .text(let text):
                outcome.text += text
            case .toolUse(let id, let name, let input):
                outcome.toolUses.append((id: id, name: name, input: input))
            case .toolResult, .opaque:
                break
            }
        }
        try Self.validate(outcome)
        return outcome
    }

    // Streaming SSE round. Event shapes per the Messages API streaming
    // contract: message_start, content_block_start, content_block_delta
    // (text_delta / input_json_delta), content_block_stop, message_delta
    // (stop_reason), message_stop.
    private func streamRound(
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation
    ) async throws -> RoundOutcome {
        let request = try makeRequest(streaming: true)
        let lines: AsyncThrowingStream<String, Error>
        let status: Int
        do { (lines, status) = try await transport.streamLines(request) }
        catch { throw Self.transportError(error) }
        try Task.checkCancellation()
        guard status == 200 else {
            // Only a bounded body is needed to recognize context overflow.
            var body = Data()
            do {
                for try await line in lines {
                    try Task.checkCancellation()
                    body.append(contentsOf: (line + "\n").utf8.prefix(max(0, 16_384 - body.count)))
                    if body.count >= 16_384 { break }
                }
            } catch let error as URLError where error.code == .dataLengthExceedsMaximum {
                // The bounded reader cancelled an oversized error body. The
                // known HTTP status is still authoritative and safe to report.
                try Task.checkCancellation()
            } catch { throw Self.transportError(error) }
            throw Self.mapHTTPError(status: status, body: body)
        }

        var parser = ServerSentEventParser()
        var accumulator = AnthropicStreamAccumulator()
        var iterator = lines.makeAsyncIterator()
        while !accumulator.isComplete {
            let line: String?
            do { line = try await iterator.next() }
            catch { throw Self.transportError(error) }
            try Task.checkCancellation()
            guard let line else { break }
            if let event = parser.consume(line: line), let text = try accumulator.consume(event) {
                continuation.yield(.chunk(text))
            }
        }
        try Task.checkCancellation()
        if !accumulator.isComplete, let event = parser.flush(), let text = try accumulator.consume(event) {
            continuation.yield(.chunk(text))
        }
        guard accumulator.isComplete else {
            throw AgentRuntimeError.invalidProviderResponse("Incomplete Messages API stream")
        }
        var outcome = RoundOutcome()
        outcome.text = accumulator.text
        outcome.blocks = accumulator.content
        outcome.stopReason = accumulator.stopReason
        for block in outcome.blocks {
            if case .toolUse(let id, let name, let input) = block {
                outcome.toolUses.append((id: id, name: name, input: input))
            }
        }
        try Self.validate(outcome)
        return outcome
    }

    private static func validate(_ outcome: RoundOutcome) throws {
        guard let reason = outcome.stopReason, !reason.isEmpty else {
            throw AgentRuntimeError.invalidProviderResponse("Incomplete Messages API response")
        }
        // The runtime end frame represents a completed turn and cannot expose
        // provider truncation metadata. Never turn a partial result into success
        // or automatically continue a request that could incur further charges.
        switch reason {
        case "end_turn", "stop_sequence", "tool_use": break
        case "model_context_window_exceeded": throw AgentRuntimeError.contextWindowExceeded
        case "max_tokens": throw AgentRuntimeError.generationFailed("Messages API output token limit reached")
        case "pause_turn": throw AgentRuntimeError.generationFailed("Messages API server turn is incomplete")
        case "refusal": throw AgentRuntimeError.guardrailViolation
        default: throw AgentRuntimeError.invalidProviderResponse("Unsupported Messages API stop reason")
        }
        guard (reason == "tool_use") == !outcome.toolUses.isEmpty,
              outcome.toolUses.allSatisfy({ !$0.id.isEmpty && !$0.name.isEmpty }),
              Set(outcome.toolUses.map(\.id)).count == outcome.toolUses.count else {
            throw AgentRuntimeError.invalidProviderResponse("Incomplete Messages API response")
        }
    }

    private static func transportError(_ error: any Error) -> AgentRuntimeError {
        if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
            return .cancelled
        }
        if let error = error as? URLError {
            return .generationFailed("Messages API transport failed (code \(error.code.rawValue))")
        }
        return .generationFailed("Messages API transport failed")
    }

    private static func safeError(_ error: any Error) -> AgentRuntimeError {
        if Task.isCancelled || error is CancellationError { return .cancelled }
        guard let error = error as? AgentRuntimeError else { return transportError(error) }
        if case .structuredOutputInvalid = error {
            return .structuredOutputInvalid("Provider output does not match the declared schema")
        }
        return error
    }

    static func mapHTTPError(status: Int, body: Data) -> AgentRuntimeError {
        let envelope = try? JSONDecoder().decode(AnthropicWire.APIErrorEnvelope.self, from: Data(body.prefix(16_384)))
        let message = envelope?.error.message.lowercased() ?? ""
        switch status {
        case 400 where message.contains("too long") || message.contains("context"):
            return .contextWindowExceeded
        case 401, 403:
            return .modelUnavailable(.missingProviderKey(provider: ProviderKeys.anthropicProvider))
        case 429, 500...599:
            return .generationFailed("Messages API status \(status)")
        default:
            return .invalidProviderResponse("Messages API status \(status)")
        }
    }

    static func mapStreamError(type: String?, message: String?) -> AgentRuntimeError {
        switch type {
        case "authentication_error", "permission_error":
            return .modelUnavailable(.missingProviderKey(provider: ProviderKeys.anthropicProvider))
        case "invalid_request_error":
            let message = message?.lowercased() ?? ""
            if message.contains("too long") || message.contains("context") { return .contextWindowExceeded }
            return .invalidProviderResponse("Messages API rejected the request")
        default:
            return .generationFailed("Messages API stream failed")
        }
    }
}
