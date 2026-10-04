import AgentRuntime
import Foundation
import Testing
@testable import RuntimeDemoSupport

private actor ControlledSession: AgentSession {
    nonisolated let manifest: AgentManifest
    private(set) var prewarmCalls = 0
    private(set) var cancelCalls = 0
    private(set) var inputs: [String] = []
    private let holdPrewarm: Bool
    private let holdSend: Bool
    private var prewarmContinuation: CheckedContinuation<Void, Never>?
    private var sendContinuation: CheckedContinuation<Void, Never>?
    private var streams: [AsyncThrowingStream<AgentStreamEvent, Error>.Continuation] = []

    init(manifest: AgentManifest, holdPrewarm: Bool = false, holdSend: Bool = false) {
        self.manifest = manifest
        self.holdPrewarm = holdPrewarm
        self.holdSend = holdSend
    }
    func prewarm() async {
        prewarmCalls += 1
        if holdPrewarm { await withCheckedContinuation { prewarmContinuation = $0 } }
    }
    func releasePrewarm() { prewarmContinuation?.resume(); prewarmContinuation = nil }
    func send(_ text: String) async -> AsyncThrowingStream<AgentStreamEvent, Error> {
        inputs.append(text)
        let (stream, continuation) = AsyncThrowingStream<AgentStreamEvent, Error>.makeStream()
        streams.append(continuation)
        if holdSend { await withCheckedContinuation { sendContinuation = $0 } }
        return stream
    }
    func releaseSend() { sendContinuation?.resume(); sendContinuation = nil }
    // Intentionally uncooperative: cancellation does not terminate generation or
    // prewarming, so tests can release late work after a reset.
    func cancel() { cancelCalls += 1 }
    func transcript() -> [AgentMessage] { [] }
    func turnsUsed() -> Int { inputs.count }
    func emit(_ event: AgentStreamEvent, turn: Int? = nil) { streams[turn ?? (streams.count - 1)].yield(event) }
    func finish(_ error: (any Error)? = nil, turn: Int? = nil) { streams[turn ?? (streams.count - 1)].finish(throwing: error) }
}

private actor ControlledFactory {
    private var sessions: [ControlledSession]
    private let holdCreation: Bool
    private let failFirst: Bool
    private var waiting: [CheckedContinuation<any AgentSession, any Error>] = []
    private(set) var configurations: [AgentSessionConfiguration] = []
    private(set) var manifests: [AgentManifest] = []

    init(_ sessions: [ControlledSession], holdCreation: Bool = false, failFirst: Bool = false) {
        self.sessions = sessions
        self.holdCreation = holdCreation
        self.failFirst = failFirst
    }
    func make(_ manifest: AgentManifest, _ configuration: AgentSessionConfiguration) async throws -> any AgentSession {
        manifests.append(manifest)
        configurations.append(configuration)
        if failFirst, configurations.count == 1 { throw AgentRuntimeError.modelUnavailable(.missingProviderKey(provider: "anthropic")) }
        if holdCreation { return try await withCheckedThrowingContinuation { waiting.append($0) } }
        return sessions.removeFirst()
    }
    func release(_ session: ControlledSession) { waiting.removeFirst().resume(returning: session) }
    func reject(_ error: any Error) { waiting.removeFirst().resume(throwing: error) }
}

@Suite @MainActor
struct RuntimeDemoModelTests {
    private func manifest(limit: Int? = 3, streaming: Bool = true, requiresConfirmation: Bool = false) throws -> AgentManifest {
        let config = AgentConfig(
            id: "model_test", name: "Manifest-owned name", version: "test", schemaVersion: "2",
            systemPrompt: "Manifest-owned prompt", runtime: AgentRuntimeConfig(streaming: streaming, maxTurns: limit),
            model: AgentModelConfig(strategy: "fallback", candidates: [AgentModelCandidate(name: "test", model: "test:model")]),
            tools: AgentToolsConfig(allowed: ["save_story"], definitions: [
                ToolDefinition(name: "save_story", description: "Save", parameters: ["type": .string("object")])
            ], toolPolicy: AgentToolPolicy(requireUserConfirmation: requiresConfirmation ? ["save_story"] : []))
        )
        return try AgentManifestLoader.load(JSONEncoder().encode(config))
    }

