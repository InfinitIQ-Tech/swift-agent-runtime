# Agent Working Rules — swift-agent-runtime

## What this repository is

The public Swift runtime for the open AgentConfig format (AF-73 epic). It
executes portable `AgentConfig` manifests on-device via Apple Foundation
Models or via the Anthropic Messages API behind one runtime protocol. The
AgentFactory-owned contract for this lane lives in
`AgentFactory/features/swift-agent-runtime/SPEC.md` (sibling checkout at
`../AgentFactory`); the schema contract lives in `../agent-config-spec`.

## Boundaries

- **Always**: keep the package platform floors at iOS 17 / macOS 15; gate all
  Foundation Models API behind `@available(iOS 26.0, macOS 26.0, *)`; keep
  local manifest execution free of any AgentFactory network call; keep
  `SchemaDriftTests` green.
- **Ask first**: any change to the supported `schema_version` set, the
  `AgentStreamEvent` frame contract, or the public protocol surface consumed
  by apps (DreamHero depends on it).
- **Never**: hand-edit the vendored schema or example manifests (use
  `scripts/sync-public-schema.sh`); put provider keys in manifests, logs,
  fixtures, or persisted state; depend on `AgentFactoryDTO` (it imports Vapor
  and cannot link on iOS).

## Commands

```sh
swift build
swift test
xcodebuild -scheme AgentRuntime -destination "generic/platform=iOS Simulator" build
swift run agent-runtime-demo --manifest Manifests/story-companion.agentconfig.json --dry-run
scripts/sync-public-schema.sh   # re-vendor schema + examples from ../agent-config-spec
```
