import Foundation
import XCTest
@testable import AgentRuntime
#if canImport(FoundationModels)
import FoundationModels
#endif

/// AF-83: per-turn structured output declared in the manifest's `output`
/// section, plus session prewarm. Both adapters must yield the same decoded
/// `structured` payload on the end frame with zero call-site changes.
final class StructuredOutputTests: XCTestCase {
    private let keyedConfiguration = AgentSessionConfiguration(
        providerKeys: ProviderKeys(["anthropic": "sk-test-not-a-real-key"])
    )

    private func cloudSession(
        config: AgentConfig,
        transport: StubHTTPTransport
    ) throws -> any AgentSession {
        let adapter = ClaudeMessagesAdapter(transport: transport)
        let manifest = try Fixtures.manifest(for: config)
        let candidate = try XCTUnwrap(manifest.config.model.candidates.first { $0.provider == "anthropic" })
        return try adapter.makeSession(
            manifest: manifest,
            candidate: candidate,
            configuration: keyedConfiguration
        )
    }

    // MARK: - Manifest loading

    func testManifestWithOutputSectionDecodesTypedTree() throws {
        let manifest = try Fixtures.manifest(named: "portable-agent-config.json")
        let output = try XCTUnwrap(manifest.config.output)
        XCTAssertEqual(output.format.type, "json_schema")
        XCTAssertEqual(output.format.schema["type"]?.stringValue, "object")
    }

    func testManifestWithoutOutputSectionHasNilOutput() throws {
        let manifest = try Fixtures.manifest(named: "on-device-story-agent.json")
        XCTAssertNil(manifest.config.output, "absent output section must behave exactly as before AF-83")
    }

    // MARK: - Payload decoding

    func testDecodeStructuredPayloadAcceptsConformingObject() throws {
        let format = Fixtures.outputConfig().format
        let payload = try format.decodeStructuredPayload(
            from: #"{"reply":"Once upon a time","choices":["Go left","Go right"]}"#
        )
        XCTAssertEqual(payload["reply"], .string("Once upon a time"))
        XCTAssertEqual(payload["choices"], .array([.string("Go left"), .string("Go right")]))
    }

    func testDecodeStructuredPayloadRejectsNonJSONWithTypedError() {
        let format = Fixtures.outputConfig().format
        XCTAssertThrowsError(try format.decodeStructuredPayload(from: "Once upon a time...")) { error in
            guard case AgentRuntimeError.structuredOutputInvalid = error else {
                return XCTFail("expected structuredOutputInvalid, got \(error)")
            }
        }
    }

