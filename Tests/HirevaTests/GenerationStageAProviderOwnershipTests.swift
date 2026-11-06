import Foundation
import Testing
import os
@testable import Hireva

@MainActor
struct GenerationStageAProviderOwnershipTests {
    @Test(.timeLimit(.minutes(1)))
    func ownedStreamUsesTheSameFrozenServiceRequestAsBeforeMigration() async throws {
        let database = try await TestSupport.makeInMemoryDatabase()
        let settings = SettingsRepository(database: database)
        let client = OwnedStageAClient()
        let service = SuggestionGenerationService(llmRouter: LLMRouter(settingsRepository: settings, clients: [.deepSeek: client]))
        let owner = GenerationCoordinator(dependencies: .init(suggestionGenerationService: service))
        let input = makeInput(model: "synthetic-original", generationID: "reference-generation")
        var reference: Task<String, Error>?
        var owned: Task<String, Error>?
        do {
            // Capture the real pre-migration service call, rather than mirror
            // prompt creation or invent an expected provider message.
            let stream = try await service.generateFastSayFirstStream(question: input.question,
                context: input.providerContext, cvSummary: input.cv, jdSummary: input.jd,
                customProviderConfig: input.configuration)
            let referenceTask = Task { var value = ""; for try await token in stream { value += token }; return value }
            reference = referenceTask
            _ = try await client.nextStarted()
            client.emit("reference", model: input.configuration.model)
            client.finish(model: input.configuration.model)
            #expect(try await joinedValue(referenceTask) == "reference")
            var replacement = input.configuration
            replacement.id = UUID()
            replacement.model = "synthetic-settings-replacement"
            try settings.saveProviderConfiguration(replacement)
            try settings.setActiveRealtimeProvider(id: replacement.id)
            owner.activate(identity: input.context.identity, persistenceTicket: 0,
                triggerPath: .manualGenerate, startedAt: input.context.startedAt,
                providerConfiguration: input.configuration)
            let observations = OwnedStageAObservations()
            let pending = try #require(launch(owner, input: input, observations: observations))
            owned = pending
            #expect(try await client.nextStarted() == input.configuration.model)
            client.emit("owned", model: input.configuration.model)
            client.finish(model: input.configuration.model)
            #expect(try await joinedValue(pending) == "owned")
            let calls = client.calls
            try #require(calls.count == 2)
            #expect(calls[0] == calls[1])
            #expect(calls[1].configuration.model == "synthetic-original")
            #expect(calls[1].options.temperature == 0.1)
            #expect(calls[1].options.stream)
            #expect(observations.completed == ["owned"])
            #expect(observations.exitCount == 1)
            owner.clearStageATask(generationID: input.context.generationID)
            await owner.drainRetiredTasks()
            #expect(owner.pendingCleanupTaskCount == 0)
            client.finishAll()
            try database.close()
        } catch {
            reference?.cancel(); owned?.cancel(); client.finishAll()
            _ = await reference?.result; _ = await owned?.result
            _ = await owner.shutdownAndDrain()
            try? database.close()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: Array(0..<20))
    func actualOwnedStreamsRejectLateOutputAcrossTwentyJoinedInterleavings(order: Int) async throws {
        // Five kinds repeated four times; they are not twenty independent
        // performance samples. Each round owns its DB/service/task handles.
        let database = try await TestSupport.makeInMemoryDatabase()
        let settings = SettingsRepository(database: database)
        let client = OwnedStageAClient()
        let service = SuggestionGenerationService(llmRouter: LLMRouter(settingsRepository: settings, clients: [.deepSeek: client]))
        let owner = GenerationCoordinator(dependencies: .init(suggestionGenerationService: service))
        let oldInput = makeInput(model: "old-\(order)", generationID: "old-generation-\(order)")
        let newInput = makeInput(model: "new-\(order)", generationID: order % 5 == 2 ? oldInput.context.generationID : "new-generation-\(order)")
        let oldObservations = OwnedStageAObservations()
        let newObservations = OwnedStageAObservations()
        var old: Task<String, Error>?
        var replacement: Task<String, Error>?
        do {
            owner.activate(identity: oldInput.context.identity, persistenceTicket: 0,
                triggerPath: .manualGenerate, startedAt: oldInput.context.startedAt)
            let requiredOldStream: Task<String, Error> = try #require(launch(owner, input: oldInput, observations: oldObservations))
            old = requiredOldStream
            if order % 5 != 1 { #expect(try await client.nextStarted() == oldInput.configuration.model) }
            if order % 5 == 3 {
                owner.markTerminal(generationID: oldInput.context.generationID)
                client.emit("late terminal token", model: oldInput.configuration.model)
                client.finish(model: oldInput.configuration.model)
                _ = await old?.result
                #expect(oldObservations.rejectedCount == 1)
            }
            if order % 5 == 4 {
                owner.closeAdmission()
                #expect(launch(owner, input: newInput, observations: newObservations) == nil)
                client.emit("late closed token", model: oldInput.configuration.model)
                client.finish(model: oldInput.configuration.model)
                _ = await old?.result
                await owner.drainRetiredTasks()
                #expect(newObservations.startedCount == 0)
                #expect(owner.pendingCleanupTaskCount == 0)
            } else {
                owner.activate(identity: newInput.context.identity, persistenceTicket: 0,
                    triggerPath: .manualGenerate, startedAt: newInput.context.startedAt)
                let newTask = try #require(launch(owner, input: newInput, observations: newObservations))
                replacement = newTask
                #expect(try await client.nextStarted() == newInput.configuration.model)
                client.emit("late old token", model: oldInput.configuration.model)
                client.finish(model: oldInput.configuration.model)
                _ = await old?.result
                #expect(owner.isCurrent(newInput.context.identity))
                #expect(newTask.isCancelled == false)
                client.emit("new answer", model: newInput.configuration.model)
                client.finish(model: newInput.configuration.model)
                #expect(try await joinedValue(newTask) == "new answer")
                #expect(newObservations.tokens == ["new answer"])
                #expect(newObservations.completed == ["new answer"])
                owner.clearStageATask(generationID: newInput.context.generationID)
                await owner.drainRetiredTasks()
                #expect(owner.pendingCleanupTaskCount == 0)
            }
            #expect(oldObservations.tokens.isEmpty)
            #expect(oldObservations.completed.isEmpty)
            #expect(oldObservations.exitCount == 1)
            client.finishAll()
            try database.close()
        } catch {
            old?.cancel(); replacement?.cancel(); client.finishAll()
            _ = await old?.result; _ = await replacement?.result
            _ = await owner.shutdownAndDrain()
            try? database.close()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func actualApplicationProjectionPublishesThroughLiveOwnerAndJoinsItsTask() async throws {
        let suite = "StageAApplicationProjection-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = try await TestSupport.makeInMemoryDatabase()
        let settings = SettingsRepository(database: database)
        let client = OwnedStageAClient()
        let app = AppState(database: database, questionRoutingProvider: HermeticQuestionRoutingProvider(),
            llmRouter: LLMRouter(settingsRepository: settings, clients: [.deepSeek: client]),
            permissionService: HermeticPermissionService(), keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            dialogueDefaults: defaults)
        var pending: Task<String, Error>?
        do {
            let session = try app.sessionRepository.createSession(mode: .mock)
            app.currentSession = session
            let input = makeInput(model: "synthetic-ui", generationID: "application-projection", session: session)
            app.activateGeneration(question: input.question, generationID: input.context.generationID,
                triggerPath: .manualGenerate, requestStart: input.context.startedAt, source: nil, speaker: nil)
            let trigger = StageBTrigger()
            let task = try #require(app.launchProviderFirstAnswer(context: input.context,
                providerQuestion: input.question, providerContext: input.providerContext,
                cvSummary: input.cv, jdSummary: input.jd, providerConfiguration: input.configuration, trigger: trigger))
            pending = task
            #expect(try await client.nextStarted() == input.configuration.model)
            let answer = "A database transaction applies the writes atomically: every operation commits together, or a failure rolls back every change."
            client.emit(answer, model: input.configuration.model)
            client.finish(model: input.configuration.model)
            #expect(try await joinedValue(task) == answer)
            #expect(app.liveInterview.streamedSayFirst == answer)
            #expect(app.streamedSayFirst == app.liveInterview.streamedSayFirst)
            #expect(app.streamFirstTokenAt != nil)
            #expect(app.streamFirstVisibleTextAt != nil)
            #expect(app.streamFullResponseAt != nil)
            #expect(app.generationCoordinator.stageATask != nil)
            // Completion also releases this exact Stage B trigger without
            // starting a new timer; no Stage B provider is invoked in this case.
            await trigger.wait(timeoutMs: 500)
            app.clearStageATask(generationID: input.context.generationID)
            await app.generationCoordinator.drainRetiredTasks()
            #expect(app.generationCoordinator.pendingCleanupTaskCount == 0)
            await app.shutdownForTesting()
            client.finishAll()
            try database.close()
        } catch {
            pending?.cancel(); client.finishAll(); _ = await pending?.result
            await app.shutdownForTesting()
            try? database.close()
            throw error
        }
    }

    private func joinedValue(_ task: Task<String, Error>) async throws -> String {
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private struct Input {
        let context: GenerationExecutionContext
        let question: DetectedQuestion
        let providerContext: RetrievedContext
        let configuration: LLMProviderConfiguration
        let cv: String
        let jd: String
    }
    private func makeInput(model: String, generationID: String,
        session: InterviewSession? = nil) -> Input {
        let session = session ?? InterviewSession(id: "synthetic-stage-a-session", title: "Synthetic Stage A",
            company: nil, role: nil, startedAt: Date(), endedAt: nil, mode: .mock, createdAt: Date())
        let question = DetectedQuestion(id: "question-" + model, sessionID: session.id, transcriptSegmentID: nil,
            questionText: "Explain database transactions and atomicity.", intent: .technical, answerStrategy: .directAnswer,
            confidence: 1, reason: "Synthetic ownership regression", shouldTrigger: true, questionComplete: true,
            modelName: "fixture", promptVersion: "fixture", createdAt: Date())
        let providerContext = RetrievedContext(cvChunks: [], jobDescriptionChunks: [])
        let configuration = LLMProviderConfiguration.deepSeekDefault(model: model)
        let snapshot = PromptContextBuilder.promptSnapshot(question: question, context: providerContext,
            transcriptContext: "", cvSummary: "None provided.", jdSummary: "None provided.", stage: .firstAnswer)
        // No InterviewContextSnapshot is invented here: the complete identity
        // variation is the new question, including the same-generation-ID case.
        let context = GenerationExecutionContext(session: session, question: question, generationID: generationID,
            triggerPath: .manualGenerate, providerID: configuration.id.uuidString, providerModel: model,
            retrievedContext: providerContext, promptSnapshot: snapshot, transcriptSnapshot: "", startedAt: Date(),
            source: nil, speaker: nil)
        return .init(context: context, question: question, providerContext: providerContext, configuration: configuration,
            cv: "None provided.", jd: "None provided.")
    }
    private func launch(_ owner: GenerationCoordinator, input: Input, observations: OwnedStageAObservations) -> Task<String, Error>? {
        owner.launchStageAFirstAnswer(context: input.context, providerQuestion: input.question,
            providerContext: input.providerContext, cvSummary: input.cv, jdSummary: input.jd,
            providerConfiguration: input.configuration, onStarted: { _ in observations.startedCount += 1 },
            onToken: { _, _, collected in observations.tokens.append(collected); return true },
            onCompleted: { _, value in observations.completed.append(value); return value },
            onRejected: { _ in observations.rejectedCount += 1 }, onExit: { observations.exitCount += 1 })
    }
}

@MainActor
private final class OwnedStageAObservations {
    var startedCount = 0
    var rejectedCount = 0
    var exitCount = 0
    var tokens: [String] = []
    var completed: [String] = []
}

private struct OwnedStageACall: Equatable, Sendable {
    let configuration: LLMProviderConfiguration
    let messages: [LLMChatMessage]
    let responseFormat: LLMResponseFormat?
    let options: LLMRequestOptions
}

// The fake owns stream continuations, not producer Tasks. All mutable state is
// protected by one lock; yields/finish happen outside it, with no lock over await.
private final class OwnedStageAClient: LLMClientProtocol, Sendable {
    let providerKind: LLMProviderKind = .deepSeek
    private struct State: Sendable {
        var calls: [OwnedStageACall] = []
        var continuations: [String: AsyncThrowingStream<String, Error>.Continuation] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let starts = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingOldest(4))
    var calls: [OwnedStageACall] { state.withLock { $0.calls } }
    func chatCompletionStream(configuration: LLMProviderConfiguration, messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?, options: LLMRequestOptions) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            state.withLock {
                $0.calls.append(.init(configuration: configuration, messages: messages, responseFormat: responseFormat, options: options))
                $0.continuations[configuration.model] = continuation
            }
            starts.continuation.yield(configuration.model)
        }
    }
    func emit(_ token: String, model: String) {
        let continuation = state.withLock { $0.continuations[model] }
        continuation?.yield(token)
    }
    func finish(model: String) {
        let continuation = state.withLock { $0.continuations.removeValue(forKey: model) }
        continuation?.finish()
    }
    func finishAll() {
        let continuations = state.withLock { state in
            let values = Array(state.continuations.values); state.continuations.removeAll(); return values
        }
        continuations.forEach { $0.finish() }
        starts.continuation.finish()
    }
    func nextStarted() async throws -> String {
        try await TestEventWaitTrace(label: "coordinator.stage_a.provider")
            .nextEvent(in: starts.stream, event: "actual_service_started")
    }
    func testConnection(configuration: LLMProviderConfiguration) async throws -> LLMConnectionTestResult {
        .init(success: true, message: "Synthetic", latencyMS: 0, models: [])
    }
    func chatCompletion(configuration: LLMProviderConfiguration, messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?, options: LLMRequestOptions) async throws -> LLMChatResult {
        throw LLMProviderError.notConfigured("Non-streaming synthetic client")
    }
    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] { [] }
}
