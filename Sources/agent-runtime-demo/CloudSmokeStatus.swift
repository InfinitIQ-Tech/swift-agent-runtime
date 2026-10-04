import AgentRuntime
import Foundation

/// Opt-in, closed-schema diagnostics. Never accepts input, request bodies,
/// headers, generated text, raw errors, or credentials for serialization.
final class CloudSmokeStatus: @unchecked Sendable {
    enum Stage: String, Encodable {
        case started
        case credentialEntryRequested = "credential_entry_requested"
        case awaitingSend = "awaiting_send"
        case ownerDeclined = "owner_declined"
        case turnStarted = "turn_started"
        case requestStarted = "request_started"
        case responseReceived = "response_received"
        case streaming
        case completed
        case failed
    }

    enum Failure: String, Encodable {
        case configuration, credentialEntry = "credential_entry", unavailable
        case authentication, network, generation, invalidResponse = "invalid_response"
        case contextLimit = "context_limit", outputLimit = "output_limit"
        case guardrail, cancelled, turnLimit = "turn_limit", tool, unknown

        static func classify(_ error: Error) -> Self {
            guard let error = error as? AgentRuntimeError else { return .unknown }
            switch error {
            case .modelUnavailable(.missingProviderKey): return .authentication
            case .modelUnavailable, .noUsableModelCandidate: return .unavailable
            case .guardrailViolation: return .guardrail
            case .contextWindowExceeded: return .contextLimit
            case .cancelled: return .cancelled
            case .maxTurnsExceeded: return .turnLimit
            case .toolNotAllowed, .toolNotRegistered: return .tool
            case .invalidProviderResponse, .structuredOutputInvalid: return .invalidResponse
            case .unsupportedOutputFormat: return .configuration
            case .generationFailed(let message):
                if message == "Messages API output token limit reached" { return .outputLimit }
                if message.hasPrefix("Messages API transport failed") { return .network }
                return .generation
            }
        }
    }

    private struct Snapshot: Encodable {
        let schemaVersion = 1
        let processID = ProcessInfo.processInfo.processIdentifier
        var updatedAt = Date().timeIntervalSince1970
        var stage = Stage.started
        var requestStarted = false
        var httpStatus: Int?
        var streamed = false
        var failure: Failure?
    }

    private let lock = NSLock()
    private let url: URL
    private var snapshot = Snapshot()

    init(path: String) throws {
        url = URL(fileURLWithPath: path)
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }

    func record(_ stage: Stage, failure: Failure? = nil, httpStatus: Int? = nil) {
        lock.lock()
        defer { lock.unlock() }
        snapshot.stage = stage
        snapshot.updatedAt = Date().timeIntervalSince1970
        if stage == .requestStarted { snapshot.requestStarted = true }
        if stage == .streaming { snapshot.streamed = true }
        if let httpStatus, (100...599).contains(httpStatus) { snapshot.httpStatus = httpStatus }
        snapshot.failure = failure
        do { try JSONEncoder().encode(snapshot).write(to: url, options: .atomic) }
        catch {
            FileHandle.standardError.write(Data("error: smoke status could not be updated\n".utf8))
        }
    }
}

/// Observes only transport milestones and numeric HTTP status. The enclosing
/// SingleRequestCloudTransport enforces its existing one-request limit first.
struct ObservedCloudSmokeTransport: HTTPStreamTransport {
    let status: CloudSmokeStatus
    private let transport = URLSessionStreamTransport()

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        status.record(.requestStarted)
        let result = try await transport.send(request)
        status.record(.responseReceived, httpStatus: result.1)
        return result
    }

    func streamLines(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, Int) {
        status.record(.requestStarted)
        let result = try await transport.streamLines(request)
        status.record(.responseReceived, httpStatus: result.1)
        return result
    }
}
