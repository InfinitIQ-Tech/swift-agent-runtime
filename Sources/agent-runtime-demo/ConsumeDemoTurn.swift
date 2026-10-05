import AgentRuntime

/// Consume one complete turn before reporting success. An end frame is only a
/// pending success until the stream finishes cleanly and cancellation is checked.
@MainActor
func consumeDemoTurn(
    _ events: AsyncThrowingStream<AgentStreamEvent, Error>,
    status: CloudSmokeStatus? = nil,
    onEvent: (AgentStreamEvent) throws -> Void
) async throws {
    do {
        var pendingEnd: AgentStreamEvent?
        try Task.checkCancellation()
        for try await event in events {
            try Task.checkCancellation()
            guard pendingEnd == nil else {
                throw AgentRuntimeError.invalidProviderResponse("Demo turn emitted an event after its end frame")
            }
            switch event {
            case .start:
                status?.record(.turnStarted)
            case .chunk(let text):
                if !text.isEmpty { status?.record(.streaming) }
            case .end:
                pendingEnd = event
                continue
            case .toolCall, .toolResult:
                break
            }
            try onEvent(event)
        }
        try Task.checkCancellation()
        guard let pendingEnd else {
            throw AgentRuntimeError.invalidProviderResponse("Demo turn finished without an end frame")
        }
        try onEvent(pendingEnd)
        try Task.checkCancellation()
        status?.record(.completed)
    } catch {
        status?.record(.failed, failure: .classify(error))
        throw error
    }
}
