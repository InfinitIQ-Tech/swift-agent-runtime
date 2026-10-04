import AgentRuntime
import Foundation
import Observation

public typealias DemoSessionFactory = @Sendable (AgentManifest, AgentSessionConfiguration) async throws -> any AgentSession

public enum DemoSessionState: String, Sendable {
    case notConnected, connecting, ready, sending, interrupted, unavailable, exhausted

    public var label: String {
        switch self {
        case .notConnected: "Not connected"
        case .connecting: "Preparing model…"
        case .ready: "Ready"
        case .sending: "Responding…"
        case .interrupted: "Start a new conversation to continue"
        case .unavailable: "Model unavailable — retry or connect with a provider key"
        case .exhausted: "Turn limit reached — start a new conversation"
        }
    }
}

public struct DemoMessage: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let role: AgentMessage.Role
    public var text: String
    public var isInterrupted: Bool

    public init(role: AgentMessage.Role, text: String, isInterrupted: Bool = false) {
        id = UUID()
        self.role = role
        self.text = text
        self.isInterrupted = isInterrupted
    }
}

public struct DemoSavedStory: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let body: String
}

/// Safe UI errors preserve the runtime category without rendering arbitrary
/// provider response bodies, URLs, credentials, or transport diagnostics.
public struct DemoFailure: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case unavailable, guardrail, contextWindow, cancelled, generation, turnLimit, tool, response, output
    }
    public let kind: Kind
    public let message: String

    static func from(_ error: any Error) -> Self {
        guard let error = error as? AgentRuntimeError else {
            if error is CancellationError {
                return Self(kind: .cancelled, message: "The operation was cancelled. Start a new conversation to continue.")
            }
            return Self(kind: .generation, message: "The model request failed. Start a new conversation and check your connection or provider key.")
        }
        switch error {
        case .modelUnavailable(let reason):
            let message: String
            switch reason {
            case .osTooOld: message = "On-device generation requires iOS or macOS 26. Use an eligible device or enter a cloud provider key."
            case .deviceNotEligible: message = "This device cannot run the on-device model. Enter a cloud provider key."
            case .appleIntelligenceNotEnabled: message = "Enable Apple Intelligence in Settings, or enter a cloud provider key."
            case .modelNotReady: message = "The on-device model is still preparing. Retry after its download finishes, or enter a cloud provider key."
            case .missingProviderKey: message = "No model is available. Enable the on-device model on an eligible device, or enter an Anthropic key and connect."
            case .unsupportedModel: message = "No installed adapter supports this manifest's models."
            case .other: message = "The model is unavailable. Retry or connect with a provider key."
            }
            return Self(kind: .unavailable, message: message)
        case .noUsableModelCandidate:
            return Self(kind: .unavailable, message: "No model is available for this manifest. Retry or connect with a provider key.")
        case .guardrailViolation:
            return Self(kind: .guardrail, message: "The model declined this request under its safety rules. Start a new conversation to try another request.")
        case .contextWindowExceeded:
            return Self(kind: .contextWindow, message: "This conversation exceeded the model's context window. Start a new conversation.")
        case .cancelled:
            return Self(kind: .cancelled, message: "The operation was cancelled. Start a new conversation to continue.")
        case .generationFailed:
            return Self(kind: .generation, message: "Generation failed. Start a new conversation and check your connection or provider key.")
        case .maxTurnsExceeded:
            return Self(kind: .turnLimit, message: "The manifest's turn limit was reached. Start a new conversation.")
        case .toolNotAllowed, .toolNotRegistered:
            return Self(kind: .tool, message: "A requested tool is not permitted or registered. Start a new conversation.")
        case .invalidProviderResponse:
            return Self(kind: .response, message: "The provider returned an invalid response. Start a new conversation to retry.")
        case .unsupportedOutputFormat, .structuredOutputInvalid:
            return Self(kind: .output, message: "The model could not produce the manifest's required output format. Start a new conversation.")
        }
    }
}

/// Shared app state. Credentials and sessions live only in memory. Every
/// asynchronous operation belongs to an epoch; reset/interruption invalidates
/// it before any cancellation is awaited. Discarded sessions are never reused.
@MainActor @Observable
public final class RuntimeDemoModel {
    public let manifest: AgentManifest
    public var draft = ""
    public private(set) var messages: [DemoMessage] = []
    public private(set) var state: DemoSessionState = .notConnected
    public private(set) var remainingTurns: Int?
    public private(set) var modelLabel: String?
    public private(set) var error: DemoFailure?
    public private(set) var savedStories: [DemoSavedStory] = []

    @ObservationIgnored private let sessionFactory: DemoSessionFactory
    @ObservationIgnored private var session: (any AgentSession)?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var epoch: UInt64 = 0
    @ObservationIgnored private var providerKey = ""
    @ObservationIgnored private var completedTurns = 0

    public init(manifest: AgentManifest, sessionFactory: @escaping DemoSessionFactory = { manifest, configuration in
        try AgentRuntimeResolver.makeSession(manifest: manifest, configuration: configuration)
    }) {
        self.manifest = manifest
        self.sessionFactory = sessionFactory
        remainingTurns = manifest.config.runtime.maxTurns
    }

    public var isBusy: Bool { state == .connecting || state == .sending }
    public var canSend: Bool {
        state == .ready && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && remainingTurns != 0
    }

    /// A connect is always a new conversation: a fresh session cannot truthfully
    /// continue a transcript belonging to a discarded adapter.
    public func connect(providerKey: String = "") {
        self.providerKey = providerKey.trimmingCharacters(in: .whitespacesAndNewlines)
        newConversation()
    }

