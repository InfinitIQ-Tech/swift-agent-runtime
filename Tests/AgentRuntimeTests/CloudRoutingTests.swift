import Foundation
import XCTest
@testable import AgentRuntime

final class CloudRoutingTests: XCTestCase {
    private let cloud = AgentModelCandidate(name: "cloud", model: "anthropic:claude-haiku-4-5")
    private let local = AgentModelCandidate(name: "local", model: "apple:foundation-models")

    private func manifest(strategy: String = "fallback", policy: [String: JSONValue]?) throws -> AgentManifest {
        let base = Fixtures.config()
        return try Fixtures.manifest(for: AgentConfig(
            id: base.id, name: base.name, version: base.version, schemaVersion: base.schemaVersion,
            systemPrompt: base.systemPrompt, runtime: base.runtime,
            model: AgentModelConfig(strategy: strategy, candidates: [cloud, local], routingPolicy: policy)
        ))
    }

    private func selectedModel(_ manifest: AgentManifest, localAvailable: Bool = true) async throws -> String {
        let adapters: [any AgentRuntimeAdapter] = [
            SelectionAdapter(provider: "anthropic", available: true),
            SelectionAdapter(provider: "apple", available: localAvailable)
        ]
        XCTAssertEqual(AgentRuntimeResolver.availability(manifest: manifest, adapters: adapters), .available)
        let session = try AgentRuntimeResolver.makeSession(manifest: manifest, adapters: adapters)
        let events = try await collectEvents(await session.send("hello"))
        guard case .start(let start)? = events.first else { throw AgentRuntimeError.invalidProviderResponse("missing start") }
        return start.model
    }

    func testPreferOnDevicePrioritizesLocalCandidateDespiteManifestOrder() async throws {
        let model = try await selectedModel(manifest(policy: ["prefer_on_device": .bool(true)]))
        XCTAssertEqual(model, local.model)
    }

    func testFalseOrAbsentPreferenceRetainsManifestOrder() async throws {
        for policy: [String: JSONValue]? in [nil, [:], ["prefer_on_device": .bool(false)]] {
            let model = try await selectedModel(manifest(policy: policy))
            XCTAssertEqual(model, cloud.model)
        }
    }

    func testSingleSelectionIsNotOverriddenByRoutingHint() async throws {
        let model = try await selectedModel(manifest(strategy: "single", policy: ["prefer_on_device": .bool(true)]))
        XCTAssertEqual(model, cloud.model)
    }

    func testPreferredUnavailableLocalCandidateStillFallsBack() async throws {
        let model = try await selectedModel(manifest(policy: ["prefer_on_device": .bool(true)]), localAvailable: false)
        XCTAssertEqual(model, cloud.model)
    }

    func testUnknownRoutingMetadataRoundTripsWithoutReordering() async throws {
        let policy: [String: JSONValue] = ["future_option": .object(["keep": .bool(true)])]
        let manifest = try manifest(policy: policy)
        let roundTrip = try AgentManifestLoader.load(manifest.canonicalJSONData())
        XCTAssertEqual(roundTrip.config.model.routingPolicy, policy)
        let model = try await selectedModel(roundTrip)
        XCTAssertEqual(model, cloud.model)
    }

    func testCloudCandidateOrderSurvivesOnDevicePreference() async throws {
        let source = try manifest(policy: ["prefer_on_device": .bool(true)])
        guard case .object(var raw) = source.document else { return XCTFail("expected object") }
        raw["model"] = .object([
            "strategy": .string("fallback"),
            "candidates": .array([
                .object(["name": .string("one"), "model": .string("anthropic:first")]),
                .object(["name": .string("two"), "model": .string("anthropic:second")]),
                .object(["name": .string("local"), "model": .string(local.model)])
            ]),
            "routing_policy": .object(["prefer_on_device": .bool(true)])
        ])
        let manifest = try AgentManifestLoader.load(JSONEncoder().encode(raw))
        let model = try await selectedModel(manifest, localAvailable: false)
        XCTAssertEqual(model, "anthropic:first")
    }

