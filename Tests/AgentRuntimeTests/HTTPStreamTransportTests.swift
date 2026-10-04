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
