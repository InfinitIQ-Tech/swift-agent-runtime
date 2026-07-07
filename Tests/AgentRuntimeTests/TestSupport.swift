import Foundation
import XCTest
@testable import AgentRuntime

enum Fixtures {
    static func resourceURL(_ name: String) throws -> URL {
        let url = Bundle.module.url(forResource: "Resources/\(name)", withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil)
        return try XCTUnwrap(url, "missing test resource \(name)")
    }

    static func resourceData(_ name: String) throws -> Data {
        try Data(contentsOf: resourceURL(name))
    }

    static func manifest(named name: String = "on-device-story-agent.json") throws -> AgentManifest {
        try AgentManifestLoader.load(resourceData(name))
    }

    static func config(
        streaming: Bool = true,
        maxTurns: Int? = nil,
        maxConcurrentTools: Int? = nil,
        tools: AgentToolsConfig? = nil,
        candidates: [AgentModelCandidate] = [AgentModelCandidate(name: "cloud", model: "anthropic:claude-haiku-4-5")],
        strategy: String = "fallback",
        output: AgentOutputConfig? = nil
    ) -> AgentConfig {
        AgentConfig(
            id: "test_agent",
            name: "Test Agent",
            version: "v1",
            schemaVersion: "2",
            systemPrompt: "You are a test agent.",
            runtime: AgentRuntimeConfig(streaming: streaming, maxTurns: maxTurns, maxConcurrentTools: maxConcurrentTools),
            model: AgentModelConfig(strategy: strategy, candidates: candidates),
            tools: tools,
            output: output
        )
    }

    /// A structured-output declaration matching the DREAM-18 shape: a reply
    /// plus tappable choices.
    static func outputConfig(type: String = "json_schema") -> AgentOutputConfig {
        AgentOutputConfig(format: AgentOutputFormat(
            type: type,
            schema: [
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "required": .array([.string("reply"), .string("choices")]),
                "properties": .object([
                    "reply": .object(["type": .string("string")]),
                    "choices": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")])
                    ])
                ])
            ]
        ))
    }

    static func manifest(for config: AgentConfig) throws -> AgentManifest {
        let data = try JSONEncoder().encode(config)
        return try AgentManifestLoader.load(data)
    }

    static func toolDefinition(
        name: String,
        endpoint: ToolEndpoint? = nil
    ) -> ToolDefinition {
        ToolDefinition(
            name: name,
            description: "Test tool \(name)",
            parameters: [
                "type": .string("object"),
                "properties": .object(["query": .object(["type": .string("string")])]),
                "required": .array([.string("query")])
            ],
            endpoint: endpoint
        )
    }
}

// MARK: - Webhook transport stub

/// Scripted webhook transport. Each call pops the next scripted result.
final class StubWebhookTransport: WebhookTransport, @unchecked Sendable {
    enum Step {
        case respond(status: Int, body: String)
        case fail(any Error)
    }

    private let lock = NSLock()
    private var steps: [Step]
    private(set) var requests: [URLRequest] = []

    init(steps: [Step]) {
        self.steps = steps
    }

    private func record(_ request: URLRequest) -> Step? {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        return steps.isEmpty ? nil : steps.removeFirst()
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let step = record(request)
        switch step {
        case .respond(let status, let body):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(body.utf8), response)
        case .fail(let error):
            throw error
        case nil:
            throw URLError(.unsupportedURL)
        }
    }
}

// MARK: - Cloud transport stub

/// Scripted Messages API transport. Each round pops the next scripted response.
final class StubHTTPTransport: HTTPStreamTransport, @unchecked Sendable {
    enum Step {
        /// Non-streaming JSON response.
        case json(status: Int, body: String)
        /// Streaming SSE response delivered as raw lines.
        case sse(status: Int, lines: [String])
    }

    private let lock = NSLock()
    private var steps: [Step]
    private(set) var requestBodies: [Data] = []
    private(set) var requests: [URLRequest] = []

    init(steps: [Step]) {
        self.steps = steps
    }

