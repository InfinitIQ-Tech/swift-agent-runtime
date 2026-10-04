#!/usr/bin/env bash
# Prove that the real XCTest drift gate rejects an isolated schema bump.
# Vendored resources and the public-schema pin are never modified.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${SCHEMA_DRIFT_LOG_DIR:-$REPO_ROOT/.build/schema-drift-proof}"
SCRATCH_PATH="${SCHEMA_DRIFT_SCRATCH_PATH:-$REPO_ROOT/.build/schema-drift-proof-build}"
mkdir -p "$LOG_DIR"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agent-schema-drift.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT
SOURCE="$REPO_ROOT/Tests/AgentRuntimeTests/Resources/agent-config.v2.schema.json"
BEFORE="$(shasum -a 256 "$SOURCE")"

python3 - "$SOURCE" "$TEMP_DIR/bumped.schema.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    schema = json.load(source)
schema["properties"]["schema_version"]["enum"] = ["__unsupported_schema_drift_probe__"]
with open(sys.argv[2], "w", encoding="utf-8") as target:
    json.dump(schema, target)
    target.write("\n")
PY

cd "$REPO_ROOT"
echo "Running the unmodified public-schema drift suite..."
env -u SCHEMA_DRIFT_TEST_SCHEMA swift test --scratch-path "$SCRATCH_PATH" \
  --filter SchemaDriftTests > "$LOG_DIR/clean.log" 2>&1 || {
  cat "$LOG_DIR/clean.log"
  echo "error: clean drift suite failed; negative proof is invalid" >&2
  exit 1
}

echo "Running the same gate against an isolated unsupported schema_version..."
set +e
SCHEMA_DRIFT_TEST_SCHEMA="$TEMP_DIR/bumped.schema.json" \
  swift test --scratch-path "$SCRATCH_PATH" --skip-build \
  --filter SchemaDriftTests.testVendoredSchemaMatchesRuntimeModels \
  > "$LOG_DIR/bumped.log" 2>&1
STATUS=$?
set -e
if [[ "$STATUS" -eq 0 ]]; then
  cat "$LOG_DIR/bumped.log"
  echo "error: simulated schema bump unexpectedly passed the real drift gate" >&2
  exit 1
fi
if ! grep -q 'schema_version enum drifted' "$LOG_DIR/bumped.log"; then
  cat "$LOG_DIR/bumped.log"
  echo "error: test failed for a reason other than schema-version drift" >&2
  exit 1
fi
if [[ "$(shasum -a 256 "$SOURCE")" != "$BEFORE" ]]; then
  echo "error: vendored schema changed during proof" >&2
  exit 1
fi
echo "PASS: clean drift suite passed; isolated schema bump failed XCTest with exit $STATUS."
echo "Vendored schema SHA-256 unchanged: $BEFORE"
echo "Evidence: $LOG_DIR/clean.log and $LOG_DIR/bumped.log"
