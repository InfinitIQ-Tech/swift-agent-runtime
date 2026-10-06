import Foundation
import XCTest
@testable import AgentRuntime

final class WebhookHeaderTests: XCTestCase {
    func testDeclaredContentTypeAndMethodArePreserved() async throws {
        let transport = StubWebhookTransport(steps: [.respond(status: 201, body: "created")])
        let endpoint = ToolEndpoint(
            url: "https://tools.example.invalid/update",
            method: "patch",
            headers: ["content-type": "application/vnd.example+json", "X-Tool-Version": "2"]
        )
        let call = AgentToolCall(toolId: "update", callId: "c-update", args: ["query": .string("hello")])
        let result = await WebhookToolExecutor(transport: transport).execute(
            endpoint: endpoint, call: call, timeoutMs: 125
        )

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.output, "created")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/vnd.example+json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Tool-Version"), "2")
        XCTAssertEqual(request.timeoutInterval, 0.125, accuracy: 0.001)
        XCTAssertEqual(
            try JSONDecoder().decode([String: JSONValue].self, from: XCTUnwrap(request.httpBody)),
            call.args
        )
    }

    func testAbsentContentTypeUsesJSONAndDefaultTimeout() async throws {
        let transport = StubWebhookTransport(steps: [.respond(status: 204, body: "")])
        _ = await WebhookToolExecutor(transport: transport).execute(
            endpoint: ToolEndpoint(url: "https://tools.example.invalid/update"),
            call: AgentToolCall(toolId: "update", args: [:]),
            timeoutMs: nil
        )
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 30)
    }
}
