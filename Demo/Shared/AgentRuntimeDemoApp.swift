import AgentRuntime
import RuntimeDemoSupport
import SwiftUI

@main
struct AgentRuntimeDemoApp: App {
    var body: some Scene {
        WindowGroup {
            DemoRootView()
                #if os(macOS)
                .frame(minWidth: 480, minHeight: 520)
                #endif
        }
        .defaultSize(width: 680, height: 760)
    }
}

struct DemoRootView: View {
    @State private var model: RuntimeDemoModel?
    @State private var loadFailed = false

    private var isSimulation: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--demo-simulation")
        #else
        false
        #endif
    }

    var body: some View {
        Group {
            if let model {
                ChatView(model: model, isSimulation: isSimulation)
            } else if loadFailed {
                ContentUnavailableView(
                    "Manifest unavailable",
                    systemImage: "doc.badge.exclamationmark",
                    description: Text("The bundled agent manifest could not be loaded. Rebuild the demo with its checked-in manifest resource.")
                )
            } else {
                ProgressView("Loading agent…")
            }
        }
        .task {
            guard model == nil, !loadFailed else { return }
            do {
                guard let url = Bundle.main.url(forResource: "story-companion.agentconfig", withExtension: "json") else {
                    loadFailed = true
                    return
                }
                let manifest = try AgentManifestLoader.load(contentsOf: url)
                #if DEBUG
                if isSimulation {
                    let factory = DemoSimulationFactory(
                        unavailableFirst: ProcessInfo.processInfo.arguments.contains("--demo-unavailable-first")
                    )
                    model = RuntimeDemoModel(manifest: manifest, sessionFactory: { manifest, configuration in
                        try await factory.makeSession(manifest: manifest, configuration: configuration)
                    })
                } else {
                    model = RuntimeDemoModel(manifest: manifest)
                }
                #else
                model = RuntimeDemoModel(manifest: manifest)
                #endif
                model?.connect()
            } catch {
                loadFailed = true
            }
        }
    }
}
