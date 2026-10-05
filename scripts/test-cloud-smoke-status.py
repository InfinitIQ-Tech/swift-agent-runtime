#!/usr/bin/env python3
"""Compile and test the actual cloud smoke status serializer without network I/O.

The temporary SwiftPM harness depends only on the local AgentRuntime product.
It never runs the demo, opens a terminal, reads input or inherited environment,
uses a real network transport, or accesses provider credentials. Test
payloads are synthetic canaries. Each invocation has a 120-second deadline.
"""

import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]

TESTS = r'''
import AgentRuntime
import Foundation
import XCTest
@testable import CloudSmokeStatusHarness

final class CloudSmokeStatusTests: XCTestCase, @unchecked Sendable {
    private static let canary = "synthetic-noncredential-status-canary"
    private let requiredKeys: Set<String> = [
        "schemaVersion", "processID", "updatedAt", "stage", "requestStarted", "streamed"
    ]
    private let stages: [(CloudSmokeStatus.Stage, String)] = [
        (.started, "started"), (.credentialEntryRequested, "credential_entry_requested"),
        (.awaitingSend, "awaiting_send"), (.ownerDeclined, "owner_declined"),
        (.turnStarted, "turn_started"), (.requestStarted, "request_started"),
        (.responseReceived, "response_received"), (.streaming, "streaming"),
        (.completed, "completed"), (.failed, "failed")
    ]
    private let failures: [(CloudSmokeStatus.Failure, String)] = [
        (.configuration, "configuration"), (.credentialEntry, "credential_entry"),
        (.unavailable, "unavailable"), (.authentication, "authentication"),
        (.network, "network"), (.generation, "generation"),
        (.invalidResponse, "invalid_response"), (.contextLimit, "context_limit"),
        (.outputLimit, "output_limit"), (.guardrail, "guardrail"),
        (.cancelled, "cancelled"), (.turnLimit, "turn_limit"),
        (.tool, "tool"), (.unknown, "unknown")
    ]

    func testInitialSnapshotHasExactClosedSchemaAndBoundedValues() throws {
        try withStatus { _, url in
            let snapshot = try read(url)
            XCTAssertEqual(Set(snapshot.keys), requiredKeys)
            XCTAssertEqual(snapshot["schemaVersion"] as? Int, 1)
            XCTAssertEqual(snapshot["processID"] as? Int32, ProcessInfo.processInfo.processIdentifier)
            let timestamp = try XCTUnwrap(snapshot["updatedAt"] as? Double)
            XCTAssertTrue(timestamp.isFinite)
            XCTAssertGreaterThan(timestamp, 0)
            XCTAssertEqual(snapshot["stage"] as? String, "started")
            XCTAssertEqual(snapshot["requestStarted"] as? Bool, false)
            XCTAssertEqual(snapshot["streamed"] as? Bool, false)
        }
    }

    func testEveryStageSerializesOnlyAnAllowedIdentifier() throws {
        for (stage, expected) in stages {
            try withStatus { status, url in
                status.record(stage)
                let snapshot = try read(url)
                XCTAssertEqual(Set(snapshot.keys), requiredKeys)
                XCTAssertEqual(snapshot["stage"] as? String, expected)
                XCTAssertLessThanOrEqual(try Data(contentsOf: url).count, 512)
            }
        }
    }

    func testEveryFailureSerializesOnlyAnAllowedIdentifier() throws {
        for (failure, expected) in failures {
            try withStatus { status, url in
                status.record(.failed, failure: failure)
                let snapshot = try read(url)
                XCTAssertEqual(Set(snapshot.keys), requiredKeys.union(["failure"]))
                XCTAssertEqual(snapshot["failure"] as? String, expected)
                XCTAssertEqual(snapshot["stage"] as? String, "failed")
                XCTAssertLessThanOrEqual(try Data(contentsOf: url).count, 512)
            }
        }
    }

    func testRuntimeErrorClassificationIsBoundedAndPayloadFree() throws {
        let payload = "{\"x-api-key\":\"" + Self.canary + "\",\"body\":\"" + String(repeating: "private-output", count: 4096) + "\"}\n"
        let cases: [(Error, String)] = [
            (AgentRuntimeError.modelUnavailable(.missingProviderKey(provider: payload)), "authentication"),
            (AgentRuntimeError.modelUnavailable(.osTooOld), "unavailable"),
            (AgentRuntimeError.modelUnavailable(.deviceNotEligible), "unavailable"),
            (AgentRuntimeError.modelUnavailable(.appleIntelligenceNotEnabled), "unavailable"),
            (AgentRuntimeError.modelUnavailable(.modelNotReady), "unavailable"),
            (AgentRuntimeError.modelUnavailable(.unsupportedModel), "unavailable"),
            (AgentRuntimeError.modelUnavailable(.other(payload)), "unavailable"),
            (AgentRuntimeError.noUsableModelCandidate, "unavailable"),
            (AgentRuntimeError.guardrailViolation, "guardrail"),
            (AgentRuntimeError.contextWindowExceeded, "context_limit"),
            (AgentRuntimeError.cancelled, "cancelled"),
            (CancellationError(), "cancelled"),
            (AgentRuntimeError.maxTurnsExceeded(limit: Int.max), "turn_limit"),
            (AgentRuntimeError.toolNotAllowed(payload), "tool"),
            (AgentRuntimeError.toolNotRegistered(payload), "tool"),
            (AgentRuntimeError.invalidProviderResponse(payload), "invalid_response"),
            (AgentRuntimeError.structuredOutputInvalid(payload), "invalid_response"),
            (AgentRuntimeError.unsupportedOutputFormat(payload), "configuration"),
            (AgentRuntimeError.generationFailed(payload), "generation"),
            (AgentRuntimeError.generationFailed("Messages API output token limit reached"), "output_limit"),
            (AgentRuntimeError.generationFailed("Messages API output token limit reached " + payload), "generation"),
            (AgentRuntimeError.generationFailed("Messages API transport failed " + payload), "network"),
            (AgentRuntimeError.generationFailed("prefix Messages API transport failed " + payload), "generation")
        ]
        for (error, expected) in cases {
            try withStatus { status, url in
                status.record(.failed, failure: .classify(error))
                let snapshot = try read(url)
                XCTAssertEqual(Set(snapshot.keys), requiredKeys.union(["failure"]))
                XCTAssertEqual(snapshot["failure"] as? String, expected)
                try assertNoPayload(at: url)
            }
        }
    }

    func testArbitraryErrorsCannotPersistDescriptionsDomainsOrUserInfo() throws {
        let errors: [Error] = [
            UntrustedDiagnostic(),
            NSError(domain: Self.canary, code: Int.max, userInfo: [
                NSLocalizedDescriptionKey: Self.canary,
                "request": ["x-api-key": Self.canary],
                "response": String(repeating: Self.canary, count: 4096)
            ]),
            URLError(.notConnectedToInternet)
        ]
        for error in errors {
            try withStatus { status, url in
                status.record(.failed, failure: .classify(error))
                XCTAssertEqual(try read(url)["failure"] as? String, "unknown")
                try assertNoPayload(at: url)
            }
        }
    }

    func testCompletedSnapshotRetainsRequestResponseAndStreamingMilestones() throws {
        try withStatus { status, url in
            status.record(.requestStarted)
            status.record(.responseReceived, httpStatus: 200)
            status.record(.streaming)
            status.record(.completed)
            let snapshot = try read(url)
            XCTAssertEqual(Set(snapshot.keys), requiredKeys.union(["httpStatus"]))
            XCTAssertEqual(snapshot["stage"] as? String, "completed")
            XCTAssertEqual(snapshot["requestStarted"] as? Bool, true)
            XCTAssertEqual(snapshot["httpStatus"] as? Int, 200)
            XCTAssertEqual(snapshot["streamed"] as? Bool, true)
            XCTAssertNil(snapshot["failure"])
        }
    }

    func testFailedSnapshotsRetainOnlyMilestonesActuallyReached() throws {
        for (httpStatus, streamed) in [(nil as Int?, false), (401, false), (200, true)] {
            try withStatus { status, url in
                status.record(.requestStarted)
                if let httpStatus { status.record(.responseReceived, httpStatus: httpStatus) }
                if streamed { status.record(.streaming) }
                status.record(.failed, failure: .generation)
                let snapshot = try read(url)
                XCTAssertEqual(snapshot["stage"] as? String, "failed")
                XCTAssertEqual(snapshot["requestStarted"] as? Bool, true)
                XCTAssertEqual(snapshot["httpStatus"] as? Int, httpStatus)
                XCTAssertEqual(snapshot["streamed"] as? Bool, streamed)
                XCTAssertEqual(snapshot["failure"] as? String, "generation")
            }
        }
    }

    func testHTTPStatusBoundsRejectInvalidValuesWithoutErasingEvidence() throws {
        let invalid = [Int.min, -1, 0, 99, 600, Int.max]
        try withStatus { status, url in
            for value in invalid {
                status.record(.responseReceived, httpStatus: value)
                XCTAssertNil(try read(url)["httpStatus"])
            }
            for value in [100, 200, 401, 429, 500, 599] {
                status.record(.responseReceived, httpStatus: value)
                XCTAssertEqual(try read(url)["httpStatus"] as? Int, value)
            }
            for value in invalid {
                status.record(.failed, failure: .network, httpStatus: value)
                XCTAssertEqual(try read(url)["httpStatus"] as? Int, 599)
            }
        }
    }

    func testOwnerDeclineDoesNotClaimARequestOrStreaming() throws {
        try withStatus { status, url in
            status.record(.credentialEntryRequested)
            status.record(.awaitingSend)
            status.record(.ownerDeclined)
            let snapshot = try read(url)
            XCTAssertEqual(Set(snapshot.keys), requiredKeys)
            XCTAssertEqual(snapshot["stage"] as? String, "owner_declined")
            XCTAssertEqual(snapshot["requestStarted"] as? Bool, false)
            XCTAssertEqual(snapshot["streamed"] as? Bool, false)
            XCTAssertNil(snapshot["httpStatus"])
        }
    }

    func testConcurrentWritesRemainDecodableAndMilestonesRemainSticky() throws {
        try withStatus { status, url in
            DispatchQueue.concurrentPerform(iterations: 40) { index in
                switch index % 4 {
                case 0: status.record(.requestStarted)
                case 1: status.record(.responseReceived, httpStatus: 200)
                case 2: status.record(.streaming)
                default: status.record(.turnStarted)
                }
                // Concurrent readers see a complete old or new JSON snapshot.
                do {
                    let snapshot = try read(url)
                    XCTAssertTrue(requiredKeys.isSubset(of: Set(snapshot.keys)))
                    XCTAssertTrue(Set(snapshot.keys).isSubset(of: requiredKeys.union(["httpStatus", "failure"])))
                } catch { XCTFail("atomic status file was not decodable") }
            }
            status.record(.completed)
            let snapshot = try read(url)
            XCTAssertEqual(snapshot["stage"] as? String, "completed")
            XCTAssertEqual(snapshot["requestStarted"] as? Bool, true)
            XCTAssertEqual(snapshot["httpStatus"] as? Int, 200)
            XCTAssertEqual(snapshot["streamed"] as? Bool, true)
            XCTAssertNil(snapshot["failure"])
        }
    }

    func testProgressNeverRegressesWhenTransportOvertakesConsumer() throws {
        try withStatus { status, url in
            status.record(.requestStarted)
            status.record(.responseReceived, httpStatus: 200)
            status.record(.turnStarted)
            XCTAssertEqual(try read(url)["stage"] as? String, "response_received")
            status.record(.streaming)
            status.record(.responseReceived, httpStatus: 200)
            XCTAssertEqual(try read(url)["stage"] as? String, "streaming")
        }
    }

    func testEveryTerminalOutcomeRejectsAllLateUpdates() throws {
        for terminal: CloudSmokeStatus.Stage in [.completed, .failed, .ownerDeclined] {
            try withStatus { status, url in
                status.record(.requestStarted)
                status.record(.responseReceived, httpStatus: 200)
                status.record(.streaming)
                status.record(terminal, failure: terminal == .failed ? .cancelled : nil)
                let settled = try Data(contentsOf: url)
                for (lateStage, _) in stages {
                    status.record(lateStage, failure: .unknown, httpStatus: 401)
                    XCTAssertEqual(try Data(contentsOf: url), settled)
                }
            }
        }
    }

    private func read(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func assertNoPayload(at url: URL) throws {
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains(Self.canary), "synthetic canary escaped the closed schema")
        XCTAssertFalse(text.contains("private-output"), "arbitrary provider output escaped the closed schema")
        XCTAssertFalse(text.contains("x-api-key"), "arbitrary request header escaped the closed schema")
        XCTAssertLessThanOrEqual(data.count, 512)
    }

    private func withStatus(_ body: (CloudSmokeStatus, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("status.json")
        try body(CloudSmokeStatus(path: url.path), url)
    }

    private struct UntrustedDiagnostic: Error, CustomStringConvertible, LocalizedError {
        var description: String { CloudSmokeStatusTests.canary }
        var errorDescription: String? { CloudSmokeStatusTests.canary }
    }
}
'''


