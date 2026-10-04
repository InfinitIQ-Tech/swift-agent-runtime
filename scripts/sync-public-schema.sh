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

if [[ -n "$(git -C "$SPEC_REPO" status --porcelain -- schema examples)" ]]; then
  echo "error: commit public schema/example changes in InfinitIQ-Tech/agent-config-spec before syncing" >&2
  exit 1
fi
REVISION="$(git -C "$SPEC_REPO" rev-parse HEAD)"
for SOURCE in schema/agent-config.v2.schema.json examples/on-device-story-agent.json examples/portable-agent-config.json; do
  git -C "$SPEC_REPO" cat-file -e "$REVISION:$SOURCE"
done
git -C "$SPEC_REPO" show "$REVISION:schema/agent-config.v2.schema.json" > "$REPO_ROOT/Tests/AgentRuntimeTests/Resources/agent-config.v2.schema.json"
git -C "$SPEC_REPO" show "$REVISION:examples/on-device-story-agent.json" > "$REPO_ROOT/Tests/AgentRuntimeTests/Resources/on-device-story-agent.json"
git -C "$SPEC_REPO" show "$REVISION:examples/portable-agent-config.json" > "$REPO_ROOT/Tests/AgentRuntimeTests/Resources/portable-agent-config.json"
git -C "$SPEC_REPO" show "$REVISION:examples/on-device-story-agent.json" > "$REPO_ROOT/Manifests/story-companion.agentconfig.json"
printf '%s\n' "$REVISION" > "$REPO_ROOT/scripts/public-schema-revision.txt"

echo "Vendored public schema and examples synced from $SPEC_REPO at $REVISION"
"$REPO_ROOT/scripts/verify-public-schema.sh"
echo "Run 'swift test --filter SchemaDriftTests' to verify the runtime still matches."
