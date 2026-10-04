import AgentRuntime
import RuntimeDemoSupport
import SwiftUI

struct ChatView: View {
    @Bindable var model: RuntimeDemoModel
    let isSimulation: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingConnection = false
    @State private var showingLibrary = false
    @State private var providerKey = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                status
                Divider()
                transcript
                Divider()
                composer
            }
            .navigationTitle(model.manifest.config.name)
            .toolbar {
                ToolbarItemGroup {
                    Button("New conversation", systemImage: "plus.bubble") {
                        model.newConversation()
                    }
                    .accessibilityIdentifier("newConversation")
                    Button("Saved stories", systemImage: "books.vertical") {
                        showingLibrary = true
                    }
                    .accessibilityIdentifier("savedStories")
                    Button("Connection", systemImage: "gearshape") {
                        showingConnection = true
                    }
                    .accessibilityIdentifier("connection")
                }
            }
            .sheet(isPresented: $showingConnection, onDismiss: { providerKey = "" }) {
                connection
            }
            .sheet(isPresented: $showingLibrary) {
                library
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.suspend() }
        }
        .onDisappear { model.suspend() }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isSimulation {
                Label("Simulation · no model or network", systemImage: "testtube.2")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("simulationBanner")
            }
            HStack {
                Text(statusText)
                    .font(.subheadline.bold())
                    .accessibilityIdentifier("sessionStatus")
                Spacer()
                if let remaining = model.remainingTurns {
                    Text("\(remaining) turns left")
                        .font(.caption.monospacedDigit())
                        .accessibilityIdentifier("remainingTurns")
                }
            }
            if let label = model.modelLabel {
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.error {
                Text(error.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("sessionError")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4))
    }

    private var statusText: String {
        switch model.state {
        case .notConnected: "Not connected"
        case .connecting: "Connecting…"
        case .ready: "Ready"
        case .sending: "Replying…"
        case .interrupted: "Interrupted · start a new conversation"
        case .unavailable: "Model unavailable · open Connection"
        case .exhausted: "Turn limit reached · start a new conversation"
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if model.messages.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("An agent from one manifest", systemImage: "doc.text")
                                .font(.headline)
                            Text(model.manifest.config.description ?? "A portable agent running without an AgentFactory backend.")
                                .foregroundStyle(.secondary)
                            Text("Send a message to begin. Saved stories stay in memory while this window is open.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 20)
                    }
                    ForEach(model.messages) { message in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(message.role == .user ? "You" : message.role == .tool ? "Tool" : model.manifest.config.name)
                                .font(.caption.bold()).foregroundStyle(.secondary)
                            Text(message.text.isEmpty ? "…" : message.text)
                                .textSelection(.enabled)
                                .accessibilityIdentifier(message.role == .assistant ? "assistantMessage" : "chatMessage")
                            if message.isInterrupted {
                                Text("Interrupted").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(message.role == .user ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding()
            }
            .accessibilityIdentifier("transcript")
            .onChange(of: model.messages) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("Message", text: $model.draft, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("messageInput")
                .onSubmit { model.send() }
            if model.isBusy {
                Button("Stop", systemImage: "stop.fill") { model.stop() }
                    .accessibilityIdentifier("stop")
            } else {
                Button("Send", systemImage: "arrow.up") { model.send() }
                    .disabled(!model.canSend)
                    .accessibilityIdentifier("send")
            }
        }
        .padding()
    }

    private var connection: some View {
        NavigationStack {
            Form {
                Section("Bundled agent") {
                    LabeledContent("Name", value: model.manifest.config.name)
                    LabeledContent("Schema", value: model.manifest.config.schemaVersion)
                    ForEach(model.manifest.config.model.candidates, id: \.name) { candidate in
                        Text(candidate.model).font(.caption).textSelection(.enabled)
                    }
                }
                Section("Connect") {
                    Text("On-device chat requires Apple Intelligence and an available model on iOS 26 or macOS 26. The manifest tries on-device first, then Anthropic when a key is provided.")
                    SecureField("Anthropic API key (optional)", text: $providerKey)
                        .accessibilityIdentifier("providerKey")
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                    Text("The key stays in memory for this window. Connecting starts a new conversation. An empty key reconnects without cloud access.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Connect") {
                        model.connect(providerKey: providerKey)
                        providerKey = ""
                        showingConnection = false
                    }
                    .accessibilityIdentifier("connectSession")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Connection")
            .toolbar {
                ToolbarItem { Button("Done") { showingConnection = false } }
            }
            #if os(macOS)
            .frame(width: 500, height: 500)
            #endif
        }
    }

    private var library: some View {
        NavigationStack {
            List {
                Text("Stories saved by the agent’s save_story tool. This demo library is in memory only.")
                    .font(.callout).foregroundStyle(.secondary)
                if model.savedStories.isEmpty {
                    Text("No saved stories yet.")
                }
                ForEach(model.savedStories) { story in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(story.title).font(.headline)
                        Text(story.body).textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Saved stories")
            .toolbar { ToolbarItem { Button("Done") { showingLibrary = false } } }
            #if os(macOS)
            .frame(width: 500, height: 450)
            #endif
        }
    }
}
