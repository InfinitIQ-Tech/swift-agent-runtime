import Foundation
import XCTest
@testable import AgentRuntime
#if canImport(FoundationModels)
import FoundationModels

/// Explicit start/release signals make lifecycle races reproducible without sleeps.
private actor FoundationModelsResponseGate {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var response: CheckedContinuation<String, Error>?
    private(set) var prompts: [String] = []

    func respond(_ prompt: String) async throws -> String {
        prompts.append(prompt)
        started = true
        startWaiter?.resume()
        startWaiter = nil
        return try await withCheckedThrowingContinuation { response = $0 }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func release(_ text: String) {
        response?.resume(returning: text)
        response = nil
    }
}

private actor FoundationModelsPromptRecorder {
    private(set) var prompts: [String] = []
    func record(_ prompt: String) { prompts.append(prompt) }
}

private struct FoundationModelsObservedTurn: Sendable {
    let events: [AgentStreamEvent]
    let error: AgentRuntimeError?
}

private func observeFoundationModelsTurn(
    _ stream: AsyncThrowingStream<AgentStreamEvent, Error>
) async -> FoundationModelsObservedTurn {
    var events: [AgentStreamEvent] = []
    do {
        for try await event in stream { events.append(event) }
        return FoundationModelsObservedTurn(events: events, error: nil)
    } catch {
        return FoundationModelsObservedTurn(
            events: events,
            error: (error as? AgentRuntimeError) ?? .generationFailed(String(describing: error))
        )
    }
}
#endif

final class FoundationModelsSessionTests: XCTestCase {
    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    private func makeSession(
        streaming: Bool = false,
        maxTurns: Int? = nil,
        output: AgentOutputConfig? = nil,
        operations: FoundationModelsOperations,
        relay: ToolEventRelay = ToolEventRelay()
    ) throws -> FoundationModelsSession {
        let candidate = AgentModelCandidate(name: "device", model: "apple:foundation-models")
        let config = Fixtures.config(
            streaming: streaming, maxTurns: maxTurns, candidates: [candidate], output: output
        )
        return try FoundationModelsSession(
            manifest: Fixtures.manifest(for: config), candidate: candidate,
            configuration: .init(), operations: operations, relay: relay
        )
    }
    #endif

    func testTextStreamingAndNonStreamingEnforceTurnBudget() async throws {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip("Foundation Models requires OS 26") }
        for streaming in [true, false] {
            let recorder = FoundationModelsPromptRecorder()
            let operations = FoundationModelsOperations(
                respondText: { prompt in
                    XCTAssertFalse(streaming)
                    await recorder.record(prompt)
                    return "hello"
                },
                streamText: { prompt, receive in
                    XCTAssertTrue(streaming)
                    await recorder.record(prompt)
                    try await receive("he")
                    try await receive("hello")
                }
            )
            let session = try makeSession(streaming: streaming, maxTurns: 1, operations: operations)
            let events = try await collectEvents(await session.send("first"))
            var expected: [AgentStreamEvent] = [.start(.init(turn: 1, candidate: "device", model: "apple:foundation-models"))]
            if streaming { expected += [.chunk("he"), .chunk("llo")] }
            expected.append(.end(.init(text: "hello", remainingTurns: 0)))
            XCTAssertEqual(events, expected)
            let exhausted = await observeFoundationModelsTurn(await session.send("second"))
            XCTAssertTrue(exhausted.events.isEmpty)
            XCTAssertEqual(exhausted.error, .maxTurnsExceeded(limit: 1))
            let prompts = await recorder.prompts
            let turns = await session.turnsUsed()
            let transcript = await session.transcript()
            XCTAssertEqual(prompts, ["first"])
            XCTAssertEqual(turns, 1)
            XCTAssertEqual(transcript, [.init(role: .user, content: "first"), .init(role: .assistant, content: "hello")])
        }
        #else
        throw XCTSkip("FoundationModels SDK not present")
        #endif
    }

    func testSequentialTurnsReleaseSlotAndAllowUnboundedDefault() async throws {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip("Foundation Models requires OS 26") }
        let session = try makeSession(operations: .init(respondText: { "reply: \($0)" }))
        for turn in 1...3 {
            let events = try await collectEvents(await session.send("\(turn)"))
            XCTAssertEqual(events, [
                .start(.init(turn: turn, candidate: "device", model: "apple:foundation-models")),
                .end(.init(text: "reply: \(turn)"))
            ])
        }
        let turns = await session.turnsUsed()
        let transcript = await session.transcript()
        XCTAssertEqual(turns, 3)
        XCTAssertEqual(transcript.count, 6)
        #else
        throw XCTSkip("FoundationModels SDK not present")
        #endif
    }

    func testOverlapIsRejectedWithoutConsumingTurnOrReplacingActiveTask() async throws {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip("Foundation Models requires OS 26") }
        let gate = FoundationModelsResponseGate()
        let session = try makeSession(maxTurns: 2, operations: .init(respondText: { prompt in
            if prompt == "first" { return try await gate.respond(prompt) }
            return "next reply"
        }))
        let first = await session.send("first")
        await gate.waitUntilStarted()
        let rejected = await observeFoundationModelsTurn(await session.send("overlap"))
        XCTAssertTrue(rejected.events.isEmpty)
        XCTAssertEqual(rejected.error, .generationFailed("A turn is already in progress"))
        let activeTurns = await session.turnsUsed()
        XCTAssertEqual(activeTurns, 1)
        await gate.release("first reply")
        let completed = try await collectEvents(first)
        XCTAssertEqual(completed.last, .end(.init(text: "first reply", remainingTurns: 1)))
        let second = try await collectEvents(await session.send("second"))
        XCTAssertEqual(second.first, .start(.init(turn: 2, candidate: "device", model: "apple:foundation-models")))
        XCTAssertEqual(second.last, .end(.init(text: "next reply", remainingTurns: 0)))
        #else
        throw XCTSkip("FoundationModels SDK not present")
        #endif
    }

    func testCancellationRetainsSlotUntilLateNonStreamingResponseUnwinds() async throws {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip("Foundation Models requires OS 26") }
        let gate = FoundationModelsResponseGate()
        let session = try makeSession(maxTurns: 2, operations: .init(respondText: { prompt in
            if prompt == "cancel me" { return try await gate.respond(prompt) }
            return "recovered"
        }))
        let first = await session.send("cancel me")
        await gate.waitUntilStarted()
        await session.cancel()
        let blocked = await observeFoundationModelsTurn(await session.send("too early"))
        XCTAssertEqual(blocked.error, .generationFailed("A turn is already in progress"))
        await gate.release("late response")
        let cancelled = await observeFoundationModelsTurn(first)
        XCTAssertEqual(cancelled.error, .cancelled)
        XCTAssertEqual(cancelled.events, [.start(.init(turn: 1, candidate: "device", model: "apple:foundation-models"))])
        let transcript = await session.transcript()
        XCTAssertEqual(transcript, [.init(role: .user, content: "cancel me")])
        let next = try await collectEvents(await session.send("next"))
        XCTAssertEqual(next.last, .end(.init(text: "recovered", remainingTurns: 0)))
        #else
        throw XCTSkip("FoundationModels SDK not present")
        #endif
    }

    func testCancellationAfterStreamingSnapshotCannotPublishEnd() async throws {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip("Foundation Models requires OS 26") }
        let gate = FoundationModelsResponseGate()
        let session = try makeSession(streaming: true, operations: .init(streamText: { prompt, receive in
            try await receive("partial")
            _ = try await gate.respond(prompt)
        }))
        let stream = await session.send("cancel")
        await gate.waitUntilStarted()
        await session.cancel()
        await gate.release("ignored")
        let cancelled = await observeFoundationModelsTurn(stream)
        XCTAssertEqual(cancelled.error, .cancelled)
        XCTAssertEqual(cancelled.events, [
            .start(.init(turn: 1, candidate: "device", model: "apple:foundation-models")), .chunk("partial")
        ])
        let transcript = await session.transcript()
        XCTAssertEqual(transcript, [.init(role: .user, content: "cancel")])
        #else
        throw XCTSkip("FoundationModels SDK not present")
        #endif
    }

    func testCancellationAfterLateStructuredResponseCannotPublishPayload() async throws {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip("Foundation Models requires OS 26") }
        let gate = FoundationModelsResponseGate()
        let session = try makeSession(streaming: true, output: Fixtures.outputConfig(), operations: .init(
            respond: { prompt, _ in try await gate.respond(prompt) }
        ))
        let stream = await session.send("cancel structured")
        await gate.waitUntilStarted()
        await session.cancel()
        await gate.release(#"{"reply":"late","choices":["wait"]}"#)
        let cancelled = await observeFoundationModelsTurn(stream)
        XCTAssertEqual(cancelled.error, .cancelled)
        XCTAssertEqual(cancelled.events, [.start(.init(turn: 1, candidate: "device", model: "apple:foundation-models"))])
        let transcript = await session.transcript()
        XCTAssertEqual(transcript, [.init(role: .user, content: "cancel structured")])
        #else
        throw XCTSkip("FoundationModels SDK not present")
        #endif
    }

    func testFailureCleansRelayAndAllowsNextTurnWithConsumedBudget() async throws {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip("Foundation Models requires OS 26") }
        let relay = ToolEventRelay()
        let toolCall = AgentToolCall(toolId: "native", callId: "one", args: [:])
        let toolResult = AgentToolResult(toolId: "native", callId: "one", output: "result", success: true)
        let session = try makeSession(maxTurns: 2, operations: .init(respondText: { prompt in
            if prompt == "fail" {
                await relay.emitCall(toolCall)
                await relay.emitResult(toolResult)
                throw AgentRuntimeError.guardrailViolation
            }
            return "recovered"
        }), relay: relay)
        let failed = await observeFoundationModelsTurn(await session.send("fail"))
        XCTAssertEqual(failed.error, .guardrailViolation)
        XCTAssertEqual(failed.events, [
            .start(.init(turn: 1, candidate: "device", model: "apple:foundation-models")),
            .toolCall(toolCall), .toolResult(toolResult)
        ])
        // A late callback after failure must not retain results or its old stream.
        await relay.emitResult(toolResult)
        let staleResults = await relay.endTurn()
        XCTAssertTrue(staleResults.isEmpty)
        let next = try await collectEvents(await session.send("next"))
        XCTAssertEqual(next.last, .end(.init(text: "recovered", remainingTurns: 0)))
        let turns = await session.turnsUsed()
        XCTAssertEqual(turns, 2)
        let exhausted = await observeFoundationModelsTurn(await session.send("exhausted"))
        XCTAssertEqual(exhausted.error, .maxTurnsExceeded(limit: 2))
        #else
        throw XCTSkip("FoundationModels SDK not present")
        #endif
    }

    func testFrameworkNullMetadataIsDistinctFromLiteralNullText() throws {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip("Foundation Models requires OS 26") }
        XCTAssertNil(FoundationModelsOperations.textSnapshot("null", rawContent: GeneratedContent(kind: .null)))
        XCTAssertEqual(
            FoundationModelsOperations.textSnapshot("null", rawContent: GeneratedContent(kind: .string("null"))),
            "null"
        )
        XCTAssertEqual(
            FoundationModelsOperations.textSnapshot("hello", rawContent: GeneratedContent(kind: .string("hello"))),
            "hello"
        )
        #else
        throw XCTSkip("FoundationModels SDK not present")
        #endif
    }

    func testSnapshotsPreserveLiteralNullAndAvoidDuplicateDeltas() async throws {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip("Foundation Models requires OS 26") }
        for snapshots in [["n", "nu", "nul", "null"], ["null"], ["", "hello", "hello", "hello!"]] {
            let session = try makeSession(streaming: true, operations: .init(streamText: { _, receive in
                for snapshot in snapshots { try await receive(snapshot) }
            }))
            let events = try await collectEvents(await session.send("text"))
            let chunks = events.compactMap { event -> String? in
                guard case .chunk(let text) = event else { return nil }
                return text
            }
            let text = try XCTUnwrap(snapshots.last)
            XCTAssertEqual(chunks.joined(), text)
            XCTAssertFalse(chunks.contains(""))
            XCTAssertEqual(events.last, .end(.init(text: text)))
        }
        #else
        throw XCTSkip("FoundationModels SDK not present")
        #endif
    }
    func testToolPlaceholdersAndRestartedSegmentsKeepChunksAndEndConsistent() async throws {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip("Foundation Models requires OS 26") }
        let snapshots: [String?] = [nil, "Before ", nil, "After ", "tail"]
        let session = try makeSession(streaming: true, operations: .init(streamText: { _, receive in
            for snapshot in snapshots { try await receive(snapshot) }
        }))
        let events = try await collectEvents(await session.send("with tool"))
        XCTAssertEqual(events, [
            .start(.init(turn: 1, candidate: "device", model: "apple:foundation-models")),
            .chunk("Before "), .chunk("After "), .chunk("tail"),
            .end(.init(text: "Before After tail"))
        ])
        #else
        throw XCTSkip("FoundationModels SDK not present")
        #endif
    }

}
