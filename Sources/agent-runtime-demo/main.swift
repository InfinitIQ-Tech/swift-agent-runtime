import AgentRuntime
import RuntimeDemoSupport
import CryptoKit
import Foundation
import Darwin

// Minimal manifest-driven chat demo. Everything the agent is comes from the
// checked-in AgentConfig manifest; no backend, no deployment, no tenant.
//
//   swift run agent-runtime-demo --manifest Manifests/story-companion.agentconfig.json --dry-run
//   swift run agent-runtime-demo --manifest Manifests/story-companion.agentconfig.json
//   swift run agent-runtime-demo --manifest ... --adapter cloud --prompt-provider-key
//
// Adapter selection follows the manifest's model.candidates: on-device
// Foundation Models when available (macOS 26 with Apple Intelligence),
// otherwise the Anthropic cloud adapter when a key is supplied.

var smokeStatus: CloudSmokeStatus?

@MainActor
func fail(_ message: String, category: CloudSmokeStatus.Failure = .configuration) -> Never {
    smokeStatus?.record(.failed, failure: category)
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

var manifestPath: String?
var dryRun = false
var adapterChoice = "automatic"
var promptProviderKey = false
var cloudSmokeTest = false
var smokeStatusPath: String?
var arguments = ArraySlice(CommandLine.arguments.dropFirst())
while let argument = arguments.popFirst() {
    switch argument {
    case "--manifest":
        manifestPath = arguments.popFirst()
    case "--dry-run":
        dryRun = true
    case "--adapter":
        guard let value = arguments.popFirst(), ["automatic", "cloud", "on-device"].contains(value) else {
            fail("--adapter requires automatic, cloud, or on-device")
        }
        adapterChoice = value
    case "--prompt-provider-key":
        promptProviderKey = true
    case "--cloud-smoke-test":
        cloudSmokeTest = true
    case "--smoke-status-file":
        guard let value = arguments.popFirst() else { fail("--smoke-status-file requires a path") }
        smokeStatusPath = value
    case "--help", "-h":
        print("usage: agent-runtime-demo --manifest <path> [--dry-run] [--adapter automatic|cloud|on-device] [--prompt-provider-key] [--cloud-smoke-test] [--smoke-status-file <path>]")
        exit(0)
    default:
        fail("unknown argument \(argument)")
    }
}

if let smokeStatusPath {
    guard cloudSmokeTest, !dryRun else { fail("--smoke-status-file requires a non-dry cloud smoke test") }
    do { smokeStatus = try CloudSmokeStatus(path: smokeStatusPath) }
    catch { fail("smoke status file could not be created") }
}

// Process-level cancellation is opt-in to the owner-run smoke flow. The
// handler restores terminal attributes and records only a fixed outcome.
let smokeInterruptHandler = cloudSmokeTest && !dryRun
    ? CloudSmokeInterruptHandler(status: smokeStatus)
    : nil

guard let manifestPath else {
    fail("--manifest <path> is required")
}

let manifest: AgentManifest
do {
    let data = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
    if cloudSmokeTest {
        // The published cost ceiling is valid only for this exact pinned
        // Haiku manifest, with its original prompt/tools and no server tools.
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == "b8b521d2b48b5f69dab463302e4447498d45516db56f67b3c94048fd6b689733" else {
            fail("--cloud-smoke-test requires the unchanged checked-in story manifest")
        }
        guard adapterChoice != "on-device" else {
            fail("--cloud-smoke-test cannot use --adapter on-device")
        }
        adapterChoice = "cloud"
    }
    manifest = try AgentManifestLoader.load(data)
} catch {
    fail("manifest failed to load: \(error)")
}

let config = manifest.config
print("Loaded agent \"\(config.name)\" (\(config.id) \(config.version), schema_version \(config.schemaVersion))")
print("Model candidates: \(config.model.candidates.map(\.model).joined(separator: ", "))")

var keys = ProviderKeys()
if (promptProviderKey || cloudSmokeTest) && !dryRun {
    // Read from the controlling terminal with echo disabled. Never accept a
    // key as an argument, place it in shell history, or print it.
    guard isatty(STDIN_FILENO) == 1 else {
        fail("secure key entry requires an interactive terminal", category: .credentialEntry)
    }
    smokeStatus?.record(.credentialEntryRequested)
    do {
        keys[ProviderKeys.anthropicProvider] = try readSecureProviderKey()
        guard let enteredKey = keys[ProviderKeys.anthropicProvider],
              !enteredKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail("no provider key entered", category: .credentialEntry)
        }
    } catch SecureKeyReaderError.inputTooLong {
        fail("provider key input is too long", category: .credentialEntry)
    } catch SecureKeyReaderError.interrupted {
        smokeInterruptHandler?.finishInterruptedRead()
        fail("provider key entry cancelled", category: .cancelled)
    } catch SecureKeyReaderError.invalidEncoding {
        fail("provider key input is not valid UTF-8", category: .credentialEntry)
    } catch {
        fail("secure key entry requires an interactive terminal", category: .credentialEntry)
    }
    if cloudSmokeTest {
        print("Type SEND to send the request, or anything else to exit: ", terminator: "")
        fflush(stdout)
        smokeStatus?.record(.awaitingSend)
        errno = 0
        let confirmation = readLine()
        if confirmation == nil && errno == EINTR {
            smokeInterruptHandler?.finishInterruptedRead()
            fail("request confirmation cancelled", category: .cancelled)
        }
        guard confirmation == "SEND" else {
            smokeStatus?.record(.ownerDeclined)
            exit(0)
        }
    }
} else if !dryRun, let anthropicKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] {
    keys[ProviderKeys.anthropicProvider] = anthropicKey
}
let adapters: [any AgentRuntimeAdapter]
switch adapterChoice {
case "cloud":
    let smokeTransport: any HTTPStreamTransport = smokeStatus.map {
        SingleRequestCloudTransport(transport: ObservedCloudSmokeTransport(status: $0))
    } ?? SingleRequestCloudTransport()
    adapters = cloudSmokeTest
        ? [ClaudeMessagesAdapter(maxTokens: 256, transport: smokeTransport)]
        : [ClaudeMessagesAdapter()]
case "on-device": adapters = [FoundationModelsAdapter()]
default: adapters = AgentRuntimeResolver.defaultAdapters()
}
let configuration = AgentSessionConfiguration(
    providerKeys: keys,
    confirmToolExecution: { call in
        print("\n[tool \(call.toolId) requests confirmation — auto-approving for demo]")
        return true
    }
)