TURN_TESTS = r'''
import AgentRuntime
import Foundation
import XCTest
@testable import CloudSmokeStatusHarness

@MainActor
final class DemoTurnTests: XCTestCase {
    private let canary = "synthetic-noncredential-status-canary"

    func testClaudeSuccessCompletesOnlyAfterCleanStreamFinish() async throws {
        try await withStatus { status, url in
            let session = try makeSession(status: status, lines: Self.completeLines)
            var ends = 0
            try await consumeDemoTurn(await session.send("test"), status: status) { event in
                if case .end = event {
                    ends += 1
                    XCTAssertNotEqual(try read(url)["stage"] as? String, "completed")
                }
            }
            XCTAssertEqual(ends, 1)
            try assertSnapshot(url, stage: "completed", failure: nil, request: true, http: 200, streamed: true)
        }
    }

    func testClaudeAuthenticationFailurePreservesHTTPStatusWithoutPayload() async throws {
        try await withStatus { status, url in
            let session = try makeSession(status: status, statusCode: 401, lines: [canary])
            await assertFailure(await session.send("test"), status: status)
            try assertSnapshot(url, stage: "failed", failure: "authentication", request: true, http: 401, streamed: false)
        }
    }

    func testClaudeMalformedEOFFailsAfterChunkWithoutAnEnd() async throws {
        try await withStatus { status, url in
            let session = try makeSession(status: status, lines: Self.partialLines)
            await assertFailure(await session.send("test"), status: status)
            try assertSnapshot(url, stage: "failed", failure: "invalid_response", request: true, http: 200, streamed: true)
        }
    }

    func testClaudePostChunkTransportErrorRetainsStreamingEvidence() async throws {
        try await withStatus { status, url in
            let session = try makeSession(status: status, lines: Self.partialLines, failure: AgentRuntimeError.generationFailed(canary))
            await assertFailure(await session.send("test"), status: status)
            try assertSnapshot(url, stage: "failed", failure: "network", request: true, http: 200, streamed: true)
        }
    }

    func testClaudeCancellationDoesNotBecomeSuccessfulEOF() async throws {
        try await withStatus { status, url in
            let session = try makeSession(status: status, lines: Self.partialLines, failure: CancellationError())
            await assertFailure(await session.send("test"), status: status)
            try assertSnapshot(url, stage: "failed", failure: "cancelled", request: true, http: 200, streamed: true)
        }
    }

    func testEmptyAndChunkOnlyStreamsRequireAnEnd() async throws {
        for frames: [AgentStreamEvent] in [[], [.chunk("partial")]] {
            try await withStatus { status, url in
                await assertFailure(stream(frames), status: status)
                try assertSnapshot(url, stage: "failed", failure: "invalid_response", request: false, http: nil, streamed: !frames.isEmpty)
            }
        }
    }

    func testEndFollowedByDuplicateOrOtherEventFailsBeforeForwardingExtraEvent() async throws {
        let end = AgentStreamEvent.end(.init(text: "answer"))
        for extra in [end, .chunk("late"), .start(.init(turn: 1, candidate: "cloud", model: "anthropic:test"))] {
            try await withStatus { status, url in
                var forwarded = 0
                do {
                    try await consumeDemoTurn(stream([end, extra]), status: status) { _ in forwarded += 1 }
                    XCTFail("post-end event was accepted")
                } catch {}
                XCTAssertEqual(forwarded, 0)
                try assertSnapshot(url, stage: "failed", failure: "invalid_response", request: false, http: nil, streamed: false)
            }
        }
    }

    func testErrorAfterEndCannotPublishCompletedStatus() async throws {
        try await withStatus { status, url in
            var endCallbacks = 0
            do {
                try await consumeDemoTurn(stream([.end(.init(text: "answer"))], failure: .generationFailed(canary)), status: status) { event in
                    if case .end = event { endCallbacks += 1 }
                }
                XCTFail("post-end error was accepted")
            } catch {}
            XCTAssertEqual(endCallbacks, 0)
            try assertSnapshot(url, stage: "failed", failure: "generation", request: false, http: nil, streamed: false)
        }
    }

    func testTaskCancellationAtEndAndBeforeIterationAreClassifiedCancelled() async throws {
        for cancelAtEnd in [false, true] {
            try await withStatus { status, url in
                let operation = Task { @MainActor in
                    if !cancelAtEnd { withUnsafeCurrentTask { $0?.cancel() } }
                    try await consumeDemoTurn(stream([.end(.init(text: "answer"))]), status: status) { _ in
                        if cancelAtEnd { withUnsafeCurrentTask { $0?.cancel() } }
                    }
                }
                switch await operation.result {
                case .success: XCTFail("cancelled consumer succeeded")
                case .failure(let error): XCTAssertTrue(error is CancellationError)
                }
                try assertSnapshot(url, stage: "failed", failure: "cancelled", request: false, http: nil, streamed: false)
            }
        }
    }

    func testTaskCancellationWhileAwaitingMoreFramesCannotLookLikeCleanEOF() async throws {
        try await withStatus { status, url in
            let (events, continuation) = AsyncThrowingStream<AgentStreamEvent, Error>.makeStream()
            continuation.yield(.chunk("partial"))
            let operation = Task { @MainActor in
                try await consumeDemoTurn(events, status: status) { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
            switch await operation.result {
            case .success: XCTFail("cancelled consumer succeeded")
            case .failure(let error): XCTAssertTrue(error is CancellationError)
            }
            continuation.finish()
            try assertSnapshot(url, stage: "failed", failure: "cancelled", request: false, http: nil, streamed: true)
        }
    }

    func testCallbackFailureBeforeCleanClosureIsTerminalAndBounded() async throws {
        try await withStatus { status, url in
            do {
                try await consumeDemoTurn(stream([.end(.init(text: "answer"))]), status: status) { _ in
                    throw NSError(domain: canary, code: 7, userInfo: [NSLocalizedDescriptionKey: canary])
                }
                XCTFail("callback failure was swallowed")
            } catch {}
            try assertSnapshot(url, stage: "failed", failure: "unknown", request: false, http: nil, streamed: false)
        }
    }

    func testObservedNonStreamingTransportRecordsRequestAndResponse() async throws {
        try await withStatus { status, url in
            let observer = ObservedCloudSmokeTransport(status: status, transport: FixtureTransport(statusCode: 202, lines: [], failure: nil))
            let (_, code) = try await observer.send(URLRequest(url: URL(string: "https://fixture.invalid")!))
            XCTAssertEqual(code, 202)
            try assertSnapshot(url, stage: "response_received", failure: nil, request: true, http: 202, streamed: false)
        }
    }

    private func assertFailure(_ events: AsyncThrowingStream<AgentStreamEvent, Error>, status: CloudSmokeStatus) async {
        do {
            try await consumeDemoTurn(events, status: status) { _ in }
            XCTFail("expected failed stream")
        } catch {}
    }

    private func stream(_ frames: [AgentStreamEvent], failure: AgentRuntimeError? = nil) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            for frame in frames { continuation.yield(frame) }
            continuation.finish(throwing: failure)
        }
    }

    private func makeSession(status: CloudSmokeStatus, statusCode: Int = 200, lines: [String], failure: (any Error)? = nil) throws -> any AgentSession {
        let candidate = AgentModelCandidate(name: "cloud", model: "anthropic:test-model")
        let config = AgentConfig(id: "smoke_test", name: "Smoke test", version: "v1", schemaVersion: "2", systemPrompt: "test", runtime: .init(streaming: true), model: .init(strategy: "single", candidates: [candidate]))
        let manifest = try AgentManifestLoader.load(JSONEncoder().encode(config))
        let transport = ObservedCloudSmokeTransport(status: status, transport: FixtureTransport(statusCode: statusCode, lines: lines, failure: failure))
        return try ClaudeMessagesAdapter(transport: transport).makeSession(manifest: manifest, candidate: candidate, configuration: .init(providerKeys: .init(["anthropic": canary])))
    }

    private func read(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func assertSnapshot(_ url: URL, stage: String, failure: String?, request: Bool, http: Int?, streamed: Bool) throws {
        let data = try Data(contentsOf: url)
        let snapshot = try read(url)
        XCTAssertEqual(snapshot["stage"] as? String, stage)
        XCTAssertEqual(snapshot["failure"] as? String, failure)
        XCTAssertEqual(snapshot["requestStarted"] as? Bool, request)
        XCTAssertEqual(snapshot["httpStatus"] as? Int, http)
        XCTAssertEqual(snapshot["streamed"] as? Bool, streamed)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(canary))
        XCTAssertLessThanOrEqual(data.count, 512)
    }

    private func withStatus(_ body: (CloudSmokeStatus, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("status.json")
        try await body(CloudSmokeStatus(path: url.path), url)
    }

    private static let partialLines = [
        "event: message_start", #"data: {"type":"message_start","message":{"id":"test"}}"#, "",
        "event: content_block_start", #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#, "",
        "event: content_block_delta", #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hello"}}"#, ""
    ]
    private static let completeLines = partialLines + [
        "event: content_block_stop", #"data: {"type":"content_block_stop","index":0}"#, "",
        "event: message_delta", #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#, "",
        "event: message_stop", #"data: {"type":"message_stop"}"#, ""
    ]
}

private struct FixtureTransport: HTTPStreamTransport {
    let statusCode: Int
    let lines: [String]
    let failure: (any Error)?
    func send(_ request: URLRequest) async throws -> (Data, Int) { (Data(), statusCode) }
    func streamLines(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, Int) {
        (AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish(throwing: failure)
        }, statusCode)
    }
}
'''


