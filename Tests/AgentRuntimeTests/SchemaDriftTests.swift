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
        // Used only by scripts/prove-schema-drift.sh to run the real gate
        // against a temporary changed contract, without touching vendored bytes.
        let data: Data
        if let path = ProcessInfo.processInfo.environment["SCHEMA_DRIFT_TEST_SCHEMA"] {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } else {
            data = try Fixtures.resourceData("agent-config.v2.schema.json")
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
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

    /// Exercise the real Codable implementations, not just the hand-maintained
    /// property list above. Both full and required-only documents are generated
    /// from the public schema, so changed wire keys, field types, optionality,
    /// and fields silently dropped by a decoder cannot pass by editing a mirror.
    func testSchemaGeneratedDocumentsMatchActualRuntimeCodableTypes() throws {
        let schema = try loadVendoredSchema()
        try checkCodable(AgentConfig.self, name: "#root", schema: schema)
        try checkCodable(AgentRuntimeConfig.self, schema: schema)
        try checkCodable(AgentModelCandidate.self, schema: schema)
        try checkCodable(AgentModelConfig.self, schema: schema)
        try checkCodable(AgentMemoryConfig.self, schema: schema)
        try checkCodable(AgentRetrievalConfig.self, schema: schema)
        try checkCodable(ToolEndpoint.self, schema: schema)
        try checkCodable(ToolDefinition.self, schema: schema)
        try checkCodable(AgentToolPolicy.self, schema: schema)
        try checkCodable(AgentToolsConfig.self, schema: schema)
        try checkCodable(AgentGuardrailsConfig.self, schema: schema)
        try checkCodable(AgentOutputFormat.self, schema: schema)
        try checkCodable(AgentOutputConfig.self, schema: schema)

        let document = try Self.sample(for: schema, root: schema, requiredOnly: false)
        let manifest = try AgentManifestLoader.load(JSONEncoder().encode(document))
        XCTAssertEqual(manifest.document, document, "schema-generated manifest must load without loss")
    }

    private func checkCodable<T: Codable>(
        _ type: T.Type,
        name: String? = nil,
        schema: JSONValue
    ) throws {
        let name = name ?? String(describing: type)
        let node = try XCTUnwrap(name == "#root" ? schema : schema["$defs"]?[name], name)
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        for requiredOnly in [false, true] {
            let document = try Self.sample(for: node, root: schema, requiredOnly: requiredOnly)
            let decoded = try decoder.decode(type, from: encoder.encode(document))
            let roundTrip = try decoder.decode(JSONValue.self, from: encoder.encode(decoded))
            XCTAssertEqual(roundTrip, document, "\(name): actual Codable wire surface differs from schema (requiredOnly: \(requiredOnly))")
        }

        guard case .object(let members) = try Self.sample(for: node, root: schema, requiredOnly: false) else {
            return XCTFail("\(name) must be an object")
        }
        if case .array(let required)? = node["required"] {
            for key in required.compactMap(\.stringValue) {
                var missingRequired = members
                missingRequired.removeValue(forKey: key)
                XCTAssertThrowsError(
                    try decoder.decode(type, from: encoder.encode(JSONValue.object(missingRequired))),
                    "\(name).\(key) is schema-required but the runtime decoder accepts its absence"
                )
            }
        }
    }

    /// A deliberately small fixture generator for this contract's schema
    /// vocabulary. It fails on unsupported shapes instead of inventing values.
    private static func sample(for node: JSONValue, root: JSONValue, requiredOnly: Bool) throws -> JSONValue {
        if let ref = node["$ref"]?.stringValue {
            let prefix = "#/$defs/"
            guard ref.hasPrefix(prefix), let target = root["$defs"]?[String(ref.dropFirst(prefix.count))] else {
                throw FixtureError.unsupported("Unresolved reference: \(ref)")
            }
            return try sample(for: target, root: root, requiredOnly: requiredOnly)
        }
        if case .array(let values)? = node["enum"], let value = values.first(where: { $0 != .null }) {
            return value
        }
        if case .array(let choices)? = node["anyOf"],
           let choice = choices.first(where: { $0["type"]?.stringValue != "null" }) {
            return try sample(for: choice, root: root, requiredOnly: requiredOnly)
        }
        let type: String?
        if case .array(let types)? = node["type"] {
            type = types.compactMap(\.stringValue).first(where: { $0 != "null" })
        } else {
            type = node["type"]?.stringValue
        }
        switch type {
        case "string": return .string("schema-fixture")
        case "integer": return .integer(7)
        case "number": return .number(1.5)
        case "boolean": return .bool(true)
        case "array":
            guard let items = node["items"] else { throw FixtureError.unsupported("Array has no items schema") }
            return .array([try sample(for: items, root: root, requiredOnly: requiredOnly)])
        case "object":
            guard case .object(let properties)? = node["properties"] else {
                if let additional = node["additionalProperties"], case .object = additional {
                    return .object(["sample": try sample(for: additional, root: root, requiredOnly: requiredOnly)])
                }
                return .object(["sample": .string("preserved"), "nested": .array([.integer(7), .bool(true), .null])])
            }
            let keys: Set<String>
            if requiredOnly {
                if case .array(let required)? = node["required"] {
                    keys = Set(required.compactMap(\.stringValue))
                } else {
                    keys = []
                }
            } else {
                keys = Set(properties.keys)
            }
            var members: [String: JSONValue] = [:]
            for key in keys {
                guard let property = properties[key] else { throw FixtureError.unsupported("Required property missing: \(key)") }
                members[key] = try sample(for: property, root: root, requiredOnly: requiredOnly)
            }
            return .object(members)
        default:
            throw FixtureError.unsupported("Unrecognized fixture schema: \(node)")
        }
    }

    private enum FixtureError: Error {
        case unsupported(String)
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

    /// Local clones may omit the sibling, but CI supplies SPEC_REPO pointing
    /// to the exact commit in scripts/public-schema-revision.txt and runs the
    /// byte-level provenance gate. An explicitly configured missing checkout
    /// is an error, never a skipped drift check.
    func testVendoredSchemaMatchesSiblingSpecRepoWhenPresent() throws {
        let configuredPath = ProcessInfo.processInfo.environment["SPEC_REPO"]
        let defaultURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AgentRuntimeTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // swift-agent-runtime
            .deletingLastPathComponent() // backend
            .appendingPathComponent("agent-config-spec")
        let specURL = configuredPath.map { URL(fileURLWithPath: $0) } ?? defaultURL
        let siblingURL = specURL.appendingPathComponent("schema/agent-config.v2.schema.json")
        guard FileManager.default.fileExists(atPath: siblingURL.path) else {
            if configuredPath != nil {
                return XCTFail("SPEC_REPO is missing the public schema; check out the pinned agent-config-spec revision")
            }
            throw XCTSkip("sibling agent-config-spec checkout not present")
        }
        XCTAssertEqual(
            try Data(contentsOf: siblingURL),
            try Fixtures.resourceData("agent-config.v2.schema.json"),
            "vendored schema is stale — run scripts/sync-public-schema.sh"
        )
        for example in ["on-device-story-agent.json", "portable-agent-config.json"] {
            XCTAssertEqual(
                try Data(contentsOf: specURL.appendingPathComponent("examples/\(example)")),
                try Fixtures.resourceData(example),
                "\(example) differs from public spec — run scripts/sync-public-schema.sh"
            )
        }
    }
}
