import AgentRuntime
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Demo smoke-test transport: admits one request at the standard service tier.
/// Streaming and non-streaming methods share a budget consumed before any
/// suspension, including malformed, failed, and cancelled attempts. Requests
/// and credentials are forwarded without being retained by this wrapper.
public actor SingleRequestCloudTransport: HTTPStreamTransport {
    private let transport: any HTTPStreamTransport
    private var attempted = false

    public init(transport: any HTTPStreamTransport = URLSessionStreamTransport()) {
        self.transport = transport
    }

    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        try await transport.send(prepare(request))
    }

    public func streamLines(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, Int) {
        try await transport.streamLines(prepare(request))
    }

    private func prepare(_ request: URLRequest) throws -> URLRequest {
        guard !attempted else {
            throw AgentRuntimeError.generationFailed("Cloud smoke test request limit reached")
        }
        attempted = true
        guard let body = request.httpBody,
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: body),
              case .object(var fields) = decoded else {
            throw AgentRuntimeError.generationFailed("Cloud smoke test requires a JSON request object")
        }
        fields["service_tier"] = .string("standard_only")
        var request = request
        do { request.httpBody = try JSONEncoder().encode(JSONValue.object(fields)) }
        catch { throw AgentRuntimeError.generationFailed("Cloud smoke test request could not be encoded") }
        return request
    }
}
