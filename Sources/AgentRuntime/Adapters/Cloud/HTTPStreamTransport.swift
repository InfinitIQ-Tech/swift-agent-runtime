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
///
/// The default session has no cache, cookie storage, or credential storage.
/// Host-injected sessions remain responsible for their own storage policy;
/// redirects, cache reads, and automatic cookies are disabled per request.
public struct URLSessionStreamTransport: HTTPStreamTransport {
    private let session: URLSession

    public init(session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(
            for: isolatedRequest(request), delegate: RejectRedirectsDelegate()
        )
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http.statusCode)
    }

    public func streamLines(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, Int) {
        let (bytes, response) = try await session.bytes(
            for: isolatedRequest(request), delegate: RejectRedirectsDelegate()
        )
        do {
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            let reader = HTTPLineReader(bytes: bytes, status: http.statusCode)
            // Pull one line at a time. There is no detached producer holding the
            // continuation alive when the consumer stops at message_stop.
            let stream = AsyncThrowingStream<String, Error>(unfolding: {
                try await reader.nextLine()
            })
            return (stream, http.statusCode)
        } catch {
            bytes.task.cancel()
            throw error
        }
    }

    private func isolatedRequest(_ request: URLRequest) -> URLRequest {
        var request = request
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        return request
    }
}

/// A task delegate also applies to an injected session: authenticated requests
/// never follow a redirect to a different path, origin, or protocol.
private final class RejectRedirectsDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// UTF-8 line framing for SSE, including empty lines and CR, LF, and CRLF.
/// Foundation's generic line conveniences are not the framing contract here.
/// The reader owns the real data task until EOF, failure, or stream release.
private actor HTTPLineReader {
    // Bound wire bytes before appending or UTF-8 decoding. The event budget
    // spans nonblank lines so many small `data:` lines cannot bypass it.
    // Delimiters do not count; a blank line resets the event budget.
    private static let maximumEventBytes = 1_048_576
    private let maximumLineBytes: Int
    private var iterator: URLSession.AsyncBytes.Iterator?
    private let task: URLSessionDataTask
    private var eventBytes = 0
    private var skipLineFeed = false
    private var firstLine = true
    private var finished = false

    init(bytes: URLSession.AsyncBytes, status: Int) {
        iterator = bytes.makeAsyncIterator()
        task = bytes.task
        // Non-success bodies only need the adapter's 16 KiB error prefix.
        // Apply that cap while reading, even if no newline ever arrives.
        maximumLineBytes = status == 200 ? Self.maximumEventBytes : 16_384
    }

    deinit {
        task.cancel()
    }

    func nextLine() async throws -> String? {
        if Task.isCancelled {
            finished = true
            task.cancel()
            throw CancellationError()
        }
        guard !finished else { return nil }
        // AsyncThrowingStream consumers must not advance an iterator
        // concurrently. Reject accidental concurrent readers as well.
        guard var iterator = iterator else { throw URLError(.badServerResponse) }
        self.iterator = nil
        defer { if !finished { self.iterator = iterator } }
        do {
            return try await withTaskCancellationHandler {
                var line: [UInt8] = []
                while let byte = try await iterator.next() {
                    try Task.checkCancellation()
                    if skipLineFeed {
                        skipLineFeed = false
                        if byte == 0x0A { continue }
                    }
                    if byte == 0x0A || byte == 0x0D {
                        skipLineFeed = byte == 0x0D
                        if line.isEmpty { eventBytes = 0 }
                        return try decode(line)
                    }
                    guard line.count < maximumLineBytes,
                          eventBytes < Self.maximumEventBytes else {
                        // No response text, request URL, or headers in errors.
                        throw URLError(.dataLengthExceedsMaximum)
                    }
                    line.append(byte)
                    eventBytes += 1
                }
                finished = true
                task.cancel()
                return line.isEmpty ? nil : try decode(line)
            } onCancel: {
                self.task.cancel()
            }
        } catch {
            finished = true
            task.cancel()
            throw error
        }
    }

    private func decode(_ bytes: [UInt8]) throws -> String {
        guard var line = String(bytes: bytes, encoding: .utf8) else {
            throw URLError(.cannotDecodeRawData)
        }
        if firstLine {
            firstLine = false
            if line.first == "\u{FEFF}" { line.removeFirst() }
        }
        return line
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
        // SSE strips at most one ASCII space following the first colon.
        // Trailing spaces and additional leading spaces belong to the data.
        let fields = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        var value = fields.count == 2 ? String(fields[1]) : ""
        if value.first == " " { value.removeFirst() }
        if fields.first == "event" {
            currentEvent = value
        } else if fields.first == "data" {
            dataLines.append(value)
        }
        return nil
    }

    /// Flushes a trailing event not terminated by a blank line.
    mutating func flush() -> ServerSentEvent? {
        consume(line: "")
    }
}
