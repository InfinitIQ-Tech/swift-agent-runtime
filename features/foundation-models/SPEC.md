# SPEC.md — Foundation Models adapter

> This is the implementation source of truth for AF-78 in `swift-agent-runtime`. The portable contract is owned by `../AgentFactory/features/swift-agent-runtime/SPEC.md`.

## Data flow and API baseline

A loaded `AgentManifest` supplies the immutable version snapshot. `FoundationModelsAdapter` maps only `apple:foundation-models` to Apple's on-device `SystemLanguageModel.default`. `FoundationModelsSession` creates one `LanguageModelSession` with the snapshot's `systemPrompt` as instructions and the normalized allowed tools. Updating AgentFactory agent metadata cannot change an existing local session. No AgentFactory endpoint or provider credential is used.

The adapter uses the iOS 26/macOS 26 GA API surface, with `canImport(FoundationModels)` and availability gates; package floors remain iOS 17/macOS 15. The implementation uses session instructions, `respond(to:)`, cumulative `streamResponse(to:)` snapshots, guided `respond(to:schema:)`, and `prewarm()`. Current later-generation provider APIs are outside this adapter.

`AgentRuntimeResolver.availability` and `makeSession` apply identical candidate selection: `single` inspects only the first candidate; other strategy values use ordered fallback. Unsupported Apple model identifiers are not aliases for the default model.

## Turn lifecycle

1. A session admits at most one active generation. A concurrent `send` finishes with the existing `generationFailed` error before consuming a turn or starting model work.
2. An admitted send consumes one turn, including failed or cancelled attempts. Null/absent `max_turns` leaves session turns unbounded. Exhaustion produces `maxTurnsExceeded` without a start frame or generation.
3. Every admitted successful text turn emits `start`, then text-delta `chunk` frames only when `runtime.streaming` is true, then one `end` with complete text and remaining turns. Non-streaming emits `start` and `end`; structured output preserves AF-83 end-only payload semantics.
4. Cumulative snapshots are converted to deltas, retaining text across framework segment restarts. Literal text such as `null` is preserved; content alone is not a reserved tool placeholder. Tool frames remain available on both text paths.
5. Cancellation is checked before generation and after asynchronous generation/cleanup. Cancelled turns emit no successful end or assistant transcript entry, even if an injected operation ignores cancellation. Relay state is released on success and failure. The active slot is released only after the operation unwinds, so a cancelled model operation cannot overlap a replacement turn.
6. The public `AgentSession`, error cases, supported schema versions, and event shapes are unchanged.

## Availability and recovery

`FoundationModelsAdapter.availability` exposes `osTooOld`, `deviceNotEligible`, `appleIntelligenceNotEnabled`, `modelNotReady`, and `unsupportedModel` without constructing a session. Hosts can retry after the owner enables Apple Intelligence or finishes model download, offer the manifest's cloud candidate with an explicitly supplied key, or keep the Send control disabled while the adapter is unavailable. Context overflow and guardrail refusals remain typed generation errors. Hosts discard interrupted sessions to avoid reusing a framework transcript with a partial turn.

The model runs on device, but manifest webhook tools can require networking. The checked-in story manifest uses a native tool; the SwiftUI host stores stories in memory. Offline evidence requires a real eligible device with downloaded model assets, the original bundled manifest, no provider key, and successful generation with connectivity disabled by its owner. Simulation/injected operations and Simulator builds do not prove offline model execution. Automation must not disconnect a remotely operated execution Mac.

## Verification

- `swift test` includes deterministic Foundation Models text streaming/non-streaming, turn limits, overlap, cancellation, transcript and relay cleanup checks through an internal operations seam; this is behavior evidence, not live generation evidence.
- Resolver tests cover strategy-consistent availability and exact Apple model selection.
- `scripts/verify-public-schema.sh` keeps vendored schema and manifest bytes aligned to the pinned source.
- Run package and demo SDK builds plus the existing macOS/iOS UI suites when the adapter changes, recording counts and skips separately.
- Run the CLI from the original checked-in manifest without `ANTHROPIC_API_KEY`, recording model, OS, events, and actual generation output. The owner deferred the signed physical-device airplane-mode check from AF-78 to [AF-84](https://infinitiqtech.atlassian.net/browse/AF-84); that follow-up requires actual offline evidence and does not inherit a pass from these checks.
- A hosted final-revision macOS job running all four existing Debug Simulation UI tests can satisfy the deterministic Mac UI regression without local Automation Mode authentication. Record exact revision, run and test results; do not infer execution from workflow configuration or a badge.

## Conformance criteria

1. Given a version snapshot, when an on-device session is created, then its `system_prompt` becomes that session's instructions.
2. Given streaming enabled or disabled, when a text turn completes, then event ordering and complete text conform to the existing stream contract.
3. Given the turn budget is exhausted or another turn is active, when `send` is called, then no additional generation starts or budget is consumed.
4. Given cancellation before a late model result, when that result returns, then no successful end frame is emitted.
5. Given an unavailable or unsupported model candidate, when availability and session creation are evaluated, then both use the same configured strategy.
