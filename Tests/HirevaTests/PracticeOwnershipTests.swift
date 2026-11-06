import Foundation
import Combine
import Testing
@testable import Hireva

@Suite(.serialized)
@MainActor
struct PracticeOwnershipTests {
    @Test(.timeLimit(.minutes(1)))
    func routingAndEvaluationUseOneFrozenProviderConfiguration() async throws {
        let environment = try await HirevaTestEnvironment(prefix: "PracticeOwnership")
        let original = PracticeOwnershipProvider()
        let replacement = PracticeOwnershipProvider()
        let app = environment.appState
        app.localLLMProviderOverride = original
        app.setSelectedQwenModelName("frozen-practice-model")
        let controller = app.practiceController
        controller.start(kind: .generalKnowledge, question: "Explain a deterministic retry policy.", language: "en", criteria: ["State the retry policy"], maxFollowUps: 0)
        controller.beginAnswer()
        controller.run?.draft = "Bound the number of retries."
        let completion = PracticeOwnershipCompletionObservation(controller: controller)
        var replacedAfterFreeze = false
        // Configuration is frozen before this synchronous error-clear publication.
        let replacementObservation = controller.errorUpdates.dropFirst().sink { incoming in
            MainActor.assumeIsolated {
                guard incoming == nil, controller.run?.phase == .evaluating,
                      !replacedAfterFreeze else { return }
                replacedAfterFreeze = true
                app.localLLMProviderOverride = replacement
                app.setSelectedQwenModelName("replacement-practice-model")
            }
        }
        defer { replacementObservation.cancel() }
        do {
            controller.submit()
            #expect(replacedAfterFreeze)
            #expect(app.selectedQwenModelName == "replacement-practice-model")
            try await completion.wait(label: "PracticeOwnership.frozen.evaluation")

            #expect(await original.routingModels == ["frozen-practice-model"])
            #expect(await original.evaluationModels == ["frozen-practice-model"])
            #expect(await original.reviewModels == ["frozen-practice-model"])
            #expect(controller.run?.phase == .completed)
            #expect(await replacement.routingModels.isEmpty)
            #expect(await replacement.evaluationModels.isEmpty)
            #expect(await replacement.reviewModels.isEmpty)
            controller.cancel()
            try await environment.shutdown()
            completion.close()
        } catch {
            completion.close()
            do { try await environment.shutdown() }
            catch let cleanupError { Issue.record(cleanupError) }
            throw error
        }
    }
    @Test(.timeLimit(.minutes(1)))
    func attemptRevisionCannotReceiveLateEvaluationForOldAnswer() async throws {
        let environment = try await HirevaTestEnvironment(prefix: "PracticeOwnership")
        let evaluationGate = PracticeOwnershipGate()
        environment.appState.localLLMProviderOverride = PracticeOwnershipProvider(evaluationGate: evaluationGate)
        let controller = environment.appState.practiceController
        controller.start(kind: .generalKnowledge, question: "Explain a deterministic retry policy.", language: "en", criteria: ["State the retry policy"], maxFollowUps: 0)
        controller.beginAnswer()
        controller.run?.draft = "Bound the number of retries."
        let completion = PracticeOwnershipCompletionObservation(controller: controller)
        do {
            controller.submit()
            _ = try await TestEventWaitTrace(label: "PracticeOwnership.revision.evaluate")
                .nextEvent(in: evaluationGate.enteredEvents.stream, event: "evaluation.entered")
            controller.run?.attempts[0].revision += 1
            controller.run?.attempts[0].answer = "Use the corrected retry budget."
            await evaluationGate.open()
            // Provider delivery precedes controller admission. Observe the real
            // completed/failed/paused publication for this session and question.
            try await completion.wait(label: "PracticeOwnership.revision.completion")

            #expect(controller.run?.attempts[0].feedback == nil)
            #expect(controller.run?.attempts[0].answer == "Use the corrected retry budget.")
            controller.cancel()
            try await environment.shutdown()
            completion.close()
        } catch {
            await evaluationGate.open()
            completion.close()
            do { try await environment.shutdown() }
            catch let cleanupError { Issue.record(cleanupError) }
            throw error
        }
    }
    @Test(.timeLimit(.minutes(1)))
    func liveDebounceClockDoesNotChangePracticeEvaluationDeadline() async throws {
        let environment = try await HirevaTestEnvironment(prefix: "PracticeOwnership")
        let liveClock = MockDelayProvider()
        environment.appState.delayProvider = liveClock
        environment.appState.localLLMProviderOverride = PracticeOwnershipProvider()
        let controller = environment.appState.practiceController
        controller.start(kind: .generalKnowledge, question: "Explain bounded retries.", language: "en", criteria: ["Bound retries"], maxFollowUps: 0)
        controller.beginAnswer()
        controller.run?.draft = "Bound the number of retries."
        let completion = PracticeOwnershipCompletionObservation(controller: controller)
        do {
            controller.submit()
            try await completion.wait(label: "PracticeOwnership.live-clock.completion")
            #expect(controller.run?.phase == .completed)
            #expect(!liveClock.delayCalledWithNanoseconds.contains(90_000_000_000))
            try await environment.shutdown()
            completion.close()
        } catch {
            completion.close()
            do { try await environment.shutdown() }
            catch let cleanupError { Issue.record(cleanupError) }
            throw error
        }
    }
    @Test(.timeLimit(.minutes(1)))
    func runContextChangeCannotReceiveLateEvaluationForOldSnapshot() async throws {
        let environment = try await HirevaTestEnvironment(prefix: "PracticeOwnership")
        let gate = PracticeOwnershipGate()
        environment.appState.localLLMProviderOverride = PracticeOwnershipProvider(evaluationGate: gate)
        let controller = environment.appState.practiceController
        controller.start(kind: .generalKnowledge, question: "Explain bounded retries.", language: "en", criteria: ["Bound retries"], maxFollowUps: 0)
        controller.beginAnswer()
        controller.run?.draft = "Bound the number of retries."
        let completion = PracticeOwnershipCompletionObservation(controller: controller)
        do {
            controller.submit()
            _ = try await TestEventWaitTrace(label: "PracticeOwnership.context.evaluate")
                .nextEvent(in: gate.enteredEvents.stream, event: "evaluation.entered")
            let oldAttemptSnapshot = controller.run?.attempts[0].contextSnapshotID
            controller.run?.snapshotID = "synthetic-replacement-context"
            await gate.open()
            try await completion.wait(label: "PracticeOwnership.context.completion")
            #expect(controller.run?.attempts[0].contextSnapshotID == oldAttemptSnapshot)
            #expect(controller.run?.attempts[0].feedback == nil)
            #expect(controller.run?.phase == .paused)
            try await environment.shutdown()
            completion.close()
        } catch {
            await gate.open()
            completion.close()
            do { try await environment.shutdown() }
            catch let cleanupError { Issue.record(cleanupError) }
            throw error
        }
    }
    @Test
    func applicationTerminationCancelsPracticeOnlyEvaluation() async throws {
        let environment = try await HirevaTestEnvironment(prefix: "PracticeOwnership")
        let gate = PracticeOwnershipGate()
        environment.appState.localLLMProviderOverride = PracticeOwnershipProvider(evaluationGate: gate)
        let controller = environment.appState.practiceController
        controller.start(kind: .generalKnowledge, question: "Explain bounded retries.", language: "en", criteria: ["Bound retries"], maxFollowUps: 0)
        controller.beginAnswer()
        controller.run?.draft = "Bound the number of retries."
        controller.submit()
        await gate.waitUntilEntered()
        let oldToken = controller.ownershipToken
        #expect(environment.appState.currentSession == nil)
        environment.appState.handleApplicationWillTerminate()
        #expect(controller.ownershipToken != oldToken)
        #expect(controller.run?.phase == .cancelled)
        await gate.open()
        try await waitUntil { controller.run?.phase != .evaluating }
        try await environment.shutdown()
        #expect(controller.run?.attempts[0].feedback == nil)
    }

