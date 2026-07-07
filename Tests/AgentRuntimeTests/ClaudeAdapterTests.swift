import Foundation
import XCTest
@testable import AgentRuntime

final class ClaudeAdapterTests: XCTestCase {
    private let keyedConfiguration = AgentSessionConfiguration(
        providerKeys: ProviderKeys(["anthropic": "sk-test-not-a-real-key"])
    )

    private func session(
        config: AgentConfig,
        transport: StubHTTPTransport,
        configuration: AgentSessionConfiguration? = nil
    ) throws -> any AgentSession {
        let adapter = ClaudeMessagesAdapter(transport: transport)
        let manifest = try Fixtures.manifest(for: config)
        let candidate = try XCTUnwrap(manifest.config.model.candidates.first { $0.provider == "anthropic" })
        return try adapter.makeSession(
            manifest: manifest,
            candidate: candidate,
            configuration: configuration ?? keyedConfiguration
        )
    }

    func testAvailabilityRequiresProviderKey() {
        let adapter = ClaudeMessagesAdapter()
        let candidate = AgentModelCandidate(name: "cloud", model: "anthropic:claude-haiku-4-5")

        XCTAssertEqual(
            adapter.availability(for: candidate, configuration: AgentSessionConfiguration()),
            .unavailable(.missingProviderKey(provider: "anthropic"))
        )
        XCTAssertEqual(
            adapter.availability(for: candidate, configuration: keyedConfiguration),
            .available
        )
        XCTAssertEqual(
            adapter.availability(
                for: AgentModelCandidate(name: "on_device", model: "apple:foundation-models"),
                configuration: keyedConfiguration
            ),
            .unavailable(.unsupportedModel)
        )
    }

    func testProviderKeysNeverAppearInDescriptions() {
        let keys = ProviderKeys(["anthropic": "sk-super-secret"])
        XCTAssertFalse("\(keys)".contains("sk-super-secret"))
        XCTAssertFalse(String(reflecting: keys).contains("sk-super-secret"))
        XCTAssertTrue("\(keys)".contains("anthropic"), "provider names stay visible for debugging")
    }

    func testStreamingTurnEmitsSSEFrameSequence() async throws {
        let transport = StubHTTPTransport(steps: [
            .sse(status: 200, lines: StubHTTPTransport.textRound(["Once", " upon", " a time"]))
        ])
        let session = try session(config: Fixtures.config(streaming: true), transport: transport)

        let events = try await collectEvents(await session.send("tell me a story"))

        guard case .start(let start) = events.first else {
            return XCTFail("expected start frame first, got \(events)")
        }
        XCTAssertEqual(start.turn, 1)
        XCTAssertEqual(start.model, "anthropic:claude-haiku-4-5")

        let chunks: [String] = events.compactMap {
            if case .chunk(let delta) = $0 { return delta }
            return nil
        }
        XCTAssertEqual(chunks, ["Once", " upon", " a time"])

        guard case .end(let result)? = events.last else {
            return XCTFail("expected end frame last")
        }
        XCTAssertEqual(result.text, "Once upon a time")
        XCTAssertTrue(result.toolResults.isEmpty)

        // Request construction: model id, system prompt, headers, no tools key.
        let request = transport.requests[0]
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-test-not-a-real-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        let body = try JSONDecoder().decode(JSONValue.self, from: transport.requestBodies[0])
        XCTAssertEqual(body["model"], .string("claude-haiku-4-5"))
        XCTAssertEqual(body["system"], .string("You are a test agent."))
        XCTAssertEqual(body["stream"], .bool(true))
        XCTAssertNil(body["tools"], "an agent with no tools configured sends no tools")
        XCTAssertNil(body["temperature"])
    }

