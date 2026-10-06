# Tool calling — AF-79

## Ownership and data flow

The portable contract is owned by `../AgentFactory/features/swift-agent-runtime/SPEC.md`. The pinned public schema defines the manifest fields. `AgentToolbox` normalizes the version snapshot once; both adapters register only that toolbox. `ToolExecutionEngine` resolves allowed calls to a declared webhook endpoint or a host handler and returns the existing tool result metadata. The Foundation Models bridge may submit overlapping single-call batches to the same engine. Local execution has no AgentFactory or sidecar service dependency.

## Normalization

- Explicit `tools.allowed` wins, including an empty list. Absent/null `allowed` derives names from definitions. Missing/empty tools or unresolvable names expose zero tools.
- Each name resolves to its last definition, including when `allowed` is absent. Duplicate allowed names expose one definition. Complete definition metadata is retained.
- Resolved definitions use the sidecar's sorted Unicode scalar name order, independent of manifest list order. Names use exact Unicode identity without canonical-equivalence merging. This intentionally corrects the earlier Swift-only manifest-order behavior to match `LangchainRuntimeService/app/application/tools_manager.py`.
- Normalization does not execute endpoints. The Swift runtime owns webhook dispatch; the sidecar's selected endpoint is metadata, not evidence of sidecar webhook execution.
- Native handler dispatch and confirmation-policy names use the same exact Unicode identity. A differently spelled stored handler key never aliases an allowed name. The existing Swift dictionary configuration can represent only one of two canonically equivalent keys; an unregistered exact spelling fails as missing a handler rather than invoking another tool.

## Execution and lifecycle

- `runtime.max_concurrent_tools` limits active work across every overlapping batch on one engine. Absent values retain the default width of one. Results remain in input call order. Waiting calls are admitted fairly without exceeding the shared cap.
- Only allowed calls may execute. `max_tools_per_turn` and the remaining runtime budget are checked at admission. The call-count allowance is consumed when capacity is granted, including subsequent confirmation denial or cancellation, preserving existing attempt-counting behavior. Calls cancelled while still queued consume no allowance. Calls waiting for capacity must observe the latest counters before starting. Confirmation-required tools fail closed without an approving host hook; cancellation or a turn change during confirmation prevents handler/transport dispatch.
- `max_total_runtime_ms` is a cumulative admission budget: completed execution durations are charged as each call finishes, before capacity is offered to later calls. Time waiting for a permit or user confirmation is excluded. Concurrent admitted calls can overshoot the budget; once completed durations exhaust it, no later call starts. A webhook receives a timeout capped by the remaining budget and the existing 30-second default. The runtime does not promise forced cancellation of an uncooperative host handler.
- Cancellation removes pending work and prevents new handler dispatch. Already running work retains capacity until it unwinds, including a handler or confirmation hook that ignores cancellation. Completion, failure, denied confirmation, and cancellation each release capacity exactly once.
- `beginTurn()` resets only the new turn's policy counters. It does not free occupied capacity. Pending old-turn calls cannot start in a new turn, and old completions cannot charge its budget. Normal adapter turns already serialize generation; direct engine callers receive the same isolation safeguards.
- Public session protocols, engine signatures, supported schema versions, platform floors, and stream event shapes stay unchanged. Tool results preserve tool id, call id, output, success, and measured duration where execution occurred.

## Verification and conformance

Given no tools, an empty allow-list, or only unresolved names, when an adapter normalizes its tool surface, then no tool is registered. Given duplicate definitions and omitted or explicit allowed names, when normalized, then one last definition per name appears in sidecar order.

Given a shared engine with width one, when overlapping batches or Foundation Models bridge callbacks execute, then at most one handler is active. Given width greater than one, when independent calls arrive, then the configured parallelism is usable and ordered results are preserved.

Given exhausted completed-runtime or call-count budgets, when pending work is considered, then no new handler starts. Given cancellation, failed/denied work, or a new turn, when queued and active work settles, then capacity and per-turn counters remain usable and isolated.

Automated tests use injected handlers/transports, bounded gates, and the actual bridge callback without generation. Webhook success, HTTP failure, transport timeout, declared headers/methods, and tool metadata remain covered. Full macOS/iOS package tests, platform SDK/demo builds, existing Simulation UI tests where authorized, public-schema provenance/drift checks, and the original manifest CLI dry run form the verification gates. No live model, provider request, device offline acceptance, or published-release change is implied by these tests.

Webhook arguments use a JSON body for non-GET methods or query items for GET. Declared headers, including a case-insensitive `Content-Type`, are preserved; non-GET requests default that header to `application/json` only when absent. A successful 2xx response returns the body; HTTP failures and transport failures/timeouts produce unsuccessful tool results.
