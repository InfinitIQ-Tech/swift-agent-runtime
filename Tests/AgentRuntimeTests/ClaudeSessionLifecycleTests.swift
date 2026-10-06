import Foundation
import XCTest
@testable import AgentRuntime

/// The first response deliberately ignores cancellation until the test releases
/// it, proving the session cannot publish stale output or free its slot early.
private actor ClaudeResponseGate: HTTPStreamTransport {
    let started: @Sendable () -> Void
    private var pending: CheckedContinuation<Void, Never>?
    private(set) var requests: [URLRequest] = []

    init(started: @escaping @Sendable () -> Void) { self.started = started }

    private func admit(_ request: URLRequest) async {
        requests.append(request)
        if requests.count == 1 {
            await withCheckedContinuation { continuation in
                pending = continuation
                started()
            }
        }
    }

    func release() { pending?.resume(); pending = nil }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        await admit(request)
        return (Data(#"{"content":[{"type":"text","text":"complete"}],"stop_reason":"end_turn"}"#.utf8), 200)
    }

    func streamLines(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, Int) {
        await admit(request)
        return (AsyncThrowingStream { continuation in
            for line in StubHTTPTransport.textRound(["complete"]) { continuation.yield(line) }
            continuation.finish()
        }, 200)
    }
}

final class ClaudeSessionLifecycleTests: XCTestCase {
    private func session(transport: any HTTPStreamTransport, streaming: Bool = false, maxTurns: Int? = nil) throws -> ClaudeMessagesSession {
        let config = Fixtures.config(streaming: streaming, maxTurns: maxTurns)
        return try XCTUnwrap(ClaudeMessagesAdapter(transport: transport).makeSession(
            manifest: Fixtures.manifest(for: config), candidate: config.model.candidates[0],
            configuration: .init(providerKeys: .init(["anthropic": "test-lifecycle-key"]))
        ) as? ClaudeMessagesSession)
    }

    private func failure(_ stream: AsyncThrowingStream<AgentStreamEvent, Error>) async -> AgentRuntimeError? {
        do { _ = try await collectEvents(stream); return nil }
        catch { return error as? AgentRuntimeError }
    }

    func testOverlapRejectsWithoutConsumingBudgetAndSequentialTurnSucceeds() async throws {
        let started = expectation(description: "first request started")
        let transport = ClaudeResponseGate { started.fulfill() }
        let session = try session(transport: transport, maxTurns: 2)
        let first = await session.send("first")
        await fulfillment(of: [started], timeout: 5)
        let overlap = await failure(await session.send("overlap"))
        let used = await session.turnsUsed()
        XCTAssertEqual(overlap, .generationFailed("A turn is already in progress"))
        XCTAssertEqual(used, 1)
        await transport.release()
        let completed = try await collectEvents(first)
        XCTAssertEqual(completed.last, .end(.init(text: "complete", remainingTurns: 1)))
        let second = try await collectEvents(await session.send("second"))
        XCTAssertEqual(second.last, .end(.init(text: "complete", remainingTurns: 0)))
        let exhausted = await failure(await session.send("third"))
        XCTAssertEqual(exhausted, .maxTurnsExceeded(limit: 2))
    }

    func testCancellationRetainsSlotUntilLateResponseAndRollsBackWireState() async throws {
        for streaming in [false, true] {
            let started = expectation(description: "first request started \(streaming)")
            let transport = ClaudeResponseGate { started.fulfill() }
            let session = try session(transport: transport, streaming: streaming, maxTurns: 2)
            let first = await session.send("cancel me")
            await fulfillment(of: [started], timeout: 5)
            await session.cancel()
            let overlap = await failure(await session.send("too early"))
            XCTAssertEqual(overlap, .generationFailed("A turn is already in progress"))
            await transport.release()
            var received: [AgentStreamEvent] = []
            do {
                for try await event in first { received.append(event) }
                XCTFail("expected cancellation")
            } catch { XCTAssertEqual(error as? AgentRuntimeError, .cancelled) }
            XCTAssertEqual(received.count, 1)
            let history = await session.transcript()
            XCTAssertEqual(history, [.init(role: .user, content: "cancel me")])
            let next = try await collectEvents(await session.send("next"))
            XCTAssertEqual(next.last, .end(.init(text: "complete", remainingTurns: 0)))
            let requests = await transport.requests
            let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(requests.last?.httpBody))
            guard case .array(let messages)? = body["messages"] else { return XCTFail("missing messages") }
            XCTAssertEqual(messages.count, 1, "interrupted wire messages must be rolled back")
            XCTAssertEqual(messages[0]["content"], .array([.object(["type": .string("text"), "text": .string("next")])]))
        }
    }

    func testTerminatedConsumerCannotCommitAssistantHistory() async throws {
        let session = try session(transport: StubHTTPTransport(steps: []))
        let (_, continuation) = AsyncThrowingStream<AgentStreamEvent, Error>.makeStream()
        continuation.finish()
        do {
            try await session.publishTurnResult(.init(text: "late"), to: continuation)
            XCTFail("expected terminated publication")
        } catch { XCTAssertEqual(error as? AgentRuntimeError, .cancelled) }
        let history = await session.transcript()
        XCTAssertTrue(history.isEmpty)
    }

    func testDroppedTerminalCannotCommitAssistantHistory() async throws {
        let session = try session(transport: StubHTTPTransport(steps: []))
        let (stream, continuation) = AsyncThrowingStream<AgentStreamEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(0))
        do {
            try await session.publishTurnResult(.init(text: "late"), to: continuation)
            XCTFail("expected dropped publication")
        } catch { XCTAssertEqual(error as? AgentRuntimeError, .generationFailed("Terminal event was dropped")) }
        continuation.finish()
        withExtendedLifetime(stream) {}
        let history = await session.transcript()
        XCTAssertTrue(history.isEmpty)
    }

    func testFailedTurnConsumesBudgetAndRollsBackProviderReplay() async throws {
        let transport = StubHTTPTransport(steps: [
            .json(status: 429, body: "provider response"),
            .json(status: 200, body: #"{"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}"#)
        ])
        let session = try session(transport: transport, maxTurns: 2)
        let failed = await failure(await session.send("failed"))
        XCTAssertEqual(failed, .generationFailed("Messages API status 429"))
        let events = try await collectEvents(await session.send("retry"))
        XCTAssertEqual(events.last, .end(.init(text: "ok", remainingTurns: 0)))
        let body = try JSONDecoder().decode(JSONValue.self, from: transport.requestBodies[1])
        guard case .array(let messages)? = body["messages"] else { return XCTFail("missing messages") }
        XCTAssertEqual(messages.count, 1)
    }

    func testPrewarmMakesNoRequest() async throws {
        let transport = StubHTTPTransport(steps: [])
        let session = try session(transport: transport)
        await session.prewarm()
        XCTAssertTrue(transport.requests.isEmpty)
    }
}
