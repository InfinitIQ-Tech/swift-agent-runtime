# Cloud adapter

> Source of truth for AF-80 cloud execution, transport, and candidate routing in this package. The portable contract remains owned by `../AgentFactory/features/swift-agent-runtime/SPEC.md` and the pinned public schema.

## Scope and data flow

The existing `ClaudeMessagesAdapter` implements `AgentRuntimeAdapter` and creates an `AgentSession`. It uses the Anthropic Messages API. AF-80 strengthens that implementation; it does not add an OpenAI adapter or an Assistants API dependency. This module supersedes GPTBridge for portable manifest execution. GPTBridge remains a separate client; importing its provider-specific API would not replace the manifest, tool, or session contracts already owned here.

`AgentManifest` supplies instructions, model candidates, routing metadata, tools, output schema, and turn limits. `AgentSessionConfiguration` supplies only in-memory provider credentials and host tool handlers. `AgentRuntimeResolver` chooses an available candidate once per session. `ClaudeMessagesSession` builds provider requests and executes tool rounds through `ToolExecutionEngine`. There are no AgentFactory endpoints, DTO, database, or persisted credential changes.

## Routing

- `single` considers only the first manifest candidate; routing hints cannot override it.
- Ordered fallback retains candidate order. Under fallback, `routing_policy.prefer_on_device: true` stably moves the supported `apple:foundation-models` candidate before cloud candidates. False or absent keeps manifest order. Availability and construction use identical ordering.
- Other routing members are preserved as pass-through metadata per the public schema. This package does not implement weighted routing or per-turn reselection. Existing unrecognized strategies retain the documented ordered-fallback interpretation.
- Claude accepts only a nonempty `anthropic:<model>` identifier and a nonblank runtime-supplied key. Direct adapter construction applies the same eligibility checks.
- Provider failures after selection do not silently switch providers or replay paid requests.

## Cloud turns and errors

- One admitted turn runs at a time. Overlap fails with `generationFailed` before consuming budget. Every admitted attempt consumes one turn. Cancellation holds the active slot until cleanup finishes and prevents late successful output.
- Incomplete or malformed known SSE events, unfinished tool arguments, and missing `message_stop` fail with `invalidProviderResponse`; they cannot publish an `end` frame. Unknown event types remain forward compatible.
- Only complete tool argument objects may execute. Assistant tool blocks retain provider order when replayed. Tool-round text appears once in the wire transcript.
- Successful assistant history is committed only after the terminal frame is accepted. Interrupted cloud wire state is rolled back before a later send; externally performed tool effects are not undone. Hosts discard interrupted sessions as documented by the shared demo lifecycle.
- HTTP authentication, context exhaustion, refusals, cancellation, malformed responses, and generation failures use the existing typed errors. Diagnostics use bounded runtime-authored descriptions and status/code values, never raw provider bodies, transport error descriptions, or request headers.
- `model_context_window_exceeded` maps to `contextWindowExceeded`; `max_tokens`, `pause_turn`, and unknown stop reasons fail without an `end` result or automatic provider continuation. Only `end_turn` and `stop_sequence` finish ordinary responses; `tool_use` continues the bounded client-tool loop.
- AF-83 structured output remains non-streaming with recursive validation and whole-payload delivery. Prewarm remains a network-free no-op.

## Credential boundary

Credentials are separate from manifest encoding and transcripts. Provider key descriptions, reflection and debug output redact values, including recursive reflection of a constructed cloud session. The production transport uses ephemeral storage, no URL cache, cookies, or credential store, and rejects redirects so authenticated requests cannot forward the key. Injected host transports/sessions are responsible for the same storage policy; `URLSessionStreamTransport` also blocks redirects for injected sessions. No credential lookup or acquisition is performed by the runtime.

The CLI accepts `--adapter automatic|cloud|on-device`, defaulting to automatic. It injects that adapter set into the resolver without rewriting the manifest or send/consume loop. `--prompt-provider-key` requires an interactive terminal, disables echo, clears the temporary input buffer, and keeps the key in memory. Existing host-provided `ANTHROPIC_API_KEY` remains supported during execution; `--dry-run` reads no provider credential and never prompts. The CLI flushes text chunks for incremental display and prints whole structured payloads on the terminal frame.

`--cloud-smoke-test` selects Claude with a 256 output-token limit, sends one fixed short story prompt through the same session consumer, and exits. `SingleRequestCloudTransport` in demo support admits at most one transport call across streaming/non-streaming methods, consuming the budget before suspension, even if the request fails. A tool request cannot lead to a second billed round; that outcome does not satisfy live text acceptance. The owner alone invokes this mode, enters an existing key, and initiates the credential-bearing request. The agent must not open the prompt, capture terminal input, or initiate this mode with credentials. No manifest bytes or public runtime protocol change is involved.

## Verification and acceptance

Run `swift test`, `swift build`, the pinned schema gate and relevant platform builds from the repository root. Focused tests cover overlap/cancellation, incomplete and malformed streams, tool replay, HTTP/SSE/transport diagnostic redaction, provider eligibility, routing order, and the original checked-in manifest through the same session call site with different adapter sets. Production transport checks use local deterministic URL loading; they are not live provider evidence.

1. Given the checked-in story manifest and an owner-supplied in-memory Claude credential, when its cloud candidate is selected and a turn is sent, then a live stream emits start, text chunks, and a successful end. This requires separately recorded live evidence.
2. Given that same manifest and consumer, when the available adapter set changes, then neither manifest bytes nor send/consume code changes.
3. Given provider responses or failures that echo test sentinel values, when errors are surfaced, then diagnostics contain no credential sentinel and no provider body.
4. Given cancellation, an overlapping send, or a truncated stream, when generation finishes, then no false success is committed.

Always preserve iOS 17/macOS 15 floors, AF-78 lifecycle behavior, AF-81 demo semantics, AF-83 output validation, and schema drift checks. Ask before changing the public protocol/event/schema surface. Never hand-edit vendored manifests/schema, persist credentials, or claim mocked responses are live acceptance. Live verification requires owner-controlled secure credential entry and spend authorization; keys must not be sent in chat or acquired by the agent.
