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

    func testAbsentAllowedExposesEveryDefinition() {
        let config = Fixtures.config(tools: AgentToolsConfig(
            allowed: nil,
            definitions: [
                Fixtures.toolDefinition(name: "search"),
                Fixtures.toolDefinition(name: "calculator")
            ]
        ))
        let toolbox = AgentToolbox.resolve(config: config)
        XCTAssertEqual(toolbox.tools.map(\.name), ["search", "calculator"])
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

    func testExposureFollowsAllowedOrder() {
        let config = Fixtures.config(tools: AgentToolsConfig(
            allowed: ["b", "a"],
            definitions: [
                Fixtures.toolDefinition(name: "a"),
                Fixtures.toolDefinition(name: "b")
            ]
        ))
        let toolbox = AgentToolbox.resolve(config: config)
        XCTAssertEqual(toolbox.tools.map(\.name), ["b", "a"])
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
