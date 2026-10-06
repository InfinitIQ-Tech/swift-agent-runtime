# swift-agent-runtime

[![CI](https://github.com/InfinitIQ-Tech/swift-agent-runtime/actions/workflows/ci.yml/badge.svg)](https://github.com/InfinitIQ-Tech/swift-agent-runtime/actions/workflows/ci.yml)

**A Swift runtime for the open [AgentConfig](https://github.com/InfinitIQ-Tech/agent-config-spec) format.**

One portable, snake_case JSON manifest fully describes an agent — prompt,
model strategy, runtime limits, tools, guardrails. This package executes that
manifest on Apple platforms:

- **on-device** via Apple's Foundation Models framework (iOS 26 / macOS 26),
  fully offline — no backend, no tenant, no network on the execution path
- **in the cloud** via the Anthropic Messages API, behind the same runtime
  protocol — switching adapters requires zero changes to the manifest or the
  calling code

```swift
import AgentRuntime

let manifest = try AgentManifestLoader.load(contentsOf: manifestURL)

var configuration = AgentSessionConfiguration()
configuration.providerKeys[ProviderKeys.anthropicProvider] = keyFromSecureInput // cloud only; in memory

// Applies model.strategy and routing_policy to manifest.model.candidates:
// "apple:foundation-models" on-device, "anthropic:<model>" in the cloud.
let session = try AgentRuntimeResolver.makeSession(manifest: manifest, configuration: configuration)

for try await event in await session.send("Tell me a story") {
    switch event {
    case .start(let turn): print("turn \(turn.turn) on \(turn.model)")
    case .chunk(let delta): print(delta, terminator: "")
    case .toolCall(let call): print("tool: \(call.toolId)")
    case .toolResult(let result): print("tool done: \(result.success)")
    case .end(let result): print("\ndone, \(result.remainingTurns ?? 0) turns left")
    }
}
```

## What the runtime honors from the manifest

| Manifest section | Behavior |
|---|---|
| `system_prompt` | Instructions from the loaded version snapshot on every adapter; later AgentFactory metadata edits do not mutate the session |
| `runtime.streaming` | `start` → text-delta `chunk` frames → `end` when on; `start` → `end` when off (tool events may occur in either mode) |
| `runtime.max_turns` | Typed `maxTurnsExceeded` once the session limit is reached |
| `runtime.max_concurrent_tools` | Concurrent tool-execution width |
| `model.strategy` / `model.candidates` | `single` uses only the first candidate; `fallback` walks candidates until an adapter is available; unrecognized strategies retain ordered fallback |
| `model.routing_policy.prefer_on_device` | Under fallback, `true` stably prioritizes exact `apple:foundation-models`; false/absent retains manifest order. Other routing metadata is preserved without changing selection |
| `tools.allowed` / `tools.definitions` | Sidecar-parity allow-list normalization; only allowed tools are ever registered with a model. No tools configured → zero tools registered |
| `tools.definitions[].endpoint` | Webhook execution over `URLSession` (method, headers) |
| `tools.tool_policy` | `max_tools_per_turn`, `max_total_runtime_ms`, `require_user_confirmation` via a host confirmation hook |
| `output.format` (`json_schema`) | Per-turn structured output: guided generation on-device, `output_config` on the Messages API. The decoded payload arrives as `AgentTurnResult.structured` on the `end` frame — identical across adapters. Structured turns emit no `chunk` frames. Unknown format types or unsupported schemas fail session creation with typed errors; nested payload violations raise `structuredOutputInvalid` |
| Session `prewarm()` | Foundation Models calls `LanguageModelSession.prewarm()` at conversation entry; cloud is a no-op with zero network requests |
| `memory`, `retrieval`, `guardrails`, unknown sections | Pass-through: preserved on round-trip, never dropped |

Sessions also expose `prewarm()`: on-device it calls
`LanguageModelSession.prewarm()` to cut first-token latency (call it at the
conversation entry point, not on every appearance); on the cloud adapter it is
a no-op, so hosts can call it unconditionally.

The portable structured-output subset uses an object root and explicit types:
`object`, `array`, `string`, `integer`, `number`, and `boolean`. Objects declare
`properties`, optional `required`, and `additionalProperties: false`; arrays
declare an `items` schema. String `enum` values and the string annotations
`title`, `description`, and `$schema` are supported. Optional properties may be
omitted; `null`, unions, references, and other constraint keywords are not in
this subset. Both adapters reject unsupported or malformed schemas at session
creation with `AgentManifestError.invalidManifest`, before generation or a
network request. The public manifest format can carry broader JSON Schemas;
this runtime executes the documented portable subset.

Every structured response is recursively validated for required fields, nested
types, array items, exact enum membership, and unexpected properties. A failure
raises `AgentRuntimeError.structuredOutputInvalid` and emits no `end` result.
`AgentTurnResult.text` contains the same final JSON represented by `structured`,
including after tool calls. Manifests without `output` retain ordinary text and
streaming behavior.

The cloud wire shape follows the current
[Anthropic structured-output API](https://platform.claude.com/docs/en/build-with-claude/structured-outputs)
(verified 2026-10-03): `output_config.format` with `type: "json_schema"`; no
structured-output beta header is needed. Provider-supported model and schema
complexity limits still apply. Unit tests use injected transports and
Foundation Models operations; they do not establish live provider/device
quality or latency.

Provider keys are runtime-supplied configuration (`ProviderKeys`), never part
of the manifest, never persisted by the runtime, and redacted from descriptions,
debug output, and reflection. Cloud diagnostics use runtime-authored messages
and status/code values, never raw provider bodies or transport descriptions.

## Cloud execution

AF-80 extends the existing `ClaudeMessagesAdapter` using the
[Anthropic Messages API](https://platform.claude.com/docs/en/api/messages/create).
It supersedes GPTBridge for portable AgentConfig execution: the runtime already
owns the manifest, tools, structured output, and `AgentSession` contract.
GPTBridge's static `appLaunch`, Chat Completions methods, and deprecated
Assistants helpers remain in that separate client. No GPTBridge dependency,
OpenAI adapter, or Assistants API is introduced here.

Both availability and session creation use the same candidate ordering. A
nonempty `anthropic:<model>` identifier and a nonblank runtime key make a
candidate locally available; this check makes no request and does not validate
account access. Selection happens once per session. Provider errors do not
silently select another model or replay paid requests. Hosts can inject an
adapter set into `AgentRuntimeResolver` while keeping the manifest and
`AgentSession.send` consumer unchanged.

Cloud sessions admit one active turn. Overlap fails before consuming a turn;
each admitted attempt consumes a turn, including failure or cancellation.
Cancellation keeps the active slot until cleanup finishes and prevents a late
successful `end`. A missing terminal provider event, malformed known stream
event, or incomplete tool arguments fails with `invalidProviderResponse`.
Unknown event types remain forward compatible. Interrupted provider history
is rolled back; external tool effects are not undone. Hosts should discard an
interrupted session, as the SwiftUI demo does.

The default cloud transport uses an ephemeral URL session with cache, cookies,
and credential storage disabled and rejects redirects. A host that injects a
custom transport/session owns the equivalent safeguards. The runtime acquires
no credentials. See [cloud verification](docs/cloud-verification.md) for the
API references, GPTBridge decision, deterministic evidence scope, and the
owner-run live-streaming procedure. Automated tests do not establish live
provider acceptance.

## Platforms

Package floors: **iOS 17** / **macOS 15**, so apps with lower deployment
targets can link the library. All Foundation Models API is gated behind
`@available(iOS 26.0, macOS 26.0, *)`; below that, the on-device adapter
reports `unavailable(.osTooOld)` and the cloud adapter still works.
Availability is a cheap, non-throwing query suitable for gating UI entry
points:

```swift
if AgentRuntimeResolver.availability(manifest: manifest).isAvailable { ... }
```

Building requires the Xcode 26 SDK.

The Foundation Models adapter uses the **iOS 26/macOS 26 GA API surface**:
[`SystemLanguageModel.default`](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/default),
[`LanguageModelSession`](https://developer.apple.com/documentation/foundationmodels/languagemodelsession)
instructions, text responses, cumulative response streams, guided generation,
and prewarm. Only `apple:foundation-models` selects this on-device model;
other `apple:` names are unsupported. The OS owns the installed model revision.
Availability and session creation both respect `single` versus ordered fallback.

On-device sessions admit one active generation. Overlapping sends fail with
`generationFailed` without consuming a turn. Each admitted attempt consumes
one `max_turns` slot, including failed/cancelled attempts. Cancellation keeps
the active slot occupied until generation unwinds and prevents a late response
from publishing a successful `end`. Hosts should discard interrupted sessions
because the framework transcript may include a partial turn.

Unavailable states are explicit: an older OS reports `osTooOld`; unsupported
hardware reports `deviceNotEligible`; Apple Intelligence disabled reports
`appleIntelligenceNotEnabled`; missing/downloading assets report `modelNotReady`.
The host can disable sending and retry after the owner resolves the condition,
or use an allowed cloud fallback only with a runtime-supplied key. No automatic
model download, settings change, or provider credential acquisition occurs.
An unsupported candidate reports `unsupportedModel`. Context-window exhaustion
and guardrail refusals surface as typed errors during generation.

See [on-device verification](docs/foundation-models-verification.md) for the
offline acceptance procedure and evidence boundaries. Model generation is
on-device; webhook tools can still require network access. The bundled story
demo uses an in-memory native tool.
Physical-device airplane-mode verification is tracked separately in
[AF-84](https://infinitiqtech.atlassian.net/browse/AF-84), deferred from AF-78
by the owner. This deferral does not claim an offline test passed.

## SwiftUI demo (iOS + macOS)

Open `Demo/AgentRuntimeDemo.xcodeproj`, select the `AgentRuntimeDemo` scheme,
and run on **My Mac** or an iOS Simulator/device. The checked-in project links
this local package; no project generator, backend, account, or package download
is needed. A physical iOS device requires the developer's own signing team.
Xcode 26 is required; deployment floors remain iOS 17 and macOS 15.

The app bundles `Manifests/story-companion.agentconfig.json` directly. The
manifest supplies the agent name, system prompt, candidate order, native tool,
and six-turn limit. The normal runtime resolver uses Foundation Models on an
eligible Apple Intelligence device. If unavailable, Connection accepts an
optional Anthropic key for the manifest's cloud fallback. Cloud execution
requires network access to Anthropic; local model execution needs no backend.
The secure field is cleared after connecting or closing the sheet. Keys,
conversations, and the demo story library are never persisted.

Chat displays streamed or final-only responses, tool events, and remaining
turns. Stop, backgrounding, or a generation failure interrupts the session;
New conversation creates a fresh session and clears the transcript. Repeated
sends are disabled while work is running. The native `save_story` tool stores
stories in the window's in-memory Saved stories library, which survives
conversation resets and disappears when the window closes. Tools requiring
confirmation are not automatically approved.

A simulator or older OS can show model-unavailable state normally. For
repeatable UI verification without a model/key, add `--demo-simulation` to
the Debug scheme's launch arguments. This explicitly labeled simulation uses
the bundled manifest and an injected session, makes no provider calls, and is
excluded from Release builds. `slow`, `fail`, `final`, and `save` exercise
interruption, safe errors, final-only text, and the native tool respectively;
other text produces a simulated reply. This is UI evidence, not model-quality
or live-provider evidence.

The original CLI remains available:

```sh
# validate a manifest (no network, no backend)
swift run agent-runtime-demo --manifest Manifests/story-companion.agentconfig.json --dry-run

# chat using manifest routing and the available adapters
swift run agent-runtime-demo --manifest Manifests/story-companion.agentconfig.json

# general cloud chat; hidden terminal key entry
swift run agent-runtime-demo --manifest Manifests/story-companion.agentconfig.json --adapter cloud --prompt-provider-key

# bounded live check within the owner's authorization
.build/debug/agent-runtime-demo --manifest Manifests/story-companion.agentconfig.json --cloud-smoke-test
```

`--adapter automatic` is the default; `cloud` and `on-device` restrict the
available adapter set without editing the manifest or changing the send loop.
Supplying a key alone does not override an available on-device candidate.
`--prompt-provider-key` uses `readpassphrase` with echo disabled and a required
controlling terminal. It accepts up to 1,022 UTF-8 bytes, rejects oversized
input, and clears its temporary buffer. The CLI also accepts an owner-provided `ANTHROPIC_API_KEY` in its
process environment when the prompt flag is absent; no key belongs in a shell
command, `.env` file, launch configuration, or chat. `--dry-run` neither reads
provider keys nor prompts for them and makes no provider request.

`--cloud-smoke-test` is the bounded live acceptance path. It verifies the
original manifest's SHA-256, forces cloud, sets `max_tokens: 256` and
`service_tier: "standard_only"`, and permits at most one provider request,
including tool continuations. It always uses hidden owner key entry, ignores
environment keys, and requires the owner to type `SEND` and press Enter before
sending its fixed short prompt. With explicit owner permission, the coding
agent may prepare/open the protected prompt and monitor credential-free
results; the owner alone enters the key and initiates the request. It exits
after that turn; `--adapter on-device` conflicts
with this mode. A tool continuation is denied and does not count as successful
live acceptance. The documented standard-rate ceiling is **$0.20128 before
tax** at published standard prices; tax and custom account terms are excluded.
The terminal flow has no cost text or separate budget gate. Each invocation
must stay within the owner's authorization. Pricing assumptions, secure entry,
and evidence requirements are in [cloud verification](docs/cloud-verification.md).

Optional `--smoke-status-file <path>` requires `--cloud-smoke-test` without
`--dry-run`. It writes only a closed JSON schema of PID, timestamp, fixed
stage/failure values, numeric HTTP status, and request/stream flags; it never
writes credential input, request bodies, generated text, or raw errors. Use a
fresh path and verify the expected process and timestamps before interpreting
it. `credential_entry_requested` means the reader is about to be called; it
does **not** prove the protected prompt is ready. The verification guide
defines the remaining stage and completion evidence boundaries.

Maintainers can regenerate the checked-in Xcode project from `Demo/project.yml`
with XcodeGen (`xcodegen generate --spec Demo/project.yml`; generated with 2.45.4).
Ordinary app builds do not require XcodeGen or any third-party package.

## Contract drift

The public schema is the contract. A vendored copy of
`agent-config.v2.schema.json` lives in the test resources and is updated only
via `scripts/sync-public-schema.sh` from a sibling
[`agent-config-spec`](https://github.com/InfinitIQ-Tech/agent-config-spec)
checkout. Sync requires a committed public spec and records its exact revision
in `scripts/public-schema-revision.txt`. `scripts/verify-public-schema.sh`
checks that the sibling checkout (or `SPEC_REPO` override) is at that revision
and that the vendored schema and examples are byte-identical. A missing explicit
`SPEC_REPO` fails verification.

CI checks out the pinned public spec and runs the external verification gate
alongside `SchemaDriftTests`. The tests compare structural expectations and
exercise the actual runtime Codable models with schema-generated payloads.
`scripts/prove-schema-drift.sh` runs the real gate against an isolated simulated
`schema_version` bump, checks that it fails for the expected reason, and leaves
the checked-in schema untouched. The normal clean-schema run must pass first.

## Platform verification

The same script runs locally and in CI:

```sh
CI_VERIFICATION_DIR=/tmp/agent-runtime-verification scripts/ci-platform-tests.sh macos
CI_VERIFICATION_DIR=/tmp/agent-runtime-verification scripts/ci-platform-tests.sh ios
scripts/prove-schema-drift.sh
```

The scripts run runtime/model tests, Release app builds, and Debug Simulation
UI tests. iOS verification includes Simulator and unsigned device-SDK builds;
it does not establish physical-device execution. `IOS_SIMULATOR_ID` selects
an installed iPhone simulator; otherwise the newest available one is selected.
Logs and result bundles are stored in a separate timestamped run directory.
Using `/tmp` avoids Finder metadata that can invalidate local app signing in
some Documents folders. Mac builds use ad hoc signing without a development
team; device installation requires a developer signing configuration.

macOS XCTest UI tests also require the host's UI Automation authorization.
`automationmodetool` with no arguments reports its status without changing it.
If Automation Mode is disabled and authentication is required, the host owner
must authorize UI testing before the Mac suite can run. A runner startup
failure is not a passing UI result. Verification details and limitations are
recorded in `features/demo-app/spec_log.md`.

## Development

```sh
swift test                                                        # full suite
swift test --filter SchemaDriftTests                              # drift gate only
xcodebuild -scheme AgentRuntime -destination "generic/platform=iOS Simulator" build
```

## License

MIT — see [LICENSE](LICENSE).