    func testCheckedInManifestUsesSameConsumerWithEitherAdapterSet() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let original = try Data(contentsOf: root.appendingPathComponent("Manifests/story-companion.agentconfig.json"))
        XCTAssertEqual(original, try Fixtures.resourceData("on-device-story-agent.json"))
        let manifest = try AgentManifestLoader.load(original)
        let transport = StubHTTPTransport(steps: [.sse(status: 200, lines: StubHTTPTransport.textRound(["A gentle", " story."]))])
        let configuration = AgentSessionConfiguration(providerKeys: ProviderKeys(["anthropic": "routing-test-sentinel"]))
        // The same resolver/send/consume function and unmodified manifest run
        // on each adapter set. The local side is deterministic simulation;
        // the cloud side exercises the actual Messages adapter with a stub.
        func run(_ adapters: [any AgentRuntimeAdapter]) async throws -> [AgentStreamEvent] {
            let session = try AgentRuntimeResolver.makeSession(manifest: manifest, configuration: configuration, adapters: adapters)
            return try await collectEvents(await session.send("Tell a gentle story."))
        }
        let localEvents = try await run([SelectionAdapter(provider: "apple", available: true)])
        let cloudEvents = try await run([ClaudeMessagesAdapter(transport: transport)])
        guard case .start(let localStart)? = localEvents.first,
              case .start(let cloudStart)? = cloudEvents.first,
              case .end(let result)? = cloudEvents.last else { return XCTFail("missing events") }
        XCTAssertEqual(localStart.model, "apple:foundation-models")
        XCTAssertEqual(cloudStart.model, "anthropic:claude-haiku-4-5")
        XCTAssertEqual(result.text, "A gentle story.")
        XCTAssertEqual(cloudEvents.filter { if case .chunk = $0 { return true }; return false }.count, 2)
        XCTAssertEqual(try manifest.canonicalJSONData(), try AgentManifestLoader.load(original).canonicalJSONData())
        let body = try JSONDecoder().decode(JSONValue.self, from: transport.requestBodies[0])
        XCTAssertEqual(body["system"], .string(manifest.config.systemPrompt))
        XCTAssertEqual(body["model"], .string("claude-haiku-4-5"))
        XCTAssertFalse(String(decoding: transport.requestBodies[0], as: UTF8.self).contains("routing-test-sentinel"))
        XCTAssertFalse(String(decoding: try manifest.canonicalJSONData(), as: UTF8.self).contains("routing-test-sentinel"))
    }
}

private struct SelectionAdapter: AgentRuntimeAdapter {
    let provider: String
    let available: Bool
    var identifier: String { provider }
    func supports(candidate: AgentModelCandidate) -> Bool { candidate.provider == provider }
    func availability(for candidate: AgentModelCandidate, configuration: AgentSessionConfiguration) -> AgentRuntimeAvailability {
        available ? .available : .unavailable(.deviceNotEligible)
    }
    func makeSession(manifest: AgentManifest, candidate: AgentModelCandidate, configuration: AgentSessionConfiguration) throws -> any AgentSession {
        SelectionSession(manifest: manifest, candidate: candidate)
    }
}

private actor SelectionSession: AgentSession {
    nonisolated let manifest: AgentManifest
    let candidate: AgentModelCandidate
    init(manifest: AgentManifest, candidate: AgentModelCandidate) { self.manifest = manifest; self.candidate = candidate }
    func send(_ text: String) async -> AsyncThrowingStream<AgentStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.start(AgentTurnStart(turn: 1, candidate: candidate.name, model: candidate.model)))
            continuation.yield(.end(AgentTurnResult(text: "local simulation")))
            continuation.finish()
        }
    }
    func prewarm() {}
    func cancel() {}
    func transcript() -> [AgentMessage] { [] }
    func turnsUsed() -> Int { 0 }
}
