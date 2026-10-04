#!/usr/bin/env bash
# Run the same deterministic runtime + SwiftUI verification locally and in CI.
# Requires Xcode 26+, a macOS host, and an installed iOS Simulator for ios.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLATFORM="${1:-}"
if [[ "$PLATFORM" != macos && "$PLATFORM" != ios ]]; then
  echo "usage: scripts/ci-platform-tests.sh macos|ios" >&2
  exit 2
fi
OUTPUT="${CI_VERIFICATION_DIR:-$REPO_ROOT/.build/ci-verification}/$PLATFORM/$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"
cd "$REPO_ROOT"

run_logged() {
  local label="$1"
  shift
  printf 'Running %s:' "$label"
  printf ' %q' "$@"
  printf '\n'
  "$@" 2>&1 | tee "$OUTPUT/$label.log"
}

DEMO=(-project Demo/AgentRuntimeDemo.xcodeproj -scheme AgentRuntimeDemo)
if [[ "$PLATFORM" == macos ]]; then
  run_logged runtime-build swift build
  run_logged runtime-and-model-tests swift test
  # Ad-hoc signing permits local XCTest launch without a development team.
  SIGNING=(CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES)
  DESTINATION="platform=macOS"
  run_logged demo-release-build xcodebuild "${DEMO[@]}" -configuration Release \
    -destination "$DESTINATION" -derivedDataPath "$OUTPUT/DemoDerivedData" \
    "${SIGNING[@]}" build
else
  if [[ -z "${IOS_SIMULATOR_ID:-}" ]]; then
    xcrun simctl list devices available --json > "$OUTPUT/simulators.json"
    IOS_SIMULATOR_ID="$(python3 - "$OUTPUT/simulators.json" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    inventory = json.load(source)
candidates = []
for runtime, devices in inventory["devices"].items():
    match = re.search(r"\.iOS-(\d+)-(\d+)(?:-(\d+))?$", runtime)
    if not match:
        continue
    version = tuple(int(value or 0) for value in match.groups())
    if version < (17, 0, 0):
        continue
    for device in devices:
        if device.get("isAvailable") and device["name"].startswith("iPhone"):
            candidates.append((version, device["name"], device["udid"]))
if not candidates:
    sys.exit("error: install an iOS 17+ iPhone Simulator runtime before testing")
print(max(candidates)[2])
PY
)"
  fi
  DESTINATION="platform=iOS Simulator,id=$IOS_SIMULATOR_ID"
  # bootstatus also boots a shutdown destination and waits until it is usable.
  run_logged simulator-boot xcrun simctl bootstatus "$IOS_SIMULATOR_ID" -b
  SIGNING=(CODE_SIGNING_ALLOWED=NO)
  run_logged runtime-simulator-build xcodebuild -scheme AgentRuntime \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$OUTPUT/PackageDerivedData" "${SIGNING[@]}" build
  run_logged runtime-and-model-tests xcodebuild -scheme swift-agent-runtime-Package \
    -destination "$DESTINATION" -parallel-testing-enabled NO \
    -derivedDataPath "$OUTPUT/PackageDerivedData" \
    -resultBundlePath "$OUTPUT/PackageTests.xcresult" "${SIGNING[@]}" test
  run_logged demo-release-simulator-build xcodebuild "${DEMO[@]}" -configuration Release \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$OUTPUT/DemoDerivedData" "${SIGNING[@]}" build
  run_logged demo-release-device-build xcodebuild "${DEMO[@]}" -configuration Release \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$OUTPUT/DemoDerivedData" "${SIGNING[@]}" build
fi

# The Debug-only simulated session is selected by the tests themselves. No
# provider key, model download, backend, or live provider request is required.
run_logged demo-ui-tests xcodebuild "${DEMO[@]}" -configuration Debug \
  -destination "$DESTINATION" -parallel-testing-enabled NO \
  -derivedDataPath "$OUTPUT/DemoDerivedData" \
  -resultBundlePath "$OUTPUT/DemoUITests.xcresult" "${SIGNING[@]}" test
echo "PASS: $PLATFORM runtime, demo model, Release app build, and simulated UI tests."
echo "Evidence: $OUTPUT"
