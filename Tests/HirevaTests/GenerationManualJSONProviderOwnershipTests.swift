import Foundation
import Testing
@testable import Hireva

/// New-API ownership characterization, applied only with its provider-owner
/// patch. This file is not a pre-migration red test; the separate Manual RAG
/// cancellation regression invokes the unchanged production entry.
@MainActor
struct GenerationManualJSONProviderOwnershipTests {
    @Test(.timeLimit(.minutes(1)))
    func ownedJSONChildUsesTheActualServiceAndFrozenProtocolArguments() async throws {
        let db = try AppDatabase(inMemory: true)
        let repository = SettingsRepository(database: db)
        let transport = ManualOwnedJSONClient()
        let service = SuggestionGenerationService(llmRouter: LLMRouter(settingsRepository: repository,
            clients: [.deepSeek: transport]))
        let owner = GenerationCoordinator(dependencies: .init(suggestionGenerationService: service))
        let input = makeInput(generation: "manual-parity", model: "synthetic-manual-original")
        var reference: Task<(card: SuggestionCard, response: LLMChatResult), Error>?
        var owned: Task<(card: SuggestionCard, response: LLMChatResult), Error>?
        do {
            let original = Task { try await service.generate(question: input.context.question,
                context: input.context.retrievedContext, transcriptContext: input.context.transcriptSnapshot,
                sessionID: input.context.session.id, timeoutInterval: 12,
                customProviderConfig: input.configuration, interviewContextSnapshot: nil) }
            reference = original
            #expect(try await next(transport) == 1)
            await transport.gate.release(1)
            let originalOutput = try await original.value
            var later = input.configuration
            later.id = UUID(); later.model = "synthetic-replacement-model"
            try repository.saveProviderConfiguration(later)
            try repository.setActiveRealtimeProvider(id: later.id)
            activate(owner, input: input)
            let childAwaiter = Task { try await owner.generateManualSuggestion(context: input.context,
                providerConfiguration: input.configuration, timeoutInterval: 12) }
            owned = childAwaiter
            #expect(try await next(transport) == 2)
            #expect(owner.activeGeneration?.manualProviderTask != nil)
            #expect(owner.pendingCleanupTaskCount == 1)
            await transport.gate.release(2)
            let ownedOutput = try await childAwaiter.value
            let calls = await transport.gate.calls()
            try #require(calls.count == 2)
            #expect(calls[0] == calls[1])
            #expect(calls[1].configuration == input.configuration)
            #expect(calls[1].format == .jsonObject)
            #expect(calls[1].options.temperature == 0.2)
            #expect(calls[1].options.timeoutInterval == 12)
            #expect(!calls[1].options.stream)
            #expect(ownedOutput.card.sayFirst == originalOutput.card.sayFirst)
            #expect(ownedOutput.card.questionID == input.context.question.id)
            #expect(ownedOutput.card.promptPrimaryQuestion == input.context.promptPrimaryQuestion)
            #expect(ownedOutput.response == originalOutput.response)
            #expect(owner.activeGeneration?.manualProviderTask == nil)
            await owner.drainRetiredTasks()
            #expect(owner.pendingCleanupTaskCount == 0)
            await transport.gate.releaseAll()
            try db.close()
        } catch {
            reference?.cancel(); owned?.cancel()
            await transport.gate.releaseAll()
            _ = await reference?.result; _ = await owned?.result
            _ = await owner.shutdownAndDrain()
            try? db.close()
            throw error
        }
    }

