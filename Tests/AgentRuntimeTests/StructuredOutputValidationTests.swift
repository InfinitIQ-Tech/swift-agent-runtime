import Foundation
import XCTest
@testable import AgentRuntime

final class StructuredOutputValidationTests: XCTestCase {
    func testRecursivelyRejectsNonconformingPayloadsWithTypedError() throws {
        let format = Fixtures.outputConfig().format
        for payload in [
            #"{}"#,
            #"{"reply":1,"choices":[]}"#,
            #"{"reply":"hi","choices":[1]}"#,
            #"{"reply":"hi","choices":[],"extra":true}"#,
            #"{"reply":"hi","choices":null}"#
        ] {
            XCTAssertThrowsError(try format.decodeStructuredPayload(from: payload), payload) { error in
                guard case AgentRuntimeError.structuredOutputInvalid = error else {
                    return XCTFail("expected structuredOutputInvalid, got \(error)")
                }
            }
        }
    }

    func testNestedEnumsOptionalMembersAndPrimitiveTypes() throws {
        let format = AgentOutputFormat(type: "json_schema", schema: [
            "type": .string("object"), "additionalProperties": .bool(false),
            "properties": .object([
                "story_state": .object([
                    "type": .string("object"), "additionalProperties": .bool(false),
                    "required": .array([.string("mood")]),
                    "properties": .object([
                        "mood": .object(["type": .string("string"), "enum": .array([.string("calm"), .string("sleepy")])]),
                        "count": .object(["type": .string("integer")]),
                        "score": .object(["type": .string("number")]),
                        "done": .object(["type": .string("boolean")])
                    ])
                ])
            ]), "required": .array([.string("story_state")])
        ])
        XCTAssertNoThrow(try format.decodeStructuredPayload(from: #"{"story_state":{"mood":"calm"}}"#))
        XCTAssertNoThrow(try format.decodeStructuredPayload(from: #"{"story_state":{"mood":"calm","count":2,"score":1.5,"done":false}}"#))
        for payload in [
            #"{"story_state":{}}"#,
            #"{"story_state":{"mood":"angry"}}"#,
            #"{"story_state":{"mood":"calm","count":1.5}}"#,
            #"{"story_state":{"mood":"calm","done":"false"}}"#,
            #"{"story_state":{"mood":"calm","score":true}}"#,
            #"{"story_state":{"mood":"calm","extra":0}}"#
        ] {
            XCTAssertThrowsError(try format.decodeStructuredPayload(from: payload), payload) { error in
                guard case AgentRuntimeError.structuredOutputInvalid(let reason) = error else {
                    return XCTFail("expected structuredOutputInvalid, got \(error)")
                }
                XCTAssertTrue(reason.contains("$.story_state"))
            }
        }
    }

    func testCloudRejectsUnsupportedOrMalformedSchemasBeforeAnyRequest() throws {
        let valid = Fixtures.outputConfig().format.schema
        var invalidSchemas: [[String: JSONValue]] = [
            [:], ["type": .string("array"), "items": .object(["type": .string("string")])]
        ]
        for (key, value) in [
            ("additionalProperties", JSONValue.bool(true)),
            ("required", .array([.string("unknown")])),
            ("required", .array([.string("reply"), .string("reply")])),
            ("minProperties", .integer(1)),
            ("$ref", .string("#/$defs/story"))
        ] {
            var schema = valid; schema[key] = value; invalidSchemas.append(schema)
        }
        for child in [
            ["type": JSONValue.string("string"), "minLength": .integer(1)],
            ["type": .string("string"), "enum": .array([.integer(1)])],
            ["type": .string("null")],
            ["type": .string("array")],
            ["type": .string("object"), "properties": .object([:])]
        ] {
            var schema = valid
            schema["properties"] = .object(["reply": .object(child)])
            schema["required"] = .array([.string("reply")])
            invalidSchemas.append(schema)
        }
        let transport = StubHTTPTransport(steps: [])
        let adapter = ClaudeMessagesAdapter(transport: transport)
        for schema in invalidSchemas {
            let config = Fixtures.config(output: .init(format: .init(type: "json_schema", schema: schema)))
            let manifest = try Fixtures.manifest(for: config)
            XCTAssertThrowsError(try adapter.makeSession(
                manifest: manifest, candidate: config.model.candidates[0],
                configuration: AgentSessionConfiguration(providerKeys: ProviderKeys(["anthropic": "test-key"]))
            )) { error in
                guard case AgentManifestError.invalidManifest = error else {
                    return XCTFail("expected invalidManifest, got \(error)")
                }
            }
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testCloudSchemaPreservesSnakeCasePropertyNames() async throws {
        let schema: [String: JSONValue] = [
            "type": .string("object"), "additionalProperties": .bool(false),
            "properties": .object(["reply_text": .object(["type": .string("string")])]),
            "required": .array([.string("reply_text")])
        ]
        let config = Fixtures.config(output: .init(format: .init(type: "json_schema", schema: schema)))
        let transport = StubHTTPTransport(steps: [.json(status: 200, body: #"{"content":[{"type":"text","text":"{\"reply_text\":\"hi\"}"}],"stop_reason":"end_turn"}"#)])
        let session = try ClaudeMessagesAdapter(transport: transport).makeSession(
            manifest: Fixtures.manifest(for: config), candidate: config.model.candidates[0],
            configuration: AgentSessionConfiguration(providerKeys: ProviderKeys(["anthropic": "test-key"]))
        )
        _ = try await collectEvents(await session.send("hello"))
        let body = try JSONDecoder().decode(JSONValue.self, from: transport.requestBodies[0])
        XCTAssertEqual(body["output_config"]?["format"]?["schema"], .object(schema))
        XCTAssertNil(body["output_format"])
        XCTAssertNil(transport.requests[0].value(forHTTPHeaderField: "anthropic-beta"))
    }

    func testCloudRejectsNestedViolationWithoutEndFrame() async throws {
        let config = Fixtures.config(output: Fixtures.outputConfig())
        let transport = StubHTTPTransport(steps: [.json(status: 200, body: #"{"content":[{"type":"text","text":"{\"reply\":\"hi\",\"choices\":[1]}"}],"stop_reason":"end_turn"}"#)])
        let session = try ClaudeMessagesAdapter(transport: transport).makeSession(
            manifest: Fixtures.manifest(for: config), candidate: config.model.candidates[0],
            configuration: AgentSessionConfiguration(providerKeys: ProviderKeys(["anthropic": "test-key"]))
        )
        do {
            for try await event in await session.send("hello") {
                if case .end = event { XCTFail("invalid output must never be delivered") }
            }
            XCTFail("expected validation failure")
        } catch let error as AgentRuntimeError {
            guard case .structuredOutputInvalid(let reason) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(reason, "Provider output does not match the declared schema")
        }
    }

    func testCloudStructuredToolTurnReturnsOnlyFinalJSONInTextAndReplay() async throws {
        let json = #"{"reply":"hi","choices":[]}"#
        let transport = StubHTTPTransport(steps: [
            .json(status: 200, body: #"{"content":[{"type":"text","text":"Checking a fact."},{"type":"tool_use","id":"call_1","name":"search","input":{"query":"story"}}],"stop_reason":"tool_use"}"#),
            .json(status: 200, body: #"{"content":[{"type":"text","text":"{\"reply\":\"hi\",\"choices\":[]}"}],"stop_reason":"end_turn"}"#),
            .json(status: 200, body: #"{"content":[{"type":"text","text":"{\"reply\":\"hi\",\"choices\":[]}"}],"stop_reason":"end_turn"}"#)
        ])
        let config = Fixtures.config(tools: .init(definitions: [Fixtures.toolDefinition(name: "search")]), output: Fixtures.outputConfig())
        let session = try ClaudeMessagesAdapter(transport: transport).makeSession(
            manifest: Fixtures.manifest(for: config), candidate: config.model.candidates[0],
            configuration: .init(providerKeys: ProviderKeys(["anthropic": "test-key"]), toolHandlers: ["search": { _ in "found" }])
        )
        let events = try await collectEvents(await session.send("hello"))
        guard case .end(let result)? = events.last else { return XCTFail("expected end") }
        XCTAssertEqual(result.text, json)
        XCTAssertEqual(result.structured, try Fixtures.outputConfig().format.decodeStructuredPayload(from: json))
        XCTAssertEqual(result.toolResults.count, 1)
        XCTAssertFalse(events.contains { if case .chunk = $0 { true } else { false } })
        let transcript = await session.transcript()
        XCTAssertEqual(transcript.last?.content, json)
        _ = try await collectEvents(await session.send("next"))
        let body = try JSONDecoder().decode(JSONValue.self, from: transport.requestBodies[2])
        guard case .array(let messages)? = body["messages"] else { return XCTFail("missing messages") }
        guard case .array(let content)? = messages[messages.count - 2]["content"] else { return XCTFail("missing content") }
        XCTAssertEqual(content.first?["text"], .string(json))
    }
}
