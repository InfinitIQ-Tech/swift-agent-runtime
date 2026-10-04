#if DEBUG
import AgentRuntime
import Foundation

actor DemoSimulationFactory {
    private var unavailableFirst: Bool

    init(unavailableFirst: Bool) { self.unavailableFirst = unavailableFirst }

    func makeSession(manifest: AgentManifest, configuration: AgentSessionConfiguration) throws -> any AgentSession {
        if unavailableFirst {
            unavailableFirst = false
            throw AgentRuntimeError.modelUnavailable(.osTooOld)
        }
        return DemoSimulationSession(manifest: manifest, configuration: configuration)
    }
}

/// Explicit UI-test seam; never compiled into Release and never presented as a model.
actor DemoSimulationSession: AgentSession {
    nonisolated let manifest: AgentManifest
    private let configuration: AgentSessionConfiguration
    private var used = 0
    private var task: Task<Void, Never>?

    init(manifest: AgentManifest, configuration: AgentSessionConfiguration) {
        self.manifest = manifest
        self.configuration = configuration
    }

    func send(_ text: String) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<AgentStreamEvent, Error>.makeStream()
        if let limit = manifest.config.runtime.maxTurns, used >= limit {
            continuation.finish(throwing: AgentRuntimeError.maxTurnsExceeded(limit: limit))
            return stream
        }
        used += 1
        let index = used
        task = Task {
            do {
                continuation.yield(.start(AgentTurnStart(turn: index, candidate: "simulation", model: "Simulation")))
                if text.lowercased() == "fail" {
                    throw AgentRuntimeError.generationFailed("Private provider diagnostics must not be displayed")
                }
                let reply = "Simulated reply \(index): \(text)"
                if text.lowercased() != "final" {
                    continuation.yield(.chunk("Simulated "))
                    try await Task.sleep(for: .milliseconds(text.lowercased() == "slow" ? 5_000 : 150))
                    continuation.yield(.chunk("reply \(index): \(text)"))
                }
                var results: [AgentToolResult] = []
                if text.lowercased() == "save" {
                    let call = AgentToolCall(toolId: "save_story", callId: "simulation-\(index)", args: [
                        "title": .string("A simulated story"), "body": .string("A small fox followed the moon home.")
                    ])
                    continuation.yield(.toolCall(call))
                    if let save = configuration.toolHandlers["save_story"] {
                        let output = try await save(call.args)
                        let result = AgentToolResult(toolId: call.toolId, callId: call.callId, output: output, success: true)
                        results.append(result)
                        continuation.yield(.toolResult(result))
                    }
                }
                try Task.checkCancellation()
                continuation.yield(.end(AgentTurnResult(
                    text: reply, toolResults: results,
                    remainingTurns: manifest.config.runtime.maxTurns.map { max(0, $0 - index) }
                )))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        let running = task
        continuation.onTermination = { reason in
            if case .cancelled = reason { running?.cancel() }
        }
        return stream
    }

    func prewarm() {}
    func cancel() { task?.cancel(); task = nil }
    func transcript() -> [AgentMessage] { [] }
    func turnsUsed() -> Int { used }
}
#endif
