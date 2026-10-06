import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Transport seam for webhook tool execution, injectable in tests.
public protocol WebhookTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Production transport backed by `URLSession`.
public struct URLSessionWebhookTransport: WebhookTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

/// Executes the Swift lane's `ToolDefinition.endpoint` webhooks:
/// arguments travel as a JSON body (or query
/// items for GET), static manifest headers are applied, and a 2xx status is
/// success with the response body as the tool output.
struct WebhookToolExecutor: Sendable {
    let transport: WebhookTransport
    /// Default per-call timeout when the policy budget does not bound it tighter.
    static let defaultTimeoutMs = 30_000

    struct Outcome: Sendable {
        let output: String
        let success: Bool
    }

    func execute(endpoint: ToolEndpoint, call: AgentToolCall, timeoutMs: Int?) async -> Outcome {
        guard var components = URLComponents(string: endpoint.url) else {
            return Outcome(output: "Invalid tool endpoint URL.", success: false)
        }
        let method = (endpoint.method ?? "POST").uppercased()

        if method == "GET" {
            var items = components.queryItems ?? []
            for (key, value) in call.args.sorted(by: { $0.key < $1.key }) {
                items.append(URLQueryItem(name: key, value: Self.queryValue(value)))
            }
            components.queryItems = items.isEmpty ? nil : items
        }

        guard let url = components.url else {
            return Outcome(output: "Invalid tool endpoint URL.", success: false)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        let effectiveTimeoutMs = min(timeoutMs ?? Self.defaultTimeoutMs, Self.defaultTimeoutMs)
        request.timeoutInterval = TimeInterval(effectiveTimeoutMs) / 1000
        for (header, value) in endpoint.headers ?? [:] {
            request.setValue(value, forHTTPHeaderField: header)
        }
        if method != "GET" {
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            do {
                request.httpBody = try JSONEncoder().encode(call.args)
            } catch {
                return Outcome(output: "Tool arguments were not encodable: \(error)", success: false)
            }
        }

        do {
            let (data, response) = try await transport.send(request)
            let body = String(data: data, encoding: .utf8) ?? ""
            let success = (200..<300).contains(response.statusCode)
            return Outcome(
                output: success ? body : "Tool endpoint returned status \(response.statusCode): \(body)",
                success: success
            )
        } catch {
            return Outcome(output: "Tool endpoint request failed: \(error.localizedDescription)", success: false)
        }
    }

    private static func queryValue(_ value: JSONValue) -> String {
        switch value {
        case .string(let s): return s
        case .integer(let i): return String(i)
        case .number(let n): return String(n)
        case .bool(let b): return String(b)
        case .null: return ""
        case .object, .array:
            let data = (try? JSONEncoder().encode(value)) ?? Data()
            return String(data: data, encoding: .utf8) ?? ""
        }
    }
}
