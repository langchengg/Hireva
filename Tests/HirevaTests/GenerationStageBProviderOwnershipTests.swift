import Foundation
import Testing
import os
@testable import Hireva

@MainActor
struct GenerationStageBProviderOwnershipTests {
    private static let answer = "A database transaction groups operations into an atomic unit. Atomicity means every operation commits together or all changes roll back together."
    private static let fullText = "STRATEGY:\nDirect Answer\nSAY_FIRST:\n" + answer + "\nKEY_POINTS:\n- Commit every operation or roll back every change.\n- Isolation controls concurrent visibility.\nFOLLOW_UP_READY:\n- Explain the isolation level required by the application.\nCAUTION:\n"

    @Test(.timeLimit(.minutes(1)))
    func ownedSectionStreamKeepsTheActualServiceRequestAndRawValidationInput() async throws {
        let database = try AppDatabase(inMemory: true)
        let settings = SettingsRepository(database: database)
        let client = OwnedStageBClient()
        let service = SuggestionGenerationService(llmRouter: LLMRouter(settingsRepository: settings, clients: [.deepSeek: client]))
        let owner = GenerationCoordinator(dependencies: .init(suggestionGenerationService: service))
        let input = makeInput(model: "synthetic-stream-original", generationID: "stream-parity")
        let observations = StageBObservations()
        let clock = StageBHeldClock()
        var reference: Task<String, Error>?
        var owned: Task<Void, Never>?
        do {
            let stream = try await service.generateFullCardSectionStream(question: input.question,
                context: input.providerContext, transcriptContext: input.context.transcriptSnapshot,
                sessionID: input.context.session.id, cvSummary: input.cv, jdSummary: input.jd,
                customProviderConfig: input.configuration)
            let original = Task { var text = ""; for try await token in stream { text += token }; return text }
            reference = original
            #expect(try await client.nextStarted() == "stream:" + input.configuration.model)
            client.emit(Self.fullText, model: input.configuration.model)
            client.finish(model: input.configuration.model)
            #expect(try await joinedValue(original) == Self.fullText)
            var replacement = input.configuration
            replacement.id = UUID(); replacement.model = "synthetic-later-settings"
            try settings.saveProviderConfiguration(replacement)
            try settings.setActiveRealtimeProvider(id: replacement.id)
            activate(owner, input: input)
            let task = try #require(launch(owner, input: input, observations: observations, clock: clock))
            owned = task
            #expect(try await client.nextStarted() == "stream:" + input.configuration.model)
            // This is an explicitly synthetic secret-shaped marker. It verifies
            // that raw evidence input and already-redacted output remain distinct.
            let marker = "sk-synthetic_marker_01234567890123456789"
            client.emit(Self.fullText + marker, model: input.configuration.model)
            client.finish(model: input.configuration.model)
            await joinedValue(task)
            let calls = client.calls
            try #require(calls.count == 2)
            #expect(calls[0] == calls[1])
            #expect(calls[1].options.temperature == 0.2)
            #expect(calls[1].options.timeoutInterval == 15.0)
            #expect(calls[1].responseFormat == .text)
            #expect(calls[1].options.stream)
            let raw = try #require(observations.rawSections.last)
            let completed = try #require(observations.results.last)
            #expect(raw.sayFirst == Self.answer)
            #expect(raw.caution == marker)
            #expect(completed.parsedSections?.caution == "[REDACTED_API_KEY]")
            #expect(completed.identity == input.context.identity)
            #expect(completed.providerStatus == .completed)
            #expect(observations.sawStreaming == [true])
            #expect(observations.failureCount == 0)
            #expect(observations.exits == [true])
            #expect(owner.stageBTask == nil)
            await owner.drainRetiredTasks()
            #expect(owner.pendingCleanupTaskCount == 0)
            client.finishAll(); clock.releaseAll()
            try database.close()
        } catch {
            reference?.cancel(); owned?.cancel(); client.finishAll(); clock.releaseAll()
            _ = await reference?.result; await owned?.value
            _ = await owner.shutdownAndDrain()
            try? database.close()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func emptyStreamUsesTheSameFrozenFullCardServiceAndFifteenSecondClock() async throws {
        let database = try AppDatabase(inMemory: true)
        let settings = SettingsRepository(database: database)
        let client = OwnedStageBClient()
        let service = SuggestionGenerationService(llmRouter: LLMRouter(settingsRepository: settings, clients: [.deepSeek: client]))
        let owner = GenerationCoordinator(dependencies: .init(suggestionGenerationService: service))
        let input = makeInput(model: "synthetic-fallback-original", generationID: "fallback-parity")
        let observations = StageBObservations()
        let clock = StageBHeldClock()
        var pending: Task<Void, Never>?
        do {
            _ = try await service.generateFullCard(question: input.question, context: input.providerContext,
                transcriptContext: input.context.transcriptSnapshot, sessionID: input.context.session.id,
                cvSummary: input.cv, jdSummary: input.jd, customProviderConfig: input.configuration)
            #expect(try await client.nextStarted() == "json:" + input.configuration.model)
            var replacement = input.configuration
            replacement.id = UUID(); replacement.model = "synthetic-fallback-replacement"
            try settings.saveProviderConfiguration(replacement)
            try settings.setActiveRealtimeProvider(id: replacement.id)
            activate(owner, input: input)
            let task = try #require(launch(owner, input: input, observations: observations, clock: clock))
            pending = task
            #expect(try await client.nextStarted() == "stream:" + input.configuration.model)
            client.finish(model: input.configuration.model)
            #expect(try await client.nextStarted() == "json:" + input.configuration.model)
            await joinedValue(task)
            let jsonCalls = client.calls.filter { !$0.options.stream }
            try #require(jsonCalls.count == 2)
            #expect(jsonCalls[0] == jsonCalls[1])
            #expect(jsonCalls[1].responseFormat == .jsonObject)
            #expect(jsonCalls[1].options.temperature == 0.2)
            #expect(jsonCalls[1].options.timeoutInterval == nil)
            #expect(clock.requestedNanoseconds == [15_000_000_000])
            #expect(clock.pendingCount == 0)
            #expect(observations.fallbackResults.count == 1)
            #expect(observations.fallbackResults.first?.providerModel == input.configuration.model)
            #expect(observations.rawSections.first?.sayFirst == Self.answer)
            #expect(observations.sawStreaming == [false])
            #expect(observations.failureCount == 0)
            await owner.drainRetiredTasks()
            #expect(owner.pendingCleanupTaskCount == 0)
            client.finishAll(); clock.releaseAll()
            try database.close()
        } catch {
            pending?.cancel(); client.finishAll(); clock.releaseAll(); await pending?.value
            _ = await owner.shutdownAndDrain()
            try? database.close()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: Array(0..<20))
    func oldWorkerExitNeverClearsAReplacementAcrossTwentyJoinedInterleavings(order: Int) async throws {
        // Five deterministic kinds repeated four times, each with its own
        // database, client, clock and handles. This is not a performance sample.
        let database = try AppDatabase(inMemory: true)
        let settings = SettingsRepository(database: database)
        let client = OwnedStageBClient()
        let service = SuggestionGenerationService(llmRouter: LLMRouter(settingsRepository: settings, clients: [.deepSeek: client]))
        let owner = GenerationCoordinator(dependencies: .init(suggestionGenerationService: service))
        let oldInput = makeInput(model: "old-\(order)", generationID: "old-\(order)")
        var replacement = makeInput(model: "new-\(order)", generationID: order % 5 == 1 ? oldInput.context.generationID : "new-\(order)")
        if order % 5 == 2 {
            replacement = Input(context: oldInput.context, question: oldInput.question,
                providerContext: oldInput.providerContext, configuration: replacement.configuration,
                cv: oldInput.cv, jd: oldInput.jd)
        }
        let oldObservations = StageBObservations()
        let newObservations = StageBObservations()
        let gate = StageBCompletionGate()
        let clock = StageBHeldClock()
        var old: Task<Void, Never>?
        var next: Task<Void, Never>?
        do {
            activate(owner, input: oldInput)
            let requiredOldExpansionWorker: Task<Void, Never> = try #require(launch(owner, input: oldInput, observations: oldObservations,
                clock: clock, completionGate: order % 5 == 4 ? nil : gate))
            old = requiredOldExpansionWorker
            #expect(try await client.nextStarted() == "stream:" + oldInput.configuration.model)
            if order % 5 == 4 {
                // A provider really emits after terminal, without relying
                // on cancellation to fence that same identity's output.
                owner.markTerminal(generationID: oldInput.context.generationID)
                client.emit(Self.fullText, model: oldInput.configuration.model)
                client.finish(model: oldInput.configuration.model)
                await old?.value
                #expect(oldObservations.rawSections.isEmpty)
                #expect(oldObservations.results.isEmpty)
                #expect(oldObservations.rejectedCount == 1)
                #expect(owner.stageBTask == nil)
            } else {
                client.emit(Self.fullText, model: oldInput.configuration.model)
                client.finish(model: oldInput.configuration.model)
                try await gate.waitUntilEntered()
                if order % 5 == 3 {
                    owner.closeAdmission()
                    #expect(launch(owner, input: replacement, observations: newObservations, clock: clock) == nil)
                    gate.release()
                    await old?.value
                    #expect(newObservations.results.isEmpty)
                } else {
                    if order % 5 != 2 { activate(owner, input: replacement) }
                    let newTask = try #require(launch(owner, input: replacement, observations: newObservations, clock: clock))
                    next = newTask
                    #expect(try await client.nextStarted() == "stream:" + replacement.configuration.model)
                    gate.release()
                    await old?.value
                    #expect(owner.isCurrent(replacement.context.identity))
                    #expect(owner.stageBTask != nil)
                    #expect(!newTask.isCancelled)
                    #expect(oldObservations.exits == [false])
                    client.emit(Self.fullText, model: replacement.configuration.model)
                    client.finish(model: replacement.configuration.model)
                    await joinedValue(newTask)
                    #expect(newObservations.rawSections.count == 1)
                    #expect(newObservations.results.first?.identity == replacement.context.identity)
                    #expect(newObservations.exits == [true])
                }
            }
            await owner.drainRetiredTasks()
            #expect(owner.pendingCleanupTaskCount == 0)
            #expect(oldObservations.failureCount == 0)
            client.finishAll(); clock.releaseAll(); gate.release()
            try database.close()
        } catch {
            old?.cancel(); next?.cancel(); gate.release(); client.finishAll(); clock.releaseAll()
            await old?.value; await next?.value
            _ = await owner.shutdownAndDrain()
            try? database.close()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationWhileWaitingForTheExactTriggerNeverStartsAProvider() async throws {
        let database = try AppDatabase(inMemory: true)
        let client = OwnedStageBClient()
        let service = SuggestionGenerationService(llmRouter: LLMRouter(settingsRepository: SettingsRepository(database: database), clients: [.deepSeek: client]))
        let owner = GenerationCoordinator(dependencies: .init(suggestionGenerationService: service))
        let input = makeInput(model: "never-started", generationID: "cancel-trigger")
        let clock = StageBHeldClock()
        let trigger = StageBTrigger(delayProvider: clock)
        let observations = StageBObservations()
        var pending: Task<Void, Never>?
        do {
            activate(owner, input: input)
            let requiredWaitingWorker: Task<Void, Never> = try #require(launch(owner, input: input, observations: observations, clock: clock, trigger: trigger))
            pending = requiredWaitingWorker
            #expect(try await clock.nextSleep() == 500_000_000)
            owner.invalidateAndCancel()
            await pending?.value
            await owner.drainRetiredTasks()
            #expect(client.calls.isEmpty)
            #expect(clock.requestedNanoseconds == [500_000_000])
            #expect(clock.pendingCount == 0)
            #expect(observations.results.isEmpty)
            #expect(observations.failureCount == 0)
            #expect(owner.pendingCleanupTaskCount == 0)
            client.finishAll(); clock.releaseAll()
            try database.close()
        } catch {
            pending?.cancel(); trigger.trigger(); client.finishAll(); clock.releaseAll()
            await pending?.value; _ = await owner.shutdownAndDrain()
            try? database.close()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func actualApplicationCallbackPublishesAndPersistsThroughItsExistingBoundaries() async throws {
        let suite = "StageBApplicationProjection-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = try AppDatabase(inMemory: true)
        let settings = SettingsRepository(database: database)
        let client = OwnedStageBClient()
        let app = AppState(database: database, questionRoutingProvider: HermeticQuestionRoutingProvider(),
            llmRouter: LLMRouter(settingsRepository: settings, clients: [.deepSeek: client]),
            permissionService: HermeticPermissionService(), keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            dialogueDefaults: defaults)
        let clock = StageBHeldClock()
        app.generationWatchdogDelayProvider = clock
        var pending: Task<Void, Never>?
        do {
            let session = try app.sessionRepository.createSession(mode: .mock)
            app.currentSession = session
            let input = makeInput(model: "synthetic-app-stage-b", generationID: "app-stage-b", session: session)
            try app.suggestionRepository.saveDetectedQuestion(input.question)
            app.activateGeneration(question: input.question, generationID: input.context.generationID,
                triggerPath: .manualGenerate, requestStart: input.context.startedAt, source: nil, speaker: nil,
                providerConfiguration: input.configuration)
            let trigger = StageBTrigger(delayProvider: clock)
            trigger.trigger()
            let task = try #require(app.launchProviderExpansion(context: input.context, providerQuestion: input.question,
                providerContext: input.providerContext, cvSummary: input.cv, jdSummary: input.jd,
                providerConfiguration: input.configuration, cardID: "actual-stage-b-card", retrievedChunks: [], trigger: trigger))
            pending = task
            #expect(try await client.nextStarted() == "stream:" + input.configuration.model)
            client.emit(Self.fullText, model: input.configuration.model)
            client.finish(model: input.configuration.model)
            await joinedValue(task)
            await app.generationCoordinator.drainRetiredTasks()
            let card = try #require(app.currentSuggestion)
            #expect(card.id == "actual-stage-b-card")
            #expect(card.sayFirst == Self.answer)
            #expect(card.stageBCompleted == true)
            #expect(card.stageBStatus == "completed")
            #expect(app.liveInterview.currentSuggestion == card)
            #expect(app.generationUIState.isTerminal)
            #expect(app.stageBTask == nil)
            #expect(!app.stageBTaskActive)
            let saved = try app.suggestionRepository.suggestions(sessionID: session.id)
            #expect(saved.count == 1)
            #expect(saved.first?.id == card.id)
            #expect(saved.first?.stageBStatus == "completed")
            #expect(app.generationCoordinator.pendingCleanupTaskCount == 0)
            await app.shutdownForTesting()
            client.finishAll(); clock.releaseAll()
            try database.close()
        } catch {
            pending?.cancel(); client.finishAll(); clock.releaseAll(); await pending?.value
            await app.shutdownForTesting()
            try? database.close()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectedActualPreviewDoesNotStopTheOwnedStreamBeforeAQualifiedFinalCard() async throws {
        let suite = "StageBRejectedPreview-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = try AppDatabase(inMemory: true)
        let client = OwnedStageBClient()
        let app = AppState(database: database, questionRoutingProvider: HermeticQuestionRoutingProvider(),
            llmRouter: LLMRouter(settingsRepository: SettingsRepository(database: database), clients: [.deepSeek: client]),
            permissionService: HermeticPermissionService(), keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            dialogueDefaults: defaults)
        let clock = StageBHeldClock()
        let previews = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingOldest(4))
        var pending: Task<Void, Never>?
        do {
            let session = try app.sessionRepository.createSession(mode: .mock)
            app.currentSession = session
            let input = makeInput(model: "synthetic-partial-rejection", generationID: "partial-rejection", session: session)
            try app.suggestionRepository.saveDetectedQuestion(input.question)
            app.activateGeneration(question: input.question, generationID: input.context.generationID,
                triggerPath: .manualGenerate, requestStart: input.context.startedAt, source: nil, speaker: nil,
                providerConfiguration: input.configuration)
            let trigger = StageBTrigger(delayProvider: clock)
            trigger.trigger()
            let task = try #require(app.generationCoordinator.launchStageBExpansion(
                context: input.context, providerQuestion: input.question, providerContext: input.providerContext,
                cvSummary: input.cv, jdSummary: input.jd, providerConfiguration: input.configuration,
                trigger: trigger, deadlineDelayProvider: clock, onStarted: { _ in }, onReady: { _ in },
                onSections: { _, sections, streamStartedMS in
                    // The real publication rule rejects an incomplete preview.
                    // No duplicated answer-validation implementation lives here.
                    let accepted = app.publishStreamingSections(sections, cardID: "partial-rejection-card",
                        generationID: input.context.generationID, question: input.question, session: session,
                        requestStart: input.context.startedAt, stageBStreamStartedMS: streamStartedMS)
                    previews.continuation.yield(accepted)
                }, onFallbackResult: { _, _ in Issue.record("Nonempty stream unexpectedly used JSON fallback"); return false },
                onCompleted: { identity, result, sections, sawStreaming, streamStartedMS in
                    let decision = app.generationCoordinator.interpretStageBResult(
                        generationID: identity.generationID, detectedQuestionID: input.question.id,
                        activeGenerationID: app.currentGenerationID, questionText: input.question.questionText,
                        providerResult: result, sections: sections, sawStreamingSections: sawStreaming,
                        visibleSayFirst: app.currentSuggestion?.sayFirst, visibleAnswerExists: app.visibleAnswerExists,
                        identity: identity, questionDecision: input.question.taskDescriptor?.decision)
                    let plan = app.generationCoordinator.makeStageBApplicationPlan(from: decision,
                        visibleSuggestion: app.currentSuggestion, activeGenerationID: app.currentGenerationID,
                        activeQuestionID: app.activeQuestionID)
                    try await app.applyStageBApplicationPlan(plan, sections: sections,
                        cardID: "partial-rejection-card", generationID: identity.generationID,
                        question: input.question, session: session, requestStart: input.context.startedAt,
                        stageBStreamStartedMS: streamStartedMS, retrievedChunks: [], triggerPath: .manualGenerate,
                        source: nil, speaker: nil, preserveFallbackSayFirst: false)
                }, onFailure: { _, _ in Issue.record("Owned expansion unexpectedly failed") },
                onRejected: { _ in Issue.record("Current expansion identity unexpectedly rejected") },
                onPhase: { _, _, _ in }, onExit: { _, _ in }))
            pending = task
            #expect(try await client.nextStarted() == "stream:" + input.configuration.model)
            let prefix = "STRATEGY:\nDirect Answer\nSAY_FIRST:\nA"
            client.emit(prefix, model: input.configuration.model)
            let accepted = try await TestEventWaitTrace(label: "stageB.rejectedPreview")
                .nextEvent(in: previews.stream, event: "actual_publication_returned")
            #expect(!accepted)
            #expect(app.generationCoordinator.canPublish(input.context.identity))
            #expect(!task.isCancelled)
            #expect(app.stageBTask != nil)
            client.emit(String(Self.fullText.dropFirst(prefix.count)), model: input.configuration.model)
            client.finish(model: input.configuration.model)
            await joinedValue(task)
            await app.generationCoordinator.drainRetiredTasks()
            #expect(app.currentSuggestion?.sayFirst == Self.answer)
            #expect(app.currentSuggestion?.stageBStatus == "completed")
            #expect(app.generationUIState.isTerminal)
            let rows = try app.suggestionRepository.suggestions(sessionID: session.id)
            #expect(rows.count == 1)
            #expect(rows.first?.sayFirst == Self.answer)
            #expect(rows.first?.stageBStatus == "completed")
            #expect(app.generationCoordinator.pendingCleanupTaskCount == 0)
            previews.continuation.finish(); client.finishAll(); clock.releaseAll()
            await app.shutdownForTesting()
            try database.close()
        } catch {
            pending?.cancel(); previews.continuation.finish(); client.finishAll(); clock.releaseAll(); await pending?.value
            await app.shutdownForTesting()
            try? database.close()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func synchronousUIInvalidationBeforeProviderEntryKeepsTheFrozenRequestInactive(invalidateInPhase: Bool) async throws {
        let database = try AppDatabase(inMemory: true)
        let client = OwnedStageBClient()
        let service = SuggestionGenerationService(llmRouter: LLMRouter(settingsRepository: SettingsRepository(database: database), clients: [.deepSeek: client]))
        let owner = GenerationCoordinator(dependencies: .init(suggestionGenerationService: service))
        let input = makeInput(model: "reentrant-provider", generationID: "reentrant-provider")
        let clock = StageBHeldClock()
        let trigger = StageBTrigger(delayProvider: clock)
        trigger.trigger()
        var pending: Task<Void, Never>?
        do {
            activate(owner, input: input)
            let task = try #require(owner.launchStageBExpansion(context: input.context,
                providerQuestion: input.question, providerContext: input.providerContext,
                cvSummary: input.cv, jdSummary: input.jd, providerConfiguration: input.configuration,
                trigger: trigger, deadlineDelayProvider: clock, onStarted: { _ in },
                onReady: { _ in if !invalidateInPhase { owner.invalidateAndCancel() } },
                onSections: { _, _, _ in Issue.record("Invalidated request emitted sections") },
                onFallbackResult: { _, _ in Issue.record("Invalidated request made JSON fallback"); return false },
                onCompleted: { _, _, _, _, _ in Issue.record("Invalidated request completed") },
                onFailure: { _, _ in Issue.record("Cancellation became a provider failure") }, onRejected: { _ in },
                onPhase: { _, phase, _ in if invalidateInPhase && phase == 3 { owner.invalidateAndCancel() } },
                onExit: { _, _ in }))
            pending = task
            await joinedValue(task)
            await owner.drainRetiredTasks()
            #expect(client.calls.isEmpty)
            #expect(owner.activeGeneration == nil)
            #expect(owner.pendingCleanupTaskCount == 0)
            client.finishAll(); clock.releaseAll()
            try database.close()
        } catch {
            pending?.cancel(); client.finishAll(); clock.releaseAll(); await pending?.value
            _ = await owner.shutdownAndDrain()
            try? database.close()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func providerFailureRetiresTheExactWorkerBeforeItsApplicationCallback() async throws {
        let database = try AppDatabase(inMemory: true)
        let client = OwnedStageBClient()
        let service = SuggestionGenerationService(llmRouter: LLMRouter(settingsRepository: SettingsRepository(database: database), clients: [.deepSeek: client]))
        let owner = GenerationCoordinator(dependencies: .init(suggestionGenerationService: service))
        let input = makeInput(model: "synthetic-provider-error", generationID: "provider-error")
        let clock = StageBHeldClock()
        let trigger = StageBTrigger(delayProvider: clock)
        trigger.trigger()
        var callbackCount = 0
        var pending: Task<Void, Never>?
        do {
            activate(owner, input: input)
            let task = try #require(owner.launchStageBExpansion(context: input.context,
                providerQuestion: input.question, providerContext: input.providerContext,
                cvSummary: input.cv, jdSummary: input.jd, providerConfiguration: input.configuration,
                trigger: trigger, deadlineDelayProvider: clock, onStarted: { _ in }, onReady: { _ in },
                onSections: { _, _, _ in }, onFallbackResult: { _, _ in false },
                onCompleted: { _, _, _, _, _ in Issue.record("Failed provider completed") },
                onFailure: { identity, error in
                    callbackCount += 1
                    #expect(identity == input.context.identity)
                    #expect((error as NSError).domain == "SyntheticStageBError")
                    #expect(owner.stageBTask == nil)
                    #expect(!Task.isCancelled)
                    #expect(owner.pendingCleanupTaskCount == 1)
                }, onRejected: { _ in Issue.record("Current failure unexpectedly discarded") },
                onPhase: { _, _, _ in }, onExit: { _, _ in }))
            pending = task
            #expect(try await client.nextStarted() == "stream:" + input.configuration.model)
            client.fail(model: input.configuration.model)
            await joinedValue(task)
            #expect(callbackCount == 1)
            await owner.drainRetiredTasks()
            #expect(owner.pendingCleanupTaskCount == 0)
            client.finishAll(); clock.releaseAll()
            try database.close()
        } catch {
            pending?.cancel(); client.finishAll(); clock.releaseAll(); await pending?.value
            _ = await owner.shutdownAndDrain()
            try? database.close()
            throw error
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
    private func makeInput(model: String, generationID: String, session: InterviewSession? = nil) -> Input {
        let session = session ?? InterviewSession(id: "synthetic-stage-b-session", title: "Synthetic Stage B",
            company: nil, role: nil, startedAt: Date(), endedAt: nil, mode: .mock, createdAt: Date())
        let question = DetectedQuestion(id: "question-" + model, sessionID: session.id, transcriptSegmentID: nil,
            questionText: "Explain database transactions and atomicity.", intent: .technical, answerStrategy: .directAnswer,
            confidence: 1, reason: "Synthetic ownership regression", shouldTrigger: true, questionComplete: true,
            modelName: "fixture", promptVersion: "fixture", createdAt: Date())
        let providerContext = RetrievedContext(cvChunks: [], jobDescriptionChunks: [])
        let configuration = LLMProviderConfiguration.deepSeekDefault(model: model)
        let context = GenerationExecutionContext.make(session: session, question: question, generationID: generationID,
            triggerPath: .manualGenerate, provider: configuration, retrievedContext: providerContext,
            transcriptSnapshot: "Synthetic transcript remains frozen.", cvSummary: "None provided.", jdSummary: "None provided.",
            startedAt: Date(), source: nil, speaker: nil, stage: .firstAnswer)
        return .init(context: context, question: question, providerContext: providerContext, configuration: configuration,
            cv: "None provided.", jd: "None provided.")
    }
    private func activate(_ owner: GenerationCoordinator, input: Input) {
        owner.activate(identity: input.context.identity, persistenceTicket: 0,
            triggerPath: .manualGenerate, startedAt: input.context.startedAt, providerConfiguration: input.configuration)
    }
    private func launch(_ owner: GenerationCoordinator, input: Input, observations: StageBObservations,
        clock: StageBHeldClock, completionGate: StageBCompletionGate? = nil,
        trigger: StageBTrigger? = nil) -> Task<Void, Never>? {
        let exactTrigger = trigger ?? StageBTrigger(delayProvider: clock)
        // Supplying a trigger tests the actual wait; ordinary fixture requests
        // explicitly release their own exact trigger before launch.
        if trigger == nil { exactTrigger.trigger() }
        return owner.launchStageBExpansion(context: input.context, providerQuestion: input.question,
            providerContext: input.providerContext, cvSummary: input.cv, jdSummary: input.jd,
            providerConfiguration: input.configuration, trigger: exactTrigger, deadlineDelayProvider: clock,
            onStarted: { _ in observations.startedCount += 1 }, onReady: { _ in observations.readyCount += 1 },
            onSections: { _, _, _ in observations.previewCount += 1 },
            onFallbackResult: { _, result in observations.fallbackResults.append(result); return true },
            onCompleted: { _, result, sections, sawStreaming, _ in
                observations.results.append(result); observations.rawSections.append(sections)
                observations.sawStreaming.append(sawStreaming)
                if let completionGate { await completionGate.suspend() }
            },
            onFailure: { _, _ in observations.failureCount += 1 },
            onRejected: { _ in observations.rejectedCount += 1 }, onPhase: { _, _, _ in },
            onExit: { _, cleared in observations.exits.append(cleared) })
    }
    private func joinedValue(_ task: Task<Void, Never>) async {
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
    private func joinedValue(_ task: Task<String, Error>) async throws -> String {
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

@MainActor
private final class StageBObservations {
    var startedCount = 0
    var readyCount = 0
    var previewCount = 0
    var failureCount = 0
    var rejectedCount = 0
    var results: [GenerationProviderResult] = []
    var fallbackResults: [GenerationProviderResult] = []
    var rawSections: [StreamingSuggestionSections] = []
    var sawStreaming: [Bool] = []
    var exits: [Bool] = []
}

@MainActor
private final class StageBCompletionGate {
    private let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    private var waiting: CheckedContinuation<Void, Never>?
    private var released = false
    func suspend() async {
        entered.continuation.yield(())
        guard !released else { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func waitUntilEntered() async throws {
        try await TestEventWaitTrace(label: "stageB.oldCompletion")
            .nextEvent(in: entered.stream, event: "application_callback_entered")
    }
    func release() { released = true; waiting?.resume(); waiting = nil; entered.continuation.finish() }
}

private struct OwnedStageBCall: Equatable, Sendable {
    let configuration: LLMProviderConfiguration
    let messages: [LLMChatMessage]
    let responseFormat: LLMResponseFormat?
    let options: LLMRequestOptions
}
private final class OwnedStageBClient: LLMClientProtocol, Sendable {
    let providerKind: LLMProviderKind = .deepSeek
    private struct State: Sendable {
        var calls: [OwnedStageBCall] = []
        var streams: [String: AsyncThrowingStream<String, Error>.Continuation] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let starts = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingOldest(8))
    var calls: [OwnedStageBCall] { state.withLock { $0.calls } }
    func chatCompletionStream(configuration: LLMProviderConfiguration, messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?, options: LLMRequestOptions) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(8)) { continuation in
            state.withLock {
                $0.calls.append(.init(configuration: configuration, messages: messages, responseFormat: responseFormat, options: options))
                $0.streams[configuration.model] = continuation
            }
            starts.continuation.yield("stream:" + configuration.model)
        }
    }
    func chatCompletion(configuration: LLMProviderConfiguration, messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?, options: LLMRequestOptions) async throws -> LLMChatResult {
        state.withLock { $0.calls.append(.init(configuration: configuration, messages: messages, responseFormat: responseFormat, options: options)) }
        starts.continuation.yield("json:" + configuration.model)
        return LLMChatResult(content: #"{"strategy":"Direct Answer","say_first":"A database transaction groups operations into an atomic unit. Atomicity means every operation commits together or all changes roll back together.","key_points":["Commit every operation or roll back every change.","Isolation controls concurrent visibility."],"follow_up_ready":["Explain the isolation level required by the application."],"confidence":0.9,"caution":"","evidence_used":[],"risk_level":"low"}"#,
            modelName: configuration.model, providerKind: .deepSeek, providerName: "Synthetic",
            baseURL: "http://synthetic.invalid", latencyMS: 0, isLocal: false, rawResponse: nil)
    }
    func emit(_ token: String, model: String) { state.withLock { $0.streams[model] }?.yield(token) }
    func finish(model: String) { state.withLock { $0.streams.removeValue(forKey: model) }?.finish() }
    func fail(model: String) {
        state.withLock { $0.streams.removeValue(forKey: model) }?.finish(throwing: NSError(domain: "SyntheticStageBError", code: 7))
    }
    func finishAll() {
        let streams = state.withLock { state in let values = Array(state.streams.values); state.streams.removeAll(); return values }
        streams.forEach { $0.finish() }; starts.continuation.finish()
    }
    func nextStarted() async throws -> String {
        try await TestEventWaitTrace(label: "coordinator.stage_b.provider")
            .nextEvent(in: starts.stream, event: "actual_service_started")
    }
    func testConnection(configuration: LLMProviderConfiguration) async throws -> LLMConnectionTestResult {
        .init(success: true, message: "Synthetic", latencyMS: 0, models: [])
    }
    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] { [] }
}

// Cancellation of AsyncStream.next wakes the sleeping fake without spawning a
// cleanup Task. All mutable registrations are under one lock, never across await.
private final class StageBHeldClock: DelayProvider, Sendable {
    private struct State: Sendable {
        var requested: [UInt64] = []
        var waiting: [UUID: AsyncStream<Void>.Continuation] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let starts = AsyncStream<UInt64>.makeStream(bufferingPolicy: .bufferingOldest(8))
    var requestedNanoseconds: [UInt64] { state.withLock { $0.requested } }
    var pendingCount: Int { state.withLock { $0.waiting.count } }
    func sleep(nanoseconds: UInt64) async throws {
        let id = UUID()
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        state.withLock { $0.requested.append(nanoseconds); $0.waiting[id] = pair.continuation }
        starts.continuation.yield(nanoseconds)
        defer { state.withLock { $0.waiting.removeValue(forKey: id) }?.finish() }
        var iterator = pair.stream.makeAsyncIterator()
        _ = await iterator.next()
        try Task.checkCancellation()
    }
    func releaseAll() {
        let continuations = state.withLock { state in let values = Array(state.waiting.values); state.waiting.removeAll(); return values }
        continuations.forEach { $0.finish() }; starts.continuation.finish()
    }
    func nextSleep() async throws -> UInt64 {
        try await TestEventWaitTrace(label: "stageB.exactTriggerClock")
            .nextEvent(in: starts.stream, event: "clock_registered")
    }
}