    public func newConversation() {
        invalidateOperation()
        let token = epoch
        messages = []
        draft = ""
        error = nil
        modelLabel = nil
        completedTurns = 0
        remainingTurns = manifest.config.runtime.maxTurns
        state = .connecting

        var keys = ProviderKeys()
        if !providerKey.isEmpty { keys[ProviderKeys.anthropicProvider] = providerKey }
        let configuration = AgentSessionConfiguration(providerKeys: keys, toolHandlers: [
            "save_story": { [weak self] arguments in
                guard let self else { throw AgentRuntimeError.cancelled }
                return try await self.saveStory(arguments, epoch: token)
            }
        ])
        let manifest = manifest
        let factory = sessionFactory
        operation = Task { [weak self] in
            do {
                guard self?.epoch == token, !Task.isCancelled else { return }
                let candidate = try await factory(manifest, configuration)
                guard let self, self.epoch == token, !Task.isCancelled else {
                    await candidate.cancel()
                    return
                }
                self.session = candidate
                await candidate.prewarm()
                guard self.epoch == token, !Task.isCancelled else { return }
                self.state = .ready
                self.operation = nil
            } catch {
                guard let self, self.epoch == token, !Task.isCancelled else { return }
                self.error = DemoFailure.from(error)
                self.state = .unavailable
                self.operation = nil
            }
        }
    }

    public func send() {
        guard canSend, let session else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        error = nil
        state = .sending
        messages.append(DemoMessage(role: .user, text: redacted(text)))
        let reply = DemoMessage(role: .assistant, text: "")
        messages.append(reply)
        let token = epoch
        operation = Task { [weak self] in
            do {
                guard self?.epoch == token, !Task.isCancelled else { return }
                let events = await session.send(text)
                var receivedEnd = false
                for try await event in events {
                    guard let self, self.epoch == token, !Task.isCancelled else { return }
                    // Await stream completion before allowing a repeated send.
                    // Terminal text can be shown while adapter cleanup finishes.
                    if !receivedEnd { receivedEnd = self.receive(event, replyID: reply.id) }
                }
                guard let self, self.epoch == token, !Task.isCancelled else { return }
                if receivedEnd {
                    self.state = self.remainingTurns == 0 ? .exhausted : .ready
                    self.operation = nil
                    return
                }
                self.failTurn(AgentRuntimeError.invalidProviderResponse("Missing terminal event"), replyID: reply.id)
            } catch {
                guard let self, self.epoch == token, !Task.isCancelled else { return }
                self.failTurn(error, replyID: reply.id)
            }
        }
    }

    public func stop() {
        guard isBusy else { return }
        interrupt()
    }

    /// Called when the scene backgrounds or the conversation disappears.
    public func suspend() {
        guard state != .notConnected, state != .interrupted else { return }
        interrupt()
    }

    private func interrupt() {
        let wasSending = state == .sending
        invalidateOperation()
        if wasSending, let index = messages.lastIndex(where: { $0.role == .assistant }) {
            messages[index].isInterrupted = true
        }
        state = .interrupted
        error = nil
    }

    private func invalidateOperation() {
        epoch &+= 1
        operation?.cancel()
        operation = nil
        let discarded = session
        session = nil
        if let discarded { Task { await discarded.cancel() } }
    }

    private func receive(_ event: AgentStreamEvent, replyID: UUID) -> Bool {
        switch event {
        case .start(let start):
            modelLabel = redacted(start.model)
            if let limit = manifest.config.runtime.maxTurns { remainingTurns = max(0, limit - start.turn) }
        case .chunk(let text):
            if let index = messages.firstIndex(where: { $0.id == replyID }) {
                messages[index].text = redacted(messages[index].text + text)
            }
        case .toolCall(let call):
            messages.append(DemoMessage(role: .tool, text: "Calling \(redacted(call.toolId))…"))
        case .toolResult(let result):
            messages.append(DemoMessage(role: .tool, text: "\(redacted(result.toolId)): \(result.success ? "Succeeded" : "Failed") — \(redacted(result.output))"))
        case .end(let result):
            if let index = messages.firstIndex(where: { $0.id == replyID }) {
                // Terminal text is authoritative, including non-streaming and
                // structured turns that never emit a chunk.
                messages[index].text = redacted(result.text)
            }
            completedTurns += 1
            remainingTurns = result.remainingTurns ?? manifest.config.runtime.maxTurns.map { max(0, $0 - completedTurns) }
            return true
        }
        return false
    }

    private func failTurn(_ failure: any Error, replyID: UUID) {
        if let index = messages.firstIndex(where: { $0.id == replyID }) { messages[index].isInterrupted = true }
        let display = DemoFailure.from(failure)
        invalidateOperation()
        error = display
        if display.kind == .turnLimit {
            remainingTurns = 0
            state = .exhausted
        } else {
            state = .interrupted
        }
    }

    private func saveStory(_ arguments: [String: JSONValue], epoch token: UInt64) throws -> String {
        guard epoch == token, state == .sending, !Task.isCancelled else { throw AgentRuntimeError.cancelled }
        guard let title = arguments["title"]?.stringValue, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let body = arguments["body"]?.stringValue, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentRuntimeError.generationFailed("save_story requires a title and body")
        }
        savedStories.append(DemoSavedStory(id: UUID(), title: redacted(title), body: redacted(body)))
        return "Saved to this demo's in-memory story library."
    }

    private func redacted(_ text: String) -> String {
        providerKey.isEmpty ? text : text.replacingOccurrences(of: providerKey, with: "<redacted>")
    }
}
