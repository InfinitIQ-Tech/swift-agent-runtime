import Foundation
import XCTest
@testable import AgentRuntime

final class HTTPStreamTransportTests: XCTestCase, @unchecked Sendable {
    func testDefaultSessionHasNoCacheCookieOrCredentialStorage() throws {
        let transport = URLSessionStreamTransport()
        let session = try XCTUnwrap(Mirror(reflecting: transport).children.first { $0.label == "session" }?.value as? URLSession)
        let configuration = session.configuration
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        session.invalidateAndCancel()
    }

    func testSendReturnsBodyAndStatusAndDisablesRequestStorage() async throws {
        let fixture = TransportFixture { loader in
            XCTAssertFalse(loader.request.httpShouldHandleCookies)
            XCTAssertEqual(loader.request.cachePolicy, .reloadIgnoringLocalCacheData)
            loader.respond(status: 503, bytes: Data("unavailable".utf8))
        }
        let (transport, session, request) = fixture.transport()
        defer { session.invalidateAndCancel(); fixture.remove() }
        let (data, status) = try await transport.send(request)
        XCTAssertEqual(status, 503)
        XCTAssertEqual(data, Data("unavailable".utf8))
    }

    func testStreamPreservesEmptyLinesAndSplitUTF8ForEveryNewlineStyle() async throws {
        let fixture = TransportFixture { loader in
            loader.respond(status: 200, chunks: Data("\u{FEFF}event: text\r\ndata: héllo 🌍\r\n\r\ndata: two\n\ndata: three\r\rtrailing".utf8).map { Data([$0]) })
        }
        let (transport, session, request) = fixture.transport()
        defer { session.invalidateAndCancel(); fixture.remove() }
        let (stream, status) = try await transport.streamLines(request)
        var lines: [String] = []
        for try await line in stream { lines.append(line) }
        XCTAssertEqual(status, 200)
        XCTAssertEqual(lines, ["event: text", "data: héllo 🌍", "", "data: two", "", "data: three", "", "trailing"])
        var parser = ServerSentEventParser()
        let events = lines.compactMap { parser.consume(line: $0) }
        XCTAssertEqual(events, [
            ServerSentEvent(event: "text", data: "héllo 🌍"),
            ServerSentEvent(event: nil, data: "two"),
            ServerSentEvent(event: nil, data: "three")
        ])
    }

    func testSSEParserPreservesPayloadWhitespaceAndEmptyDataFields() {
        var parser = ServerSentEventParser()
        for line in [": keepalive", "event: text", "data:  padded  ", "data", "data:\tvalue"] {
            XCTAssertNil(parser.consume(line: line))
        }
        XCTAssertEqual(parser.consume(line: ""), ServerSentEvent(event: "text", data: " padded  \n\n\tvalue"))
        XCTAssertNil(parser.consume(line: ""))
    }

