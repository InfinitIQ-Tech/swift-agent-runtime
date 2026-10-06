import Foundation
import XCTest
@testable import AgentRuntime
#if canImport(FoundationModels)
import FoundationModels
#endif

final class ToolExecutionPolicyTests: XCTestCase {
    private func engine(
        width: Int? = 1,
        policy: AgentToolPolicy? = nil,
        handler: @escaping AgentToolHandler,
        confirm: (@Sendable (AgentToolCall) async -> Bool)? = nil
    ) -> ToolExecutionEngine {
        ToolExecutionEngine(
            toolbox: AgentToolbox.resolve(config: Fixtures.config(
                maxConcurrentTools: width,
                tools: AgentToolsConfig(definitions: [Fixtures.toolDefinition(name: "local")], toolPolicy: policy)
            )),
            configuration: AgentSessionConfiguration(toolHandlers: ["local": handler], confirmToolExecution: confirm),
            transport: StubWebhookTransport(steps: [])
        )
    }

    func testOverlappingBatchesShareCapacityAndPreserveFIFOAdmission() async {
        let gate = PolicyGate()
        let engine = engine { await gate.run($0["query"]?.stringValue ?? "missing") }
        let batch = Task { await engine.execute([policyCall("first"), policyCall("second")]) }
        let enteredFirst = await gate.waitForEntries(1)
        XCTAssertTrue(enteredFirst)
        let overlapping = Task { await engine.execute([policyCall("third")]) }
        let overlapped = await gate.waitForEntries(2, milliseconds: 40)
        XCTAssertFalse(overlapped, "The second batch must share the first batch's capacity")
        await gate.release("first")
        let enteredSecond = await gate.waitForEntries(2)
        XCTAssertTrue(enteredSecond)
        let firstTwo = await gate.started
        XCTAssertEqual(firstTwo, ["first", "second"], "A later batch must not overtake already queued work")
        await gate.release("second")
        let enteredThird = await gate.waitForEntries(3)
        XCTAssertTrue(enteredThird)
        await gate.releaseAll()
        let results = await batch.value + overlapping.value
        let peak = await gate.peak
        XCTAssertEqual(peak, 1)
        XCTAssertEqual(results.map(\.callId), ["first", "second", "third"])
        XCTAssertTrue(results.allSatisfy(\.success))
    }

    func testConfiguredParallelismIsUsableAndResultsRemainOrdered() async {
        let gate = PolicyGate()
        let engine = engine(width: 2) { await gate.run($0["query"]?.stringValue ?? "missing") }
        let batch = Task { await engine.execute([policyCall("first"), policyCall("second"), policyCall("third")]) }
        let enteredTwo = await gate.waitForEntries(2)
        XCTAssertTrue(enteredTwo, "Do not fix a shared cap by serializing every tool")
        await gate.release("second")
        let enteredThird = await gate.waitForEntries(3)
        XCTAssertTrue(enteredThird, "Freed capacity should be usable before the slow first call finishes")
        await gate.releaseAll()
        let results = await batch.value
        let peak = await gate.peak
        XCTAssertEqual(peak, 2)
        XCTAssertEqual(results.map(\.callId), ["first", "second", "third"])
        XCTAssertEqual(results.map(\.output), ["first", "second", "third"])
    }

