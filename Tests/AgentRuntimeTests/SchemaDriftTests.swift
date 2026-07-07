import Foundation
import XCTest
@testable import AgentRuntime

/// Contract-drift gate against the public AgentConfig JSON Schema
/// (InfinitIQ-Tech/agent-config-spec). The vendored copy in test resources is
/// updated only via `scripts/sync-public-schema.sh`. When the public schema
/// changes shape or bumps `schema_version` without a matching runtime update,
/// these tests fail CI.
final class SchemaDriftTests: XCTestCase {
    /// The runtime's wire surface, mirrored from the Codable models. A change
    /// to either side must land in lockstep with the public schema.
    static let expectations: [String: (properties: Set<String>, required: Set<String>)] = [
        "#root": (
            properties: ["id", "name", "version", "schema_version", "system_prompt", "description",
                         "tags", "runtime", "model", "memory", "retrieval", "tools", "guardrails", "output"],
            required: ["id", "name", "version", "schema_version", "system_prompt", "runtime", "model"]
        ),
        "AgentRuntimeConfig": (
            properties: ["streaming", "max_turns", "max_concurrent_tools"],
            required: ["streaming"]
        ),
        "AgentModelCandidate": (
            properties: ["name", "model"],
            required: ["name", "model"]
        ),
        "AgentModelConfig": (
            properties: ["strategy", "candidates", "routing_policy"],
            required: ["strategy", "candidates"]
        ),
        "AgentMemoryConfig": (
            properties: ["type", "window_turns"],
            required: []
        ),
        "AgentRetrievalConfig": (
            properties: ["enabled", "corpus_ids", "top_k", "rerank", "filters"],
            required: ["enabled"]
        ),
        "ToolEndpoint": (
            properties: ["url", "method", "headers"],
            required: ["url"]
        ),
        "ToolDefinition": (
            properties: ["name", "description", "parameters", "endpoint"],
            required: ["name", "description", "parameters"]
        ),
        "AgentToolPolicy": (
            properties: ["require_user_confirmation", "max_total_runtime_ms", "max_tools_per_turn"],
            required: []
        ),
        "AgentToolsConfig": (
            properties: ["allowed", "definitions", "tool_policy"],
            required: []
        ),
        "AgentGuardrailsConfig": (
            properties: ["pii_redaction", "jailbreak_detection", "blocked_topics"],
            required: []
        ),
        "AgentOutputFormat": (
            properties: ["type", "schema"],
            required: ["type", "schema"]
        ),
        "AgentOutputConfig": (
            properties: ["format"],
            required: ["format"]
        )
    ]

