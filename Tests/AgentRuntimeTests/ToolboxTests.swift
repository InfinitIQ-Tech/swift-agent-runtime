import Foundation
import XCTest
@testable import AgentRuntime

/// Allow-list normalization parity with the control-plane sidecar
/// (`tools_manager.py`): explicit `allowed` wins; absent `allowed` with
/// definitions exposes all; `[]` or no tools section exposes zero.
final class ToolboxTests: XCTestCase {
    func testNoToolsSectionExposesZeroTools() {
        let toolbox = AgentToolbox.resolve(config: Fixtures.config(tools: nil))
        XCTAssertTrue(toolbox.isEmpty)
    }

    func testEmptyAllowedListExposesZeroToolsEvenWithDefinitions() {
        let config = Fixtures.config(tools: AgentToolsConfig(
            allowed: [],
            definitions: [Fixtures.toolDefinition(name: "search")]
        ))
        let toolbox = AgentToolbox.resolve(config: config)
        XCTAssertTrue(toolbox.isEmpty, "allowed: [] is an explicit allow-list enabling no tools")
    }

    func testAbsentAllowedExposesEveryDefinedNameInSidecarOrder() {
        let config = Fixtures.config(tools: AgentToolsConfig(
            allowed: nil,
            definitions: [
                Fixtures.toolDefinition(name: "search"),
                Fixtures.toolDefinition(name: "calculator")
            ]
        ))
        let toolbox = AgentToolbox.resolve(config: config)
        XCTAssertEqual(toolbox.tools.map(\.name), ["calculator", "search"])
    }

    func testExplicitAllowedFiltersDefinitions() {
        let config = Fixtures.config(tools: AgentToolsConfig(
            allowed: ["calculator"],
            definitions: [
                Fixtures.toolDefinition(name: "search"),
                Fixtures.toolDefinition(name: "calculator")
            ]
        ))
        let toolbox = AgentToolbox.resolve(config: config)
        XCTAssertEqual(toolbox.tools.map(\.name), ["calculator"])
    }

    func testAllowedNamesWithoutDefinitionsAreIgnored() {
        let config = Fixtures.config(tools: AgentToolsConfig(
            allowed: ["ghost", "search", "search"],
            definitions: [Fixtures.toolDefinition(name: "search")]
        ))
        let toolbox = AgentToolbox.resolve(config: config)
        XCTAssertEqual(toolbox.tools.map(\.name), ["search"], "unresolvable and duplicate names drop out")
    }

    func testExposureUsesSidecarNameOrderRegardlessOfAllowedOrder() {
        let config = Fixtures.config(tools: AgentToolsConfig(
            allowed: ["b", "a"],
            definitions: [
                Fixtures.toolDefinition(name: "a"),
                Fixtures.toolDefinition(name: "b")
            ]
        ))
        let toolbox = AgentToolbox.resolve(config: config)
        XCTAssertEqual(toolbox.tools.map(\.name), ["a", "b"])
    }

    func testMissingOrEmptyDefinitionsExposeZeroTools() {
        for definitions: [ToolDefinition]? in [nil, []] {
            for allowed: [String]? in [nil, [], ["ghost"]] {
                let toolbox = AgentToolbox.resolve(config: Fixtures.config(tools: .init(
                    allowed: allowed, definitions: definitions
                )))
                XCTAssertTrue(toolbox.isEmpty)
            }
        }
    }

    /// This full manifest is also checked against the pinned JSON Schema and
    /// the actual sidecar ToolsManager during the AF-79 parity verification.
    func testDuplicateDefinitionsUseLastCompleteDefinitionWithAbsentNullOrExplicitAllowed() throws {
        let fixture = try Fixtures.resourceData("toolbox-normalization.json")
        let base = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
        for allowed: Any? in [nil, NSNull(), ["zeta", "search", "ghost", "search", "alpha"]] {
            var document = base
            var tools = try XCTUnwrap(document["tools"] as? [String: Any])
            tools["allowed"] = allowed
            document["tools"] = tools
            let manifest = try AgentManifestLoader.load(JSONSerialization.data(withJSONObject: document))
            let toolbox = AgentToolbox.resolve(config: manifest.config)

            XCTAssertEqual(toolbox.tools.map(\.name), ["alpha", "search", "zeta"])
            let selected = try XCTUnwrap(toolbox.definition(named: "search"))
            let last = try XCTUnwrap(manifest.config.tools?.definitions?.last)
            XCTAssertEqual(selected, last, "all fields must come from the last definition")
            XCTAssertEqual(selected.description, "Last search definition")
            XCTAssertEqual(selected.endpoint?.url, "https://last.invalid/search")
            XCTAssertEqual(selected.endpoint?.method, "PUT")
            XCTAssertEqual(selected.endpoint?.headers, ["X-Definition": "last"])
            XCTAssertEqual(selected.parameters["required"], .array([.string("query")]))
        }
    }

