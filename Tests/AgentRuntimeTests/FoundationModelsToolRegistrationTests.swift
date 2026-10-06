import Foundation
import XCTest
@testable import AgentRuntime
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Exercises the same registration builder used by FoundationModelsSession,
/// without requiring model availability or invoking a generation.
final class FoundationModelsToolRegistrationTests: XCTestCase {
    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    private func registeredTools(for config: AgentConfig) throws -> [ManifestBridgedTool] {
        let toolbox = AgentToolbox.resolve(config: config)
        return try ManifestBridgedTool.makeTools(
            toolbox: toolbox,
            engine: ToolExecutionEngine(toolbox: toolbox, configuration: .init()),
            relay: ToolEventRelay()
        )
    }
    #endif

    func testMissingEmptyAndUnresolvableToolSurfacesRegisterZeroTools() throws {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip("Foundation Models requires OS 26") }
        let definitions = [Fixtures.toolDefinition(name: "search")]
        let cases: [AgentToolsConfig?] = [
            nil,
            .init(),
            .init(allowed: [], definitions: definitions),
            .init(allowed: ["ghost"], definitions: definitions),
            .init(allowed: ["search"], definitions: [])
        ]
        for tools in cases {
            XCTAssertTrue(try registeredTools(for: Fixtures.config(tools: tools)).isEmpty)
        }
        #else
        throw XCTSkip("FoundationModels SDK not present")
        #endif
    }

    func testRegistrationIncludesOnlyAllowedLastDefinitionsInSidecarOrder() throws {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip("Foundation Models requires OS 26") }
        let manifest = try Fixtures.manifest(named: "toolbox-normalization.json")
        let inferred = try registeredTools(for: manifest.config)
        XCTAssertEqual(inferred.map(\.name), ["alpha", "search", "zeta"])
        XCTAssertEqual(inferred.first { $0.name == "search" }?.description, "Last search definition")

        let config = Fixtures.config(tools: .init(
            allowed: ["zeta", "search", "ghost", "search"],
            definitions: manifest.config.tools?.definitions
        ))
        let explicit = try registeredTools(for: config)
        XCTAssertEqual(explicit.map(\.name), ["search", "zeta"])
        XCTAssertEqual(explicit.first?.description, "Last search definition")
        #else
        throw XCTSkip("FoundationModels SDK not present")
        #endif
    }
}
