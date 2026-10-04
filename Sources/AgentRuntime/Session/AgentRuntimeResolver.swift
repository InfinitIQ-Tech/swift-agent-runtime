import Foundation

/// Entry point that picks an adapter for a manifest's model candidates and
/// opens a session. Swapping between on-device and cloud execution is purely
/// a matter of which adapters are available — the manifest and call sites do
/// not change.
public enum AgentRuntimeResolver {
    /// The default adapter set: on-device Foundation Models first, then the
    /// Anthropic cloud adapter.
    public static func defaultAdapters() -> [any AgentRuntimeAdapter] {
        [FoundationModelsAdapter(), ClaudeMessagesAdapter()]
    }

    /// Walks `model.candidates` under `model.strategy` and returns a session
    /// for the first candidate an adapter can serve right now.
    ///
    /// - `single`: only the first candidate is considered.
    /// - `fallback` (and any unrecognized strategy): candidates are tried in
    ///   manifest order. Unrecognized strategies are pass-through per the
    ///   public schema; ordered fallback is this runtime's execution-time
    ///   interpretation.
    public static func makeSession(
        manifest: AgentManifest,
        configuration: AgentSessionConfiguration = AgentSessionConfiguration(),
        adapters: [any AgentRuntimeAdapter]? = nil
    ) throws -> any AgentSession {
        let adapters = adapters ?? defaultAdapters()
        var lastReason: AgentRuntimeUnavailableReason = .unsupportedModel
        for candidate in candidates(for: manifest) {
            for adapter in adapters where adapter.supports(candidate: candidate) {
                switch adapter.availability(for: candidate, configuration: configuration) {
                case .available:
                    return try adapter.makeSession(
                        manifest: manifest,
                        candidate: candidate,
                        configuration: configuration
                    )
                case .unavailable(let reason):
                    lastReason = reason
                }
            }
        }
        throw AgentRuntimeError.modelUnavailable(lastReason)
    }

    /// Availability under the same selection strategy used by `makeSession`.
    /// A `single` strategy never advertises a later fallback candidate.
    public static func availability(
        manifest: AgentManifest,
        configuration: AgentSessionConfiguration = AgentSessionConfiguration(),
        adapters: [any AgentRuntimeAdapter]? = nil
    ) -> AgentRuntimeAvailability {
        let adapters = adapters ?? defaultAdapters()
        var lastReason: AgentRuntimeUnavailableReason = .unsupportedModel
        for candidate in candidates(for: manifest) {
            for adapter in adapters where adapter.supports(candidate: candidate) {
                switch adapter.availability(for: candidate, configuration: configuration) {
                case .available:
                    return .available
                case .unavailable(let reason):
                    lastReason = reason
                }
            }
        }
        return .unavailable(lastReason)
    }

    private static func candidates(for manifest: AgentManifest) -> [AgentModelCandidate] {
        if manifest.config.model.strategy == "single" {
            return Array(manifest.config.model.candidates.prefix(1))
        }
        return manifest.config.model.candidates
    }
}
