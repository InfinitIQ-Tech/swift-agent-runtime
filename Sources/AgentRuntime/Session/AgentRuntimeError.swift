import Foundation

/// Why a runtime adapter cannot execute right now.
public enum AgentRuntimeUnavailableReason: Equatable, Sendable {
    /// The OS is older than the adapter's floor (for example, Foundation Models below iOS 26 / macOS 26).
    case osTooOld
    /// The hardware cannot run the on-device model.
    case deviceNotEligible
    /// Apple Intelligence is not enabled on the device.
    case appleIntelligenceNotEnabled
    /// Model assets are not downloaded or are still downloading.
    case modelNotReady
    /// A cloud adapter has no provider key for the requested provider.
    case missingProviderKey(provider: String)
    /// No candidate in `model.candidates` names a provider this adapter serves.
    case unsupportedModel
    /// Any other adapter-specific reason.
    case other(String)
}

/// Cheap, non-OS-gated availability signal hosts can query before showing entry points.
public enum AgentRuntimeAvailability: Equatable, Sendable {
    case available
    case unavailable(AgentRuntimeUnavailableReason)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

/// Typed error taxonomy for session execution. Cases are deliberately
/// distinguishable so hosts can log them distinctly while mapping several of
/// them to one user-facing treatment.
public enum AgentRuntimeError: Error, Equatable, Sendable {
    /// The selected model cannot execute (device ineligible, assets missing, model lost mid-session).
    case modelUnavailable(AgentRuntimeUnavailableReason)
    /// The model refused the request on safety grounds.
    case guardrailViolation
    /// The conversation no longer fits the model's context window.
    case contextWindowExceeded
    /// The caller cancelled the in-flight turn.
    case cancelled
    /// Generation failed for a reason other than the cases above.
    case generationFailed(String)
    /// The session has consumed `runtime.max_turns` turns.
    case maxTurnsExceeded(limit: Int)
    /// A tool call named a tool outside the normalized allow-list.
    case toolNotAllowed(String)
    /// An allowed tool has no endpoint and no host-registered handler.
    case toolNotRegistered(String)
    /// No adapter can run any of the manifest's model candidates.
    case noUsableModelCandidate
    /// The adapter received a response it cannot interpret.
    case invalidProviderResponse(String)
    /// The manifest declares an `output.format.type` this runtime cannot execute.
    case unsupportedOutputFormat(String)
    /// The provider returned output that does not conform to the manifest's declared output schema.
    case structuredOutputInvalid(String)
}
