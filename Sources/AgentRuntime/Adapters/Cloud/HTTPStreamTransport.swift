import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Transport seam for the cloud adapter, injectable in tests.
public protocol HTTPStreamTransport: Sendable {
    /// Sends a request and returns the full response body.
    func send(_ request: URLRequest) async throws -> (Data, Int)
    /// Sends a request and returns the response as a stream of text lines
    /// (for Server-Sent Events).
    func streamLines(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, Int)
}

/// Production transport backed by `URLSession`.
public struct URLSessionStreamTransport: HTTPStreamTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http.statusCode)
    }

    public func streamLines(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, Int) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        let stream = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
        return (stream, http.statusCode)
    }
}

/// One parsed Server-Sent Event.
struct ServerSentEvent: Equatable {
    let event: String?
    let data: String
}

/// Incremental SSE line parser: feed lines, collect completed events.
struct ServerSentEventParser {
    private var currentEvent: String?
    private var dataLines: [String] = []

    /// Consumes one line; returns a completed event when a blank line closes it.
    mutating func consume(line: String) -> ServerSentEvent? {
        if line.isEmpty {
            defer {
                currentEvent = nil
                dataLines = []
            }
            guard !dataLines.isEmpty else { return nil }
            return ServerSentEvent(event: currentEvent, data: dataLines.joined(separator: "\n"))
        }
        if line.hasPrefix("event:") {
            currentEvent = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("data:") {
            dataLines.append(String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// Flushes a trailing event not terminated by a blank line.
    mutating func flush() -> ServerSentEvent? {
        consume(line: "")
    }
}
