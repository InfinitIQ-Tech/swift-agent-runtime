import Foundation
import XCTest
@testable import AgentRuntime

final class ToolExecutionEngineTests: XCTestCase {
    private func engine(
        tools: AgentToolsConfig?,
        maxConcurrentTools: Int? = nil,
        configuration: AgentSessionConfiguration = AgentSessionConfiguration(),
        transport: WebhookTransport = StubWebhookTransport(steps: [])
    ) -> ToolExecutionEngine {
        let config = Fixtures.config(maxConcurrentTools: maxConcurrentTools, tools: tools)
        return ToolExecutionEngine(
            toolbox: AgentToolbox.resolve(config: config),
            configuration: configuration,
            transport: transport
        )
    }

    private func webhookTool(named name: String, method: String? = nil) -> AgentToolsConfig {
        AgentToolsConfig(definitions: [
            ToolDefinition(
                name: name,
                description: "webhook",
                parameters: ["type": .string("object")],
                endpoint: ToolEndpoint(
                    url: "https://tools.example.com/\(name)",
                    method: method,
                    headers: ["Authorization": "Bearer test-token"]
                )
            )
        ])
    }

    func testWebhookSuccessReturnsBody() async throws {
        let transport = StubWebhookTransport(steps: [.respond(status: 200, body: "{\"ok\":true}")])
        let engine = engine(tools: webhookTool(named: "search"), transport: transport)
        await engine.beginTurn()
        let results = await engine.execute([AgentToolCall(toolId: "search", callId: "c1", args: ["query": .string("hi")])])

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].success)
        XCTAssertEqual(results[0].output, "{\"ok\":true}")
        XCTAssertEqual(results[0].callId, "c1")
        XCTAssertNotNil(results[0].durationMs)

        let request = transport.requests[0]
        XCTAssertEqual(request.httpMethod, "POST", "method defaults to POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        let body = try JSONDecoder().decode([String: JSONValue].self, from: XCTUnwrap(request.httpBody))
        XCTAssertEqual(body["query"], .string("hi"))
    }

    func testWebhookFailureStatusIsUnsuccessfulResult() async {
        let transport = StubWebhookTransport(steps: [.respond(status: 500, body: "boom")])
        let engine = engine(tools: webhookTool(named: "search"), transport: transport)
        await engine.beginTurn()
        let results = await engine.execute([AgentToolCall(toolId: "search", args: [:])])

        XCTAssertFalse(results[0].success)
        XCTAssertTrue(results[0].output.contains("500"))
    }

    func testWebhookTimeoutIsUnsuccessfulResult() async {
        let transport = StubWebhookTransport(steps: [.fail(URLError(.timedOut))])
        let engine = engine(tools: webhookTool(named: "search"), transport: transport)
        await engine.beginTurn()
        let results = await engine.execute([AgentToolCall(toolId: "search", args: [:])])

        XCTAssertFalse(results[0].success)
        XCTAssertTrue(results[0].output.contains("request failed"), results[0].output)
    }

    func testGETWebhookEncodesArgsAsQueryItems() async throws {
        let transport = StubWebhookTransport(steps: [.respond(status: 200, body: "ok")])
        let engine = engine(tools: webhookTool(named: "lookup", method: "GET"), transport: transport)
        await engine.beginTurn()
        _ = await engine.execute([AgentToolCall(toolId: "lookup", args: ["query": .string("cats")])])

        let url = try XCTUnwrap(transport.requests[0].url)
        XCTAssertEqual(transport.requests[0].httpMethod, "GET")
        XCTAssertTrue(url.absoluteString.contains("query=cats"), url.absoluteString)
        XCTAssertNil(transport.requests[0].httpBody)
    }

    func testDisallowedToolFailsWithoutNetworkCall() async {
        let transport = StubWebhookTransport(steps: [.respond(status: 200, body: "never")])
        let engine = engine(tools: webhookTool(named: "search"), transport: transport)
        await engine.beginTurn()
        let results = await engine.execute([AgentToolCall(toolId: "not_a_tool", args: [:])])

        XCTAssertFalse(results[0].success)
        XCTAssertTrue(results[0].output.contains("allow-list"))
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testHostHandlerExecutesToolsWithoutEndpoint() async {
        let tools = AgentToolsConfig(definitions: [Fixtures.toolDefinition(name: "local_tool")])
        let configuration = AgentSessionConfiguration(toolHandlers: [
            "local_tool": { args in
                "handled:\(args["query"]?.stringValue ?? "")"
            }
        ])
        let engine = engine(tools: tools, configuration: configuration)
        await engine.beginTurn()
        let results = await engine.execute([AgentToolCall(toolId: "local_tool", args: ["query": .string("x")])])

        XCTAssertTrue(results[0].success)
        XCTAssertEqual(results[0].output, "handled:x")
    }

    func testToolWithoutEndpointOrHandlerFails() async {
        let tools = AgentToolsConfig(definitions: [Fixtures.toolDefinition(name: "orphan")])
        let engine = engine(tools: tools)
        await engine.beginTurn()
        let results = await engine.execute([AgentToolCall(toolId: "orphan", args: [:])])

        XCTAssertFalse(results[0].success)
        XCTAssertTrue(results[0].output.contains("no endpoint and no host-registered handler"))
    }

    func testMaxToolsPerTurnIsEnforcedAcrossBatches() async {
        let tools = AgentToolsConfig(
            definitions: [Fixtures.toolDefinition(name: "local_tool")],
            toolPolicy: AgentToolPolicy(maxToolsPerTurn: 1)
        )
        let configuration = AgentSessionConfiguration(toolHandlers: [
            "local_tool": { _ in "ok" }
        ])
        let engine = engine(tools: tools, configuration: configuration)
        await engine.beginTurn()

        let first = await engine.execute([AgentToolCall(toolId: "local_tool", args: [:])])
        let second = await engine.execute([AgentToolCall(toolId: "local_tool", args: [:])])
        XCTAssertTrue(first[0].success)
        XCTAssertFalse(second[0].success)
        XCTAssertTrue(second[0].output.contains("max_tools_per_turn"))

        // A new turn resets the counter.
        await engine.beginTurn()
        let third = await engine.execute([AgentToolCall(toolId: "local_tool", args: [:])])
        XCTAssertTrue(third[0].success)
    }

    func testConfirmationRequiredToolFailsWithoutHookAndRunsWithApproval() async {
        let tools = AgentToolsConfig(
            definitions: [Fixtures.toolDefinition(name: "local_tool")],
            toolPolicy: AgentToolPolicy(requireUserConfirmation: ["local_tool"])
        )
        let handlers: [String: AgentToolHandler] = ["local_tool": { _ in "ok" }]

        let noHook = engine(tools: tools, configuration: AgentSessionConfiguration(toolHandlers: handlers))
        await noHook.beginTurn()
        let denied = await noHook.execute([AgentToolCall(toolId: "local_tool", args: [:])])
        XCTAssertFalse(denied[0].success)
        XCTAssertTrue(denied[0].output.contains("confirmation"))

        let approving = engine(tools: tools, configuration: AgentSessionConfiguration(
            toolHandlers: handlers,
            confirmToolExecution: { _ in true }
        ))
        await approving.beginTurn()
        let approved = await approving.execute([AgentToolCall(toolId: "local_tool", args: [:])])
        XCTAssertTrue(approved[0].success)
    }

    func testBatchResultsPreserveCallOrder() async {
        let tools = AgentToolsConfig(definitions: [
            Fixtures.toolDefinition(name: "a"),
            Fixtures.toolDefinition(name: "b"),
            Fixtures.toolDefinition(name: "c")
        ])
        let configuration = AgentSessionConfiguration(toolHandlers: [
            "a": { _ in
                try await Task.sleep(nanoseconds: 20_000_000)
                return "slow"
            },
            "b": { _ in "fast" },
            "c": { _ in "medium" }
        ])
        let engine = engine(tools: tools, maxConcurrentTools: 2, configuration: configuration)
        await engine.beginTurn()
        let results = await engine.execute([
            AgentToolCall(toolId: "a", callId: "1", args: [:]),
            AgentToolCall(toolId: "b", callId: "2", args: [:]),
            AgentToolCall(toolId: "c", callId: "3", args: [:])
        ])
        XCTAssertEqual(results.map(\.callId), ["1", "2", "3"])
        XCTAssertEqual(results.map(\.output), ["slow", "fast", "medium"])
    }
}