    @Test
    func standaloneFeatureKeepsOriginatingConsentTicketAfterOffOn() async throws {
        let database = try AppDatabase(inMemory: true)
        let consent = PersistenceConsent()
        let controller = standaloneController(database: database, consent: consent)
        controller.start(kind: .generalKnowledge, question: "Explain bounded retries.", language: "en", criteria: ["Bound retries"], maxFollowUps: 0)
        controller.beginAnswer()
        let sessionID = try #require(controller.run?.sessionID)
        let repository = PracticeRepository(database: database)
        #expect(try repository.load(sessionID: sessionID)?.phase == .answering)

        // The feature's current history preference remains on. Only the
        // consent generation changes, isolating the atomic write boundary.
        consent.update(enabled: false)
        consent.update(enabled: true)
        controller.run?.draft = "Synthetic late write canary"
        controller.persist()
        #expect(try repository.load(sessionID: sessionID)?.draft == "")
        #expect(controller.error == nil)
        await controller.shutdown()
        try database.close()
    }

    @Test
    func microphoneProviderChoiceIsFrozenBeforePermissionSuspension() async throws {
        let database = try AppDatabase(inMemory: true)
        let gate = PracticeOwnershipGate()
        let provider = PracticeOwnershipASRProvider()
        var selected: ASRProviderID = .localParakeet
        var requested: [ASRProviderID] = []
        var made: [ASRProviderID] = []
        let controller = standaloneController(database: database, selectedASRProvider: { selected }, requestAudioPermissions: { id in
            requested.append(id)
            await gate.enter()
        }, makeAudioProvider: { id in
            made.append(id)
            return provider
        })
        controller.start(kind: .generalKnowledge, question: "Explain bounded retries.", language: "en", criteria: ["Bound retries"], maxFollowUps: 0)
        controller.beginAnswer()
        controller.startMicrophone()
        await gate.waitUntilEntered()
        selected = .appleSpeech
        await gate.open()
        try await waitUntil { controller.recording }
        #expect(requested == [.localParakeet])
        #expect(made == [.localParakeet])
        #expect(await provider.configurations.map(\.captureMode) == [.microphoneOnly])
        await controller.shutdown()
        #expect(!controller.recording)
        #expect(!controller.microphoneStarting)
        #expect(await provider.isRunning == false)
        try database.close()
    }

