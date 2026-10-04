import Foundation
import XCTest
@testable import AgentRuntime

final class ResolverTests: XCTestCase {
    private func manifest(strategy: String) throws -> AgentManifest {
        try Fixtures.manifest(for: Fixtures.config(
            candidates: [
                AgentModelCandidate(name: "on_device", model: "apple:foundation-models"),
                AgentModelCandidate(name: "cloud", model: "anthropic:claude-haiku-4-5")
            ],
            strategy: strategy
        ))
    }

    func testFallbackStrategySkipsUnavailableCandidate() async throws {
        let manifest = try manifest(strategy: "fallback")
        let adapters: [any AgentRuntimeAdapter] = [
            StubAdapter(identifier: "apple", provider: "apple", availabilityResult: .unavailable(.deviceNotEligible)),
            StubAdapter(identifier: "cloud", provider: "anthropic", availabilityResult: .available)
        ]

        XCTAssertEqual(AgentRuntimeResolver.availability(manifest: manifest, adapters: adapters), .available)
        let session = try AgentRuntimeResolver.makeSession(manifest: manifest, adapters: adapters)
        let events = try await collectEvents(await session.send("hello"))
        guard case .end(let result)? = events.last else {
            return XCTFail("expected stub session output")
        }
        XCTAssertEqual(result.text, "stub: hello")
    }

    func testSingleStrategyOnlyConsidersFirstCandidate() throws {
        let manifest = try manifest(strategy: "single")
        let adapters: [any AgentRuntimeAdapter] = [
            StubAdapter(identifier: "apple", provider: "apple", availabilityResult: .unavailable(.deviceNotEligible)),
            StubAdapter(identifier: "cloud", provider: "anthropic", availabilityResult: .available)
        ]

        XCTAssertEqual(
            AgentRuntimeResolver.availability(manifest: manifest, adapters: adapters),
            .unavailable(.deviceNotEligible)
        )
        XCTAssertThrowsError(try AgentRuntimeResolver.makeSession(manifest: manifest, adapters: adapters)) { error in
            guard case AgentRuntimeError.modelUnavailable(let reason) = error else {
                return XCTFail("expected modelUnavailable, got \(error)")
            }
            XCTAssertEqual(reason, .deviceNotEligible)
        }
    }

    func testNoSupportingAdapterThrowsUnsupportedModel() throws {
        let manifest = try manifest(strategy: "fallback")
        XCTAssertThrowsError(try AgentRuntimeResolver.makeSession(manifest: manifest, adapters: [])) { error in
            guard case AgentRuntimeError.modelUnavailable(.unsupportedModel) = error else {
                return XCTFail("expected unsupportedModel, got \(error)")
            }
        }
    }

    func testSingleUnsupportedCandidateDoesNotAdvertiseFallback() throws {
        let manifest = try Fixtures.manifest(for: Fixtures.config(candidates: [
            AgentModelCandidate(name: "unsupported", model: "apple:unknown-model"),
            AgentModelCandidate(name: "cloud", model: "anthropic:claude-haiku-4-5")
        ], strategy: "single"))
        let adapters: [any AgentRuntimeAdapter] = [
            FoundationModelsAdapter(),
            StubAdapter(identifier: "cloud", provider: "anthropic", availabilityResult: .available)
        ]
        XCTAssertEqual(AgentRuntimeResolver.availability(manifest: manifest, adapters: adapters), .unavailable(.unsupportedModel))
        XCTAssertThrowsError(try AgentRuntimeResolver.makeSession(manifest: manifest, adapters: adapters)) { error in
            XCTAssertEqual(error as? AgentRuntimeError, .modelUnavailable(.unsupportedModel))
        }
    }

    func testCompositeAvailability() throws {
        let manifest = try manifest(strategy: "fallback")
        let unavailable: [any AgentRuntimeAdapter] = [
            StubAdapter(identifier: "apple", provider: "apple", availabilityResult: .unavailable(.appleIntelligenceNotEnabled)),
            StubAdapter(identifier: "cloud", provider: "anthropic", availabilityResult: .unavailable(.missingProviderKey(provider: "anthropic")))
        ]
        XCTAssertEqual(
            AgentRuntimeResolver.availability(manifest: manifest, adapters: unavailable),
            .unavailable(.missingProviderKey(provider: "anthropic"))
        )

        let mixed: [any AgentRuntimeAdapter] = [
            StubAdapter(identifier: "apple", provider: "apple", availabilityResult: .unavailable(.modelNotReady)),
            StubAdapter(identifier: "cloud", provider: "anthropic", availabilityResult: .available)
        ]
        XCTAssertEqual(AgentRuntimeResolver.availability(manifest: manifest, adapters: mixed), .available)
    }

    func testDefaultAdaptersCoverOnDeviceAndCloud() {
        let identifiers = AgentRuntimeResolver.defaultAdapters().map(\.identifier)
        XCTAssertEqual(identifiers, ["foundation-models", "anthropic-messages"])
    }

    func testFoundationModelsAdapterFiltersProviders() {
        let adapter = FoundationModelsAdapter()
        XCTAssertTrue(adapter.supports(candidate: AgentModelCandidate(name: "d", model: "apple:foundation-models")))
        let unknown = AgentModelCandidate(name: "unknown", model: "apple:unknown-model")
        XCTAssertFalse(adapter.supports(candidate: unknown))
        XCTAssertEqual(adapter.availability(for: unknown, configuration: .init()), .unavailable(.unsupportedModel))
        XCTAssertFalse(adapter.supports(candidate: AgentModelCandidate(name: "c", model: "anthropic:claude-haiku-4-5")))
        XCTAssertEqual(
            adapter.availability(
                for: AgentModelCandidate(name: "c", model: "anthropic:claude-haiku-4-5"),
                configuration: AgentSessionConfiguration()
            ),
            .unavailable(.unsupportedModel)
        )
        // On-device availability is environment-dependent; it must return a
        // deterministic result without crashing on any host.
        let result = adapter.availability(
            for: AgentModelCandidate(name: "d", model: "apple:foundation-models"),
            configuration: AgentSessionConfiguration()
        )
        switch result {
        case .available, .unavailable:
            break
        }
    }
}
