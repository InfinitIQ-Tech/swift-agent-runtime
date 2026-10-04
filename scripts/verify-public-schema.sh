#!/usr/bin/env bash
# Verify provenance against the exact public-spec commit, without network access.
# CI checks out the pinned revision; local callers can set SPEC_REPO explicitly.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPEC_REPO="${SPEC_REPO:-$REPO_ROOT/../agent-config-spec}"
REVISION="$(cat "$REPO_ROOT/scripts/public-schema-revision.txt")"

if [[ ! "$REVISION" =~ ^[0-9a-f]{40}$ ]]; then
  echo "error: public-schema-revision.txt must contain a full commit SHA" >&2
  exit 1
fi
if [[ ! -d "$SPEC_REPO/schema" ]]; then
  echo "error: check out InfinitIQ-Tech/agent-config-spec at $REVISION and set SPEC_REPO; external verification must not be skipped" >&2
  exit 1
fi
if [[ "$(git -C "$SPEC_REPO" rev-parse HEAD)" != "$REVISION" ]]; then
  echo "error: agent-config-spec HEAD differs from pinned $REVISION; select that revision or re-sync a reviewed contract" >&2
  exit 1
fi
if [[ -n "$(git -C "$SPEC_REPO" status --porcelain -- schema examples)" ]]; then
  echo "error: agent-config-spec schema/examples have uncommitted changes" >&2
  exit 1
fi

compare() {
  if ! cmp -s "$SPEC_REPO/$1" "$REPO_ROOT/$2"; then
    echo "error: $2 differs from pinned agent-config-spec:$1; run scripts/sync-public-schema.sh" >&2
    exit 1
  fi
}
compare schema/agent-config.v2.schema.json Tests/AgentRuntimeTests/Resources/agent-config.v2.schema.json
compare examples/on-device-story-agent.json Tests/AgentRuntimeTests/Resources/on-device-story-agent.json
compare examples/portable-agent-config.json Tests/AgentRuntimeTests/Resources/portable-agent-config.json
compare examples/on-device-story-agent.json Manifests/story-companion.agentconfig.json
echo "Public schema and examples match InfinitIQ-Tech/agent-config-spec at $REVISION"
