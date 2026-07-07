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
    }

    public func availability(
        for candidate: AgentModelCandidate,
        configuration: AgentSessionConfiguration
    ) -> AgentRuntimeAvailability {
        guard supports(candidate: candidate) else {
            return .unavailable(.unsupportedModel)
        }
        guard configuration.providerKeys[ProviderKeys.anthropicProvider] != nil else {
            return .unavailable(.missingProviderKey(provider: ProviderKeys.anthropicProvider))
        }
        return .available
    }

    public func makeSession(
        manifest: AgentManifest,
        candidate: AgentModelCandidate,
        configuration: AgentSessionConfiguration
    ) throws -> any AgentSession {
        guard let key = configuration.providerKeys[ProviderKeys.anthropicProvider] else {
            throw AgentRuntimeError.modelUnavailable(.missingProviderKey(provider: ProviderKeys.anthropicProvider))
        }
        if let format = manifest.config.output?.format,
           format.type != AgentOutputFormat.jsonSchemaType {
            throw AgentRuntimeError.unsupportedOutputFormat(format.type)
        }
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
    private let apiKey: String
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
        self.apiKey = apiKey
        self.maxTokens = maxTokens
        self.endpoint = endpoint
        self.transport = transport
        self.toolbox = AgentToolbox.resolve(config: manifest.config)
        self.engine = ToolExecutionEngine(toolbox: toolbox, configuration: configuration)
    }

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
            } catch {
                continuation.finish(throwing: error)
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

    /// Cloud sessions have no local model state to warm; no-op so hosts can
    /// call `prewarm()` uniformly across adapters.
    func prewarm() {}

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

    // MARK: - Agent loop

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
            round += 1
            let outcome = try await requestOnce(continuation: continuation)
            if !outcome.text.isEmpty {
                turnText += outcome.text
            }
            finalRoundText = outcome.text

            let toolUses = outcome.toolUses
            guard outcome.stopReason == "tool_use", !toolUses.isEmpty else {
                if outcome.stopReason == "refusal" {
                    throw AgentRuntimeError.guardrailViolation
                }
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
            let results = await engine.execute(calls)
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
        }

        history.append(AgentMessage(role: .assistant, content: turnText))
        wireMessages.append(AnthropicWire.Message(role: "assistant", content: [.text(turnText)]))
        let remaining = manifest.config.runtime.maxTurns.map { max(0, $0 - usedTurns) }
        continuation.yield(.end(AgentTurnResult(
            text: turnText,
            toolResults: turnToolResults,
            remainingTurns: remaining,
            structured: structuredPayload
        )))
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
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
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
        let (data, status) = try await transport.send(request)
        guard status == 200 else {
            throw Self.mapHTTPError(status: status, body: data)
        }
        let response: AnthropicWire.Response
        do {
            response = try JSONDecoder().decode(AnthropicWire.Response.self, from: data)
        } catch {
            throw AgentRuntimeError.invalidProviderResponse("Undecodable Messages API response: \(error)")
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
            case .toolResult:
                break
            }
        }
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
        let (lines, status) = try await transport.streamLines(request)
        guard status == 200 else {
            var body = Data()
            for try await line in lines {
                body.append(Data((line + "\n").utf8))
            }
            throw Self.mapHTTPError(status: status, body: body)
        }

        var outcome = RoundOutcome()
        var parser = ServerSentEventParser()
        // Tool-use blocks under construction, keyed by content block index.
        var pendingTools: [Int: (id: String, name: String, json: String)] = [:]

        func handle(_ event: ServerSentEvent) throws {
            guard let data = event.data.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                return
            }
            let type = payload["type"]?.stringValue ?? event.event ?? ""
            switch type {
            case "content_block_start":
                guard case .integer(let index)? = payload["index"],
                      let block = payload["content_block"] else { return }
                if block["type"]?.stringValue == "tool_use" {
                    pendingTools[index] = (
                        id: block["id"]?.stringValue ?? "",
                        name: block["name"]?.stringValue ?? "",
                        json: ""
                    )
                }
            case "content_block_delta":
                guard case .integer(let index)? = payload["index"],
                      let delta = payload["delta"] else { return }
                switch delta["type"]?.stringValue {
                case "text_delta":
                    let text = delta["text"]?.stringValue ?? ""
                    outcome.text += text
                    if !text.isEmpty {
                        continuation.yield(.chunk(text))
                    }
                case "input_json_delta":
                    pendingTools[index]?.json += delta["partial_json"]?.stringValue ?? ""
                default:
                    break
                }
            case "content_block_stop":
                guard case .integer(let index)? = payload["index"],
                      let pending = pendingTools.removeValue(forKey: index) else { return }
                let input: [String: JSONValue]
                if let inputData = pending.json.data(using: .utf8),
                   let decoded = try? JSONDecoder().decode(JSONValue.self, from: inputData),
                   case .object(let members) = decoded {
                    input = members
                } else {
                    input = [:]
                }
                outcome.toolUses.append((id: pending.id, name: pending.name, input: input))
            case "message_delta":
                if let stop = payload["delta"]?["stop_reason"]?.stringValue {
                    outcome.stopReason = stop
                }
            case "error":
                let message = payload["error"]?["message"]?.stringValue ?? "stream error"
                throw AgentRuntimeError.generationFailed(message)
            default:
                break
            }
        }

        for try await line in lines {
            try Task.checkCancellation()
            if let event = parser.consume(line: line) {
                try handle(event)
            }
        }
        if let event = parser.flush() {
            try handle(event)
        }

        // Rebuild assistant blocks for the replay envelope.
        if !outcome.text.isEmpty {
            outcome.blocks.append(.text(outcome.text))
        }
        for use in outcome.toolUses {
            outcome.blocks.append(.toolUse(id: use.id, name: use.name, input: use.input))
        }
        return outcome
    }

    static func mapHTTPError(status: Int, body: Data) -> AgentRuntimeError {
        let envelope = try? JSONDecoder().decode(AnthropicWire.APIErrorEnvelope.self, from: body)
        let message = envelope?.error.message ?? String(data: body, encoding: .utf8) ?? ""
        switch status {
        case 400 where message.lowercased().contains("too long")
            || message.lowercased().contains("context"):
            return .contextWindowExceeded
        case 401, 403:
            return .modelUnavailable(.missingProviderKey(provider: ProviderKeys.anthropicProvider))
        case 429, 500..., 529:
            return .generationFailed("Messages API status \(status): \(message)")
        default:
            return .invalidProviderResponse("Messages API status \(status): \(message)")
        }
    }
}