    func testDecodeStructuredPayloadRejectsTopLevelTypeMismatch() {
        let format = Fixtures.outputConfig().format
        XCTAssertThrowsError(try format.decodeStructuredPayload(from: #"["not","an","object"]"#)) { error in
            guard case AgentRuntimeError.structuredOutputInvalid = error else {
                return XCTFail("expected structuredOutputInvalid, got \(error)")
            }
        }
    }

    // MARK: - Cloud lane

    func testCloudRequestCarriesOutputConfigFormat() async throws {
        let transport = StubHTTPTransport(steps: [
            .json(status: 200, body: #"{"content":[{"type":"text","text":"{\"reply\":\"hi\",\"choices\":[]}"}],"stop_reason":"end_turn"}"#)
        ])
        let session = try cloudSession(
            config: Fixtures.config(streaming: false, output: Fixtures.outputConfig()),
            transport: transport
        )
        _ = try await collectEvents(await session.send("hello"))

        let body = try JSONDecoder().decode(JSONValue.self, from: transport.requestBodies[0])
        let format = try XCTUnwrap(body["output_config"]?["format"])
        XCTAssertEqual(format["type"], .string("json_schema"))
        XCTAssertEqual(format["schema"]?["type"], .string("object"))
        XCTAssertNotNil(format["schema"]?["properties"])
    }

    func testCloudStructuredTurnDeliversDecodedPayloadOnEndFrame() async throws {
        let transport = StubHTTPTransport(steps: [
            .json(status: 200, body: #"{"content":[{"type":"text","text":"{\"reply\":\"A dragon appears\",\"choices\":[\"Run\",\"Talk\"]}"}],"stop_reason":"end_turn"}"#)
        ])
        let session = try cloudSession(
            config: Fixtures.config(streaming: false, output: Fixtures.outputConfig()),
            transport: transport
        )
        let events = try await collectEvents(await session.send("continue the story"))

        guard case .end(let result)? = events.last else {
            return XCTFail("expected end frame")
        }
        let structured = try XCTUnwrap(result.structured)
        XCTAssertEqual(structured["reply"], .string("A dragon appears"))
        XCTAssertEqual(structured["choices"], .array([.string("Run"), .string("Talk")]))
        XCTAssertEqual(result.text, #"{"reply":"A dragon appears","choices":["Run","Talk"]}"#)
    }

    func testCloudStructuredTurnSuppressesChunksEvenWhenManifestStreams() async throws {
        let transport = StubHTTPTransport(steps: [
            .json(status: 200, body: #"{"content":[{"type":"text","text":"{\"reply\":\"hi\",\"choices\":[]}"}],"stop_reason":"end_turn"}"#)
        ])
        let session = try cloudSession(
            config: Fixtures.config(streaming: true, output: Fixtures.outputConfig()),
            transport: transport
        )
        let events = try await collectEvents(await session.send("hello"))

        let chunkCount = events.filter { if case .chunk = $0 { return true }; return false }.count
        XCTAssertEqual(chunkCount, 0, "structured turns deliver the payload whole on the end frame")

        let body = try JSONDecoder().decode(JSONValue.self, from: transport.requestBodies[0])
        XCTAssertEqual(body["stream"], .bool(false), "structured turns request a non-streaming response")
    }

    func testCloudNonConformingOutputThrowsTypedError() async throws {
        let transport = StubHTTPTransport(steps: [
            .json(status: 200, body: #"{"content":[{"type":"text","text":"Sorry, plain prose."}],"stop_reason":"end_turn"}"#)
        ])
        let session = try cloudSession(
            config: Fixtures.config(streaming: false, output: Fixtures.outputConfig()),
            transport: transport
        )
        do {
            _ = try await collectEvents(await session.send("hello"))
            XCTFail("expected structuredOutputInvalid")
        } catch let error as AgentRuntimeError {
            guard case .structuredOutputInvalid = error else {
                return XCTFail("expected structuredOutputInvalid, got \(error)")
            }
        }
    }

    func testCloudUnstructuredManifestStillHasNilStructured() async throws {
        let transport = StubHTTPTransport(steps: [
            .json(status: 200, body: #"{"content":[{"type":"text","text":"Hello there"}],"stop_reason":"end_turn"}"#)
        ])
        let session = try cloudSession(config: Fixtures.config(streaming: false), transport: transport)
        let events = try await collectEvents(await session.send("hi"))

        guard case .end(let result)? = events.last else {
            return XCTFail("expected end frame")
        }
        XCTAssertNil(result.structured)

        let body = try JSONDecoder().decode(JSONValue.self, from: transport.requestBodies[0])
        XCTAssertNil(body["output_config"], "unstructured manifests send no output_config")
    }

    func testCloudRejectsUnknownOutputFormatTypeAtSessionCreation() throws {
        XCTAssertThrowsError(
            try cloudSession(
                config: Fixtures.config(output: Fixtures.outputConfig(type: "yaml_prose")),
                transport: StubHTTPTransport(steps: [])
            )
        ) { error in
            XCTAssertEqual(error as? AgentRuntimeError, .unsupportedOutputFormat("yaml_prose"))
        }
    }

    // MARK: - Foundation Models lane

    func testOutputSchemaConvertsToGenerationSchema() throws {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *) else {
            throw XCTSkip("Foundation Models requires iOS 26 / macOS 26")
        }
        let format = Fixtures.outputConfig().format
        XCTAssertNoThrow(
            try GenerationSchemaBuilder.makeSchema(
                toolName: "structured_output",
                parameters: format.schema
            )
        )
        #else
        throw XCTSkip("FoundationModels SDK not present")
        #endif
    }

    func testFoundationModelsRejectsUnknownOutputFormatTypeAtSessionCreation() throws {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *) else {
            throw XCTSkip("Foundation Models requires iOS 26 / macOS 26")
        }
        let config = Fixtures.config(
            candidates: [AgentModelCandidate(name: "on_device", model: "apple:foundation-models")],
            output: Fixtures.outputConfig(type: "yaml_prose")
        )
        let manifest = try Fixtures.manifest(for: config)
        XCTAssertThrowsError(
            try FoundationModelsSession(
                manifest: manifest,
                candidate: manifest.config.model.candidates[0],
                configuration: AgentSessionConfiguration()
            )
        ) { error in
            XCTAssertEqual(error as? AgentRuntimeError, .unsupportedOutputFormat("yaml_prose"))
        }
        #else
        throw XCTSkip("FoundationModels SDK not present")
        #endif
    }

    // MARK: - Prewarm

    func testCloudPrewarmIsANoOpThatSendsNoRequests() async throws {
        let transport = StubHTTPTransport(steps: [])
        let session = try cloudSession(config: Fixtures.config(), transport: transport)
        await session.prewarm()
        XCTAssertTrue(transport.requests.isEmpty, "cloud prewarm must not touch the network")
    }

}