    private func eventually(_ condition: @MainActor () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()) {
            if ContinuousClock.now > deadline {
                Issue.record("Timed out waiting for controlled asynchronous work", sourceLocation: sourceLocation)
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private func ready(limit: Int? = 3, streaming: Bool = true) async throws -> (RuntimeDemoModel, ControlledSession, ControlledFactory) {
        let manifest = try manifest(limit: limit, streaming: streaming)
        let session = ControlledSession(manifest: manifest)
        let factory = ControlledFactory([session])
        let model = RuntimeDemoModel(manifest: manifest, sessionFactory: factory.make)
        model.connect()
        try await eventually { model.state == .ready }
        return (model, session, factory)
    }

    private func begin(_ model: RuntimeDemoModel, _ session: ControlledSession, text: String = "hello", count: Int = 1) async throws {
        model.draft = text
        model.send()
        try await eventually { await session.inputs.count == count }
    }

    @Test func initialStateComesFromManifestAndRejectsEmptyOrDisconnectedSend() throws {
        let manifest = try manifest(limit: 7)
        let model = RuntimeDemoModel(manifest: manifest)
        #expect(model.manifest == manifest)
        #expect(model.remainingTurns == 7)
        #expect(model.state == .notConnected)
        model.draft = "hello"
        model.send()
        #expect(model.messages.isEmpty)
        #expect(!model.canSend)
    }

    @Test func connectPassesExactManifestAndEphemeralCredentials() async throws {
        let manifest = try manifest()
        let session = ControlledSession(manifest: manifest)
        let factory = ControlledFactory([session])
        let model = RuntimeDemoModel(manifest: manifest, sessionFactory: factory.make)
        model.connect(providerKey: "  secret-key  ")
        try await eventually { model.state == .ready }
        #expect(await factory.manifests == [manifest])
        let configuration = try #require(await factory.configurations.first)
        #expect(configuration.providerKeys[ProviderKeys.anthropicProvider] == "secret-key")
        #expect(configuration.confirmToolExecution == nil)
        #expect(!String(describing: configuration.providerKeys).contains("secret-key"))
        #expect(await session.prewarmCalls == 1)
        model.draft = " \n "
        model.send()
        #expect(model.messages.isEmpty)
        #expect(!model.canSend)
    }

    @Test func streamingToolEventsAndAuthoritativeFinalText() async throws {
        let (model, session, _) = try await ready()
        try await begin(model, session, text: "  hello  ")
        #expect(await session.inputs == ["hello"])
        #expect(model.draft.isEmpty)
        #expect(model.messages.first?.text == "hello")
        await session.emit(.start(AgentTurnStart(turn: 1, candidate: "test", model: "test:model")))
        await session.emit(.chunk("partial "))
        await session.emit(.chunk("answer"))
        await session.emit(.toolCall(AgentToolCall(toolId: "save_story", args: [:])))
        await session.emit(.toolResult(AgentToolResult(toolId: "save_story", output: "saved", success: true)))
        try await eventually { model.messages.count == 4 }
        #expect(model.messages[1].text == "partial answer")
        #expect(model.modelLabel == "test:model")
        #expect(model.remainingTurns == 2)
        #expect(model.messages[2].role == .tool)
        #expect(model.messages[3].text.contains("saved"))
        await session.emit(.end(AgentTurnResult(text: "authoritative answer", remainingTurns: 2)))
        try await eventually { model.messages[1].text == "authoritative answer" }
        #expect(model.state == .sending) // Wait for the adapter to close its stream.
        await session.finish()
        try await eventually { model.state == .ready }
    }

    @Test func endOnlyStructuredResponseAndUnlimitedTurns() async throws {
        let (model, session, _) = try await ready(limit: nil, streaming: false)
        try await begin(model, session)
        let json = "{\"reply\":\"A gentle story\"}"
        await session.emit(.end(AgentTurnResult(text: json, structured: .object(["reply": .string("A gentle story")]))))
        await session.finish()
        try await eventually { model.state == .ready }
        #expect(model.messages[1].text == json)
        #expect(model.remainingTurns == nil)
    }

    @Test func concurrentSendsAreRejectedAndTerminalTurnLimitDisablesSending() async throws {
        let (model, session, _) = try await ready(limit: 1)
        try await begin(model, session)
        model.draft = "another"
        model.send()
        #expect(await session.inputs.count == 1)
        #expect(model.messages.count == 2)
        #expect(!model.canSend)
        await session.emit(.end(AgentTurnResult(text: "done")))
        await session.finish()
        try await eventually { model.state == .exhausted }
        #expect(model.remainingTurns == 0)
        model.send()
        #expect(await session.inputs.count == 1)
    }

    @Test func repeatedCompletedSendsUseSameSessionAndTrackManifestLimit() async throws {
        let (model, session, _) = try await ready(limit: 3)
        for turn in 1...3 {
            try await begin(model, session, text: "turn \(turn)", count: turn)
            await session.emit(.end(AgentTurnResult(text: "answer \(turn)")))
            await session.finish()
            try await eventually { model.state != .sending }
            #expect(model.remainingTurns == 3 - turn)
        }
        #expect(model.messages.count == 6)
        #expect(model.state == .exhausted)
        #expect(await session.prewarmCalls == 1)
    }

    @Test func missingTerminalEventIsAnInterruptedFailure() async throws {
        let (model, session, _) = try await ready()
        try await begin(model, session)
        await session.emit(.chunk("partial"))
        await session.finish()
        try await eventually { model.state == .interrupted }
        #expect(model.error?.kind == .response)
        #expect(model.messages[1].isInterrupted)
        #expect(!model.canSend)
        try await eventually { await session.cancelCalls == 1 }
    }

    @Test func turnLimitRuntimeErrorIsPresentedWithoutPayload() async throws {
        let (model, session, _) = try await ready()
        try await begin(model, session)
        await session.finish(AgentRuntimeError.maxTurnsExceeded(limit: 3))
        try await eventually { model.state == .exhausted }
        #expect(model.remainingTurns == 0)
        #expect(model.error?.kind == .turnLimit)
    }

    @Test func unavailableConnectionCanRetry() async throws {
        let manifest = try manifest()
        let session = ControlledSession(manifest: manifest)
        let factory = ControlledFactory([session], failFirst: true)
        let unavailable = RuntimeDemoModel(manifest: manifest, sessionFactory: factory.make)
        unavailable.connect()
        try await eventually { unavailable.state == .unavailable }
        #expect(unavailable.error?.kind == .unavailable)
        #expect(unavailable.error?.message.contains("Anthropic") == true)
        #expect(!unavailable.canSend)
        unavailable.connect(providerKey: "retry")
        #expect(unavailable.error == nil)
        try await eventually { unavailable.state == .ready }
        #expect(await factory.configurations.last?.providerKeys[ProviderKeys.anthropicProvider] == "retry")
        #expect(unavailable.error == nil)
    }

    @Test func stopPreservesInterruptedDisplayButCannotReuseSession() async throws {
        let (model, session, _) = try await ready()
        try await begin(model, session)
        await session.emit(.chunk("partial"))
        try await eventually { model.messages[1].text == "partial" }
        model.stop()
        model.stop()
        #expect(model.state == .interrupted)
        #expect(model.messages[1].isInterrupted)
        #expect(model.messages[1].text == "partial")
        model.draft = "cannot continue old session"
        model.send()
        await session.emit(.end(AgentTurnResult(text: "stale reply", remainingTurns: 0)))
        await session.finish()
        try await eventually { await session.cancelCalls == 1 }
        #expect(await session.inputs.count == 1)
        #expect(model.messages[1].text == "partial")
        #expect(model.state == .interrupted)
    }

    @Test func resetDiscardsOldSessionAndIgnoresItsDelayedEvents() async throws {
        let manifest = try manifest()
        let old = ControlledSession(manifest: manifest)
        let fresh = ControlledSession(manifest: manifest)
        let factory = ControlledFactory([old, fresh])
        let model = RuntimeDemoModel(manifest: manifest, sessionFactory: factory.make)
        model.connect(providerKey: "ephemeral")
        try await eventually { model.state == .ready }
        try await begin(model, old)
        model.newConversation()
        try await eventually { model.state == .ready }
        #expect(model.messages.isEmpty)
        #expect(model.remainingTurns == 3)
        #expect(model.modelLabel == nil)
        #expect(await factory.configurations.last?.providerKeys[ProviderKeys.anthropicProvider] == "ephemeral")
        await old.emit(.start(AgentTurnStart(turn: 3, candidate: "stale", model: "stale:model")))
        await old.emit(.end(AgentTurnResult(text: "stale", remainingTurns: 0)))
        await old.finish(AgentRuntimeError.generationFailed("late failure"))
        try await begin(model, fresh, text: "new conversation")
        await fresh.emit(.end(AgentTurnResult(text: "fresh")))
        await fresh.finish()
        try await eventually { model.state == .ready }
        #expect(model.messages.map(\.text) == ["new conversation", "fresh"])
        #expect(model.error == nil)
        #expect(model.remainingTurns == 2)
        try await eventually { await old.cancelCalls == 1 }
    }

    @Test func staleCreationIsCancelledBeforePrewarming() async throws {
        let manifest = try manifest()
        let old = ControlledSession(manifest: manifest)
        let fresh = ControlledSession(manifest: manifest)
        let factory = ControlledFactory([], holdCreation: true)
        let model = RuntimeDemoModel(manifest: manifest, sessionFactory: factory.make)
        model.connect()
        try await eventually { await factory.configurations.count == 1 }
        model.newConversation()
        try await eventually { await factory.configurations.count == 2 }
        await factory.release(old)
        try await eventually { await old.cancelCalls == 1 }
        #expect(await old.prewarmCalls == 0)
        #expect(model.state == .connecting)
        await factory.release(fresh)
        try await eventually { model.state == .ready }
        #expect(await fresh.prewarmCalls == 1)
    }

    @Test func sameTurnStopPreventsSessionSendFromStarting() async throws {
        let (model, session, _) = try await ready()
        model.draft = "must not reach provider"
        model.send()
        model.stop()
        try await eventually { await session.cancelCalls == 1 }
        #expect(await session.inputs.isEmpty)
        #expect(model.state == .interrupted)
    }

    @Test func sameTurnResetPreventsSessionSendFromStarting() async throws {
        let manifest = try manifest()
        let old = ControlledSession(manifest: manifest)
        let fresh = ControlledSession(manifest: manifest)
        let factory = ControlledFactory([old, fresh])
        let model = RuntimeDemoModel(manifest: manifest, sessionFactory: factory.make)
        model.connect()
        try await eventually { model.state == .ready }
        model.draft = "must not reach provider"
        model.send()
        model.newConversation()
        try await eventually { model.state == .ready }
        #expect(await old.inputs.isEmpty)
        #expect(await fresh.inputs.isEmpty)
        #expect(model.messages.isEmpty)
        #expect(model.error == nil)
    }

    @Test func repeatedResetAndDelayedCreationDoNotCrossConversations() async throws {
        let manifest = try manifest()
        let factory = ControlledFactory([], holdCreation: true)
        let model = RuntimeDemoModel(manifest: manifest, sessionFactory: factory.make)
        for count in 1...8 {
            model.newConversation()
            try await eventually { await factory.configurations.count == count }
        }
        for _ in 1...7 {
            let discarded = ControlledSession(manifest: manifest)
            await factory.release(discarded)
            try await eventually { await discarded.cancelCalls == 1 }
            #expect(await discarded.prewarmCalls == 0)
            #expect(model.state == .connecting)
        }
        let fresh = ControlledSession(manifest: manifest)
        await factory.release(fresh)
        try await eventually { model.state == .ready }
        #expect(await fresh.cancelCalls == 0)
        #expect(model.messages.isEmpty)
    }

    @Test func staleCreationFailureCannotOverwriteNewConnection() async throws {
        let manifest = try manifest()
        let factory = ControlledFactory([], holdCreation: true)
        let model = RuntimeDemoModel(manifest: manifest, sessionFactory: factory.make)
        model.connect()
        try await eventually { await factory.configurations.count == 1 }
        model.newConversation()
        try await eventually { await factory.configurations.count == 2 }
        await factory.reject(AgentRuntimeError.generationFailed("stale error"))
        let fresh = ControlledSession(manifest: manifest)
        await factory.release(fresh)
        try await eventually { model.state == .ready }
        #expect(model.error == nil)
    }

    @Test func stopDuringPrewarmingCannotReadyDiscardedSession() async throws {
        let manifest = try manifest()
        let session = ControlledSession(manifest: manifest, holdPrewarm: true)
        let model = RuntimeDemoModel(manifest: manifest) { _, _ in session }
        model.connect()
        try await eventually { await session.prewarmCalls == 1 }
        model.stop()
        await session.releasePrewarm()
        try await eventually { await session.cancelCalls == 1 }
        #expect(model.state == .interrupted)
        #expect(!model.canSend)
    }

    @Test func stopWhileAwaitingSendDoesNotResurrectConversation() async throws {
        let manifest = try manifest()
        let session = ControlledSession(manifest: manifest, holdSend: true)
        let model = RuntimeDemoModel(manifest: manifest) { _, _ in session }
        model.connect()
        try await eventually { model.state == .ready }
        try await begin(model, session)
        model.stop()
        await session.emit(.end(AgentTurnResult(text: "too late")))
        await session.finish()
        await session.releaseSend()
        try await eventually { await session.cancelCalls == 1 }
        #expect(model.state == .interrupted)
        #expect(model.messages[1].text.isEmpty)
        #expect(model.messages[1].isInterrupted)
    }

    @Test func backgroundDiscardsReadySessionAndResetMakesFreshOne() async throws {
        let manifest = try manifest()
        let old = ControlledSession(manifest: manifest)
        let fresh = ControlledSession(manifest: manifest)
        let factory = ControlledFactory([old, fresh])
        let model = RuntimeDemoModel(manifest: manifest, sessionFactory: factory.make)
        model.connect()
        try await eventually { model.state == .ready }
        model.suspend()
        model.suspend()
        #expect(model.state == .interrupted)
        model.newConversation()
        try await eventually { model.state == .ready }
        try await eventually { await old.cancelCalls == 1 }
        #expect(await fresh.prewarmCalls == 1)
    }

    @Test func inMemorySaveStorySurvivesResetAndRejectsStaleToolHandler() async throws {
        let manifest = try manifest()
        let old = ControlledSession(manifest: manifest)
        let fresh = ControlledSession(manifest: manifest)
        let factory = ControlledFactory([old, fresh])
        let model = RuntimeDemoModel(manifest: manifest, sessionFactory: factory.make)
        model.connect()
        try await eventually { model.state == .ready }
        try await begin(model, old)
        let configuration = try #require(await factory.configurations.first)
        let save = try #require(configuration.toolHandlers["save_story"])
        let output = try await save(["title": .string("Dream"), "body": .string("A gentle story")])
        #expect(output.contains("in-memory"))
        #expect(model.savedStories.map(\.title) == ["Dream"])
        model.newConversation()
        try await eventually { model.state == .ready }
        #expect(model.savedStories.map(\.body) == ["A gentle story"])
        await #expect(throws: AgentRuntimeError.cancelled) {
            try await save(["title": .string("Stale"), "body": .string("Must not be saved")])
        }
        #expect(model.savedStories.count == 1)
        await old.finish()
    }

    @Test func saveStoryRejectsInvalidArguments() async throws {
        let (model, session, factory) = try await ready()
        try await begin(model, session)
        let config = try #require(await factory.configurations.first)
        let save = try #require(config.toolHandlers["save_story"])
        await #expect(throws: AgentRuntimeError.self) { try await save(["title": .string(" ")]) }
        #expect(model.savedStories.isEmpty)
        model.stop()
        await session.finish()
    }

    @Test func confirmationRequiredByManifestFailsClosedInDemoConfiguration() async throws {
        let manifest = try manifest(requiresConfirmation: true)
        let session = ControlledSession(manifest: manifest)
        let factory = ControlledFactory([session])
        let model = RuntimeDemoModel(manifest: manifest, sessionFactory: factory.make)
        model.connect()
        try await eventually { model.state == .ready }
        try await begin(model, session)
        let configuration = try #require(await factory.configurations.first)
        let engine = ToolExecutionEngine(toolbox: AgentToolbox.resolve(config: manifest.config), configuration: configuration)
        let results = await engine.execute([AgentToolCall(toolId: "save_story", args: ["title": .string("Story"), "body": .string("Body")])])
        #expect(results.count == 1)
        #expect(results.first?.success == false)
        #expect(results.first?.output.contains("confirmation") == true)
        #expect(model.savedStories.isEmpty)
        model.stop()
        await session.finish()
    }

    @Test func credentialsNeverAppearInProviderErrorsOrPresentedResponses() async throws {
        let manifest = try manifest()
        let session = ControlledSession(manifest: manifest)
        let model = RuntimeDemoModel(manifest: manifest) { _, _ in session }
        model.connect(providerKey: "private-secret")
        try await eventually { model.state == .ready }
        try await begin(model, session)
        await session.emit(.chunk("Echo private-secret"))
        try await eventually { model.messages[1].text.contains("redacted") }
        await session.finish(AgentRuntimeError.generationFailed("Authorization private-secret"))
        try await eventually { model.state == .interrupted }
        #expect(model.error?.kind == .generation)
        #expect(model.error?.message.contains("private-secret") == false)
        #expect(!model.messages.contains { $0.text.contains("private-secret") })
    }

    @Test func safeErrorTaxonomySuppressesAllArbitraryDetails() {
        let cases: [(any Error, DemoFailure.Kind)] = [
            (AgentRuntimeError.modelUnavailable(.other("secret")), .unavailable),
            (AgentRuntimeError.guardrailViolation, .guardrail),
            (AgentRuntimeError.contextWindowExceeded, .contextWindow),
            (AgentRuntimeError.cancelled, .cancelled),
            (CancellationError(), .cancelled),
            (AgentRuntimeError.generationFailed("secret"), .generation),
            (AgentRuntimeError.maxTurnsExceeded(limit: 3), .turnLimit),
            (AgentRuntimeError.toolNotAllowed("secret"), .tool),
            (AgentRuntimeError.toolNotRegistered("secret"), .tool),
            (AgentRuntimeError.invalidProviderResponse("secret"), .response),
            (AgentRuntimeError.unsupportedOutputFormat("secret"), .output),
            (AgentRuntimeError.structuredOutputInvalid("secret"), .output),
            (AgentRuntimeError.noUsableModelCandidate, .unavailable),
            (NSError(domain: "secret", code: 1), .generation)
        ]
        for (error, kind) in cases {
            let presentation = DemoFailure.from(error)
            #expect(presentation.kind == kind)
            #expect(!presentation.message.contains("secret"))
        }
    }
}
