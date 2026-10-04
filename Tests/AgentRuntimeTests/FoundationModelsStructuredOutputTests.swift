import Foundation
import XCTest
@testable import AgentRuntime
#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, macOS 26.0, *)
private actor FoundationModelsCallRecorder {
    var prewarmCalls = 0
    var prompts: [String] = []
    var schemas: [JSONValue] = []
    let response: String

    init(response: String) { self.response = response }
    func prewarm() { prewarmCalls += 1 }
    func respond(_ prompt: String, schema: GenerationSchema) throws -> String {
        prompts.append(prompt)
        schemas.append(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(schema)))
        return response
    }
    nonisolated var operations: FoundationModelsOperations {
        FoundationModelsOperations(
            prewarm: { await self.prewarm() },
            respond: { try await self.respond($0, schema: $1) }
        )
    }
}
#endif

final class FoundationModelsStructuredOutputTests: XCTestCase {
    func testPrewarmCallsThroughWithoutConsumingATurn() async throws {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip("Foundation Models requires OS 26") }
        let recorder = FoundationModelsCallRecorder(response: "unused")
        let config = Fixtures.config(output: Fixtures.outputConfig())
        let session: any AgentSession = try FoundationModelsSession(
            manifest: Fixtures.manifest(for: config), candidate: config.model.candidates[0],
            configuration: .init(), operations: recorder.operations
        )
        await session.prewarm()
        let calls = await recorder.prewarmCalls
        let prompts = await recorder.prompts
        let turns = await session.turnsUsed()
        let transcript = await session.transcript()
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(prompts.isEmpty)
        XCTAssertEqual(turns, 0)
        XCTAssertTrue(transcript.isEmpty)
        #else
        throw XCTSkip("FoundationModels SDK not present")
        #endif
    }

    func testBothLanesReturnIdenticalStructuredResultForOneManifest() async throws {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip("Foundation Models requires OS 26") }
        let json = #"{"reply":"A dragon appears","choices":["Run","Talk"]}"#
        let recorder = FoundationModelsCallRecorder(response: json)
        let config = Fixtures.config(candidates: [
            AgentModelCandidate(name: "device", model: "apple:foundation-models"),
            AgentModelCandidate(name: "cloud", model: "anthropic:claude-haiku-4-5")
        ], output: Fixtures.outputConfig())
        let manifest = try Fixtures.manifest(for: config)
        let local: any AgentSession = try FoundationModelsSession(
            manifest: manifest, candidate: config.model.candidates[0], configuration: .init(), operations: recorder.operations
        )
        let transport = StubHTTPTransport(steps: [.json(status: 200, body: #"{"content":[{"type":"text","text":"{\"reply\":\"A dragon appears\",\"choices\":[\"Run\",\"Talk\"]}"}],"stop_reason":"end_turn"}"#)])
        let cloud = try ClaudeMessagesAdapter(transport: transport).makeSession(
            manifest: manifest, candidate: config.model.candidates[1],
            configuration: .init(providerKeys: ProviderKeys(["anthropic": "test-key"]))
        )
        var results: [AgentTurnResult] = []
        for session in [local, cloud] {
            let events = try await collectEvents(await session.send("continue"))
            XCTAssertFalse(events.contains { if case .chunk = $0 { true } else { false } })
            guard case .end(let result)? = events.last else { return XCTFail("missing end frame") }
            results.append(result)
        }
        XCTAssertEqual(results[0], results[1])
        XCTAssertEqual(results[0].text, json)
        let prompts = await recorder.prompts
        let schemas = await recorder.schemas
        let schema = try XCTUnwrap(schemas.first)
        XCTAssertEqual(prompts, ["continue"])
        XCTAssertEqual(schema["properties"]?["reply"]?["type"], .string("string"))
        XCTAssertEqual(schema["properties"]?["choices"]?["items"]?["type"], .string("string"))
        XCTAssertEqual(schema["required"], .array([.string("choices"), .string("reply")]))
        #else
        throw XCTSkip("FoundationModels SDK not present")
        #endif
    }

    func testFoundationModelsRejectsNestedViolationWithSameTypedError() async throws {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip("Foundation Models requires OS 26") }
        let recorder = FoundationModelsCallRecorder(response: #"{"reply":"hi","choices":[7]}"#)
        let config = Fixtures.config(output: Fixtures.outputConfig())
        let session = try FoundationModelsSession(
            manifest: Fixtures.manifest(for: config), candidate: config.model.candidates[0], configuration: .init(), operations: recorder.operations
        )
        do {
            for try await event in await session.send("continue") {
                if case .end = event { XCTFail("invalid payload must never be delivered") }
            }
            XCTFail("expected structuredOutputInvalid")
        } catch let error as AgentRuntimeError {
            guard case .structuredOutputInvalid(let reason) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertTrue(reason.contains("$.choices[0]"))
        }
        #else
        throw XCTSkip("FoundationModels SDK not present")
        #endif
    }

    func testFoundationModelsRejectsUnsupportedSchemaBeforeGeneration() async throws {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip("Foundation Models requires OS 26") }
        let recorder = FoundationModelsCallRecorder(response: "unused")
        var schema = Fixtures.outputConfig().format.schema
        schema["allOf"] = .array([])
        let config = Fixtures.config(output: .init(format: .init(type: "json_schema", schema: schema)))
        XCTAssertThrowsError(try FoundationModelsSession(
            manifest: Fixtures.manifest(for: config), candidate: config.model.candidates[0], configuration: .init(), operations: recorder.operations
        )) { error in
            guard case AgentManifestError.invalidManifest = error else { return XCTFail("unexpected \(error)") }
        }
        let prompts = await recorder.prompts
        XCTAssertTrue(prompts.isEmpty)
        #else
        throw XCTSkip("FoundationModels SDK not present")
        #endif
    }

    func testGenerationSchemaPreservesNestedStructureWithoutNameCollisions() throws {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip("Foundation Models requires OS 26") }
        let source: [String: JSONValue] = [
            "type": .string("object"), "additionalProperties": .bool(false),
            "required": .array([.string("a"), .string("a_b")]),
            "properties": .object([
                "a": .object([
                    "type": .string("object"), "additionalProperties": .bool(false),
                    "required": .array([.string("b")]),
                    "properties": .object(["b": .object([
                        "type": .string("object"), "additionalProperties": .bool(false),
                        "properties": .object(["leaf_text": .object(["type": .string("string")])])
                    ])])
                ]),
                "a/b~": .object([
                    "type": .string("object"), "additionalProperties": .bool(false),
                    "properties": .object(["value": .object(["type": .string("number")])])
                ]),
                "a_b": .object([
                    "type": .string("object"), "additionalProperties": .bool(false),
                    "required": .array([.string("flag")]),
                    "properties": .object([
                        "flag": .object(["type": .string("boolean")]),
                        "mood": .object(["type": .string("string"), "enum": .array([.string("calm"), .string("sleepy")])])
                    ])
                ])
            ])
        ]
        let generated = try GenerationSchemaBuilder.makeSchema(toolName: "structured/output~", parameters: source)
        let schema = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(generated))
        func resolve(_ value: JSONValue?) throws -> JSONValue {
            let value = try XCTUnwrap(value)
            if let reference = value["$ref"]?.stringValue {
                return try XCTUnwrap(schema["$defs"]?[String(reference.dropFirst("#/$defs/".count))])
            }
            return value
        }
        let a = try resolve(schema["properties"]?["a"])
        let nestedB = try resolve(a["properties"]?["b"])
        let flatAB = try resolve(schema["properties"]?["a_b"])
        let escaped = try resolve(schema["properties"]?["a/b~"])
        XCTAssertEqual(escaped["properties"]?["value"]?["type"], .string("number"))
        XCTAssertEqual(nestedB["properties"]?.objectKeys, ["leaf_text"])
        XCTAssertEqual(nestedB["properties"]?["leaf_text"]?["type"], .string("string"))
        XCTAssertEqual(flatAB["properties"]?.objectKeys, ["flag", "mood"])
        XCTAssertEqual(flatAB["properties"]?["flag"]?["type"], .string("boolean"))
        XCTAssertEqual(flatAB["required"], .array([.string("flag")]))
        for definitionName in schema["$defs"]?.objectKeys ?? [] {
            XCTAssertFalse(definitionName.contains("/"))
            XCTAssertFalse(definitionName.contains("~"))
        }
        let mood = try resolve(flatAB["properties"]?["mood"])
        XCTAssertEqual(mood["anyOf"], .array([
            .object(["type": .string("string"), "enum": .array([.string("calm")])]),
            .object(["type": .string("string"), "enum": .array([.string("sleepy")])])
        ]))
        #else
        throw XCTSkip("FoundationModels SDK not present")
        #endif
    }
}
