import Foundation
import XCTest
@testable import AgentRuntime

private struct ClaudeFailingTransport: HTTPStreamTransport {
    let error: any Error
    func send(_ request: URLRequest) async throws -> (Data, Int) { throw error }
    func streamLines(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, Int) { throw error }
}

private struct ClaudeFailingLineTransport: HTTPStreamTransport {
    let error: any Error
    func send(_ request: URLRequest) async throws -> (Data, Int) { throw error }
    func streamLines(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, Int) {
        (AsyncThrowingStream { $0.finish(throwing: error) }, 200)
    }
}

final class ClaudeStreamValidationTests: XCTestCase {
    private let sentinel = "credential-sentinel-never-print"

    private func session(_ transport: any HTTPStreamTransport, config: AgentConfig = Fixtures.config(), handler: AgentToolHandler? = nil) throws -> any AgentSession {
        try ClaudeMessagesAdapter(transport: transport).makeSession(
            manifest: Fixtures.manifest(for: config), candidate: config.model.candidates[0],
            configuration: .init(providerKeys: .init(["anthropic": sentinel]), toolHandlers: handler.map { ["save_story": $0] } ?? [:])
        )
    }

    private func assertInvalid(_ lines: [String], file: StaticString = #filePath, line: UInt = #line) async throws {
        let transport = StubHTTPTransport(steps: [.sse(status: 200, lines: lines)])
        let session = try session(transport)
        var ended = false
        do {
            for try await event in await session.send("test") { if case .end = event { ended = true } }
            XCTFail("expected invalid stream", file: file, line: line)
        } catch {
            guard case AgentRuntimeError.invalidProviderResponse = error else {
                return XCTFail("expected invalidProviderResponse, got \(error)", file: file, line: line)
            }
            XCTAssertFalse(String(reflecting: error).contains(sentinel), file: file, line: line)
        }
        XCTAssertFalse(ended, file: file, line: line)
        let history = await session.transcript()
        XCTAssertFalse(history.contains { $0.role == .assistant }, file: file, line: line)
    }

    private func event(_ type: String, _ fields: String = "") -> [String] {
        ["event: \(type)", "data: {\"type\":\"\(type)\"\(fields)}", ""]
    }

