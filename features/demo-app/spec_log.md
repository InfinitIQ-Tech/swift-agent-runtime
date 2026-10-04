# Spec Log — Runtime Demo App

## 2026-10-04 — AF-81 implementation and local verification

The shared SwiftUI iOS/macOS app bundles the original portable story manifest and uses the existing runtime resolver and session protocol. The host owns ephemeral credentials, conversation lifecycle, and an in-memory native story library. The CLI remains available. Deterministic Debug Simulation verifies UI behavior without making live-model claims; Release excludes the simulation implementation.

The repository adds a shared Xcode project/scheme, RuntimeDemoSupport model, 24 model tests, platform UI tests, pinned schema drift checks, and a macOS-hosted CI matrix for both platforms. No runtime protocol, supported schema version, vendored schema/example bytes, backend, persistence, or provider credentials changed.

### Recorded results

All times below are UTC on 2026-10-04. Full logs and machine-readable command records are in the sibling `../verification/` folder of the isolated AF-81 workspace; this external evidence is intentionally not committed to the source repository.

| Check | Result | Evidence |
|---|---|---|
| macOS `swift test` | 73 XCTest + 24 Swift Testing tests passed; 0 failures, completed 12:57:26 | `recovery/macos-package-tests.log` and `.json` |
| iOS Simulator package tests | 73 XCTest + 24 Swift Testing tests passed; 0 failures, completed 12:56:45 | `recovery/ios-package-tests.log`, `.json`, `.xcresult` |
| iOS Simulator UI | 5 tests passed; 0 failures, completed 11:39:33 | `demo-ios-ui.log`, `.xcresult` |
| Pinned schema/examples | Exact revision and byte comparison passed at 12:58:10 | `recovery/public-schema-pin.log` |
| Isolated schema-version bump | Clean drift suite passed; bumped schema failed the real XCTest gate as expected; original schema retained | `schema-drift/clean.log`, `schema-drift/bumped.log` |
| Additional type-mismatch injection | Expected failure at `runtime.streaming` (Bool versus number); not a product regression | `schema-drift/type-mismatch.log` |
| Independent review | No actionable implementation or CI defects; `git diff --check`, shell syntax and executable-mode checks passed | Read-only review on 2026-10-04 |

The iOS package command was:

```sh
xcodebuild -scheme swift-agent-runtime-Package   -destination 'platform=iOS Simulator,id=C303C170-5D75-4975-976F-5DEDCD0B1F3E'   -parallel-testing-enabled NO   -derivedDataPath ../verification/DriftCIPackageDerivedData   -resultBundlePath ../verification/recovery/ios-package-tests.xcresult   CODE_SIGNING_ALLOWED=NO test
swift test
scripts/verify-public-schema.sh
```

The package tests were bounded to six minutes (iOS) and four minutes (macOS); both finished normally. They use deterministic sessions/transports and require no backend, Postgres, sidecar, provider key, or live generation. The existing booted iPhone 17 iOS 26.5 Simulator was reused. Full reproducible platform commands are in `scripts/ci-platform-tests.sh`; schema fault injection is in `scripts/prove-schema-drift.sh`.

### macOS UI blocker

The earlier Mac UI run failed before any tests executed. Unified system logging identifies the cause at 11:33:19: `Writer daemon requires authentication to enable automation mode.` The subsequent local authentication request was labeled `Enable UI Automation`; XCTest timed out 60 seconds later. At 12:53:51 no xcodebuild, XCTest runner, or demo app remained running. Ad hoc signing and a successful build do not establish a passing UI run.

Approval and host-owner authentication are pending. No automation/security settings or credentials were changed. The Mac UI suite must pass after authorization before AF-81 can be considered locally complete. The schema-generated Codable tests cover representative schema branches, not exhaustive JSON Schema semantics.

### Remaining verification and delivery

Release build results and runtime-only fresh-clone verification are being recorded separately after their bounded checks finish. The existing CI badge links the workflow, but there is no hosted result for this unpublished AF-81 change. No push, PR, merge, release, Jira update, physical-device execution, or live-model/provider result is claimed. Original development checkouts were compared against the saved baseline: HEAD, status, tracked diff, and recorded untracked-file hashes all match.