    @Test
    func microphoneCancelledWhileRequestingPermissionNeverCreatesProvider() async throws {
        let database = try AppDatabase(inMemory: true)
        let gate = PracticeOwnershipGate()
        var made = false
        let controller = standaloneController(database: database, requestAudioPermissions: { _ in await gate.enter() }, makeAudioProvider: { _ in
            made = true
            return PracticeOwnershipASRProvider()
        })
        controller.start(kind: .generalKnowledge, question: "Explain bounded retries.", language: "en", criteria: ["Bound retries"], maxFollowUps: 0)
        controller.beginAnswer()
        controller.startMicrophone()
        await gate.waitUntilEntered()
        controller.stopMicrophone()
        await gate.open()
        await controller.finishStoppingAudio()
        #expect(!made)
        #expect(!controller.recording)
        #expect(!controller.microphoneStarting)
        await controller.shutdown()
        try database.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func everyStandaloneShutdownWaiterJoinsTheSameHeldEvaluation() async throws {
        for order in 0..<20 {
            let database = try AppDatabase(inMemory: true)
            let gate = PracticeOwnershipGate()
            let cancellation = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
            let provider = PracticeShutdownHeldProvider(gate: gate, cancellation: cancellation.continuation)
            let controller = standaloneController(database: database,
                evaluationConfiguration: { (provider, "synthetic-shutdown-model") })
            var firstReturned = false
            var secondReturned = false
            var first: Task<Void, Never>?
            var second: Task<Void, Never>?
            let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
            do {
                controller.start(kind: .generalKnowledge, question: "Explain bounded retries.",
                    language: "en", criteria: ["Bound retries"], maxFollowUps: 0)
                controller.beginAnswer()
                controller.run?.draft = "Bound the number of retries."
                controller.submit()
                await gate.waitUntilEntered()
                first = Task { @MainActor in
                    await controller.shutdown()
                    firstReturned = true
                }
                _ = try await TestEventWaitTrace(label: "PracticeShutdown.cancel.\(order)")
                    .nextEvent(in: cancellation.stream, event: "evaluation.cancel_requested")
                #expect(!firstReturned)
                second = Task { @MainActor in
                    started.continuation.yield(())
                    await controller.shutdown()
                    secondReturned = true
                }
                _ = try await TestEventWaitTrace(label: "PracticeShutdown.waiter.\(order)")
                    .nextEvent(in: started.stream, event: "second.waiter.started")
                // Both tasks and this observer run on MainActor. The second
                // waiter executes through its first actual suspension before
                // this observer can run; its initial marker is not a sleep.
                #expect(!secondReturned,
                    "A repeated shutdown must join work already retiring, not return while the provider is held.")
                await gate.open()
                await first?.value
                await second?.value
                #expect(firstReturned && secondReturned)
                #expect(controller.run?.attempts.first?.feedback == nil)
                #expect(controller.run?.phase == .cancelled)
                cancellation.continuation.finish()
                started.continuation.finish()
                await controller.shutdown()
                try database.close()
            } catch {
                await gate.open()
                first?.cancel(); second?.cancel()
                await first?.value; await second?.value
                cancellation.continuation.finish(); started.continuation.finish()
                await controller.shutdown()
                try? database.close()
                throw error
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func redoAndExplicitSaveCannotReopenOrWriteAClosedPracticeFeature() async throws {
        let database = try AppDatabase(inMemory: true)
        let controller = standaloneController(database: database)
        let repository = PracticeRepository(database: database)
        do {
            controller.start(kind: .generalKnowledge, question: "Explain bounded retries.",
                language: "en", criteria: ["Bound retries"], maxFollowUps: 0)
            controller.beginAnswer()
            let id = try #require(controller.run?.sessionID)
            await controller.shutdown()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let closedRun = try encoder.encode(controller.run)
            let closedStored = try encoder.encode(repository.load(sessionID: id))
            controller.redo()
            let reopenedRun = try encoder.encode(controller.run)
            let reopenedStored = try encoder.encode(repository.load(sessionID: id))
            #expect(reopenedRun == closedRun)
            #expect(reopenedStored == closedStored)
            // UI bindings can still hold this object while the window closes.
            // Explicit persist is a separate admission boundary from redo.
            controller.run?.draft = "Synthetic late bound draft must not be saved."
            controller.persist()
            let lateStored = try encoder.encode(repository.load(sessionID: id))
            #expect(lateStored == closedStored)
            await controller.shutdown()
            try database.close()
        } catch {
            await controller.shutdown()
            try? database.close()
            throw error
        }
    }

    private func standaloneController(
        database: AppDatabase,
        consent: PersistenceConsent = PersistenceConsent(),
        evaluationConfiguration: @escaping () throws -> (provider: any LocalLLMProvider, model: String) = { (PracticeOwnershipProvider(), "synthetic-practice-model") },
        selectedASRProvider: @escaping () -> ASRProviderID = { .localParakeet },
        requestAudioPermissions: @escaping (ASRProviderID) async throws -> Void = { _ in },
        makeAudioProvider: @escaping (ASRProviderID) throws -> any ASRProvider = { _ in PracticeOwnershipASRProvider() }
    ) -> PracticeController {
        PracticeController(dependencies: PracticeDependencies(
            repository: PracticeRepository(database: database),
            sessions: SessionRepository(database: database),
            questions: SuggestionRepository(database: database),
            contexts: InterviewContextRepository(database: database),
            persistenceConsent: consent,
            context: { .init(historyEnabled: true, selection: .init(candidateProfileID: nil, opportunityContextID: nil, domainProfileID: .general), temporarySnapshotID: nil) },
            evaluationConfiguration: evaluationConfiguration,
            selectedASRProvider: selectedASRProvider,
            isLiveCaptureActive: { false },
            prepareForPractice: {},
            requestAudioPermissions: requestAudioPermissions,
            makeAudioProvider: makeAudioProvider,
            historyDidChange: { _ in },
            delayProvider: RealDelayProvider()
        ))
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while !predicate() {
            guard clock.now < deadline else { throw PracticeOwnershipFailure.waitTimedOut }
            try await clock.sleep(for: .milliseconds(1))
        }
    }
}

/// Observes the controller's committed terminal publication for one submitted
/// session/question. This does not cancel evaluation or claim producer exit.
/// The owning test supplies the only deadline; its cleanup then joins work.
@MainActor
private final class PracticeOwnershipCompletionObservation {
    private let completed = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    private var subscription: AnyCancellable?

    init(controller: PracticeController) {
        let sessionID = controller.run?.sessionID
        let questionID = controller.run?.questionID
        let continuation = completed.continuation
        guard sessionID != nil, questionID != nil else { continuation.finish(); return }
        subscription = controller.runUpdates.sink { incoming in
            guard let incoming, incoming.sessionID == sessionID,
                  incoming.questionID == questionID,
                  [.completed, .failed, .paused].contains(incoming.phase) else { return }
            continuation.yield(())
            continuation.finish()
        }
    }
    func wait(label: String) async throws {
        _ = try await TestEventWaitTrace(label: label)
            .nextEvent(in: completed.stream, event: "evaluation.terminal_publication")
    }
    func close() {
        subscription?.cancel(); subscription = nil
        completed.continuation.finish()
    }
}

private enum PracticeOwnershipFailure: Error { case waitTimedOut }

private actor PracticeOwnershipASRProvider: ASRProvider {
    nonisolated let id = ASRProviderID.localParakeet
    nonisolated let displayName = "Synthetic practice ASR"
    private var continuation: AsyncThrowingStream<TranscriptSegment, Error>.Continuation?
    private(set) var configurations: [ASRConfig] = []
    private(set) var isRunning = false
    func isAvailable() async -> Bool { true }
    func startTranscription(config: ASRConfig) async throws -> AsyncThrowingStream<TranscriptSegment, Error> {
        configurations.append(config)
        let pair = AsyncThrowingStream<TranscriptSegment, Error>.makeStream()
        continuation = pair.continuation
        isRunning = true
        return pair.stream
    }
    func stopTranscription() async {
        isRunning = false
        continuation?.finish()
        continuation = nil
    }
}

private actor PracticeOwnershipGate {
    nonisolated let enteredEvents = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    private var entered = false
    private var isOpen = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func enter() async {
        enteredEvents.continuation.yield(())
        enteredEvents.continuation.finish()
        entered = true
        let observing = observers; observers.removeAll()
        observing.forEach { $0.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        let waiting = waiters; waiters.removeAll()
        waiting.forEach { $0.resume() }
    }
}

private actor PracticeOwnershipProvider: LocalLLMProvider {
    nonisolated var id: String { "practice-ownership-fixture" }
    nonisolated var displayName: String { id }
    private let evaluationGate: PracticeOwnershipGate?
    private(set) var routingModels: [String] = []
    private(set) var evaluationModels: [String] = []
    private(set) var reviewModels: [String] = []
    private var admittedInputs: [String: (model: String, payload: [String: String], draft: PracticeEvaluationPayload)] = [:]

    init(evaluationGate: PracticeOwnershipGate? = nil) {
        self.evaluationGate = evaluationGate
    }
    func healthCheck(modelName: String) async -> LocalLLMHealth {
        .init(ollamaRunning: true, selectedModel: modelName, modelInstalled: true, providerSource: .localQwen, lastError: nil)
    }
    nonisolated func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        let output: String
        if request.systemPrompt?.contains("Independently critique the complete original answer") == true {
            let payload = try JSONDecoder().decode([String: String].self, from: Data(request.prompt.utf8))
            guard payload["draft_feedback"] == nil,
                  payload["draft_first_missing_rubric_id"] == nil,
                  payload["draft_first_missing_rubric_criterion"] == nil,
                  payload["previous_invalid_output"] == nil,
                  payload["editable_output_fields"] != nil else {
                throw MaterialError.invalid("Unexpected fresh review fixture phase.")
            }
            let answer = try #require(payload["answer"])
            let initial = try #require(admittedInputs[answer])
            for field in ["question", "answer", "rubric", "source_evidence", "attachment"] {
                guard payload[field] == initial.payload[field] else { throw MaterialError.invalid("Review mixed another frozen input.") }
            }
            guard request.modelName == initial.model else {
                throw MaterialError.invalid("Review changed the original model.")
            }
            reviewModels.append(request.modelName)
            var accepted = initial.draft
            accepted.reviewOutcome = "accepted" // Explicit known one-criterion scripted review.
            output = String(decoding: try JSONEncoder().encode(accepted), as: UTF8.self)
        } else if request.systemPrompt?.contains("Evaluate this practice answer") == true {
            let payload = try JSONDecoder().decode([String: String].self, from: Data(request.prompt.utf8))
            evaluationModels.append(request.modelName)
            await evaluationGate?.enter()
            let ids = (payload["rubric"] ?? "").split(separator: "\n").compactMap { $0.split(separator: ":", maxSplits: 1).first.map(String.init) }
            let quotes = Dictionary(uniqueKeysWithValues: ids.map { ($0, Optional(payload["answer"] ?? "")) })
            let draft = PracticeEvaluationPayload(coverage: quotes, suggestion: "Synthetic validated feedback", followUp: nil, reason: "All supplied criteria covered", reference: "Bound the retry count.")
            admittedInputs[payload["answer"] ?? ""] = (request.modelName, payload, draft)
            output = String(decoding: try JSONEncoder().encode(draft), as: UTF8.self)
        } else {
            routingModels.append(request.modelName)
            output = #"{"task":"generalKnowledge","personalEvidence":"notRequired","basis":"generalKnowledge","relation":"independent","clarification":""}"#
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.init(text: output, source: .localQwen, modelName: request.modelName))
            continuation.finish()
        }
    }
}

private actor PracticeShutdownHeldProvider: LocalLLMProvider {
    nonisolated let id = "practice-shutdown-held"
    nonisolated let displayName = "Synthetic shutdown held provider"
    private let gate: PracticeOwnershipGate
    private let cancellation: AsyncStream<Void>.Continuation
    private let response = PracticeOwnershipProvider()
    init(gate: PracticeOwnershipGate, cancellation: AsyncStream<Void>.Continuation) {
        self.gate = gate; self.cancellation = cancellation
    }
    func healthCheck(modelName: String) async -> LocalLLMHealth {
        await response.healthCheck(modelName: modelName)
    }
    nonisolated func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        if request.systemPrompt?.contains("Evaluate this practice answer") == true {
            await withTaskCancellationHandler {
                await gate.enter()
            } onCancel: { [cancellation] in
                cancellation.yield(())
            }
        }
        return try await response.generateAnswer(request: request)
    }
}
