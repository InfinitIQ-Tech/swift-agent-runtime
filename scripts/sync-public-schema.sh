#!/usr/bin/env bash
# Re-vendors the public AgentConfig JSON Schema and example manifests from the
# sibling spec-repo checkout (InfinitIQ-Tech/agent-config-spec). This script is
# the only sanctioned write path for the vendored copies.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPEC_REPO="${SPEC_REPO:-$REPO_ROOT/../agent-config-spec}"

if [[ ! -d "$SPEC_REPO/schema" ]]; then
  echo "error: spec repo not found at $SPEC_REPO (set SPEC_REPO to override)" >&2
  exit 1
fi

cp "$SPEC_REPO/schema/agent-config.v2.schema.json" "$REPO_ROOT/Tests/AgentRuntimeTests/Resources/agent-config.v2.schema.json"
cp "$SPEC_REPO/examples/on-device-story-agent.json" "$REPO_ROOT/Tests/AgentRuntimeTests/Resources/on-device-story-agent.json"
cp "$SPEC_REPO/examples/portable-agent-config.json" "$REPO_ROOT/Tests/AgentRuntimeTests/Resources/portable-agent-config.json"
cp "$SPEC_REPO/examples/on-device-story-agent.json" "$REPO_ROOT/Manifests/story-companion.agentconfig.json"

echo "Vendored public schema and examples synced from $SPEC_REPO"
echo "Run 'swift test --filter SchemaDriftTests' to verify the runtime still matches."
