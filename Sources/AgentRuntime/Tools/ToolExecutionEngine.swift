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
    /// Tool calls executed so far in the current turn.
    private var toolsThisTurn = 0
    /// Milliseconds of tool runtime consumed this turn.
    private var runtimeConsumedMs = 0

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

    /// Resets per-turn policy counters. Called at the start of each turn.
    public func beginTurn() {
        toolsThisTurn = 0
        runtimeConsumedMs = 0
    }

    /// Executes a batch of calls requested in one model round, honoring
    /// `max_concurrent_tools`. Results return in call order.
    public func execute(_ calls: [AgentToolCall]) async -> [AgentToolResult] {
        let width = max(1, toolbox.maxConcurrentTools ?? 1)
        var results: [AgentToolResult?] = Array(repeating: nil, count: calls.count)

        var index = 0
        while index < calls.count {
            let window = Array(calls[index..<min(index + width, calls.count)]).enumerated()
            let base = index
            await withTaskGroup(of: (Int, AgentToolResult).self) { group in
                for (offset, call) in window {
                    // Policy gates are checked serially before spawning so
                    // per-turn counting stays deterministic.
                    if let denial = policyDenial(for: call) {
                        results[base + offset] = denial
                        continue
                    }
                    toolsThisTurn += 1
                    group.addTask { [self] in
                        (base + offset, await self.executeOne(call))
                    }
                }
                for await (position, result) in group {
                    results[position] = result
                }
            }
            index += width
        }

        let ordered = results.compactMap { $0 }
        for result in ordered {
            runtimeConsumedMs += result.durationMs ?? 0
        }
        return ordered
    }

    private func policyDenial(for call: AgentToolCall) -> AgentToolResult? {
        guard toolbox.definition(named: call.toolId) != nil else {
            return AgentToolResult(
                toolId: call.toolId,
                callId: call.callId,
                output: "Tool is not in the allow-list for this agent.",
                success: false
            )
        }
        if let cap = toolbox.policy?.maxToolsPerTurn, toolsThisTurn >= cap {
            return AgentToolResult(
                toolId: call.toolId,
                callId: call.callId,
                output: "tool_policy.max_tools_per_turn (\(cap)) exhausted for this turn.",
                success: false
            )
        }
        if let budget = toolbox.policy?.maxTotalRuntimeMs, runtimeConsumedMs >= budget {
            return AgentToolResult(
                toolId: call.toolId,
                callId: call.callId,
                output: "tool_policy.max_total_runtime_ms (\(budget)) exhausted for this turn.",
                success: false
            )
        }
        return nil
    }

    private func executeOne(_ call: AgentToolCall) async -> AgentToolResult {
        guard let definition = toolbox.definition(named: call.toolId) else {
            return AgentToolResult(
                toolId: call.toolId,
                callId: call.callId,
                output: "Tool is not in the allow-list for this agent.",
                success: false
            )
        }

        if toolbox.policy?.requireUserConfirmation?.contains(call.toolId) == true {
            guard let confirm, await confirm(call) else {
                return AgentToolResult(
                    toolId: call.toolId,
                    callId: call.callId,
                    output: "User confirmation was required and not granted.",
                    success: false
                )
            }
        }

        let started = ContinuousClock.now
        let remainingBudgetMs = toolbox.policy?.maxTotalRuntimeMs.map { max(0, $0 - runtimeConsumedMs) }

        let output: String
        let success: Bool
        if let endpoint = definition.endpoint {
            let result = await webhook.execute(
                endpoint: endpoint,
                call: call,
                timeoutMs: remainingBudgetMs
            )
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
        return AgentToolResult(
            toolId: call.toolId,
            callId: call.callId,
            output: output,
            success: success,
            durationMs: durationMs
        )
    }
}
