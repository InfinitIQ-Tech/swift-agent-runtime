import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Executes tool calls against the normalized toolbox, enforcing the
/// manifest's `tool_policy` and `runtime.max_concurrent_tools`.
///
/// Resolution order per call: the call must name an allowed tool; a tool
/// with an `endpoint` executes as an HTTP webhook; otherwise a
/// host-registered handler executes it; otherwise the call fails typed.
public actor ToolExecutionEngine {
    private let toolbox: AgentToolbox
    private let handlers: [String: AgentToolHandler]
    private let confirm: (@Sendable (AgentToolCall) async -> Bool)?
    private let webhook: WebhookToolExecutor
    private var turnID = UUID()
    private var toolsThisTurn = 0
    private var runtimeConsumedMs = 0
    /// Occupancy is engine-wide, including work from a previous turn that
    /// has not unwound yet. It is never reset by `beginTurn()`.
    private var activeCalls = 0
    private var waiting: [WaitingCall] = []

    // onCancel is synchronous and nonisolated. Record cancellation immediately
    // so admission cannot race ahead of the actor's queued cleanup task.
    private final class BatchCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }

    private struct Ticket: Sendable {
        let id = UUID()
        let call: AgentToolCall
        let turnID: UUID
        let cancellation: BatchCancellation
    }

    private enum Admission: Sendable {
        case allowed
        case denied(AgentToolResult)
    }

    private struct WaitingCall {
        let ticket: Ticket
        var continuation: CheckedContinuation<Admission, Never>?
    }

    public init(
        toolbox: AgentToolbox,
        configuration: AgentSessionConfiguration,
        transport: WebhookTransport = URLSessionWebhookTransport()
    ) {
        self.toolbox = toolbox
        self.handlers = configuration.toolHandlers
        self.confirm = configuration.confirmToolExecution
        self.webhook = WebhookToolExecutor(transport: transport)
    }

    /// Starts new policy counters and invalidates queued old-turn calls.
    /// Already active calls retain their capacity until they finish.
    public func beginTurn() {
        turnID = UUID()
        toolsThisTurn = 0
        runtimeConsumedMs = 0
        let previous = waiting
        waiting.removeAll()
        for request in previous {
            request.continuation?.resume(returning: .denied(previousTurnResult(request.ticket.call)))
        }
    }

    /// Executes calls in FIFO admission order across all batches on this
    /// engine, honoring `max_concurrent_tools`. Results return in call order.
    public func execute(_ calls: [AgentToolCall]) async -> [AgentToolResult] {
        let cancellation = BatchCancellation()
        let tickets = calls.map { Ticket(call: $0, turnID: turnID, cancellation: cancellation) }
        return await withTaskCancellationHandler {
            if Task.isCancelled { cancellation.cancel() }
            // Register the whole batch before spawning children so scheduling
            // of child tasks cannot reorder its policy checks or admissions.
            waiting.append(contentsOf: tickets.map { WaitingCall(ticket: $0) })
            return await withTaskGroup(of: (Int, AgentToolResult).self) { group in
                for (index, ticket) in tickets.enumerated() {
                    group.addTask { (index, await self.executeQueued(ticket)) }
                }
                var results: [AgentToolResult?] = Array(repeating: nil, count: calls.count)
                for await (index, result) in group { results[index] = result }
                return results.compactMap { $0 }
            }
        } onCancel: {
            cancellation.cancel()
            Task { await self.removeCancelledCalls() }
        }
    }

    private func executeQueued(_ ticket: Ticket) async -> AgentToolResult {
        let admission = await withCheckedContinuation { continuation in
            guard let index = waiting.firstIndex(where: { $0.ticket.id == ticket.id }) else {
                continuation.resume(returning: Admission.denied(
                    interruption(for: ticket) ?? previousTurnResult(ticket.call)
                ))
                return
            }
            waiting[index].continuation = continuation
            admitWaitingCalls()
        }
        if case .denied(let result) = admission { return result }

        // This child is structured under execute(): cancellation propagates to
        // confirmation/transport/handler, but capacity stays occupied until it
        // actually returns (even if a host handler ignores cancellation).
        let result = await executeOne(ticket)
        if ticket.turnID == turnID {
            let (total, overflow) = runtimeConsumedMs.addingReportingOverflow(result.durationMs ?? 0)
            runtimeConsumedMs = overflow ? Int.max : total
        }
        activeCalls -= 1
        // Account for completion before another call can inspect the budget.
        admitWaitingCalls()
        return result
    }

    private func removeCancelledCalls() {
        var retained: [WaitingCall] = []
        for request in waiting {
            if request.ticket.cancellation.isCancelled {
                request.continuation?.resume(returning: .denied(cancelledResult(request.ticket.call)))
            } else {
                retained.append(request)
            }
        }
        waiting = retained
        admitWaitingCalls()
    }

    private func admitWaitingCalls() {
        let width = max(1, toolbox.maxConcurrentTools ?? 1)
        while let request = waiting.first {
            if let denial = interruption(for: request.ticket) {
                waiting.removeFirst()
                request.continuation?.resume(returning: .denied(denial))
                continue
            }
            // Wait for the earliest child's continuation rather than letting
            // a later child overtake it because of task scheduling.
            guard let continuation = request.continuation else { return }
            if let denial = policyDenial(for: request.ticket.call) {
                waiting.removeFirst()
                continuation.resume(returning: .denied(denial))
                continue
            }
            guard activeCalls < width else { return }
            waiting.removeFirst()
            toolsThisTurn += 1
            activeCalls += 1
            continuation.resume(returning: .allowed)
        }
    }

    private func policyDenial(for call: AgentToolCall) -> AgentToolResult? {
        guard toolbox.definition(named: call.toolId) != nil else {
            return failure(call, "Tool is not in the allow-list for this agent.")
        }
        if let cap = toolbox.policy?.maxToolsPerTurn, toolsThisTurn >= cap {
            return failure(call, "tool_policy.max_tools_per_turn (\(cap)) exhausted for this turn.")
        }
        return runtimeDenial(for: call)
    }

    private func runtimeDenial(for call: AgentToolCall) -> AgentToolResult? {
        if let budget = toolbox.policy?.maxTotalRuntimeMs, runtimeConsumedMs >= budget {
            return failure(call, "tool_policy.max_total_runtime_ms (\(budget)) exhausted for this turn.")
        }
        return nil
    }

    private func interruption(for ticket: Ticket) -> AgentToolResult? {
        if ticket.cancellation.isCancelled { return cancelledResult(ticket.call) }
        if ticket.turnID != turnID { return previousTurnResult(ticket.call) }
        return nil
    }

    private func cancelledResult(_ call: AgentToolCall) -> AgentToolResult {
        failure(call, "Tool execution was cancelled.")
    }

    private func previousTurnResult(_ call: AgentToolCall) -> AgentToolResult {
        failure(call, "Tool call belongs to a previous turn.")
    }

    private func failure(_ call: AgentToolCall, _ output: String) -> AgentToolResult {
        AgentToolResult(toolId: call.toolId, callId: call.callId, output: output, success: false)
    }

    private func executeOne(_ ticket: Ticket) async -> AgentToolResult {
        let call = ticket.call
        if let denial = interruption(for: ticket) { return denial }
        guard let definition = toolbox.definition(named: call.toolId) else {
            return failure(call, "Tool is not in the allow-list for this agent.")
        }

        if toolbox.policy?.requireUserConfirmation?.contains(call.toolId) == true {
            guard let confirm else {
                return failure(call, "User confirmation was required and not granted.")
            }
            let approved = await confirm(call)
            if let denial = interruption(for: ticket) { return denial }
            guard approved else {
                return failure(call, "User confirmation was required and not granted.")
            }
        }
        // Another active call can finish while confirmation is suspended.
        // Recheck the completed-runtime budget immediately before dispatch.
        if let denial = runtimeDenial(for: call) { return denial }

        let started = ContinuousClock.now
        let remainingBudgetMs = toolbox.policy?.maxTotalRuntimeMs.map { max(0, $0 - runtimeConsumedMs) }
        let output: String
        let success: Bool
        if let endpoint = definition.endpoint {
            let result = await webhook.execute(endpoint: endpoint, call: call, timeoutMs: remainingBudgetMs)
            output = result.output
            success = result.success
        } else if let handler = handlers[call.toolId] {
            do {
                output = try await handler(call.args)
                success = true
            } catch {
                output = "Tool handler failed: \(error)"
                success = false
            }
        } else {
            output = "Tool has no endpoint and no host-registered handler."
            success = false
        }

        let elapsed = started.duration(to: .now)
        let durationMs = Int(elapsed.components.seconds * 1000)
            + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
        let interrupted = interruption(for: ticket)
        return AgentToolResult(
            toolId: call.toolId,
            callId: call.callId,
            output: interrupted?.output ?? output,
            success: interrupted == nil && success,
            durationMs: durationMs
        )
    }
}
