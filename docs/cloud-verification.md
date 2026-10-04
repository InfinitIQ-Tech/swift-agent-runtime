# Cloud adapter verification

AF-80 reuses `ClaudeMessagesAdapter` behind `AgentRuntimeAdapter` and
`AgentSession`. Its implementation contract is
[`features/cloud-adapter/SPEC.md`](../features/cloud-adapter/SPEC.md).
The checked-in story manifest and its public-schema provenance remain unchanged.

## Provider and module decision

The Anthropic Messages API is the implemented cloud provider. AF-80 allows
Claude and/or OpenAI Responses; it does not require both. There is no OpenAI
Responses adapter or Assistants API dependency in this package.

This module supersedes GPTBridge for portable manifest execution. The inspected
GPTBridge client exposes static `appLaunch` credential configuration, Chat
Completions request/event models, and deprecated Assistants thread/run helpers.
Its request manager also prints raw error/decoding bodies. Folding that client
in would require replacing those provider and credential boundaries while
duplicating this runtime's manifest loading, tool policy, shared events, and
structured-output support. AF-80 strengthens the existing Messages adapter;
GPTBridge remains a separate client without changes.

Official Anthropic documentation reviewed on 2026-10-04:

| Source | Applied contract |
|---|---|
| [API overview](https://platform.claude.com/docs/en/api/overview) | Direct endpoint `https://api.anthropic.com/v1/messages`; `x-api-key` remains supported; `anthropic-version: 2023-06-01` and JSON content type. Multi-workspace credentials require a workspace header that this adapter does not configure. |
| [Create a Message](https://platform.claude.com/docs/en/api/messages/create) | Explicit model, `max_tokens`, top-level system instructions, conversation messages, tools, and streaming flag. |
| [Streaming messages](https://platform.claude.com/docs/en/build-with-claude/streaming) | Indexed content blocks, text/partial-JSON deltas, block stops, `message_stop`, in-stream errors, and forward-compatible unknown events. Tool arguments are objects after accumulation. |
| [Handling stop reasons](https://platform.claude.com/docs/en/build-with-claude/handling-stop-reasons) | Context exhaustion, output-token exhaustion and paused turns are incomplete; the adapter emits typed failures rather than successful end frames or automatic paid continuations. |
| [Define tools](https://platform.claude.com/docs/en/agents-and-tools/tool-use/define-tools) | Tool names, descriptions, and JSON `input_schema`. |
| [Structured outputs](https://platform.claude.com/docs/en/build-with-claude/structured-outputs) | `output_config.format` with `type: "json_schema"`; no structured-output beta header. AF-83's portable schema validation remains active. |
| [Model overview](https://platform.claude.com/docs/en/models/overview) | The original manifest's `claude-haiku-4-5` alias is listed. This documentation check does not prove account access or a successful request. |

## Routing and credential boundaries

`single` considers only the first candidate. Fallback uses manifest order,
except that `routing_policy.prefer_on_device: true` stably moves exact
`apple:foundation-models` candidates first. Other candidates retain their
relative order. False/absent leaves the order unchanged; other routing metadata
is preserved. Unrecognized strategies retain the existing fallback behavior.
Availability and construction use the same rule. Selection is fixed for the
session; failures do not trigger provider replay.

Keys enter through `AgentSessionConfiguration.providerKeys` and stay in memory.
The default transport disables persistent storage, cache, and cookies and
rejects redirects. Provider keys redact description/debug/reflection output;
HTTP, SSE, and transport errors do not include untrusted provider messages.
Injected host transports or URL sessions must enforce equivalent safeguards.
Manifest encoding, transcripts, and normal diagnostics are not credential
storage. The host must not put credentials in prompts or tool arguments.

## Deterministic checks

From the runtime repository root, without a provider credential:

```sh
swift test
swift build
scripts/verify-public-schema.sh
scripts/prove-schema-drift.sh
.build/debug/agent-runtime-demo --manifest Manifests/story-companion.agentconfig.json --adapter cloud --dry-run
```

The last command validates the original manifest and reports missing cloud
credentials without looking up keys or starting a request. `--dry-run` ignores
`--prompt-provider-key`. These checks need no AgentFactory, Postgres, sidecar,
or cloud account. Platform builds/UI checks are documented in the README.

Injected transport tests cover streaming and tool rounds, overlap and
cancellation, incomplete/malformed responses, safe errors, candidate routing,
and provider-key redaction. Tests using the original checked-in manifest can
show that adapter injection leaves the manifest and send/consume path unchanged.
They cannot prove live provider access, latency, quality, billing, or streaming
over the public network. Test counts, skips, commands, and revision-specific
results belong in the feature log after execution.

## Owner-run live acceptance

The smallest prerequisite is owner approval for **one invocation up to $0.21
USD before tax**, followed by owner entry of an existing single-workspace API
key that can access the manifest's `claude-haiku-4-5` candidate. Approval covers
one invocation only; a retry requires separate approval. No key should be
supplied in chat, to the coding agent, or through a repository/configuration
file. The agent must not find stored keys, generate credentials, change account
settings, open the secure prompt, or perform the live call. A normal interactive
terminal controlled by the owner is needed; the secure prompt rejects piped
stdin. No Mac UI Automation authorization is required by this CLI procedure.

The `--cloud-smoke-test` mode checks the original manifest's SHA-256 and uses
the cloud adapter even when Foundation Models is available. It sends one fixed
short prompt, caps output at 256 tokens, sets `service_tier: "standard_only"`,
and permits at most one provider request across both streaming and full-response
transport methods. A second request, including a tool continuation, is refused
locally. The original tools remain in the request. The mode always uses hidden
key entry and never reads an environment key; after entry it waits for the owner
to type `SEND` and press Enter before initiating the request. It exits after the one turn and
rejects a conflicting `--adapter on-device` selection.

The price calculation was checked against official documentation on 2026-10-04.
[Haiku 4.5 pricing](https://platform.claude.com/docs/en/about-claude/pricing)
is $1 per million input tokens and $5 per million output tokens. Its client tool
has no separate execution fee; the definition and 496 default tool-system
tokens count toward input usage. The documented
[model context limit](https://platform.claude.com/docs/en/models/overview)
is 200,000 tokens; [context accounting](https://platform.claude.com/docs/en/build-with-claude/context-windows)
includes instructions, tools, conversation, and output. The following deliberately
overcounts that combined context to establish a conservative standard-rate ceiling:

```text
200,000 input tokens × $1 / 1,000,000 = $0.20000
    256 output tokens × $5 / 1,000,000 = $0.00128
One permitted request                   $0.20128
```

Explicit [`standard_only`](https://platform.claude.com/docs/en/api/service-tiers)
avoids the default `auto` selection of existing Priority Tier capacity. This
calculation uses the published direct-API standard prices, excludes tax, and
does not assert an account-specific invoice or custom contractual rate. It
does not authorize another invocation. The general interactive CLI has larger
output and tool-round limits and does not share this smoke-test cost bound.

1. Build the reviewed revision and validate the pinned manifest, without a key:

   ```sh
   git rev-parse HEAD
   swift build
   scripts/verify-public-schema.sh
   shasum -a 256 Manifests/story-companion.agentconfig.json
   .build/debug/agent-runtime-demo --manifest Manifests/story-companion.agentconfig.json --adapter cloud --dry-run
   ```

2. Obtain explicit spend approval for the single bounded invocation described
   above. Only after approval, the owner runs the built executable in an
   interactive terminal:

   ```sh
   .build/debug/agent-runtime-demo --manifest Manifests/story-companion.agentconfig.json --cloud-smoke-test
   ```

   The owner enters the key only at the hidden terminal prompt, then explicitly
   types `SEND` and presses Enter at the request confirmation. The key stays in process memory,
   absent from command arguments and shell history, and is not persisted by the
   runtime. The owner's process sends it over HTTPS directly to Anthropic for
   authentication. The coding agent never enters, captures, handles, or
   transmits the key. Credential entry must not be recorded or logged.

3. The CLI sends its fixed short story prompt. Verify the start line names
   `anthropic:claude-haiku-4-5`, text appears incrementally, and successful
   completion shows `[5 turns remaining]`. The remaining-turn line comes from
   the `end` event; a start line alone is not successful acceptance. A tool
   request cannot trigger a second paid request; the resulting failure is
   unsuccessful acceptance. Truncation, provider errors, or missing completion
   must also be recorded as observed. No automatic or owner retry is covered
   by the first approval.

4. The process exits after the turn. Record the tested Git revision, manifest
   SHA-256, command without credentials, selected candidate, observed streaming,
   completion or typed failure, and timestamp. Capture only ordinary runtime
   output after secure entry; never record request headers, environment dumps,
   credential input, or raw provider bodies. Confirm the checked-in manifest
   is unchanged:

   ```sh
   git diff --exit-code -- Manifests/story-companion.agentconfig.json
   ```

In general interactive mode, `--adapter cloud --prompt-provider-key` and
`--adapter on-device` select different injected adapter sets while using the
same manifest and CLI send loop. The on-device mode needs an eligible device
and no key. This adapter-swap procedure is separate from the smoke test;
general cloud chat requires its own usage authorization and has no one-request
smoke-test bound.

Live AF-80 acceptance remains unverified until the owner-run result is recorded.
Deterministic tests, dry runs, or an available local Foundation Models session
do not satisfy that acceptance criterion. Physical-device airplane-mode
acceptance remains separately tracked in
[AF-84](https://infinitiqtech.atlassian.net/browse/AF-84).