    @Test(.serialized, .timeLimit(.minutes(1)), arguments: 0..<20)
    func cancelledOrOldJSONChildCannotReturnOrClearTheNextRegistration(order: Int) async throws {
        // Five deterministic orderings, four joined executions each.
        do {
            let db = try AppDatabase(inMemory: true)
            let transport = ManualOwnedJSONClient()
            let service = SuggestionGenerationService(llmRouter: LLMRouter(
                settingsRepository: SettingsRepository(database: db), clients: [.deepSeek: transport]))
            let owner = GenerationCoordinator(dependencies: .init(suggestionGenerationService: service))
            let input = makeInput(generation: "manual-old-\(order)", model: "manual-old-model-\(order)",
                snapshotID: "old-manual-snapshot-\(order)")
            var old: Task<(card: SuggestionCard, response: LLMChatResult), Error>?
            var replacement: Task<(card: SuggestionCard, response: LLMChatResult), Error>?
            do {
                activate(owner, input: input)
                let first = Task { try await owner.generateManualSuggestion(context: input.context,
                    providerConfiguration: input.configuration, timeoutInterval: 12) }
                old = first
                #expect(try await next(transport) == 1)
                let firstChild = try #require(owner.activeGeneration?.manualProviderTask)
                var newInput: Input?
                switch order % 5 {
                case 0:
                    // The awaiting parent is cancelled. The actual child must
                    // be cancelled even though this transport ignores it.
                    first.cancel()
                case 1:
                    // A same-identity terminal fence alone denies publication.
                    owner.markTerminal(generationID: input.context.generationID)
                case 2:
                    let nextInput = makeInput(generation: "manual-new-\(order)", model: "manual-new-model-\(order)")
                    activate(owner, input: nextInput)
                    newInput = nextInput
                case 3:
                    // Reuse the generation ID with a different complete context.
                    // An old cleanup is not allowed to clear this new registration.
                    let nextInput = makeInput(generation: input.context.generationID,
                        model: "manual-new-context-model-\(order)", snapshotID: "new-manual-snapshot-\(order)")
                    activate(owner, input: nextInput)
                    newInput = nextInput
                default:
                    // Same complete generation identity, different actual
                    // provider registration. Cleanup must use registrationID.
                    var configuration = input.configuration
                    configuration.model = "manual-same-identity-new-model-\(order)"
                    newInput = Input(context: input.context, configuration: configuration)
                }
                if let newInput {
                    replacement = Task { try await owner.generateManualSuggestion(context: newInput.context,
                        providerConfiguration: newInput.configuration, timeoutInterval: 12) }
                    #expect(try await next(transport) == 2)
                    let nextChild = try #require(owner.activeGeneration?.manualProviderTask)
                    #expect(!nextChild.isCancelled)
                    await transport.gate.release(1)
                    #expect(await rejected(first))
                    #expect(owner.activeGeneration?.manualProviderTask != nil)
                    #expect(!nextChild.isCancelled)
                    await transport.gate.release(2)
                    let nextTask = try #require(replacement)
                    let result = try await nextTask.value
                    #expect(result.response.modelName == newInput.configuration.model)
                    #expect(result.card.questionID == newInput.context.question.id)
                } else {
                    await transport.gate.release(1)
                    #expect(await rejected(first))
                    if order % 5 == 0 { #expect(firstChild.isCancelled) }
                }
                #expect(owner.activeGeneration?.manualProviderTask == nil)
                await owner.drainRetiredTasks()
                #expect(owner.pendingCleanupTaskCount == 0)
                await transport.gate.releaseAll()
                try db.close()
            } catch {
                old?.cancel(); replacement?.cancel()
                await transport.gate.releaseAll()
                _ = await old?.result; _ = await replacement?.result
                _ = await owner.shutdownAndDrain()
                try? db.close()
                throw error
            }
        }
    }

    private struct Input { let context: GenerationExecutionContext; let configuration: LLMProviderConfiguration }
    private func makeInput(generation: String, model: String, snapshotID: String? = nil) -> Input {
        let date = Date(timeIntervalSince1970: 1)
        var session = InterviewSession(id: "synthetic-manual-json-session", title: "Synthetic JSON ownership",
            company: nil, role: nil, startedAt: date, endedAt: nil, mode: .mock, createdAt: date)
        session.contextSnapshotID = snapshotID
        let snapshot = snapshotID.map { InterviewContextSnapshot(id: $0, sessionID: session.id,
            candidateProfileID: nil, candidateProfileVersion: nil, opportunityContextID: nil,
            opportunityContextVersion: nil, domainProfileID: InterviewDomainID.general.rawValue,
            candidateEvidence: [], opportunityEvidence: [], createdAt: date) }
        let question = DetectedQuestion(id: "question-" + generation, sessionID: session.id,
            transcriptSegmentID: nil, questionText: "Explain database transactions and atomicity.",
            intent: .technical, answerStrategy: .directAnswer, confidence: 1, reason: "Synthetic owner characterization",
            shouldTrigger: true, questionComplete: true, modelName: model, promptVersion: "synthetic",
            rawJSON: nil, createdAt: date)
        var configuration = LLMProviderConfiguration.deepSeekDefault(model: model)
        configuration.createdAt = date; configuration.updatedAt = date
        let context = GenerationExecutionContext.make(session: session, question: question,
            generationID: generation, triggerPath: .manualCapture, provider: configuration,
            retrievedContext: .init(cvChunks: [], jobDescriptionChunks: []), transcriptSnapshot: "",
            cvSummary: "", jdSummary: "", startedAt: date, source: .mock, speaker: .unknown, stage: .jsonCard,
            interviewContextSnapshot: snapshot)
        return Input(context: context, configuration: configuration)
    }
    private func activate(_ owner: GenerationCoordinator, input: Input) {
        owner.activate(identity: input.context.identity, persistenceTicket: 0, triggerPath: .manualCapture,
            startedAt: input.context.startedAt, providerConfiguration: input.configuration, answerProviderMode: .deepSeekPrimary)
    }
    private func next(_ client: ManualOwnedJSONClient) async throws -> Int {
        try await TestEventWaitTrace(label: "manual-json-provider").nextEvent(in: client.gate.started.stream, event: "provider-entered")
    }
    private func rejected(_ task: Task<(card: SuggestionCard, response: LLMChatResult), Error>) async -> Bool {
        switch await task.result {
        case .success: return false
        case .failure(let error): return error is CancellationError
        }
    }
}

private final class ManualOwnedJSONClient: LLMClientProtocol, Sendable {
    let providerKind: LLMProviderKind = .deepSeek
    let gate = ManualOwnedJSONGate()
    func testConnection(configuration: LLMProviderConfiguration) async throws -> LLMConnectionTestResult { throw CancellationError() }
    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] { throw CancellationError() }
    func chatCompletion(configuration: LLMProviderConfiguration, messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?, options: LLMRequestOptions) async throws -> LLMChatResult {
        await gate.hold(.init(configuration: configuration, messages: messages, format: responseFormat, options: options))
        return .init(content: "{\"strategy\":\"Direct Answer\",\"say_first\":\"A transaction commits all its changes atomically or rolls them all back. Isolation controls which concurrent changes it observes.\",\"key_points\":[\"Commit or roll back every operation together.\"],\"follow_up_ready\":[],\"confidence\":1,\"caution\":null,\"evidence_used\":[],\"risk_level\":\"low\"}",
            modelName: configuration.model, providerKind: .deepSeek, providerName: configuration.name,
            baseURL: configuration.baseURL, latencyMS: 0, isLocal: false, rawResponse: nil)
    }
    func chatCompletionStream(configuration: LLMProviderConfiguration, messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?, options: LLMRequestOptions) -> AsyncThrowingStream<String, Error> {
        Issue.record("Manual JSON ownership unexpectedly requested a stream")
        return AsyncThrowingStream { $0.finish(throwing: CancellationError()) }
    }
}

private actor ManualOwnedJSONGate {
    struct Call: Equatable, Sendable {
        let configuration: LLMProviderConfiguration
        let messages: [LLMChatMessage]
        let format: LLMResponseFormat?
        let options: LLMRequestOptions
    }
    nonisolated let started = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingOldest(2))
    private var captured: [Call] = []
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var released = Set<Int>()
    private var closed = false
    func calls() -> [Call] { captured }
    func hold(_ call: Call) async {
        captured.append(call)
        let ordinal = captured.count
        started.continuation.yield(ordinal)
        if !closed && !released.contains(ordinal) { await withCheckedContinuation { waiters[ordinal] = $0 } }
    }
    func release(_ ordinal: Int) { released.insert(ordinal); waiters.removeValue(forKey: ordinal)?.resume() }
    func releaseAll() {
        closed = true
        let held = Array(waiters.values); waiters.removeAll()
        held.forEach { $0.resume() }
        started.continuation.finish()
    }
}
