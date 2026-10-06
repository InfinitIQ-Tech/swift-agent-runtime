import AgentRuntime
import Foundation
import XCTest
@testable import RuntimeDemoSupport

private actor SmokeTransportStub: HTTPStreamTransport {
    enum Behavior: Sendable { case success, failure, gated }
    private let behavior: Behavior
    private let started: (@Sendable () -> Void)?
    private let responseLines: [String]
    private let streamStatus: Int
    private var pending: CheckedContinuation<Void, Never>?
    private(set) var requests: [URLRequest] = []
    private(set) var methods: [String] = []

    init(
        _ behavior: Behavior = .success,
        responseLines: [String] = ["data: first", "", "data: second", ""],
        streamStatus: Int = 202,
        started: (@Sendable () -> Void)? = nil
    ) {
        self.behavior = behavior
        self.responseLines = responseLines
        self.streamStatus = streamStatus
        self.started = started
    }

    func release() { pending?.resume(); pending = nil }

    private func record(_ request: URLRequest, method: String) async throws {
        requests.append(request)
        methods.append(method)
        switch behavior {
        case .failure: throw URLError(.timedOut)
        case .gated:
            await withCheckedContinuation { continuation in
                pending = continuation
                started?()
            }
            try Task.checkCancellation()
        case .success: break
        }
    }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        try await record(request, method: "send")
        return (Data("response-body".utf8), 201)
    }

    func streamLines(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, Int) {
        try await record(request, method: "streamLines")
        return (AsyncThrowingStream { continuation in
            for line in responseLines { continuation.yield(line) }
            continuation.finish()
        }, streamStatus)
    }
}

final class SingleRequestCloudTransportTests: XCTestCase {
    private let sentinel = "smoke-test-credential-sentinel"

