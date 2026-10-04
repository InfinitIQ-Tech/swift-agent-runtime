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
configuration.providerKeys[ProviderKeys.anthropicProvider] = keyFromKeychain // cloud only; never stored

// Picks the first available candidate from manifest.model.candidates:
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
| `system_prompt` | Session instructions on every adapter |
| `runtime.streaming` | Streamed `chunk` frames on, or a single `end` frame off |
| `runtime.max_turns` | Typed `maxTurnsExceeded` once the session limit is reached |
| `runtime.max_concurrent_tools` | Concurrent tool-execution width |
| `model.strategy` / `model.candidates` | `single` uses the first candidate; `fallback` walks candidates in order until an adapter is available |
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
of the manifest, never persisted, and redacted from every description.

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

## Demo

```sh
# validate a manifest (no network, no backend)
swift run agent-runtime-demo --manifest Manifests/story-companion.agentconfig.json --dry-run

# chat on-device (Apple Intelligence device) or via cloud (ANTHROPIC_API_KEY set)
swift run agent-runtime-demo --manifest Manifests/story-companion.agentconfig.json
```

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
alongside `SchemaDriftTests`. The tests detect differences between the runtime
models and public schema, including a simulated `schema_version` bump the
runtime does not support.

## Development

```sh
swift test                                                        # full suite
swift test --filter SchemaDriftTests                              # drift gate only
xcodebuild -scheme AgentRuntime -destination "generic/platform=iOS Simulator" build
```

## License

MIT — see [LICENSE](LICENSE).
