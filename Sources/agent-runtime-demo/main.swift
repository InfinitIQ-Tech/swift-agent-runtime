import AgentRuntime
import Foundation

// Minimal manifest-driven chat demo. Everything the agent is comes from the
// checked-in AgentConfig manifest; no backend, no deployment, no tenant.
//
//   swift run agent-runtime-demo --manifest Manifests/story-companion.agentconfig.json --dry-run
//   swift run agent-runtime-demo --manifest Manifests/story-companion.agentconfig.json
//   ANTHROPIC_API_KEY=sk-... swift run agent-runtime-demo --manifest ...
//
// Adapter selection follows the manifest's model.candidates: on-device
// Foundation Models when available (macOS 26 with Apple Intelligence),
// otherwise the Anthropic cloud adapter when a key is supplied.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

var manifestPath: String?
var dryRun = false
var arguments = ArraySlice(CommandLine.arguments.dropFirst())
while let argument = arguments.popFirst() {
    switch argument {
    case "--manifest":
        manifestPath = arguments.popFirst()
    case "--dry-run":
        dryRun = true
    case "--help", "-h":
        print("usage: agent-runtime-demo --manifest <path> [--dry-run]")
        exit(0)
    default:
        fail("unknown argument \(argument)")
    }
}

guard let manifestPath else {
    fail("--manifest <path> is required")
}

let manifest: AgentManifest
do {
    manifest = try AgentManifestLoader.load(contentsOf: URL(fileURLWithPath: manifestPath))
} catch {
    fail("manifest failed to load: \(error)")
}

let config = manifest.config
print("Loaded agent \"\(config.name)\" (\(config.id) \(config.version), schema_version \(config.schemaVersion))")
print("Model candidates: \(config.model.candidates.map(\.model).joined(separator: ", "))")

var keys = ProviderKeys()
if let anthropicKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] {
    keys[ProviderKeys.anthropicProvider] = anthropicKey
}
let configuration = AgentSessionConfiguration(
    providerKeys: keys,
    confirmToolExecution: { call in
        print("\n[tool \(call.toolId) requests confirmation — auto-approving for demo]")
        return true
    }
)

let availability = AgentRuntimeResolver.availability(manifest: manifest, configuration: configuration)
print("Runtime availability: \(availability)")

if dryRun {
    print("Dry run complete: manifest is valid and round-trip safe.")
    exit(0)
}

guard availability.isAvailable else {
    fail("no adapter available — run on a Foundation Models device or set ANTHROPIC_API_KEY")
}

let session: any AgentSession
do {
    session = try AgentRuntimeResolver.makeSession(manifest: manifest, configuration: configuration)
} catch {
    fail("could not open session: \(error)")
}

print("Type a message (ctrl-d to exit).")
runLoop: while true {
    print("\n> ", terminator: "")
    guard let line = readLine(), !line.isEmpty else { break }

    let events = await session.send(line)
    do {
        for try await event in events {
            switch event {
            case .start(let start):
                print("[turn \(start.turn) on \(start.model)]")
            case .chunk(let delta):
                print(delta, terminator: "")
            case .toolCall(let call):
                print("\n[tool call: \(call.toolId)]")
            case .toolResult(let result):
                print("[tool result: \(result.toolId) success=\(result.success)]")
            case .end(let result):
                if !manifest.config.runtime.streaming {
                    print(result.text, terminator: "")
                }
                print("")
                if let remaining = result.remainingTurns {
                    print("[\(remaining) turns remaining]")
                }
            }
        }
    } catch AgentRuntimeError.maxTurnsExceeded(let limit) {
        print("\n[max_turns (\(limit)) reached — session complete]")
        break runLoop
    } catch {
        fail("turn failed: \(error)")
    }
}
