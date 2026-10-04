# Cloud adapter spec log

## 2026-10-04 — AF-80 implementation contract

- Audited the existing Messages adapter and live AF-80 before implementation. Read Company Philosophy page 4292609 version 1 and the AgentFactory-owned runtime contract.
- Added `SPEC.md` before code changes to define routing, serialized cloud turns, complete SSE validation, credential-safe diagnostics/transport, GPTBridge supersession, and separate deterministic/live evidence.
- Original manifests, public schema, protocols and event shapes remain unchanged. Verification results will be recorded after implementation.

## 2026-10-04 — AF-80 implementation and review

- Reused the existing Claude adapter; repaired production SSE framing (Foundation's generic line sequence discards blank delimiters), complete-frame/tool validation, serialized cloud turns, cancellation cleanup, replay rollback, routing hints, and credential-safe errors/transport/reflection. Added explicit CLI adapter injection and owner-only hidden key entry without manifest changes. Documented GPTBridge supersession and current official Messages API references in `docs/cloud-verification.md`.
- Independent review found and resolved two defects: incomplete provider stop reasons reported as success, and recursive reflection exposing a session's bare credential string. The implementation now rejects truncated/paused turns and stores the redacting credential wrapper.
- Final macOS package command `swift test` passed 148 tests (124 XCTest + 24 demo model), zero failures/skips. Focused Claude/structured suites passed 52; transport passed 13; routing passed 7. These focused counts are subsets, not additional tests. Five separate CLI behavior checks passed. No server, account or provider credential was required.
- `scripts/verify-public-schema.sh` matched pin `8dde13b24d0f0b7dfa2217a17942426fc4fded7a`; `scripts/prove-schema-drift.sh` passed the clean gate and rejected an isolated version bump while leaving vendored bytes unchanged. macOS Release demo build passed with signing disabled. Final iOS and standalone clone results are recorded separately after completion.
- Live cloud acceptance remains unverified: an owner-controlled interactive terminal, compatible existing Anthropic key, and authorization for billable usage are required. No provider credential was inspected/acquired/transmitted and no provider call was made. Local Mac UI tests are not run because they can request host authentication; hosted verification can supply them after publication is authorized. Physical offline acceptance stays with AF-84.

## 2026-10-04 — Owner-controlled bounded live verification

- Added `--cloud-smoke-test` after the owner requested a concrete spend bound: exact pinned manifest SHA, fixed short prompt, Claude Haiku 4.5, `max_tokens: 256`, and one `SingleRequestCloudTransport` call at `service_tier: standard_only`. The original tools remain present; a tool continuation cannot create a second billed request. The owner must enter the key privately and type `SEND`; the agent does not initiate the request.
- Eight new demo-support tests passed, including actual-adapter streaming with the original manifest and blocked tool continuation. Independent review found no remaining actionable issue. The final macOS package now passes 156 tests (132 XCTest + 24 demo-model), zero failures/skips, superseding the earlier 148 count. Ten CLI checks passed without provider access; macOS Release rebuild passed after the support-module addition.
- Current official standard rates and Haiku's 200,000-token context give an intentionally conservative maximum of $0.20128 before tax for this one-request configuration; the requested approval ceiling is $0.21 USD per invocation. Custom account terms/tax are outside the quoted token rates. Repeating the command requires separate authorization. Live acceptance remains unperformed.
