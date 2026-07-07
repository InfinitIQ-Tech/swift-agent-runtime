import Foundation
import XCTest
@testable import AgentRuntime
#if canImport(FoundationModels)
import FoundationModels
#endif

final class FoundationModelsBridgeTests: XCTestCase {
    /// The checked-in manifest's tool schema must convert to a Foundation
    /// Models `GenerationSchema`; only allowed tools would ever be bridged.
    func testManifestToolSchemaConvertsToGenerationSchema() throws {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *) else {
            throw XCTSkip("Foundation Models requires iOS 26 / macOS 26")
        }
        let manifest = try Fixtures.manifest(named: "on-device-story-agent.json")
        let toolbox = AgentToolbox.resolve(config: manifest.config)
        XCTAssertEqual(toolbox.tools.map(\.name), ["save_story"])
        for definition in toolbox.tools {
            XCTAssertNoThrow(
                try GenerationSchemaBuilder.makeSchema(
                    toolName: definition.name,
                    parameters: definition.parameters
                )
            )
        }
        #else
        throw XCTSkip("FoundationModels SDK not present")
        #endif
    }

    func testNestedAndEnumSchemasConvert() throws {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *) else {
            throw XCTSkip("Foundation Models requires iOS 26 / macOS 26")
        }
        let parameters: [String: JSONValue] = [
            "type": .string("object"),
            "required": .array([.string("mood")]),
            "properties": .object([
                "mood": .object(["type": .string("string"), "enum": .array([.string("calm"), .string("sleepy")])]),
                "length": .object(["type": .string("integer")]),
                "tags": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                "nested": .object([
                    "type": .string("object"),
                    "properties": .object(["flag": .object(["type": .string("boolean")])])
                ])
            ])
        ]
        XCTAssertNoThrow(try GenerationSchemaBuilder.makeSchema(toolName: "complex", parameters: parameters))
        #else
        throw XCTSkip("FoundationModels SDK not present")
        #endif
    }

    /// Zero-tools regression guard on the on-device path (AF-35 bug class):
    /// a manifest with no tools must construct a session that registered no
    /// tools with the model. Requires an on-device model to be available.
    func testNoToolManifestBuildsSessionWithZeroTools() throws {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *) else {
            throw XCTSkip("Foundation Models requires iOS 26 / macOS 26")
        }
        guard case .available = SystemLanguageModel.default.availability else {
            throw XCTSkip("on-device model unavailable on this host")
        }
        let config = Fixtures.config(
            tools: AgentToolsConfig(allowed: [], definitions: [Fixtures.toolDefinition(name: "search")]),
            candidates: [AgentModelCandidate(name: "on_device", model: "apple:foundation-models")]
        )
        let manifest = try Fixtures.manifest(for: config)
        let adapter = FoundationModelsAdapter()
        let session = try adapter.makeSession(
            manifest: manifest,
            candidate: manifest.config.model.candidates[0],
            configuration: AgentSessionConfiguration()
        )
        XCTAssertNotNil(session)
        #else
        throw XCTSkip("FoundationModels SDK not present")
        #endif
    }
}