    private func record(_ request: URLRequest) -> Step? {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        requestBodies.append(request.httpBody ?? Data())
        return steps.isEmpty ? nil : steps.removeFirst()
    }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        switch record(request) {
        case .json(let status, let body):
            return (Data(body.utf8), status)
        case .sse:
            throw URLError(.unsupportedURL)
        case nil:
            throw URLError(.unsupportedURL)
        }
    }

    func streamLines(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, Int) {
        switch record(request) {
        case .sse(let status, let lines):
            let stream = AsyncThrowingStream<String, Error> { continuation in
                for line in lines {
                    continuation.yield(line)
                }
                continuation.finish()
            }
            return (stream, status)
        case .json(let status, let body):
            let stream = AsyncThrowingStream<String, Error> { continuation in
                continuation.yield(body)
                continuation.finish()
            }
            return (stream, status)
        case nil:
            throw URLError(.unsupportedURL)
        }
    }
}

extension StubHTTPTransport {
    /// SSE lines for a plain text streaming round.
    static func textRound(_ chunks: [String], stopReason: String = "end_turn") -> [String] {
        var lines = [
            "event: message_start",
            "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\"}}",
            "",
            "event: content_block_start",
            "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
            ""
        ]
        for chunk in chunks {
            let escaped = chunk.replacingOccurrences(of: "\"", with: "\\\"")
            lines += [
                "event: content_block_delta",
                "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"\(escaped)\"}}",
                ""
            ]
        }
        lines += [
            "event: content_block_stop",
            "data: {\"type\":\"content_block_stop\",\"index\":0}",
            "",
            "event: message_delta",
            "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"\(stopReason)\"},\"usage\":{\"output_tokens\":5}}",
            "",
            "event: message_stop",
            "data: {\"type\":\"message_stop\"}",
            ""
        ]
        return lines
    }

    /// SSE lines for a round where the model calls one tool.
    static func toolUseRound(toolName: String, callId: String, argumentsJSON: String) -> [String] {
        let escapedArgs = argumentsJSON
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return [
            "event: message_start",
            "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_2\"}}",
            "",
            "event: content_block_start",
            "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"\(callId)\",\"name\":\"\(toolName)\",\"input\":{}}}",
            "",
            "event: content_block_delta",
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"\(escapedArgs)\"}}",
            "",
            "event: content_block_stop",
            "data: {\"type\":\"content_block_stop\",\"index\":0}",
            "",
            "event: message_delta",
            "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":5}}",
            "",
            "event: message_stop",
            "data: {\"type\":\"message_stop\"}",
            ""
        ]
    }
}

// MARK: - Stub adapter / session

actor StubSession: AgentSession {
    nonisolated let manifest: AgentManifest

    init(manifest: AgentManifest) {
        self.manifest = manifest
    }

    func send(_ text: String) async -> AsyncThrowingStream<AgentStreamEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<AgentStreamEvent, Error>.makeStream()
        continuation.yield(.end(AgentTurnResult(text: "stub: \(text)")))
        continuation.finish()
        return stream
    }

    func prewarm() {}
    func cancel() {}
    func transcript() -> [AgentMessage] { [] }
    func turnsUsed() -> Int { 0 }
}

struct StubAdapter: AgentRuntimeAdapter {
    let identifier: String
    let provider: String
    let availabilityResult: AgentRuntimeAvailability

    func supports(candidate: AgentModelCandidate) -> Bool {
        candidate.provider == provider
    }

    func availability(
        for candidate: AgentModelCandidate,
        configuration: AgentSessionConfiguration
    ) -> AgentRuntimeAvailability {
        supports(candidate: candidate) ? availabilityResult : .unavailable(.unsupportedModel)
    }

    func makeSession(
        manifest: AgentManifest,
        candidate: AgentModelCandidate,
        configuration: AgentSessionConfiguration
    ) throws -> any AgentSession {
        StubSession(manifest: manifest)
    }
}

// MARK: - Event collection

func collectEvents(
    _ stream: AsyncThrowingStream<AgentStreamEvent, Error>
) async throws -> [AgentStreamEvent] {
    var events: [AgentStreamEvent] = []
    for try await event in stream {
        events.append(event)
    }
    return events
}