    private func loadVendoredSchema() throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Fixtures.resourceData("agent-config.v2.schema.json"))
    }

    /// Compares a schema document against the runtime's expectations and
    /// returns human-readable findings; empty means no drift.
    static func driftFindings(in schema: JSONValue) -> [String] {
        var findings: [String] = []

        func check(name: String, node: JSONValue?) {
            guard let expectation = expectations[name] else {
                findings.append("no runtime expectation registered for schema type \(name)")
                return
            }
            guard let node else {
                findings.append("schema is missing type \(name)")
                return
            }
            let properties = node["properties"]?.objectKeys ?? []
            if properties != expectation.properties {
                let extra = properties.subtracting(expectation.properties).sorted()
                let missing = expectation.properties.subtracting(properties).sorted()
                findings.append("\(name) properties drifted (schema-only: \(extra), runtime-only: \(missing)) — update swift-agent-runtime models or re-vendor via scripts/sync-public-schema.sh from InfinitIQ-Tech/agent-config-spec")
            }
            var required = Set<String>()
            if case .array(let values)? = node["required"] {
                required = Set(values.compactMap(\.stringValue))
            }
            if required != expectation.required {
                findings.append("\(name) required set drifted (schema: \(required.sorted()), runtime: \(expectation.required.sorted()))")
            }
        }

        check(name: "#root", node: schema)

        let defs = schema["$defs"]
        let defNames = defs?.objectKeys ?? []
        let expectedDefs = Set(expectations.keys).subtracting(["#root"])
        if defNames != expectedDefs {
            findings.append("$defs drifted (schema-only: \(defNames.subtracting(expectedDefs).sorted()), runtime-only: \(expectedDefs.subtracting(defNames).sorted()))")
        }
        for name in expectedDefs {
            check(name: name, node: defs?[name])
        }

        // schema_version gate: the schema's enum must equal what this runtime executes.
        var versions = Set<String>()
        if case .array(let values)? = schema["properties"]?["schema_version"]?["enum"] {
            versions = Set(values.compactMap(\.stringValue))
        }
        if versions != SupportedSchemaVersion.all {
            findings.append("schema_version enum drifted (schema: \(versions.sorted()), runtime supports: \(SupportedSchemaVersion.all.sorted())) — the runtime cannot execute a schema bump it does not know about")
        }

        return findings
    }

    func testVendoredSchemaMatchesRuntimeModels() throws {
        let findings = Self.driftFindings(in: try loadVendoredSchema())
        XCTAssertEqual(findings, [], findings.joined(separator: "\n"))
    }

    func testSimulatedSchemaVersionBumpIsDetected() throws {
        var schema = try loadVendoredSchema()
        guard case .object(var members) = schema,
              case .object(var properties)? = members["properties"] else {
            return XCTFail("unexpected schema shape")
        }
        properties["schema_version"] = .object(["enum": .array([.string("3")])])
        members["properties"] = .object(properties)
        schema = .object(members)

        let findings = Self.driftFindings(in: schema)
        XCTAssertTrue(
            findings.contains { $0.contains("schema_version enum drifted") },
            "a schema_version bump must fail the drift gate; findings: \(findings)"
        )
    }

    func testSimulatedFieldAdditionIsDetected() throws {
        var schema = try loadVendoredSchema()
        guard case .object(var members) = schema,
              case .object(var defs)? = members["$defs"],
              case .object(var runtimeDef)? = defs["AgentRuntimeConfig"],
              case .object(var properties)? = runtimeDef["properties"] else {
            return XCTFail("unexpected schema shape")
        }
        properties["max_output_tokens"] = .object(["type": .string("integer")])
        runtimeDef["properties"] = .object(properties)
        defs["AgentRuntimeConfig"] = .object(runtimeDef)
        members["$defs"] = .object(defs)
        schema = .object(members)

        let findings = Self.driftFindings(in: schema)
        XCTAssertTrue(
            findings.contains { $0.contains("AgentRuntimeConfig properties drifted") },
            "a new public field must fail the gate until the runtime models it; findings: \(findings)"
        )
    }

    func testCheckedInExamplesSatisfyTheContract() throws {
        for example in ["on-device-story-agent.json", "portable-agent-config.json"] {
            let manifest = try Fixtures.manifest(named: example)
            XCTAssertEqual(manifest.config.schemaVersion, "2", example)
            let reencoded = try JSONDecoder().decode(JSONValue.self, from: manifest.canonicalJSONData())
            let original = try JSONDecoder().decode(JSONValue.self, from: Fixtures.resourceData(example))
            XCTAssertEqual(reencoded, original, "\(example) must round-trip without loss")
        }
    }

    /// Byte-level comparison against the sibling spec-repo checkout. Skips
    /// (not fails) when `../agent-config-spec` is absent, so CI environments
    /// that clone only this repository still run the vendored assertions.
    func testVendoredSchemaMatchesSiblingSpecRepoWhenPresent() throws {
        let siblingURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AgentRuntimeTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // swift-agent-runtime
            .deletingLastPathComponent() // backend
            .appendingPathComponent("agent-config-spec/schema/agent-config.v2.schema.json")
        guard FileManager.default.fileExists(atPath: siblingURL.path) else {
            throw XCTSkip("sibling agent-config-spec checkout not present")
        }
        let sibling = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: siblingURL))
        let vendored = try loadVendoredSchema()
        XCTAssertEqual(
            sibling, vendored,
            "vendored schema is stale — run scripts/sync-public-schema.sh"
        )
    }
}