    func testTruncatedEmptyAndMalformedKnownStreamsFailWithoutEnd() async throws {
        let complete = StubHTTPTransport.textRound(["partial"])
        try await assertInvalid([])
        try await assertInvalid(Array(complete.dropLast(3)))
        try await assertInvalid(["event: message_start", "data: broken \(sentinel)", ""])
        try await assertInvalid(event("content_block_delta", #", "index":0,"delta":{"type":"text_delta","text":"orphan"}"#))
        try await assertInvalid(event("message_start", #", "message":{}"#) + event("message_stop"))
        var malformed = complete
        malformed[7] = #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":4}}"#
        try await assertInvalid(malformed)
    }

    func testUnfinishedOrNonObjectToolArgumentsNeverExecute() async throws {
        for input in ["{", "[]", "null"] {
            let transport = StubHTTPTransport(steps: [.sse(status: 200, lines: StubHTTPTransport.toolUseRound(toolName: "save_story", callId: "tool1", argumentsJSON: input))])
            let config = Fixtures.config(tools: .init(definitions: [Fixtures.toolDefinition(name: "save_story")]))
            let session = try session(transport, config: config, handler: { _ in XCTFail("malformed tool must not execute"); return "wrong" })
            do { _ = try await collectEvents(await session.send("test")); XCTFail("expected invalid input") }
            catch { guard case AgentRuntimeError.invalidProviderResponse = error else { return XCTFail("unexpected error") } }
            XCTAssertEqual(transport.requests.count, 1)
        }
    }

    func testDuplicateOrConflictingTerminalReasonsFailWithoutEnd() async throws {
        let content = Array(StubHTTPTransport.textRound(["partial"]).dropLast(6))
        for firstReason in ["end_turn", "max_tokens", "tool_use", "stop_sequence"] {
            let lines = content
                + event("message_delta", ",\"delta\":{\"stop_reason\":\"\(firstReason)\"}")
                + event("message_delta", #", "delta":{"stop_reason":"end_turn"}"#)
                + event("message_stop")
            try await assertInvalid(lines)
        }
    }

    func testUsageDeltasCannotResumeContentBeforeOrAfterTerminalReason() async throws {
        let content = Array(StubHTTPTransport.textRound(["partial"]).dropLast(6))
        let resumedContent = event("content_block_start", #", "index":1,"content_block":{"type":"text","text":"late"}"#)
            + event("content_block_stop", #", "index":1"#)
        for delta in [#"{}"#, #"{"stop_reason":null}"#, #"{"stop_reason":"end_turn"}"#] {
            let lines = content
                + event("message_delta", ",\"delta\":\(delta),\"usage\":{\"output_tokens\":5}")
                + resumedContent
                + event("message_delta", #", "delta":{"stop_reason":"end_turn"}"#)
                + event("message_stop")
            try await assertInvalid(lines)
        }
    }

    func testUsageDeltasWithoutTerminalReasonCannotComplete() async throws {
        let content = Array(StubHTTPTransport.textRound(["partial"]).dropLast(6))
        for delta in [#"{}"#, #"{"stop_reason":null}"#] {
            let usage = event("message_delta", ",\"delta\":\(delta),\"usage\":{\"output_tokens\":5}")
            try await assertInvalid(content + usage + event("message_stop"))
            try await assertInvalid(content + usage)
        }
    }

    func testMalformedAndUnknownTerminalReasonsCannotComplete() async throws {
        let content = Array(StubHTTPTransport.textRound(["partial"]).dropLast(6))
        for reason in [#""""#, "42", "true", "{}", "[]", #"" ""#, "\"\(sentinel)\""] {
            let lines = content
                + event("message_delta", ",\"delta\":{\"stop_reason\":\(reason)}")
                + event("message_stop")
            try await assertInvalid(lines)
        }
    }

    func testMessageDeltaCannotPrecedeMessageStartOrInterruptOpenBlock() async throws {
        let terminal = event("message_delta", #", "delta":{"stop_reason":"end_turn"}"#)
        try await assertInvalid(terminal + event("message_start", #", "message":{}"#) + event("message_stop"))
        let openBlock = Array(StubHTTPTransport.textRound(["partial"]).dropLast(9))
        for delta in [#"{}"#, #"{"stop_reason":null}"#, #"{"stop_reason":"end_turn"}"#] {
            let lines = openBlock
                + event("message_delta", ",\"delta\":\(delta),\"usage\":{\"output_tokens\":5}")
                + event("content_block_stop", #", "index":0"#)
                + terminal
                + event("message_stop")
            try await assertInvalid(lines)
        }
    }

    func testAccumulatorRejectsRepeatedMessageStopAndMessageDeltaAfterStop() throws {
        var parser = ServerSentEventParser()
        var accumulator = AnthropicStreamAccumulator()
        for line in StubHTTPTransport.textRound(["hello"]) {
            if let event = parser.consume(line: line) { _ = try accumulator.consume(event) }
        }
        XCTAssertTrue(accumulator.isComplete)
        for lines in [event("message_stop"), event("message_delta", #", "delta":{},"usage":{"output_tokens":6}"#)] {
            for line in lines {
                if let event = parser.consume(line: line) {
                    XCTAssertThrowsError(try accumulator.consume(event)) { error in
                        XCTAssertEqual(error as? AgentRuntimeError, .invalidProviderResponse("Malformed Messages API stream"))
                    }
                }
            }
        }
    }

    func testCumulativeUsageDeltasAroundSingleTerminalReasonRemainCompatible() async throws {
        let content = Array(StubHTTPTransport.textRound(["hello"]).dropLast(6))
        for reason in ["end_turn", "stop_sequence"] {
            let lines = content
                + event("message_delta", #", "delta":{},"usage":{"output_tokens":2}"#)
                + event("message_delta", #", "delta":{"stop_reason":null},"usage":{"output_tokens":3}"#)
                + event("message_delta", ",\"delta\":{\"stop_reason\":\"\(reason)\"},\"usage\":{\"output_tokens\":4}")
                + event("ping")
                + event("message_delta", #", "delta":{},"usage":{"output_tokens":5}"#)
                + event("message_delta", #", "delta":{"stop_reason":null},"usage":{"output_tokens":6}"#)
                + event("message_stop")
            let session = try session(StubHTTPTransport(steps: [.sse(status: 200, lines: lines)]))
            let events = try await collectEvents(await session.send("test"))
            guard case .start? = events.first else { return XCTFail("missing start") }
            XCTAssertEqual(Array(events.dropFirst()), [.chunk("hello"), .end(.init(text: "hello"))])
            let history = await session.transcript()
            XCTAssertEqual(history.filter { $0.role == .assistant }.count, 1)
        }
    }

    func testUnknownEventsPingsAndTrailingMessageStopRemainCompatible() async throws {
        var lines = StubHTTPTransport.textRound(["hello"])
        lines.insert(contentsOf: ["event: future_event", "data: future format", "", "event: ping", "data: {\"type\":\"ping\"}", ""], at: 3)
        lines.removeLast()
        let session = try session(StubHTTPTransport(steps: [.sse(status: 200, lines: lines)]))
        let events = try await collectEvents(await session.send("test"))
        XCTAssertEqual(events.last, .end(.init(text: "hello")))
    }

    func testToolReplayPreservesBlockOrderAndDoesNotDuplicateRoundText() async throws {
        let toolRound = event("message_start", #", "message":{}"#)
            + event("content_block_start", #", "index":0,"content_block":{"type":"tool_use","id":"tool1","name":"save_story","input":{}}"#)
            + event("content_block_delta", #", "index":0,"delta":{"type":"input_json_delta","partial_json":"{\"query\":\"story\"}"}"#)
            + event("content_block_stop", #", "index":0"#)
            + event("content_block_start", #", "index":1,"content_block":{"type":"text","text":"before"}"#)
            + event("content_block_stop", #", "index":1"#)
            + event("message_delta", #", "delta":{"stop_reason":"tool_use"}"#)
            + event("message_stop")
        let transport = StubHTTPTransport(steps: [
            .sse(status: 200, lines: toolRound),
            .sse(status: 200, lines: StubHTTPTransport.textRound(["after"])),
            .sse(status: 200, lines: StubHTTPTransport.textRound(["next"]))
        ])
        let config = Fixtures.config(tools: .init(definitions: [Fixtures.toolDefinition(name: "save_story")]))
        let session = try session(transport, config: config, handler: { _ in "saved" })
        let first = try await collectEvents(await session.send("first"))
        guard case .end(let result)? = first.last else { return XCTFail("missing end") }
        XCTAssertEqual(result.text, "beforeafter")
        _ = try await collectEvents(await session.send("second"))
        let body = try JSONDecoder().decode(JSONValue.self, from: transport.requestBodies[2])
        guard case .array(let messages)? = body["messages"], case .array(let firstBlocks)? = messages[1]["content"] else { return XCTFail("missing replay") }
        XCTAssertEqual(firstBlocks.map { $0["type"] }, [.string("tool_use"), .string("text")])
        XCTAssertEqual(messages[3]["content"], .array([.object(["type": .string("text"), "text": .string("after")])]))
    }

    func testHTTPAndStreamDiagnosticsDoNotIncludeProviderBody() async throws {
        for streaming in [false, true] {
            for status in [400, 401, 403, 404, 413, 429, 500, 529] {
                let body = "{\"error\":{\"type\":\"api_error\",\"message\":\"\(sentinel)\"}}"
                let session = try session(StubHTTPTransport(steps: [.json(status: status, body: body)]), config: Fixtures.config(streaming: streaming))
                do { _ = try await collectEvents(await session.send("test")); XCTFail("expected failure") }
                catch { XCTAssertFalse(String(reflecting: error).contains(sentinel)) }
            }
        }
        let lines = event("error", ",\"error\":{\"type\":\"overloaded_error\",\"message\":\"\(sentinel)\"}")
        let session = try session(StubHTTPTransport(steps: [.sse(status: 200, lines: lines)]))
        do { _ = try await collectEvents(await session.send("test")); XCTFail("expected error") }
        catch { XCTAssertEqual(error as? AgentRuntimeError, .generationFailed("Messages API stream failed")) }
    }

    func testTransportErrorsAreSanitizedAndCancellationIsTyped() async throws {
        for streaming in [false, true] {
            for code in [URLError.timedOut, URLError.cancelled] {
                let error = URLError(code, userInfo: [NSLocalizedDescriptionKey: sentinel, NSURLErrorFailingURLStringErrorKey: "https://example.com/\(sentinel)"])
                let session = try session(ClaudeFailingTransport(error: error), config: Fixtures.config(streaming: streaming))
                do { _ = try await collectEvents(await session.send("test")); XCTFail("expected error") }
                catch {
                    XCTAssertFalse(String(reflecting: error).contains(sentinel))
                    if code == .cancelled { XCTAssertEqual(error as? AgentRuntimeError, .cancelled) }
                }
            }
        }
    }

    func testStructuredOutputProviderKeysAreExcludedFromDiagnostics() async throws {
        let payload = JSONValue.object(["reply": .string("hello"), "choices": .array([]), sentinel: .string("extra")])
        let payloadText = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        let response = JSONValue.object(["content": .array([.object(["type": .string("text"), "text": .string(payloadText)])]), "stop_reason": .string("end_turn")])
        let body = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
        let session = try session(StubHTTPTransport(steps: [.json(status: 200, body: body)]), config: Fixtures.config(output: Fixtures.outputConfig()))
        do { _ = try await collectEvents(await session.send("test")); XCTFail("expected invalid structured output") }
        catch {
            XCTAssertEqual(error as? AgentRuntimeError, .structuredOutputInvalid("Provider output does not match the declared schema"))
            XCTAssertFalse(String(reflecting: error).contains(sentinel))
        }
    }

    func testInjectedRuntimeErrorFromLineTransportCannotBypassSanitization() async throws {
        let session = try session(ClaudeFailingLineTransport(error: AgentRuntimeError.generationFailed(sentinel)))
        do { _ = try await collectEvents(await session.send("test")); XCTFail("expected error") }
        catch { XCTAssertEqual(error as? AgentRuntimeError, .generationFailed("Messages API transport failed")) }
    }

    func testIncompleteStopReasonsRejectStreamingAndBlockingText() async throws {
        try await assertIncompleteStopReasons(output: nil)
    }

    func testIncompleteStopReasonsRejectOtherwiseValidStructuredOutput() async throws {
        try await assertIncompleteStopReasons(output: Fixtures.outputConfig())
    }

    private func assertIncompleteStopReasons(output: AgentOutputConfig?) async throws {
        let reasons: [(String, AgentRuntimeError)] = [
            ("model_context_window_exceeded", .contextWindowExceeded),
            ("max_tokens", .generationFailed("Messages API output token limit reached")),
            ("pause_turn", .generationFailed("Messages API server turn is incomplete"))
        ]
        for streaming in [true, false] {
            for (reason, expected) in reasons {
                let text = output == nil ? "partial" : #"{"reply":"valid JSON","choices":[]}"#
                let step: StubHTTPTransport.Step
                if streaming && output == nil {
                    step = .sse(status: 200, lines: StubHTTPTransport.textRound([text], stopReason: reason))
                } else {
                    let body = JSONValue.object([
                        "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
                        "stop_reason": .string(reason)
                    ])
                    step = .json(status: 200, body: String(decoding: try JSONEncoder().encode(body), as: UTF8.self))
                }
                let transport = StubHTTPTransport(steps: [step])
                let session = try session(transport, config: Fixtures.config(streaming: streaming, output: output))
                var ended = false
                do {
                    for try await event in await session.send("test") { if case .end = event { ended = true } }
                    XCTFail("expected failure for \(reason)")
                } catch { XCTAssertEqual(error as? AgentRuntimeError, expected) }
                XCTAssertFalse(ended)
                let history = await session.transcript()
                XCTAssertFalse(history.contains { $0.role == .assistant })
                XCTAssertEqual(transport.requests.count, 1, "incomplete responses never trigger a paid automatic continuation")
            }
        }
    }

    func testActualSessionReflectionRedactsStoredCredential() throws {
        let config = Fixtures.config()
        let session = try ClaudeMessagesAdapter().makeSession(
            manifest: Fixtures.manifest(for: config), candidate: config.model.candidates[0],
            configuration: .init(providerKeys: .init(["anthropic": sentinel]))
        )
        var description = ""
        dump(session, to: &description)
        XCTAssertFalse(description.contains(sentinel))
        XCTAssertFalse(String(reflecting: session).contains(sentinel))
        XCTAssertTrue(description.contains("redacted"))
    }

    func testEligibilityRejectsBlankKeysAndUnsupportedDirectCandidate() throws {
        let adapter = ClaudeMessagesAdapter()
        let config = Fixtures.config()
        for key in ["", " \n\t"] {
            let configuration = AgentSessionConfiguration(providerKeys: .init(["anthropic": key]))
            XCTAssertEqual(adapter.availability(for: config.model.candidates[0], configuration: configuration), .unavailable(.missingProviderKey(provider: "anthropic")))
            XCTAssertThrowsError(try adapter.makeSession(manifest: Fixtures.manifest(for: config), candidate: config.model.candidates[0], configuration: configuration))
        }
        for model in ["anthropic:", "anthropic: ", "apple:foundation-models"] {
            let candidate = AgentModelCandidate(name: "bad", model: model)
            XCTAssertFalse(adapter.supports(candidate: candidate))
            XCTAssertThrowsError(try adapter.makeSession(manifest: Fixtures.manifest(for: config), candidate: candidate, configuration: .init(providerKeys: .init(["anthropic": sentinel]))))
        }
    }
}
