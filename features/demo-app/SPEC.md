# AF-81 — SwiftUI runtime demo and verification

## Scope and source of truth

AF-81 requires a minimal SwiftUI chat app on iOS and macOS, a checked-in portable manifest with no AgentFactory dependency, a pinned public-schema drift gate, and macOS-hosted CI that builds and tests both platforms. The live Jira description was read on 2026-10-04. The company philosophy was reviewed from Confluence page 4292609 (version 1): a demo may be simple, but must be functional and honestly distinguish simulated evidence from provider execution.

The app bundles `Manifests/story-companion.agentconfig.json` directly. Only the existing sync script may update those bytes. Agent name, prompt, model order, tools and turn limits come from this manifest; no runtime protocol or supported schema-version changes are in scope. The existing CLI remains available.

## App behavior

- A checked-in Xcode project links the local AgentRuntime package and shares SwiftUI source between iOS 17 and macOS 15 targets. Foundation Models remains gated at iOS/macOS 26 inside the runtime.
- App startup loads and validates the bundled manifest. A visible unavailable/error state prevents sending until a session can be opened. Retrying availability or starting a new conversation allows recovery.
- Normal execution follows manifest model strategy and routing policy using AgentRuntimeResolver. An optional Anthropic key is entered in a secure field and remains in memory; it is never persisted or shown in errors/logs. No backend endpoint is configured or called.
- The chat shows user messages, streamed assistant text, final responses (including end-only structured turns), tool events, remaining turns, and typed errors. Empty input and concurrent sends are rejected.
- Stop cancels the active operation; reset, disappearance/backgrounding, and reconnect invalidate stale callbacks. Interrupted sessions are discarded before reuse to avoid sharing an adapter whose previous operation is still completing. Repeated send/stop/reset must not allow an old task to change a new conversation.
- The manifest's `save_story` native tool saves only to a visible in-memory demo library. No filesystem persistence is implied. Confirmation-required tools fail closed unless the host explicitly handles confirmation.
- Debug UI verification can inject deterministic runtime sessions with an explicit simulated-mode label; this path makes no model/provider claims and is unavailable in Release builds.

## Verification and acceptance

Given a fresh runtime-only clone, when `swift test` runs, then deterministic runtime and demo-model tests pass without any backend. Given the bundled manifest and an available adapter, when a message is sent, then the SwiftUI app executes that manifest through AgentSession. Unavailable devices receive an actionable state.

Given the pinned schema, when its schema_version is temporarily bumped in an isolated verification fixture, then the real drift test command fails; the clean schema passes. CI verifies the pin and vendored bytes and executes macOS and iOS Simulator builds/tests. README links the existing CI badge; a green hosted result for AF-81 is pending publication approval.

Verification includes build checks for macOS and generic iOS Simulator/device, actual Mac and iOS Simulator UI interaction using deterministic injected sessions, interrupted/repeated interactions and turn exhaustion, full package tests, and independent review. Live model generation and provider-key calls require separate evidence and are not implied by test or UI success.