    func testCompletedRuntimeDeniesLaterCallsInSameAndOverlappingBatches() async throws {
        let gate = PolicyGate()
        let engine = engine(policy: AgentToolPolicy(maxTotalRuntimeMs: 10)) { args in
            try await Task.sleep(for: .milliseconds(30))
            return await gate.run(args["query"]?.stringValue ?? "missing")
        }
        let batch = Task { await engine.execute([policyCall("first"), policyCall("second")]) }
        let entered = await gate.waitForEntries(1)
        XCTAssertTrue(entered)
        let overlapping = Task { await engine.execute([policyCall("third")]) }
        await gate.releaseAll()
        let results = await batch.value + overlapping.value
        XCTAssertTrue(results[0].success, "An admitted native handler may finish beyond the admission budget")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(results[0].durationMs), 10)
        for result in results.dropFirst() {
            XCTAssertFalse(result.success)
            XCTAssertTrue(result.output.contains("max_total_runtime_ms"), result.output)
        }
        let started = await gate.started
        XCTAssertEqual(started, ["first"])
        let subsequent = await engine.execute([policyCall("fourth")])
        XCTAssertTrue(subsequent[0].output.contains("max_total_runtime_ms"))
    }

    func testFailedExecutionAlsoConsumesRuntimeBudget() async throws {
        let engine = engine(policy: AgentToolPolicy(maxTotalRuntimeMs: 10)) { _ in
            try await Task.sleep(for: .milliseconds(30))
            throw PolicyTestError.failed
        }
        let results = await engine.execute([policyCall("first"), policyCall("second")])
        XCTAssertFalse(results[0].success)
        XCTAssertTrue(results[0].output.contains("handler failed"))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(results[0].durationMs), 10)
        XCTAssertTrue(results[1].output.contains("max_total_runtime_ms"))
    }

    func testConfirmationRechecksRuntimeBudgetBeforeDispatch() async {
        let confirmation = PolicyGate()
        let dispatches = PolicyGate(released: true)
        let engine = engine(width: 2, policy: AgentToolPolicy(
            requireUserConfirmation: ["local"], maxTotalRuntimeMs: 10
        ), handler: { args in
            try await Task.sleep(for: .milliseconds(30))
            return await dispatches.run(args["query"]?.stringValue ?? "missing")
        }, confirm: { call in
            if call.callId == "waiting" { _ = await confirmation.run("waiting") }
            return true
        })
        let waiting = Task { await engine.execute([policyCall("waiting")]) }
        let confirming = await confirmation.waitForEntries(1)
        XCTAssertTrue(confirming)
        let consumed = await engine.execute([policyCall("consume")])
        XCTAssertTrue(consumed[0].success)
        await confirmation.releaseAll()
        let results = await waiting.value
        XCTAssertTrue(results[0].output.contains("max_total_runtime_ms"))
        let started = await dispatches.started
        XCTAssertEqual(started, ["consume"])
    }

    func testCancelledBatchRemovesQueuedCallsButHoldsActiveCapacityUntilUnwind() async {
        let gate = PolicyGate()
        let engine = engine { await gate.run($0["query"]?.stringValue ?? "missing") }
        let cancelled = Task { await engine.execute([policyCall("running"), policyCall("cancelled-queued")]) }
        let running = await gate.waitForEntries(1)
        XCTAssertTrue(running)
        cancelled.cancel()
        let next = Task { await engine.execute([policyCall("next")]) }
        let leakedCapacity = await gate.waitForEntries(2, milliseconds: 40)
        XCTAssertFalse(leakedCapacity, "A handler ignoring cancellation must keep its slot until it returns")
        await gate.release("running")
        let enteredNext = await gate.waitForEntries(2)
        XCTAssertTrue(enteredNext)
        await gate.releaseAll()
        let cancelledResults = await cancelled.value
        let nextResults = await next.value
        XCTAssertEqual(cancelledResults.count, 2)
        XCTAssertTrue(cancelledResults.allSatisfy { !$0.success && $0.output.contains("cancelled") })
        XCTAssertTrue(nextResults[0].success)
        let started = await gate.started
        let peak = await gate.peak
        XCTAssertEqual(started, ["running", "next"])
        XCTAssertEqual(peak, 1)
    }

    func testAlreadyCancelledBatchCannotDispatchOrConsumeCallAllowance() async {
        let dispatches = PolicyGate(released: true)
        let start = PolicyGate()
        let engine = engine(policy: AgentToolPolicy(maxToolsPerTurn: 1)) {
            await dispatches.run($0["query"]?.stringValue ?? "missing")
        }
        let cancelled = Task {
            _ = await start.run("start")
            return await engine.execute([policyCall("cancelled")])
        }
        let waiting = await start.waitForEntries(1)
        XCTAssertTrue(waiting)
        cancelled.cancel()
        await start.releaseAll()
        let result = await cancelled.value
        XCTAssertFalse(result[0].success)
        let next = await engine.execute([policyCall("next")])
        XCTAssertTrue(next[0].success)
        let started = await dispatches.started
        XCTAssertEqual(started, ["next"])
    }

    func testCancellationDuringConfirmationPreventsHandlerAndWebhookDispatch() async {
        let confirmation = PolicyGate()
        let dispatches = PolicyGate(released: true)
        let transport = StubWebhookTransport(steps: [.respond(status: 200, body: "must not run")])
        let definitions = [Fixtures.toolDefinition(name: "local"), ToolDefinition(
            name: "remote", description: "injected webhook", parameters: ["type": .string("object")],
            endpoint: ToolEndpoint(url: "https://tools.example.com/test")
        )]
        let engine = ToolExecutionEngine(
            toolbox: AgentToolbox.resolve(config: Fixtures.config(maxConcurrentTools: 2, tools: AgentToolsConfig(
                definitions: definitions,
                toolPolicy: AgentToolPolicy(requireUserConfirmation: ["local", "remote"])
            ))),
            configuration: AgentSessionConfiguration(toolHandlers: ["local": { _ in await dispatches.run("local") }],
                confirmToolExecution: { call in _ = await confirmation.run(call.toolId); return true }),
            transport: transport
        )
        let cancelled = Task { await engine.execute([
            policyCall("local"), AgentToolCall(toolId: "remote", callId: "remote", args: [:])
        ]) }
        let enteredBoth = await confirmation.waitForEntries(2)
        XCTAssertTrue(enteredBoth)
        cancelled.cancel()
        await confirmation.releaseAll()
        let results = await cancelled.value
        XCTAssertTrue(results.allSatisfy { !$0.success && $0.output.contains("cancelled") })
        let started = await dispatches.started
        XCTAssertTrue(started.isEmpty)
        XCTAssertTrue(transport.requests.isEmpty)
        let next = await engine.execute([policyCall("next")])
        XCTAssertTrue(next[0].success, "Both confirmation slots must have been released")
    }

    func testNewTurnInvalidatesQueuedCallsAndIsolatesActiveAccounting() async {
        let gate = PolicyGate()
        let engine = engine(policy: AgentToolPolicy(maxTotalRuntimeMs: 10, maxToolsPerTurn: 2)) { args in
            if args["query"]?.stringValue == "old-running" { try await Task.sleep(for: .milliseconds(30)) }
            return await gate.run(args["query"]?.stringValue ?? "missing")
        }
        let old = Task { await engine.execute([policyCall("old-running"), policyCall("old-queued")]) }
        let entered = await gate.waitForEntries(1)
        XCTAssertTrue(entered)
        await engine.beginTurn()
        let new = Task { await engine.execute([policyCall("new")]) }
        let leakedCapacity = await gate.waitForEntries(2, milliseconds: 40)
        XCTAssertFalse(leakedCapacity, "beginTurn cannot reset occupied capacity")
        await gate.release("old-running")
        let enteredNew = await gate.waitForEntries(2)
        XCTAssertTrue(enteredNew, "Old elapsed runtime must not charge the new turn")
        await gate.releaseAll()
        let oldResults = await old.value
        let newResults = await new.value
        XCTAssertTrue(oldResults.allSatisfy { !$0.success && $0.output.contains("previous turn") })
        XCTAssertTrue(newResults[0].success)
        let started = await gate.started
        let peak = await gate.peak
        XCTAssertEqual(started, ["old-running", "new"])
        XCTAssertEqual(peak, 1)
    }

    func testNewTurnDuringConfirmationPreventsOldDispatchAndResetsCallAllowance() async {
        let confirmation = PolicyGate()
        let dispatches = PolicyGate(released: true)
        let engine = engine(policy: AgentToolPolicy(requireUserConfirmation: ["local"], maxToolsPerTurn: 1), handler: {
            await dispatches.run($0["query"]?.stringValue ?? "missing")
        }, confirm: { call in _ = await confirmation.run(call.callId ?? "missing"); return true })
        let old = Task { await engine.execute([policyCall("old")]) }
        let entered = await confirmation.waitForEntries(1)
        XCTAssertTrue(entered)
        await engine.beginTurn()
        let new = Task { await engine.execute([policyCall("new")]) }
        await confirmation.releaseAll()
        let oldResults = await old.value
        let newResults = await new.value
        XCTAssertTrue(oldResults[0].output.contains("previous turn"))
        XCTAssertTrue(newResults[0].success)
        let started = await dispatches.started
        XCTAssertEqual(started, ["new"])
        let exhausted = await engine.execute([policyCall("extra")])
        XCTAssertTrue(exhausted[0].output.contains("max_tools_per_turn"))
    }

    func testDeniedConfirmationAndFailureReleaseCapacity() async {
        let engine = engine(handler: { args in
            if args["query"]?.stringValue == "fail" { throw PolicyTestError.failed }
            return "ok"
        }, confirm: { $0.callId != "deny" })
        // Exercise failures without requiring a confirmation policy first.
        let failed = await engine.execute([policyCall("fail"), policyCall("succeed")])
        XCTAssertFalse(failed[0].success)
        XCTAssertTrue(failed[1].success)
        let confirming = self.engine(policy: AgentToolPolicy(requireUserConfirmation: ["local"]), handler: { _ in "ok" },
                                     confirm: { $0.callId != "deny" })
        let results = await confirming.execute([policyCall("deny"), policyCall("succeed")])
        XCTAssertTrue(results[0].output.contains("confirmation"))
        XCTAssertTrue(results[1].success)
    }


    func testOverlappingBatchesSharePerTurnCallCapAtParallelWidth() async {
        let gate = PolicyGate()
        let engine = engine(width: 2, policy: AgentToolPolicy(maxToolsPerTurn: 2)) {
            await gate.run($0["query"]?.stringValue ?? "missing")
        }
        let batch = Task { await engine.execute([policyCall("first"), policyCall("second"), policyCall("third")]) }
        let entered = await gate.waitForEntries(2)
        XCTAssertTrue(entered)
        let overlapping = await engine.execute([policyCall("fourth")])
        XCTAssertTrue(overlapping[0].output.contains("max_tools_per_turn"))
        await gate.releaseAll()
        let results = await batch.value
        XCTAssertTrue(results[0].success)
        XCTAssertTrue(results[1].success)
        XCTAssertTrue(results[2].output.contains("max_tools_per_turn"))
        let started = await gate.started
        XCTAssertEqual(Set(started), ["first", "second"])
        XCTAssertEqual(started.count, 2)
    }

    func testConfirmationWaitDoesNotConsumeExecutionBudget() async throws {
        let confirmation = PolicyGate()
        let engine = engine(policy: AgentToolPolicy(requireUserConfirmation: ["local"], maxTotalRuntimeMs: 100),
                            handler: { _ in "ok" }, confirm: { _ in
            _ = await confirmation.run("confirm")
            return true
        })
        let pending = Task { await engine.execute([policyCall("approved")]) }
        let entered = await confirmation.waitForEntries(1)
        XCTAssertTrue(entered)
        try await Task.sleep(for: .milliseconds(150))
        await confirmation.releaseAll()
        let results = await pending.value
        XCTAssertTrue(results[0].success, "Confirmation time is outside the tool execution budget")
        XCTAssertEqual(results[0].output, "ok")
        let subsequent = await engine.execute([policyCall("next")])
        XCTAssertTrue(subsequent[0].success, "The completed confirmation wait must not exhaust the next admission")
    }

    func testWebhookTimeoutIsCappedByBudgetAndDefault() async {
        for (budget, expectedTimeout) in [(50, 0.05), (100_000, 30.0)] {
            let transport = StubWebhookTransport(steps: [.respond(status: 200, body: "ok")])
            let definition = ToolDefinition(name: "local", description: "injected webhook", parameters: [:],
                                            endpoint: ToolEndpoint(url: "https://tools.example.com/test"))
            let engine = ToolExecutionEngine(
                toolbox: AgentToolbox.resolve(config: Fixtures.config(tools: AgentToolsConfig(
                    definitions: [definition], toolPolicy: AgentToolPolicy(maxTotalRuntimeMs: budget)
                ))),
                configuration: AgentSessionConfiguration(), transport: transport
            )
            let results = await engine.execute([policyCall("webhook")])
            XCTAssertTrue(results[0].success)
            XCTAssertEqual(transport.requests.count, 1)
            XCTAssertEqual(transport.requests.first?.timeoutInterval, expectedTimeout)
        }
    }


    func testWebhookReceivesRemainingBudgetAfterCompletedNativeCall() async throws {
        let transport = StubWebhookTransport(steps: [.respond(status: 200, body: "ok")])
        let definitions = [Fixtures.toolDefinition(name: "local"), ToolDefinition(
            name: "remote", description: "injected webhook", parameters: [:],
            endpoint: ToolEndpoint(url: "https://tools.example.com/test")
        )]
        let engine = ToolExecutionEngine(
            toolbox: AgentToolbox.resolve(config: Fixtures.config(tools: AgentToolsConfig(
                definitions: definitions, toolPolicy: AgentToolPolicy(maxTotalRuntimeMs: 10_000)
            ))),
            configuration: AgentSessionConfiguration(toolHandlers: ["local": { _ in
                try await Task.sleep(for: .milliseconds(30))
                return "ok"
            }]), transport: transport
        )
        let results = await engine.execute([
            policyCall("native"), AgentToolCall(toolId: "remote", callId: "webhook", args: [:])
        ])
        XCTAssertTrue(results.allSatisfy(\.success))
        let consumed = try XCTUnwrap(results[0].durationMs)
        XCTAssertGreaterThanOrEqual(consumed, 30)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests.first?.timeoutInterval, Double(10_000 - consumed) / 1000)
    }

    func testFoundationModelsBridgeCallbacksShareEngineCapWithoutGeneration() async throws {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *) else {
            throw XCTSkip("Foundation Models requires iOS 26 / macOS 26")
        }
        let gate = PolicyGate()
        let engine = engine { _ in await gate.run(UUID().uuidString) }
        let bridge = ManifestBridgedTool(
            name: "local", description: "injected test",
            parameters: try GenerationSchemaBuilder.makeSchema(toolName: "local", parameters: ["type": .string("object")]),
            engine: engine, relay: ToolEventRelay()
        )
        let arguments = try GeneratedContent(json: "{}")
        let first = Task { try await bridge.call(arguments: arguments) }
        let entered = await gate.waitForEntries(1)
        XCTAssertTrue(entered)
        let second = Task { try await bridge.call(arguments: arguments) }
        let overlapped = await gate.waitForEntries(2, milliseconds: 40)
        XCTAssertFalse(overlapped)
        await gate.releaseAll()
        _ = try await first.value
        _ = try await second.value
        let peak = await gate.peak
        let entries = await gate.started.count
        XCTAssertEqual(peak, 1)
        XCTAssertEqual(entries, 2)
        #else
        throw XCTSkip("FoundationModels SDK not present")
        #endif
    }
}

