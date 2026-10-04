#!/usr/bin/env python3
"""Compile and test the actual cloud smoke status serializer without network I/O.

The temporary SwiftPM harness depends only on the local AgentRuntime product.
It never runs the demo, opens a terminal, reads input or inherited environment,
instantiates the observed transport, or accesses provider credentials. Test
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
        try withStatus { status, url in
            for (stage, expected) in stages {
                status.record(stage)
                let snapshot = try read(url)
                XCTAssertEqual(Set(snapshot.keys), requiredKeys)
                XCTAssertEqual(snapshot["stage"] as? String, expected)
                XCTAssertLessThanOrEqual(try Data(contentsOf: url).count, 512)
            }
        }
    }

    func testEveryFailureSerializesOnlyAnAllowedIdentifier() throws {
        try withStatus { status, url in
            for (failure, expected) in failures {
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
        try withStatus { status, url in
            for (error, expected) in cases {
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
            URLError(.notConnectedToInternet),
            CancellationError()
        ]
        try withStatus { status, url in
            for error in errors {
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
                default: status.record(.failed, failure: .network)
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


def run(log_path: Path, timeout: int) -> int:
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="cloud-smoke-status-", dir="/tmp") as directory:
        harness = Path(directory)
        source = harness / "Sources/CloudSmokeStatusHarness"
        tests = harness / "Tests/CloudSmokeStatusHarnessTests"
        source.mkdir(parents=True)
        tests.mkdir(parents=True)
        shutil.copyfile(ROOT / "Sources/agent-runtime-demo/CloudSmokeStatus.swift", source / "CloudSmokeStatus.swift")
        (tests / "CloudSmokeStatusTests.swift").write_text(TESTS)
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