    private func request(tier: String? = nil) throws -> URLRequest {
        var fields: [String: JSONValue] = [
            "model": .string("test-model"), "max_tokens": .integer(256), "stream": .bool(true),
            "messages": .array([.object(["role": .string("user"), "content": .string("short prompt")])])
        ]
        if let tier { fields["service_tier"] = .string(tier) }
        var request = URLRequest(url: URL(string: "https://example.invalid/messages")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(JSONValue.object(fields))
        request.setValue(sentinel, forHTTPHeaderField: "x-api-key")
        return request
    }

    private func assertBudgetExhausted(_ transport: SingleRequestCloudTransport, request: URLRequest) async {
        do { _ = try await transport.send(request); XCTFail("second send must fail") }
        catch { XCTAssertEqual(error as? AgentRuntimeError, .generationFailed("Cloud smoke test request limit reached")) }
        do { _ = try await transport.streamLines(request); XCTFail("second stream must fail") }
        catch { XCTAssertEqual(error as? AgentRuntimeError, .generationFailed("Cloud smoke test request limit reached")) }
    }

    func testSendPassesResponseAndPreservesRequestFieldsWithStandardTier() async throws {
        let stub = SmokeTransportStub()
        let transport = SingleRequestCloudTransport(transport: stub)
        let request = try request()
        let (body, status) = try await transport.send(request)
        XCTAssertEqual(body, Data("response-body".utf8))
        XCTAssertEqual(status, 201)
        let forwardedRequests = await stub.requests
        let forwarded = try XCTUnwrap(forwardedRequests.first)
        XCTAssertEqual(forwarded.url, request.url)
        XCTAssertEqual(forwarded.httpMethod, request.httpMethod)
        XCTAssertEqual(forwarded.allHTTPHeaderFields, request.allHTTPHeaderFields)
        let original = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(request.httpBody))
        let actual = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(forwarded.httpBody))
        guard case .object(var expected) = original else { return XCTFail("expected object") }
        expected["service_tier"] = .string("standard_only")
        XCTAssertEqual(actual, .object(expected))
        await assertBudgetExhausted(transport, request: request)
        let calls = await stub.methods
        XCTAssertEqual(calls, ["send"])
    }

    func testStreamingPassesLinesAndOverridesAutoTier() async throws {
        let stub = SmokeTransportStub()
        let transport = SingleRequestCloudTransport(transport: stub)
        let request = try request(tier: "auto")
        let (stream, status) = try await transport.streamLines(request)
        var lines: [String] = []
        for try await line in stream { lines.append(line) }
        XCTAssertEqual(lines, ["data: first", "", "data: second", ""])
        XCTAssertEqual(status, 202)
        let requests = await stub.requests
        let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(requests.first?.httpBody))
        XCTAssertEqual(body["service_tier"], .string("standard_only"))
        await assertBudgetExhausted(transport, request: request)
        let calls = await stub.methods
        XCTAssertEqual(calls, ["streamLines"])
    }

    func testFailedAttemptConsumesSharedBudgetForEitherMethod() async throws {
        for streaming in [true, false] {
            let stub = SmokeTransportStub(.failure)
            let transport = SingleRequestCloudTransport(transport: stub)
            let request = try request()
            do {
                if streaming { _ = try await transport.streamLines(request) }
                else { _ = try await transport.send(request) }
                XCTFail("expected first failure")
            } catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
            await assertBudgetExhausted(transport, request: request)
            let requests = await stub.requests
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testConcurrentMixedMethodCannotEnterUnderlyingTransportTwice() async throws {
        let started = expectation(description: "underlying send entered")
        let stub = SmokeTransportStub(.gated) { started.fulfill() }
        let transport = SingleRequestCloudTransport(transport: stub)
        let request = try request()
        let first = Task { try await transport.send(request) }
        await fulfillment(of: [started], timeout: 5)
        await assertBudgetExhausted(transport, request: request)
        await stub.release()
        let (_, status) = try await first.value
        XCTAssertEqual(status, 201)
        let requests = await stub.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testCancellationDoesNotRestoreBudget() async throws {
        let started = expectation(description: "underlying stream entered")
        let stub = SmokeTransportStub(.gated) { started.fulfill() }
        let transport = SingleRequestCloudTransport(transport: stub)
        let request = try request()
        let first = Task { try await transport.streamLines(request) }
        await fulfillment(of: [started], timeout: 5)
        first.cancel()
        await stub.release()
        do { _ = try await first.value; XCTFail("expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        await assertBudgetExhausted(transport, request: request)
        let requests = await stub.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testCheckedInManifestStreamsThroughClaudeWithOneStandardTierRequest() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manifestURL = root.appendingPathComponent("Manifests/story-companion.agentconfig.json")
        let originalManifest = try Data(contentsOf: manifestURL)
        let manifest = try AgentManifestLoader.load(originalManifest)
        let responseLines = """
        event: message_start
        data: {"type":"message_start","message":{"id":"test-message"}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"A sleepy fox found a cozy den."}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}

        event: message_stop
        data: {"type":"message_stop"}

        """.components(separatedBy: "\n")
        let stub = SmokeTransportStub(responseLines: responseLines, streamStatus: 200)
        let transport = SingleRequestCloudTransport(transport: stub)
        let adapter = ClaudeMessagesAdapter(maxTokens: 256, transport: transport)
        let session = try AgentRuntimeResolver.makeSession(
            manifest: manifest,
            configuration: .init(providerKeys: .init(["anthropic": sentinel])),
            adapters: [adapter]
        )
        var events: [AgentStreamEvent] = []
        for try await event in await session.send("Tell a very short gentle bedtime story.") { events.append(event) }
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[1], .chunk("A sleepy fox found a cozy den."))
        XCTAssertEqual(events.last, .end(.init(text: "A sleepy fox found a cozy den.", remainingTurns: 5)))
        let requests = await stub.requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        let body = try XCTUnwrap(request.httpBody)
        let payload = try JSONDecoder().decode(JSONValue.self, from: body)
        XCTAssertEqual(payload["model"], .string("claude-haiku-4-5"))
        XCTAssertEqual(payload["max_tokens"], .integer(256))
        XCTAssertEqual(payload["service_tier"], .string("standard_only"))
        XCTAssertEqual(payload["stream"], .bool(true))
        XCTAssertEqual(payload["system"], .string(manifest.config.systemPrompt))
        let expectedTools = (manifest.config.tools?.definitions ?? []).map { tool in
            JSONValue.object(["name": .string(tool.name), "description": .string(tool.description), "input_schema": .object(tool.parameters)])
        }
        XCTAssertEqual(payload["tools"], .array(expectedTools))
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), sentinel)
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains(sentinel))
        XCTAssertEqual(try Data(contentsOf: manifestURL), originalManifest)
    }

    func testActualClaudeToolRoundCannotReachSecondUpstreamRequest() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try AgentManifestLoader.load(contentsOf: root.appendingPathComponent("Manifests/story-companion.agentconfig.json"))
        let responseLines = #"""
        event: message_start
        data: {"type":"message_start","message":{"id":"test-message"}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tool-1","name":"save_story","input":{}}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"title\":\"Tiny story\",\"body\":\"A fox sleeps.\"}"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}

        event: message_stop
        data: {"type":"message_stop"}

        """#.components(separatedBy: "\n")
        let stub = SmokeTransportStub(responseLines: responseLines, streamStatus: 200)
        let adapter = ClaudeMessagesAdapter(maxTokens: 256, transport: SingleRequestCloudTransport(transport: stub))
        let session = try AgentRuntimeResolver.makeSession(
            manifest: manifest,
            configuration: .init(providerKeys: .init(["anthropic": sentinel]), toolHandlers: ["save_story": { _ in "saved" }]),
            adapters: [adapter]
        )
        var events: [AgentStreamEvent] = []
        do {
            for try await event in await session.send("Tell a very short gentle bedtime story.") { events.append(event) }
            XCTFail("tool continuation must hit the one-request budget")
        } catch {
            XCTAssertEqual(error as? AgentRuntimeError, .generationFailed("Messages API transport failed"))
        }
        XCTAssertTrue(events.contains { if case .toolResult(let result) = $0 { return result.success }; return false })
        XCTAssertFalse(events.contains { if case .end = $0 { return true }; return false })
        let requests = await stub.requests
        let methods = await stub.methods
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(methods, ["streamLines"])
        let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(requests.first?.httpBody))
        XCTAssertEqual(body["max_tokens"], .integer(256))
        XCTAssertEqual(body["service_tier"], .string("standard_only"))
    }

    func testMalformedRequestFailsWithoutNetworkAndWithoutEchoingBody() async throws {
        for body in [Data(sentinel.utf8), Data("[]".utf8)] {
            let stub = SmokeTransportStub()
            let transport = SingleRequestCloudTransport(transport: stub)
            var request = try request()
            request.httpBody = body
            do { _ = try await transport.send(request); XCTFail("expected malformed request failure") }
            catch {
                XCTAssertEqual(error as? AgentRuntimeError, .generationFailed("Cloud smoke test requires a JSON request object"))
                XCTAssertFalse(String(reflecting: error).contains(sentinel))
            }
            await assertBudgetExhausted(transport, request: request)
            let requests = await stub.requests
            XCTAssertTrue(requests.isEmpty)
        }
    }
}
