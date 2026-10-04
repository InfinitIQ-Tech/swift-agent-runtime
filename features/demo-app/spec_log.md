# Spec Log — Runtime Demo App

## 2026-10-04 — AF-81 implementation and verified local recovery

The shared SwiftUI iOS/macOS app bundles the original portable story manifest and uses the existing runtime resolver and session protocol. The host owns ephemeral credentials, conversation lifecycle, and an in-memory native story library. The CLI remains available. Deterministic Debug Simulation verifies UI behavior without making live-model claims; Release excludes the simulation implementation.

The change adds a shared Xcode project/scheme, RuntimeDemoSupport model, 24 model tests, platform UI tests, pinned schema drift checks, and a macOS-hosted CI matrix for both platforms. No runtime protocol, supported schema version, vendored schema/example bytes, backend, persistence, or provider credentials changed. Live AF-81 and Company Philosophy Confluence page 4292609 version 1 were reviewed.

### Passed verification

Times below are UTC on 2026-10-04. Full logs, result bundles, exact argument arrays, timeouts, exit codes, and durations are retained in `../verification/recovery/` in the isolated AF-81 workspace. These machine-local artifacts are outside the source repository.

| Check | Result | Finished UTC | Evidence stem |
|---|---|---|---|
| macOS package | 73 XCTest + 24 Swift Testing tests, 0 failures | 12:57:26 | `macos-package-tests` |
| iOS Simulator package | 73 XCTest + 24 Swift Testing tests, 0 failures | 12:56:45 | `ios-package-tests` |
| Fresh runtime-only clone | 73 XCTest + 24 Swift Testing tests, 0 failures | 13:00:18 | `runtime-only-fresh-tests` |
| macOS Release | Build passed, ad hoc signed | 12:57:48 | `macos-release-build` |
| iOS Simulator Release | Build passed, unsigned | 12:57:54 | `ios-release-simulator-build` |
| iOS device SDK Release | Build passed, unsigned | 12:58:26 | `ios-release-device-build` |
| Release simulation exclusion | Checked strings/symbols absent from all three binaries | 12:58:57 | `release-simulation-exclusion` |
| Pinned schema/examples | Exact revision and byte comparison passed | 12:58:10 | `public-schema-pin` |
| CLI manifest dry run | Manifest valid and round-trip safe | 13:00:08 | `cli-dry-run` |
| macOS focused UI recovery | 1 test, 0 failures | 13:07:37 | `macos-ui-focused` |
| macOS full UI | 4 tests, 0 failures | 13:09:47 | `macos-ui-final` |
| iOS Simulator full UI | 5 tests, 0 failures | 13:13:30 | `ios-ui-final` |

The fresh clone used `git clone --no-local --single-branch --branch codex/af-81-swiftui-demo` from the isolated local repository at implementation commit `3a47eb808bec2d1e2ed6b2d83901ceca7d701c3a`, then `swift test`, with no sibling public-schema/backend repositories or existing build artifacts. The later correction affects only UI test assertions and documentation; package source, package tests, resources, and Package.swift remain byte-identical to that tested commit. No network package download, provider key, backend, Postgres, or sidecar was required. The existing iPhone 17 iOS 26.5 Simulator was reused.

Schema negative evidence in `../verification/schema-drift/` predates recovery and remains valid: `clean.log` passed six drift tests, `bumped.log` failed the real schema-version gate on the isolated unsupported version, and `type-mismatch.log` failed as expected for Bool versus number at `runtime.streaming`. These were intentional fault injections. The vendored schema bytes were not changed. Schema-generated Codable tests cover representative branches rather than exhaustive JSON Schema semantics.

### Commands and reproducibility

The executed package commands were `swift test`, `scripts/verify-public-schema.sh`, and the following iOS invocation (paths shown relative to the runtime checkout):

```sh
xcodebuild -scheme swift-agent-runtime-Package -destination 'platform=iOS Simulator,id=C303C170-5D75-4975-976F-5DEDCD0B1F3E' -parallel-testing-enabled NO -derivedDataPath ../verification/DriftCIPackageDerivedData -resultBundlePath ../verification/recovery/ios-package-tests.xcresult CODE_SIGNING_ALLOWED=NO test
swift run agent-runtime-demo --manifest Manifests/story-companion.agentconfig.json --dry-run
```

Release builds used `xcodebuild -project Demo/AgentRuntimeDemo.xcodeproj -scheme AgentRuntimeDemo -configuration Release`, with destinations `platform=macOS`, `generic/platform=iOS Simulator`, and `generic/platform=iOS`. Mac used `CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES`; iOS used `CODE_SIGNING_ALLOWED=NO`. Derived data was isolated under `/tmp/af81-recovery-release-macos` and `/tmp/af81-recovery-release-ios`.

Final UI tests used the shared project/scheme in Debug, `-parallel-testing-enabled NO`, and destinations `platform=macOS,arch=arm64` and `platform=iOS Simulator,id=C303C170-5D75-4975-976F-5DEDCD0B1F3E`. Mac used ad hoc signing; iOS disabled signing. Every recovery build/test command had an explicit wall-clock limit, and successful commands exited normally. Exact executed commands are recorded in the matching evidence `.json` files. Maintained local/CI entry points remain `scripts/ci-platform-tests.sh macos`, `scripts/ci-platform-tests.sh ios`, and `scripts/prove-schema-drift.sh`.

### Resolved macOS failures

The initial Mac runner failed before executing tests. Unified logging at 11:33:19 reported `Writer daemon requires authentication to enable automation mode.` The native `Enable UI Automation` request timed out after 60 seconds. A bounded retry at 13:01 also timed out before authentication completed. The host owner subsequently approved the prompt directly through Splashtop. At 13:07:32 Apple's read-only status query reported `Automation Mode is ENABLED`; tests then ran successfully. No passwords were entered by the agent, authentication requirements were not disabled, and no unrelated security setting was changed. Automation Mode is session-scoped and may read disabled after a test run exits.

The first executed Mac suite exposed an iOS-only test assertion: AppKit static text supplies content through accessibility value, while the tests compared only label. The status and remaining-turn assertions now accept the exact expected text from either property on the same identified element. The repetitive failing run was interrupted; the focused Mac test and both final platform UI suites passed after correction. App behavior and accessibility identifiers did not change.

### Review, limitations, and delivery status

Independent read-only review examined lifecycle/cancellation, credentials, fail-closed tool confirmation, Debug-only simulation, schema drift, Xcode linkage, scripts, and CI configuration. The later assertion correction was independently reviewed with no remaining actionable findings. `git diff --check`, shell syntax checks, and executable-mode checks passed. The unsigned device build has a nonblocking orientation warning; device installation/signing and physical-device execution were not tested.

Local verification is complete. Hosted AF-81 CI remains pending publication; the README links its workflow badge, but no green hosted result is claimed for the unpublished change. No push, PR, merge, release, Jira post, physical-device execution, or live-model/provider generation was performed. Only local commits were prepared. The four original development checkouts match their saved HEAD, status, tracked-diff hashes, and recorded untracked-file hashes.
