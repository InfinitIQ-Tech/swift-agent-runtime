import Foundation
import XCTest
@testable import AgentRuntime

final class NativeToolIdentityTests: XCTestCase {
    func testNativeHandlerRequiresExactStoredUnicodeSpelling() async {
        let composed = "caf\u{00E9}"
        let decomposed = "cafe\u{0301}"
        let calls = NativeIdentityCallLog()
        let toolbox = toolbox(names: [composed, decomposed])
        let composedOnly = ToolExecutionEngine(
            toolbox: toolbox,
            configuration: AgentSessionConfiguration(toolHandlers: [composed: { _ in
                await calls.record("composed")
                return "composed handler"
            }]),
            transport: StubWebhookTransport(steps: [])
        )

        let results = await composedOnly.execute([
            AgentToolCall(toolId: decomposed, callId: "unregistered-spelling", args: [:]),
            AgentToolCall(toolId: composed, callId: "registered-spelling", args: [:])
        ])
        XCTAssertFalse(results[0].success)
        XCTAssertTrue(results[0].output.contains("no host-registered handler"), results[0].output)
        XCTAssertEqual(results[0].callId, "unregistered-spelling")
        XCTAssertTrue(results[1].success)
        XCTAssertEqual(results[1].output, "composed handler")
        let composedCalls = await calls.values
        XCTAssertEqual(composedCalls, ["composed"], "An allowed but unregistered spelling must not dispatch another tool's handler")

        // The public String-keyed dictionary cannot store both canonically
        // equivalent keys together. Each stored spelling still works exactly.
        let decomposedOnly = ToolExecutionEngine(
            toolbox: toolbox,
            configuration: AgentSessionConfiguration(toolHandlers: [decomposed: { _ in "decomposed handler" }]),
            transport: StubWebhookTransport(steps: [])
        )
        let exact = await decomposedOnly.execute([AgentToolCall(toolId: decomposed, args: [:])])
        XCTAssertTrue(exact[0].success)
        XCTAssertEqual(exact[0].output, "decomposed handler")
    }

    func testConfirmationPolicyRequiresExactUnicodeSpelling() async {
        let composed = "caf\u{00E9}"
        let decomposed = "cafe\u{0301}"
        let confirmations = NativeIdentityCallLog()
        let engine = ToolExecutionEngine(
            toolbox: toolbox(names: [composed, decomposed], confirmationRequired: [composed]),
            configuration: AgentSessionConfiguration(
                toolHandlers: [decomposed: { _ in "decomposed handler" }],
                confirmToolExecution: { call in
                    await confirmations.record(call.callId ?? "missing")
                    return false
                }
            ),
            transport: StubWebhookTransport(steps: [])
        )
        let results = await engine.execute([
            AgentToolCall(toolId: decomposed, callId: "no-confirmation", args: [:]),
            AgentToolCall(toolId: composed, callId: "requires-confirmation", args: [:])
        ])
        XCTAssertTrue(results[0].success, "Confirmation for one exact name must not gate another allowed spelling")
        XCTAssertEqual(results[0].output, "decomposed handler")
        XCTAssertFalse(results[1].success)
        XCTAssertTrue(results[1].output.contains("confirmation"), results[1].output)
        let confirmedCalls = await confirmations.values
        XCTAssertEqual(confirmedCalls, ["requires-confirmation"])
    }

    private func toolbox(names: [String], confirmationRequired: [String]? = nil) -> AgentToolbox {
        AgentToolbox.resolve(config: Fixtures.config(tools: AgentToolsConfig(
            definitions: names.map { Fixtures.toolDefinition(name: $0) },
            toolPolicy: AgentToolPolicy(requireUserConfirmation: confirmationRequired)
        )))
    }
}

private actor NativeIdentityCallLog {
    private(set) var values: [String] = []
    func record(_ value: String) { values.append(value) }
}