private enum PolicyTestError: Error { case failed }

/// Each hold has its own bounded fallback. A failed assertion or a correct
/// serialized implementation therefore cannot deadlock the test process.
/// Continuations deliberately ignore caller cancellation to test slot ownership.
private actor PolicyGate {
    private(set) var started: [String] = []
    private(set) var peak = 0
    private var active = 0
    private var allReleased: Bool
    private var released: Set<String> = []
    private var holds: [String: CheckedContinuation<Void, Never>] = [:]
    private var timers: [String: Task<Void, Never>] = [:]

    init(released: Bool = false) { allReleased = released }

    func run(_ label: String) async -> String {
        started.append(label)
        active += 1
        peak = max(peak, active)
        if !allReleased && !released.contains(label) {
            await withCheckedContinuation { continuation in
                holds[label] = continuation
                timers[label] = Task {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    self.release(label)
                }
            }
        }
        active -= 1
        return label
    }

    func release(_ label: String) {
        released.insert(label)
        timers.removeValue(forKey: label)?.cancel()
        holds.removeValue(forKey: label)?.resume()
    }

    func releaseAll() {
        allReleased = true
        for label in Array(holds.keys) { release(label) }
    }

    func waitForEntries(_ count: Int, milliseconds: Int = 1_000) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(milliseconds))
        while started.count < count && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return started.count >= count
    }
}

private func policyCall(_ label: String) -> AgentToolCall {
    AgentToolCall(toolId: "local", callId: label, args: ["query": .string(label)])
}