def run(log_path: Path, timeout: int) -> int:
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="cloud-smoke-status-", dir="/tmp") as directory:
        harness = Path(directory)
        source = harness / "Sources/CloudSmokeStatusHarness"
        tests = harness / "Tests/CloudSmokeStatusHarnessTests"
        source.mkdir(parents=True)
        tests.mkdir(parents=True)
        for filename in ["CloudSmokeStatus.swift", "ConsumeDemoTurn.swift"]:
            shutil.copyfile(ROOT / "Sources/agent-runtime-demo" / filename, source / filename)
        (tests / "CloudSmokeStatusTests.swift").write_text(TESTS)
        (tests / "DemoTurnTests.swift").write_text(TURN_TESTS)
        (harness / "Package.swift").write_text("""// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "CloudSmokeStatusHarness",
    platforms: [.macOS(.v15)],
    dependencies: [.package(name: "LocalRuntime", path: %s)],
    targets: [
        .target(name: "CloudSmokeStatusHarness", dependencies: [.product(name: "AgentRuntime", package: "LocalRuntime")]),
        .testTarget(name: "CloudSmokeStatusHarnessTests", dependencies: ["CloudSmokeStatusHarness"])
    ]
)
""" % json.dumps(str(ROOT)))
        (harness / "tmp").mkdir()
        # Use an explicit environment; no inherited provider variables are read
        # or passed to SwiftPM/the test executable.
        environment = {
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": str(harness / "tmp"),
            "CLANG_MODULE_CACHE_PATH": str(harness / "clang-module-cache"),
            "SWIFTPM_MODULECACHE_OVERRIDE": str(harness / "swift-module-cache"),
        }
        command = [
            "/usr/bin/swift", "test", "--disable-sandbox", "--package-path", str(harness),
            "--scratch-path", str(harness / "build"), "--cache-path", str(harness / "cache"),
            "--config-path", str(harness / "config"), "--security-path", str(harness / "security"),
        ]
        log_path.parent.mkdir(parents=True, exist_ok=True)
        with log_path.open("w") as output:
            process = subprocess.Popen(
                command, stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT,
                env=environment, start_new_session=True,
            )
            print(f"START pid={process.pid} timeout={timeout}s log={log_path}", flush=True)
            deadline = time.monotonic() + timeout
            while process.poll() is None:
                remaining = deadline - time.monotonic()
                try:
                    process.wait(timeout=max(0.1, min(20, remaining)))
                except subprocess.TimeoutExpired:
                    print(f"PROGRESS elapsed={time.monotonic() - started:.1f}s log_bytes={log_path.stat().st_size}", flush=True)
                    if time.monotonic() >= deadline:
                        os.killpg(process.pid, signal.SIGTERM)
                        try:
                            process.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            os.killpg(process.pid, signal.SIGKILL)
                            process.wait()
                        print("TIMEOUT: test harness exceeded its deadline", flush=True)
                        return 124
        # Only compiler/test diagnostics from this synthetic harness are read.
        print(log_path.read_text(), end="")
        print(f"FINISHED exit_code={process.returncode} elapsed={time.monotonic() - started:.1f}s", flush=True)
        return process.returncode if process.returncode >= 0 else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", type=Path, default=Path("/tmp/cloud-smoke-status-tests.log"))
    parser.add_argument("--timeout", type=int, default=120, choices=range(1, 121), metavar="1..120")
    args = parser.parse_args()
    return run(args.log.resolve(), args.timeout)


if __name__ == "__main__":
    sys.exit(main())