    func testDuplicateDefinitionsRespectExplicitSubsetAndEmptyAllowed() throws {
        let definitions = try Fixtures.manifest(named: "toolbox-normalization.json").config.tools?.definitions
        let subset = AgentToolbox.resolve(config: Fixtures.config(tools: .init(
            allowed: ["ghost", "search", "search"], definitions: definitions
        )))
        XCTAssertEqual(subset.tools.map(\.name), ["search"])
        XCTAssertEqual(subset.definition(named: "search")?.description, "Last search definition")
        XCTAssertNil(subset.definition(named: "alpha"))

        let empty = AgentToolbox.resolve(config: Fixtures.config(tools: .init(
            allowed: [], definitions: definitions
        )))
        XCTAssertTrue(empty.isEmpty)
        XCTAssertNil(empty.definition(named: "search"))
    }

    func testNamesUseExactUnicodeSpellingAndSidecarScalarOrder() {
        let composed = "\u{00e9}"
        let decomposed = "e\u{0301}"
        let definitions = ["\u{10000}", composed, "z", "\u{e000}", decomposed].map {
            Fixtures.toolDefinition(name: $0, endpoint: .init(url: "https://example.invalid/\(Data($0.utf8).base64EncodedString())"))
        }
        for allowed: [String]? in [nil, definitions.map(\.name).reversed()] {
            let toolbox = AgentToolbox.resolve(config: Fixtures.config(tools: .init(
                allowed: allowed, definitions: definitions
            )))
            XCTAssertEqual(toolbox.tools.map { Data($0.name.utf8) },
                           [decomposed, "z", composed, "\u{e000}", "\u{10000}"].map { Data($0.utf8) })
            XCTAssertEqual(toolbox.definition(named: composed)?.endpoint, definitions[1].endpoint)
            XCTAssertEqual(toolbox.definition(named: decomposed)?.endpoint, definitions[4].endpoint)
        }
        let toolbox = AgentToolbox.resolve(config: Fixtures.config(tools: .init(
            allowed: [composed], definitions: definitions
        )))
        XCTAssertEqual(toolbox.tools.count, 1)
        XCTAssertNil(toolbox.definition(named: decomposed), "a different spelling must not bypass the allow-list")
    }

    func testLastDuplicateDefinitionDispatchesDeclaredWebhookMetadata() async throws {
        let manifest = try Fixtures.manifest(named: "toolbox-normalization.json")
        let transport = StubWebhookTransport(steps: [.respond(status: 201, body: "selected last")])
        let engine = ToolExecutionEngine(
            toolbox: AgentToolbox.resolve(config: manifest.config),
            configuration: .init(), transport: transport
        )
        await engine.beginTurn()
        let results = await engine.execute([.init(
            toolId: "search", callId: "last-definition-call", args: ["query": .string("parity")]
        )])
        let result = try XCTUnwrap(results.first)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.toolId, "search")
        XCTAssertEqual(result.callId, "last-definition-call")
        XCTAssertEqual(result.output, "selected last")
        XCTAssertNotNil(result.durationMs)
        XCTAssertEqual(transport.requests.count, 1)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://last.invalid/search")
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Definition"), "last")
        XCTAssertEqual(try JSONDecoder().decode([String: JSONValue].self, from: XCTUnwrap(request.httpBody)),
                       ["query": .string("parity")])
    }

    func testPolicyAndConcurrencyCarryThrough() {
        let config = Fixtures.config(
            maxConcurrentTools: 3,
            tools: AgentToolsConfig(
                allowed: ["search"],
                definitions: [Fixtures.toolDefinition(name: "search")],
                toolPolicy: AgentToolPolicy(requireUserConfirmation: ["search"], maxTotalRuntimeMs: 500, maxToolsPerTurn: 2)
            )
        )
        let toolbox = AgentToolbox.resolve(config: config)
        XCTAssertEqual(toolbox.maxConcurrentTools, 3)
        XCTAssertEqual(toolbox.policy?.maxToolsPerTurn, 2)
        XCTAssertEqual(toolbox.policy?.requireUserConfirmation, ["search"])
    }
}