    func testNonStreamingTurnEmitsNoChunks() async throws {
        let transport = StubHTTPTransport(steps: [
            .json(status: 200, body: #"{"content":[{"type":"text","text":"Hello there"}],"stop_reason":"end_turn"}"#)
        ])
        let session = try session(config: Fixtures.config(streaming: false), transport: transport)

        let events = try await collectEvents(await session.send("hi"))
        let chunkCount = events.filter { if case .chunk = $0 { return true }; return false }.count
        XCTAssertEqual(chunkCount, 0)
        guard case .end(let result)? = events.last else {
            return XCTFail("expected end frame")
        }
        XCTAssertEqual(result.text, "Hello there")

        let body = try JSONDecoder().decode(JSONValue.self, from: transport.requestBodies[0])
        XCTAssertEqual(body["stream"], .bool(false))
    }

    func testToolUseRoundExecutesToolAndContinues() async throws {
        let transport = StubHTTPTransport(steps: [
            .sse(status: 200, lines: StubHTTPTransport.toolUseRound(
                toolName: "save_story",
                callId: "toolu_1",
                argumentsJSON: #"{"query":"dragons"}"#
            )),
            .sse(status: 200, lines: StubHTTPTransport.textRound(["Saved!"]))
        ])
        let config = Fixtures.config(
            streaming: true,
            tools: AgentToolsConfig(definitions: [Fixtures.toolDefinition(name: "save_story")])
        )
        var configuration = keyedConfiguration
        configuration.toolHandlers = ["save_story": { args in
            "stored \(args["query"]?.stringValue ?? "?")"
        }]
        let session = try session(config: config, transport: transport, configuration: configuration)

        let events = try await collectEvents(await session.send("save it"))

        guard let callEvent = events.first(where: { if case .toolCall = $0 { return true }; return false }),
              case .toolCall(let call) = callEvent else {
            return XCTFail("expected tool_call frame")
        }
        XCTAssertEqual(call.toolId, "save_story")
        XCTAssertEqual(call.callId, "toolu_1")
        XCTAssertEqual(call.args["query"], .string("dragons"))

        guard let resultEvent = events.first(where: { if case .toolResult = $0 { return true }; return false }),
              case .toolResult(let result) = resultEvent else {
            return XCTFail("expected tool_result frame")
        }
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.output, "stored dragons")

        guard case .end(let turn)? = events.last else {
            return XCTFail("expected end frame")
        }
        XCTAssertEqual(turn.text, "Saved!")
        XCTAssertEqual(turn.toolResults.count, 1)

        // Second request replays the assistant tool_use and the tool_result.
        XCTAssertEqual(transport.requests.count, 2)
        let replay = try JSONDecoder().decode(JSONValue.self, from: transport.requestBodies[1])
        guard case .array(let messages)? = replay["messages"] else {
            return XCTFail("expected messages array")
        }
        let flattened = try JSONEncoder().encode(messages)
        let replayText = String(data: flattened, encoding: .utf8) ?? ""
        XCTAssertTrue(replayText.contains("tool_use"))
        XCTAssertTrue(replayText.contains("tool_result"))
        XCTAssertTrue(replayText.contains("toolu_1"))

        // First request exposes only allowed tools.
        let first = try JSONDecoder().decode(JSONValue.self, from: transport.requestBodies[0])
        guard case .array(let tools)? = first["tools"] else {
            return XCTFail("expected tools array")
        }
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["name"], .string("save_story"))
        XCTAssertNotNil(tools[0]["input_schema"])
    }

    func testMaxTurnsGateRefusesFurtherTurns() async throws {
        let transport = StubHTTPTransport(steps: [
            .sse(status: 200, lines: StubHTTPTransport.textRound(["one"])),
            .sse(status: 200, lines: StubHTTPTransport.textRound(["two"]))
        ])
        let session = try session(config: Fixtures.config(maxTurns: 1), transport: transport)

        let first = try await collectEvents(await session.send("first"))
        guard case .end(let result)? = first.last else {
            return XCTFail("expected end frame")
        }
        XCTAssertEqual(result.remainingTurns, 0)

        do {
            _ = try await collectEvents(await session.send("second"))
            XCTFail("expected maxTurnsExceeded")
        } catch let error as AgentRuntimeError {
            XCTAssertEqual(error, .maxTurnsExceeded(limit: 1))
        }
        let used = await session.turnsUsed()
        XCTAssertEqual(used, 1)
    }

    func testRefusalStopReasonMapsToGuardrailViolation() async throws {
        let transport = StubHTTPTransport(steps: [
            .json(status: 200, body: #"{"content":[],"stop_reason":"refusal"}"#)
        ])
        let session = try session(config: Fixtures.config(streaming: false), transport: transport)

        do {
            _ = try await collectEvents(await session.send("hi"))
            XCTFail("expected guardrailViolation")
        } catch let error as AgentRuntimeError {
            XCTAssertEqual(error, .guardrailViolation)
        }
    }

    func testContextOverflowMapsToTypedError() {
        let body = Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long: 250000 tokens"}}"#.utf8)
        XCTAssertEqual(
            ClaudeMessagesSession.mapHTTPError(status: 400, body: body),
            .contextWindowExceeded
        )
        let auth = Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8)
        XCTAssertEqual(
            ClaudeMessagesSession.mapHTTPError(status: 401, body: auth),
            .modelUnavailable(.missingProviderKey(provider: "anthropic"))
        )
    }

    func testTranscriptAccumulatesTurns() async throws {
        let transport = StubHTTPTransport(steps: [
            .sse(status: 200, lines: StubHTTPTransport.textRound(["Hi Alice"]))
        ])
        let session = try session(config: Fixtures.config(), transport: transport)
        _ = try await collectEvents(await session.send("I'm Alice"))

        let transcript = await session.transcript()
        XCTAssertEqual(transcript.map(\.role), [.user, .assistant])
        XCTAssertEqual(transcript.map(\.content), ["I'm Alice", "Hi Alice"])
    }
}
