# Foundation Models verification (AF-78)

## Evidence scopes

| Check | Establishes | Does not establish |
|---|---|---|
| Unit tests with injected Foundation Models operations | Runtime event ordering, limits, lifecycle, selection and errors | Live model execution or offline operation |
| Debug `--demo-simulation` UI suites | SwiftUI rendering and interaction | Foundation Models output |
| iOS Simulator/device SDK builds | Compilation and link compatibility | Physical-device execution |
| CLI conversation naming `apple:foundation-models`, without provider keys | Live on-device generation from the local manifest | Owner-operated airplane-mode acceptance |
| Physical iOS conversation with Airplane Mode on and Wi-Fi off | Offline acceptance on that device and installed model | Other device/model availability |

## Local Mac check

From the runtime repository, on a Mac with Apple Intelligence enabled and model assets ready:

```sh
env -u ANTHROPIC_API_KEY swift run agent-runtime-demo \
  --manifest Manifests/story-companion.agentconfig.json
```

The output must identify `apple:foundation-models`; `Runtime availability: available`
alone is insufficient. Send “Tell a two-sentence story about a robot finding a seed.
Do not save it.” and then “What did the robot find? Reply in one sentence.”
Record actual output and remaining turns. The original manifest allows six admitted
turns; the seventh is rejected with `maxTurnsExceeded`. Its bytes remain owned by
`scripts/sync-public-schema.sh`.

`swift test` covers streaming disabled with the same adapter lifecycle and verifies
that there are no `chunk` frames. A separate temporary copy of the manifest with
only `runtime.streaming` changed to `false` can verify live end-only output; label
that evidence as a variant and retain the original artifact hash.

The CLI does not register the app's native `save_story` handler. Use the SwiftUI
app for native story-library testing; avoid requesting a save during the CLI check.

## Owner-operated offline acceptance

1. Use an Apple Intelligence-capable physical iPhone/iPad running iOS/iPadOS 26 or
   later with Apple Intelligence enabled and model assets already downloaded.
2. Open `Demo/AgentRuntimeDemo.xcodeproj`, choose `AgentRuntimeDemo`, select the
   physical device, and use the owner's existing development signing team. Build
   and install using Xcode. Signing, trust, Developer Mode, or authentication
   prompts must be completed by the owner; credentials are never supplied to automation.
3. Launch without `--demo-simulation` and without an Anthropic key. Confirm the app
   connects through the bundled Story Companion manifest. Record app revision,
   manifest hash, device model, OS/build, and initial availability.
4. On that device only, the owner turns on Airplane Mode and turns Wi-Fi off.
   Bluetooth need not be changed. Keep the remotely operated execution Mac online.
5. Start a new conversation. Send the robot/seed request and follow-up above, and
   verify a real response, continuity, and remaining turns. Continue short benign
   turns to exhaust all six slots; verify a seventh cannot run. Optionally request
   a save in an earlier turn and inspect the app's in-memory Saved stories list.
6. Record screenshots or a screen recording that show device offline state, the
   real app without the Simulation label, generated output, and turn exhaustion.
   Restore the owner's preferred connectivity after recording.

The unavailability path is also acceptable behavior on an ineligible/not-ready
host, but it does not satisfy the offline-generation acceptance criterion. Record
the exact reason and retry only after the owner resolves it. Do not claim the
airplane-mode criterion passed based on builds, injected output, or an online Mac.

## API references (checked 2026-10-04)

- [Generating content and performing tasks with Foundation Models](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models)
- [LanguageModelSession](https://developer.apple.com/documentation/foundationmodels/languagemodelsession)
- [SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel)

The runtime targets the iOS 26 GA `SystemLanguageModel` and
`LanguageModelSession.GenerationError` APIs. Later API additions in current
Apple documentation do not raise this package's availability gates.