let availability = AgentRuntimeResolver.availability(manifest: manifest, configuration: configuration, adapters: adapters)
print("Runtime availability: \(availability)")

if dryRun {
    print("Dry run complete: manifest is valid and round-trip safe.")
    exit(0)
}

guard availability.isAvailable else {
    fail("no adapter available — use an eligible Foundation Models device or --prompt-provider-key for cloud", category: .unavailable)
}

let session: any AgentSession
do {
    session = try AgentRuntimeResolver.makeSession(manifest: manifest, configuration: configuration, adapters: adapters)
} catch {
    fail("could not open session: \(error)", category: .classify(error))
}

if !cloudSmokeTest { print("Type a message (ctrl-d to exit).") }
runLoop: while true {
    let line: String
    if cloudSmokeTest {
        line = "Tell a gentle two-sentence bedtime story about a moon rabbit. Do not save it or use tools."
        print("\n> \(line)")
    } else {
        print("\n> ", terminator: "")
        fflush(stdout)
        guard let input = readLine(), !input.isEmpty else { break }
        line = input
    }

    let events = await session.send(line)
    do {
        try await consumeDemoTurn(events, status: smokeStatus) { event in
            switch event {
            case .start(let start):
                print("[turn \(start.turn) on \(start.model)]")
            case .chunk(let delta):
                print(delta, terminator: "")
                fflush(stdout)
            case .toolCall(let call):
                print("\n[tool call: \(call.toolId)]")
            case .toolResult(let result):
                print("[tool result: \(result.toolId) success=\(result.success)]")
            case .end(let result):
                if !manifest.config.runtime.streaming || manifest.config.output != nil {
                    print(result.text, terminator: "")
                }
                print("")
                if let remaining = result.remainingTurns {
                    print("[\(remaining) turns remaining]")
                }
            }
        }
    } catch AgentRuntimeError.maxTurnsExceeded(let limit) {
        if cloudSmokeTest {
            fail("cloud smoke turn limit reached", category: .turnLimit)
        }
        smokeStatus?.record(.failed, failure: .turnLimit)
        print("\n[max_turns (\(limit)) reached — session complete]")
        break runLoop
    } catch {
        fail("turn failed: \(error)", category: .classify(error))
    }
    if cloudSmokeTest { break }
}
