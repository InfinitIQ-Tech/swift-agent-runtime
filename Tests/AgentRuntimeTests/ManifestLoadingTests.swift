import Foundation
import XCTest
@testable import AgentRuntime

final class ManifestLoadingTests: XCTestCase {
    func testLoadsCheckedInStoryManifest() throws {
        let manifest = try Fixtures.manifest(named: "on-device-story-agent.json")
        XCTAssertEqual(manifest.config.id, "story_companion")
        XCTAssertEqual(manifest.config.schemaVersion, "2")
        XCTAssertEqual(manifest.config.runtime.maxTurns, 6)
        XCTAssertTrue(manifest.config.runtime.streaming)
        XCTAssertEqual(manifest.config.model.candidates.map(\.provider), ["apple", "anthropic"])
        XCTAssertEqual(manifest.config.model.candidates[1].modelIdentifier, "claude-haiku-4-5")
        XCTAssertEqual(manifest.config.tools?.allowed, ["save_story"])
    }

    func testLoadsCheckedInPortableExample() throws {
        let manifest = try Fixtures.manifest(named: "portable-agent-config.json")
        XCTAssertEqual(manifest.config.id, "support_agent")
        XCTAssertEqual(manifest.config.tools?.definitions?.first?.endpoint?.url, "https://example.com/tool/search")
        XCTAssertEqual(manifest.config.tools?.toolPolicy?.maxToolsPerTurn, 2)
        XCTAssertEqual(manifest.config.guardrails?.blockedTopics, ["payments"])
    }

    func testRoundTripPreservesUnknownSections() throws {
        var document = try JSONDecoder().decode(
            JSONValue.self,
            from: Fixtures.resourceData("on-device-story-agent.json")
        )
        guard case .object(var members) = document else {
            return XCTFail("expected object document")
        }
        // Unknown top-level section plus an unknown member inside a known section.
        members["x_future_section"] = .object([
            "enabled": .bool(true),
            "weights": .array([.integer(1), .number(2.5), .null])
        ])
        if case .object(var runtime)? = members["runtime"] {
            runtime["x_future_flag"] = .string("keep-me")
            members["runtime"] = .object(runtime)
        }
        document = .object(members)

        let data = try JSONEncoder().encode(document)
        let manifest = try AgentManifestLoader.load(data)

        // Typed view still decodes; raw document retains the unknown members.
        XCTAssertEqual(manifest.config.id, "story_companion")
        XCTAssertEqual(manifest.document["x_future_section"]?["enabled"], .bool(true))
        XCTAssertEqual(manifest.document["runtime"]?["x_future_flag"], .string("keep-me"))

        // Canonical re-encode round-trips to an identical JSON tree.
        let reencoded = try JSONDecoder().decode(JSONValue.self, from: manifest.canonicalJSONData())
        XCTAssertEqual(reencoded, document)
    }

    func testRejectsUnsupportedSchemaVersion() throws {
        var document = try JSONDecoder().decode(
            JSONValue.self,
            from: Fixtures.resourceData("on-device-story-agent.json")
        )
        guard case .object(var members) = document else {
            return XCTFail("expected object document")
        }
        members["schema_version"] = .string("3")
        document = .object(members)
        let data = try JSONEncoder().encode(document)

        XCTAssertThrowsError(try AgentManifestLoader.load(data)) { error in
            guard case AgentManifestError.unsupportedSchemaVersion(let found, let supported) = error else {
                return XCTFail("expected unsupportedSchemaVersion, got \(error)")
            }
            XCTAssertEqual(found, "3")
            XCTAssertEqual(supported, ["2"])
        }
    }

    func testMissingSchemaVersionIsDistinguishable() throws {
        let data = Data(#"{"id":"a","name":"A"}"#.utf8)
        XCTAssertThrowsError(try AgentManifestLoader.load(data)) { error in
            guard case AgentManifestError.missingSchemaVersion = error else {
                return XCTFail("expected missingSchemaVersion, got \(error)")
            }
        }
    }

    func testMissingRequiredMemberFailsWithFieldPath() throws {
        var document = try JSONDecoder().decode(
            JSONValue.self,
            from: Fixtures.resourceData("on-device-story-agent.json")
        )
        guard case .object(var members) = document else {
            return XCTFail("expected object document")
        }
        members["system_prompt"] = nil
        document = .object(members)
        let data = try JSONEncoder().encode(document)

        XCTAssertThrowsError(try AgentManifestLoader.load(data)) { error in
            guard case AgentManifestError.invalidManifest(let reason) = error else {
                return XCTFail("expected invalidManifest, got \(error)")
            }
            XCTAssertTrue(reason.contains("system_prompt"), reason)
        }
    }

    func testNonObjectDocumentIsRejected() {
        XCTAssertThrowsError(try AgentManifestLoader.load(Data("[1,2,3]".utf8))) { error in
            guard case AgentManifestError.notAJSONObject = error else {
                return XCTFail("expected notAJSONObject, got \(error)")
            }
        }
        XCTAssertThrowsError(try AgentManifestLoader.load(Data("not json".utf8)))
    }
}