    func testStreamRejectsInvalidUTF8() async throws {
        let fixture = TransportFixture { $0.respond(status: 200, bytes: Data([0xFF, 0x0A])) }
        let (transport, session, request) = fixture.transport()
        defer { session.invalidateAndCancel(); fixture.remove() }
        let (stream, _) = try await transport.streamLines(request)
        do {
            for try await _ in stream {}
            XCTFail("invalid UTF-8 must fail")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cannotDecodeRawData)
        }
    }

    func testStreamAcceptsMaximumUTF8LineAcrossChunksAndResetsAfterBlankLine() async throws {
        // The 1 MiB limit counts UTF-8 bytes, excluding CR/LF delimiters.
        let line = String(repeating: "é", count: 524_288)
        let bytes = Data((line + "\r\n\r\nnext\n").utf8)
        let chunks = stride(from: 0, to: bytes.count, by: 65_535).map {
            bytes.subdata(in: $0..<min($0 + 65_535, bytes.count))
        }
        let fixture = TransportFixture { $0.respond(status: 200, chunks: chunks) }
        let (transport, session, request) = fixture.transport()
        defer { session.invalidateAndCancel(); fixture.remove() }
        let (stream, _) = try await transport.streamLines(request)
        var lines: [String] = []
        for try await line in stream { lines.append(line) }
        XCTAssertEqual(lines, [line, "", "next"])
    }

    func testErrorResponseAcceptsExactly16KiBAtEOF() async throws {
        let line = String(repeating: "é", count: 8_192)
        let fixture = TransportFixture { $0.respond(status: 503, bytes: Data(line.utf8)) }
        let (transport, session, request) = fixture.transport()
        defer { session.invalidateAndCancel(); fixture.remove() }
        let (stream, status) = try await transport.streamLines(request)
        var lines: [String] = []
        for try await line in stream { lines.append(line) }
        XCTAssertEqual(status, 503)
        XCTAssertEqual(lines, [line])
    }

    func testOversizedUnterminatedLinesCancelTaskWithoutReturningContent() async throws {
        // Exercise both limits, across many callbacks and a single oversized
        // callback. The body stays open: rejection cannot depend on EOF.
        for (status, limit) in [(200, 1_048_576), (503, 16_384)] {
            for chunkSize in [4_093, limit + 1] {
                let sentinel = "synthetic-response-content-must-not-escape"
                let bytes = Data((sentinel + String(repeating: "x", count: limit + 1 - sentinel.utf8.count)).utf8)
                let chunks = stride(from: 0, to: bytes.count, by: chunkSize).map {
                    bytes.subdata(in: $0..<min($0 + chunkSize, bytes.count))
                }
                let stopped = expectation(description: "oversized \(status) response cancelled")
                let fixture = TransportFixture(stopped: stopped) {
                    $0.respond(status: status, chunks: chunks, finish: false)
                }
                let (transport, session, request) = fixture.transport()
                defer { session.invalidateAndCancel(); fixture.remove() }
                let (stream, responseStatus) = try await transport.streamLines(request)
                XCTAssertEqual(responseStatus, status)
                var lineCount = 0
                do {
                    for try await _ in stream { lineCount += 1 }
                    XCTFail("oversized unterminated line must fail")
                } catch let error as URLError {
                    XCTAssertEqual(error.code, .dataLengthExceedsMaximum)
                    XCTAssertTrue(error.userInfo.isEmpty)
                    XCTAssertFalse(String(reflecting: error).contains(sentinel))
                    XCTAssertFalse(error.localizedDescription.contains(sentinel))
                }
                XCTAssertEqual(lineCount, 0)
                await fulfillment(of: [stopped], timeout: 2)
            }
        }
    }

    func testErrorLineLimitCountsUTF8BytesBeforeDecoding() async throws {
        // Far fewer than 16,384 characters, but one byte over the wire limit.
        let bytes = Data((String(repeating: "🌍", count: 4_096) + "x").utf8)
        let stopped = expectation(description: "oversized UTF-8 response cancelled")
        let fixture = TransportFixture(stopped: stopped) {
            $0.respond(status: 400, bytes: bytes, finish: false)
        }
        let (transport, session, request) = fixture.transport()
        defer { session.invalidateAndCancel(); fixture.remove() }
        let (stream, _) = try await transport.streamLines(request)
        do {
            for try await _ in stream { XCTFail("oversized line must not be yielded") }
            XCTFail("UTF-8 wire bytes must be bounded")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .dataLengthExceedsMaximum)
        }
        await fulfillment(of: [stopped], timeout: 2)
    }

    func testEventBudgetRejectsManySmallDataLinesAndCancelsTask() async throws {
        let line = "data:" + String(repeating: "x", count: 1_019)
        let chunks = Array(repeating: Data((line + "\n").utf8), count: 1_024) + [Data("data:x\n".utf8)]
        let stopped = expectation(description: "oversized event cancelled")
        let fixture = TransportFixture(stopped: stopped) {
            $0.respond(status: 200, chunks: chunks, finish: false)
        }
        let (transport, session, request) = fixture.transport()
        defer { session.invalidateAndCancel(); fixture.remove() }
        let (stream, _) = try await transport.streamLines(request)
        var parser = ServerSentEventParser()
        var count = 0
        do {
            for try await line in stream {
                count += 1
                XCTAssertNil(parser.consume(line: line))
            }
            XCTFail("an event cannot grow indefinitely via short data lines")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .dataLengthExceedsMaximum)
        }
        XCTAssertEqual(count, 1_024)
        await fulfillment(of: [stopped], timeout: 2)
    }

    func testEventBudgetAllowsExactBoundaryAndResetsOnBlankLines() async throws {
        let line = "data:" + String(repeating: "x", count: 524_283)
        let bytes = Data((line + "\n" + line + "\n\ndata: next\n\n").utf8)
        let fixture = TransportFixture { $0.respond(status: 200, bytes: bytes) }
        let (transport, session, request) = fixture.transport()
        defer { session.invalidateAndCancel(); fixture.remove() }
        let (stream, _) = try await transport.streamLines(request)
        var parser = ServerSentEventParser()
        var events: [ServerSentEvent] = []
        for try await line in stream {
            if let event = parser.consume(line: line) { events.append(event) }
        }
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.first?.data.utf8.count, 1_048_567)
        XCTAssertEqual(events.last, ServerSentEvent(event: nil, data: "next"))
    }

    func testOversizedBodiesThroughRealAdapterKeepSafeStatusAndNeverCompleteTurn() async throws {
        let expectedErrors: [(Int, AgentRuntimeError)] = [
            (200, .generationFailed("Messages API transport failed (code -1103)")),
            (401, .modelUnavailable(.missingProviderKey(provider: "anthropic"))),
            (429, .generationFailed("Messages API status 429")),
            (503, .generationFailed("Messages API status 503"))
        ]
        for (status, expected) in expectedErrors {
            let sentinel = "synthetic-credential-marker"
            let limit = status == 200 ? 1_048_576 : 16_384
            let bytes = Data((sentinel + String(repeating: "x", count: limit + 1)).utf8)
            let stopped = expectation(description: "adapter oversized body cancelled")
            let fixture = TransportFixture(stopped: stopped) {
                $0.respond(status: status, bytes: bytes, finish: false)
            }
            let (transport, urlSession, request) = fixture.transport()
            defer { urlSession.invalidateAndCancel(); fixture.remove() }
            let manifest = try Fixtures.manifest(for: Fixtures.config(streaming: true))
            let candidate = try XCTUnwrap(manifest.config.model.candidates.first { $0.provider == "anthropic" })
            let adapter = ClaudeMessagesAdapter(endpoint: request.url, transport: transport)
            let session = try adapter.makeSession(
                manifest: manifest, candidate: candidate,
                configuration: AgentSessionConfiguration(providerKeys: ProviderKeys(["anthropic": sentinel]))
            )
            do {
                for try await event in await session.send("synthetic input") {
                    if case .chunk = event { XCTFail("oversized first event must not publish content") }
                    if case .end = event { XCTFail("oversized body must not complete the turn") }
                }
                XCTFail("oversized body must fail")
            } catch let error as AgentRuntimeError {
                XCTAssertEqual(error, expected)
                XCTAssertFalse(String(reflecting: error).contains(sentinel))
                XCTAssertFalse(error.localizedDescription.contains(sentinel))
            }
            let transcript = await session.transcript()
            XCTAssertEqual(transcript.map(\.role), [.user])
            await fulfillment(of: [stopped], timeout: 2)
        }
    }

    func testStreamPropagatesConnectionFailure() async throws {
        let fixture = TransportFixture { loader in
            loader.respond(status: 200, bytes: Data("first\n".utf8), finish: false)
            loader.client?.urlProtocol(loader, didFailWithError: URLError(.networkConnectionLost))
        }
        let (transport, session, request) = fixture.transport()
        defer { session.invalidateAndCancel(); fixture.remove() }
        do {
            let (stream, _) = try await transport.streamLines(request)
            for try await _ in stream {}
            XCTFail("connection failure must propagate")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .networkConnectionLost)
        }
    }

    func testSendRejectsNonHTTPResponse() async throws {
        let fixture = TransportFixture { loader in
            loader.client?.urlProtocol(loader, didReceive: URLResponse(url: loader.request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil), cacheStoragePolicy: .notAllowed)
            loader.client?.urlProtocolDidFinishLoading(loader)
        }
        let (transport, session, request) = fixture.transport()
        defer { session.invalidateAndCancel(); fixture.remove() }
        do {
            _ = try await transport.send(request)
            XCTFail("non-HTTP responses must fail")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .badServerResponse)
        }
    }

    func testCancellationWhileWaitingForHeadersStopsURLSessionTask() async throws {
        let started = expectation(description: "request started")
        let stopped = expectation(description: "request cancelled")
        let fixture = TransportFixture(stopped: stopped) { _ in started.fulfill() }
        let (transport, session, request) = fixture.transport()
        defer { session.invalidateAndCancel(); fixture.remove() }
        let operation = Task { try await transport.send(request) }
        await fulfillment(of: [started], timeout: 2)
        operation.cancel()
        do { _ = try await operation.value; XCTFail("cancelled send succeeded") } catch {}
        await fulfillment(of: [stopped], timeout: 2)
    }

    func testCancellationWhileWaitingForNextLineStopsURLSessionTask() async throws {
        let read = expectation(description: "first line read")
        let stopped = expectation(description: "stream cancelled")
        let fixture = TransportFixture(stopped: stopped) { loader in
            loader.respond(status: 200, bytes: Data("first\n".utf8), finish: false)
        }
        let (transport, session, request) = fixture.transport()
        defer { session.invalidateAndCancel(); fixture.remove() }
        let operation = Task {
            let (stream, _) = try await transport.streamLines(request)
            var count = 0
            for try await _ in stream {
                count += 1
                if count == 1 { read.fulfill() }
            }
        }
        await fulfillment(of: [read], timeout: 2)
        operation.cancel()
        _ = await operation.result
        await fulfillment(of: [stopped], timeout: 2)
    }

    func testDroppingStreamAfterTerminalEventStopsURLSessionTask() async throws {
        let stopped = expectation(description: "unused body cancelled")
        let fixture = TransportFixture(stopped: stopped) { loader in
            loader.respond(status: 200, bytes: Data("event: message_stop\ndata: {}\n\n".utf8), finish: false)
        }
        let (transport, session, request) = fixture.transport()
        defer { session.invalidateAndCancel(); fixture.remove() }
        try await consumeOneEvent(transport, request: request)
        await fulfillment(of: [stopped], timeout: 2)
    }

    func testSendAndStreamRejectRedirectsEvenWithInjectedSession() async throws {
        for streaming in [false, true] {
            let fixture = TransportFixture { loader in
                guard loader.request.url?.path == "/initial" else {
                    XCTFail("redirect destination must never be requested")
                    loader.respond(status: 200, bytes: Data())
                    return
                }
                let target = loader.request.url!.deletingLastPathComponent().appendingPathComponent("redirected")
                let response = HTTPURLResponse(url: loader.request.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
                loader.client?.urlProtocol(loader, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
                loader.client?.urlProtocol(loader, didReceive: response, cacheStoragePolicy: .notAllowed)
                loader.client?.urlProtocol(loader, didLoad: Data())
                loader.client?.urlProtocolDidFinishLoading(loader)
            }
            let (transport, session, request) = fixture.transport()
            defer { session.invalidateAndCancel(); fixture.remove() }
            if streaming {
                let (lines, status) = try await transport.streamLines(request)
                XCTAssertEqual(status, 302)
                for try await _ in lines {}
            } else {
                let (_, status) = try await transport.send(request)
                XCTAssertEqual(status, 302)
            }
        }
    }

    func testRedirectFixtureFollowsWithoutTransportDelegate() async throws {
        let fixture = TransportFixture { loader in
            if loader.request.url?.path == "/redirected" {
                loader.respond(status: 200, bytes: Data("followed".utf8))
                return
            }
            let target = loader.request.url!.deletingLastPathComponent().appendingPathComponent("redirected")
            let response = HTTPURLResponse(url: loader.request.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            loader.client?.urlProtocol(loader, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            loader.client?.urlProtocol(loader, didReceive: response, cacheStoragePolicy: .notAllowed)
            loader.client?.urlProtocol(loader, didLoad: Data())
            loader.client?.urlProtocolDidFinishLoading(loader)
        }
        let (_, session, request) = fixture.transport()
        defer { session.invalidateAndCancel(); fixture.remove() }
        let (data, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(data, Data("followed".utf8))
    }

    func testProviderKeyReflectionAndDumpAreRedactedRecursively() {
        let sentinel = "transport-test-credential-sentinel"
        let keys = ProviderKeys(["anthropic": sentinel])
        let configuration = AgentSessionConfiguration(providerKeys: keys)
        var dumped = ""
        dump(configuration, to: &dumped)
        XCTAssertFalse(dumped.contains(sentinel))
        XCTAssertFalse(String(reflecting: keys).contains(sentinel))
        XCTAssertTrue(dumped.contains("<redacted>"))
        XCTAssertTrue(dumped.contains("anthropic"))
        let children = Array(Mirror(reflecting: keys).children)
        XCTAssertEqual(children.compactMap(\.label), ["providers", "keys"])
    }

    private func consumeOneEvent(_ transport: URLSessionStreamTransport, request: URLRequest) async throws {
        let (stream, _) = try await transport.streamLines(request)
        var parser = ServerSentEventParser()
        for try await line in stream {
            if parser.consume(line: line) != nil { return }
        }
        XCTFail("expected terminal event")
    }
}

/// All requests use a unique URLProtocol fixture. No DNS lookup, real provider,
/// credentials, user caches, or persistent storage are involved.
private final class TransportFixture: @unchecked Sendable {
    private static let registry = TransportFixtureRegistry()
    private let host = UUID().uuidString.lowercased() + ".invalid"
    let stopped: XCTestExpectation?
    let start: @Sendable (TransportURLProtocol) -> Void

    init(stopped: XCTestExpectation? = nil, start: @escaping @Sendable (TransportURLProtocol) -> Void) {
        self.stopped = stopped
        self.start = start
    }

    func transport() -> (URLSessionStreamTransport, URLSession, URLRequest) {
        Self.registry.insert(self, host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransportURLProtocol.self]
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        let session = URLSession(configuration: configuration)
        let request = URLRequest(url: URL(string: "https://\(host)/initial")!, timeoutInterval: 2)
        return (URLSessionStreamTransport(session: session), session, request)
    }

    func remove() { Self.registry.remove(host: host) }
    static func fixture(for request: URLRequest) -> TransportFixture? { registry.lookup(host: request.url?.host ?? "") }
}

private final class TransportFixtureRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var fixtures: [String: TransportFixture] = [:]
    func insert(_ fixture: TransportFixture, host: String) { lock.withLock { fixtures[host] = fixture } }
    func remove(host: String) { _ = lock.withLock { fixtures.removeValue(forKey: host) } }
    func lookup(host: String) -> TransportFixture? { lock.withLock { fixtures[host] } }
}

private final class TransportURLProtocol: URLProtocol, @unchecked Sendable {
    private var fixture: TransportFixture?
    override class func canInit(with request: URLRequest) -> Bool { TransportFixture.fixture(for: request) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        fixture = TransportFixture.fixture(for: request)
        fixture?.start(self)
    }
    override func stopLoading() { fixture?.stopped?.fulfill() }

    func respond(status: Int, bytes: Data, finish: Bool = true) {
        respond(status: status, chunks: [bytes], finish: finish)
    }
    func respond(status: Int, chunks: [Data], finish: Bool = true) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
        if finish { client?.urlProtocolDidFinishLoading(self) }
    }
}
