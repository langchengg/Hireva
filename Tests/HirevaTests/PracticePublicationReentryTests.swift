import Foundation
import Combine
import Testing
@testable import Hireva

/// Actual controller/Combine/GRDB publication reentry; no microphone, model or
/// AppState construction. Explicit packets test ownership, not answer quality.
@Suite
@MainActor
struct PracticePublicationReentryTests {
    @Test(.timeLimit(.minutes(1)), arguments: PracticePublicationInterruption.allCases)
    func staleSuccessCannotPublishOrPersistPastASynchronousRunChange(interruption: PracticePublicationInterruption) async throws {
        let fixture = try PracticePublicationFixture()
        do {
            let controller = fixture.controller
            controller.start(kind: .generalKnowledge, question: PracticePublicationFixture.originalQuestion,
                language: "en", criteria: ["State a boundary"], maxFollowUps: 0)
            controller.beginAnswer()
            controller.run?.draft = PracticePublicationFixture.originalAnswer
            fixture.journal.history.removeAll()
            let original = try #require(controller.run)
            fixture.journal.arm = { incoming in
                guard let attempt = incoming.attempts.first else { throw MaterialError.invalid("No original published attempt.") }
                switch interruption.action {
                case .startNewRun:
                    controller.start(kind: .generalKnowledge, question: "Explain a different transition.",
                        language: "en", criteria: ["State the new boundary"], maxFollowUps: 0)
                    fixture.journal.replacementSessionID = controller.run?.sessionID
                case .correctAndRestore:
                    // The same existing policy/capabilities used by
                    // AppState.correctPracticeAttempt, without constructing
                    // the whole AppState or its unrelated native resources.
                    fixture.consent.invalidate()
                    controller.pause()
                    try fixture.repository.correctAttempt(sessionID: original.sessionID, attemptID: attempt.id,
                        question: original.task.question, answer: PracticePublicationFixture.correctedAnswer)
                    controller.restore(sessionID: original.sessionID)
                }
            }
            fixture.observe(checkpoint: interruption.checkpoint)
            controller.submit()
            _ = try await TestEventWaitTrace(label: "PracticePublication.\(interruption)")
                .nextEvent(in: fixture.events.stream, event: "synchronous.interruption.finished")
            // Publication callback, evaluation root and this test are all on
            // MainActor. The root has no await between this callback and its
            // persist/history side effects, so this event wait resumes only
            // after that synchronous publication stack has returned.
            #expect(fixture.journal.fired)
            #expect(fixture.journal.callbackFailure == nil)
            #expect(controller.ownershipToken != fixture.journal.tokenAtPublication)
            #expect(!fixture.journal.history.contains { $0 == original.sessionID },
                "The retired success must not announce its frozen session after the callback replaces its identity.")
            switch interruption.action {
            case .startNewRun:
                let replacement = try #require(fixture.journal.replacementSessionID)
                #expect(replacement != original.sessionID)
                #expect(controller.run?.sessionID == replacement)
                #expect(controller.run?.task.question == "Explain a different transition.")
                #expect(controller.run?.phase == .asking)
                #expect(controller.run?.attempts.isEmpty == true)
                #expect(try fixture.repository.load(sessionID: replacement)?.phase == .asking)
            case .correctAndRestore:
                let stored = try #require(try fixture.repository.load(sessionID: original.sessionID))
                let corrected = try #require(stored.attempts.first)
                #expect(corrected.answer == PracticePublicationFixture.correctedAnswer)
                #expect(corrected.revision == 1)
                #expect(corrected.feedback == nil)
                #expect(corrected.corrections?.last?.answer == PracticePublicationFixture.originalAnswer)
                #expect(stored.revision == original.revision + 1)
                #expect(controller.run?.attempts.first?.answer == PracticePublicationFixture.correctedAnswer)
                #expect(controller.run?.attempts.first?.feedback == nil)
                #expect(controller.run?.revision == stored.revision)
            }
            try await fixture.close()
        } catch {
            try? await fixture.close()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func uninterruptedSuccessStillPublishesAndSavesTheAcceptedAttempt() async throws {
        let fixture = try PracticePublicationFixture()
        do {
            let controller = fixture.controller
            controller.start(kind: .generalKnowledge, question: PracticePublicationFixture.originalQuestion,
                language: "en", criteria: ["State a boundary"], maxFollowUps: 0)
            controller.beginAnswer()
            controller.run?.draft = PracticePublicationFixture.originalAnswer
            fixture.journal.history.removeAll()
            let session = try #require(controller.run?.sessionID)
            fixture.observe(checkpoint: .completed)
            controller.submit()
            _ = try await TestEventWaitTrace(label: "PracticePublication.uninterrupted")
                .nextEvent(in: fixture.events.stream, event: "completed.publication")
            #expect(fixture.journal.callbackFailure == nil)
            #expect(controller.run?.phase == .completed)
            let accepted = try #require(controller.run?.attempts.first?.feedback)
            #expect(accepted.covered.map(\.quote) == [PracticePublicationFixture.originalAnswer])
            #expect(accepted.reference == PracticePublicationFixture.reference)
            #expect(try fixture.repository.load(sessionID: session)?.attempts.first?.feedback == accepted)
            #expect(fixture.journal.history.compactMap { $0 } == [session])
            #expect(await fixture.provider.evaluationPhases == ["primary", "critic"])
            try await fixture.close()
        } catch {
            try? await fixture.close()
            throw error
        }
    }
    @Test(.timeLimit(.minutes(1)), arguments: PracticeFailurePublicationScenario.allCases)
    func staleFailureCannotOverwriteASynchronousReplacement(scenario: PracticeFailurePublicationScenario) async throws {
        let fixture = try PracticePublicationFixture(failureOrigin: scenario.origin)
        do {
            let controller = fixture.controller
            controller.start(kind: .generalKnowledge, question: PracticePublicationFixture.originalQuestion,
                language: "en", criteria: ["State a boundary"], maxFollowUps: 0)
            controller.beginAnswer()
            controller.run?.draft = PracticePublicationFixture.originalAnswer
            let original = try #require(controller.run)
            fixture.journal.history.removeAll()
            fixture.journal.arm = { incoming in
                switch scenario.action {
                case .startNewRun:
                    controller.start(kind: .generalKnowledge, question: "Explain a different transition.",
                        language: "en", criteria: ["State the new boundary"], maxFollowUps: 0)
                    fixture.journal.replacementSessionID = controller.run?.sessionID
                case .correctAndRestore:
                    let attempt = try #require(incoming.attempts.first)
                    fixture.consent.invalidate()
                    controller.pause()
                    try fixture.repository.correctAttempt(sessionID: original.sessionID, attemptID: attempt.id,
                        question: original.task.question, answer: PracticePublicationFixture.correctedAnswer)
                    controller.restore(sessionID: original.sessionID)
                }
            }
            fixture.observeError()
            controller.submit()
            _ = try await TestEventWaitTrace(label: "PracticeFailurePublication.\(scenario)")
                .nextEvent(in: fixture.events.stream, event: "synchronous.error.interruption.finished")
            // The actual error publisher runs synchronously on MainActor.
            // No await follows it inside fail before phase/persistence writes.
            #expect(fixture.journal.fired)
            #expect(fixture.journal.callbackFailure == nil)
            #expect(fixture.journal.errorAtPublication?.contains("Controlled") == true)
            #expect(controller.ownershipToken != fixture.journal.tokenAtPublication)
            #expect(controller.error == nil, "The old outer error publication must not restore a stale message after start/restore cleared it.")
            #expect(!fixture.journal.history.contains { $0 == original.sessionID })
            switch scenario.action {
            case .startNewRun:
                let replacement = try #require(fixture.journal.replacementSessionID)
                #expect(replacement != original.sessionID)
                #expect(controller.run?.sessionID == replacement)
                #expect(controller.run?.phase == .asking)
                #expect(controller.run?.attempts.isEmpty == true)
                #expect(try fixture.repository.load(sessionID: replacement)?.phase == .asking)
            case .correctAndRestore:
                let stored = try #require(try fixture.repository.load(sessionID: original.sessionID))
                let corrected = try #require(stored.attempts.first)
                #expect(stored.phase == .completed)
                #expect(stored.revision == original.revision + 1)
                #expect(corrected.answer == PracticePublicationFixture.correctedAnswer)
                #expect(corrected.revision == 1)
                #expect(corrected.feedback == nil)
                #expect(corrected.corrections?.last?.answer == PracticePublicationFixture.originalAnswer)
                #expect(controller.run?.phase == .completed)
                #expect(controller.run?.revision == stored.revision)
                #expect(controller.run?.attempts.first?.answer == corrected.answer)
            }
            try await fixture.close()
        } catch {
            try? await fixture.close()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: PracticeFailureOrigin.allCases)
    func uninterruptedFailureStillReportsAndPersistsItsOwnAttempt(origin: PracticeFailureOrigin) async throws {
        let fixture = try PracticePublicationFixture(failureOrigin: origin)
        do {
            let controller = fixture.controller
            controller.start(kind: .generalKnowledge, question: PracticePublicationFixture.originalQuestion,
                language: "en", criteria: ["State a boundary"], maxFollowUps: 0)
            controller.beginAnswer()
            controller.run?.draft = PracticePublicationFixture.originalAnswer
            let sessionID = try #require(controller.run?.sessionID)
            fixture.journal.history.removeAll()
            fixture.observeError()
            controller.submit()
            _ = try await TestEventWaitTrace(label: "PracticeFailurePublication.uninterrupted.\(origin)")
                .nextEvent(in: fixture.events.stream, event: "owned.error.reported")
            #expect(fixture.journal.callbackFailure == nil)
            #expect(controller.error?.contains("Controlled") == true)
            #expect(controller.run?.phase == .failed)
            #expect(controller.run?.sessionID == sessionID)
            #expect(controller.run?.attempts.first?.feedback == nil)
            #expect(try fixture.repository.load(sessionID: sessionID)?.phase == .failed)
            #expect(fixture.journal.history.isEmpty)
            #expect(await fixture.provider.evaluationPhases == (origin == .provider ? ["primary"] : []))
            try await fixture.close()
        } catch {
            try? await fixture.close()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [PracticePublicationInterruption.Action.startNewRun, .correctAndRestore])
    func clearingErrorCannotRegisterAStaleEvaluationOrDeadline(action: PracticePublicationInterruption.Action) async throws {
        let delay = PracticeEntryCountingDelay()
        let fixture = try PracticePublicationFixture(delayProvider: delay, waitForRoute: { await delay.waitForEntry() })
        do {
            let controller = fixture.controller
            controller.start(kind: .generalKnowledge, question: PracticePublicationFixture.originalQuestion,
                language: "en", criteria: ["State a boundary"], maxFollowUps: 0)
            controller.beginAnswer()
            controller.run?.draft = PracticePublicationFixture.originalAnswer
            controller.error = "Controlled previous message."
            let original = try #require(controller.run)
            fixture.journal.history.removeAll()
            fixture.journal.arm = { incoming in
                switch action {
                case .startNewRun:
                    controller.start(kind: .generalKnowledge, question: "Explain a different transition.",
                        language: "en", criteria: ["State the new boundary"], maxFollowUps: 0)
                    fixture.journal.replacementSessionID = controller.run?.sessionID
                case .correctAndRestore:
                    let attempt = try #require(incoming.attempts.first)
                    fixture.consent.invalidate()
                    controller.pause()
                    try fixture.repository.correctAttempt(sessionID: original.sessionID, attemptID: attempt.id,
                        question: original.task.question, answer: PracticePublicationFixture.correctedAnswer)
                    controller.restore(sessionID: original.sessionID)
                }
            }
            fixture.observeErrorClear()
            controller.submit()
            _ = try await TestEventWaitTrace(label: "PracticeEntryPublication.\(action)")
                .nextEvent(in: fixture.events.stream, event: "synchronous.error.clear.finished")
            #expect(fixture.journal.fired && fixture.journal.callbackFailure == nil)
            #expect(controller.ownershipToken != fixture.journal.tokenAtPublication)
            #expect(controller.error == nil)
            switch action {
            case .startNewRun:
                let replacement = try #require(fixture.journal.replacementSessionID)
                #expect(controller.run?.sessionID == replacement && replacement != original.sessionID)
                #expect(controller.run?.phase == .asking && controller.run?.attempts.isEmpty == true)
                #expect(try fixture.repository.load(sessionID: replacement)?.phase == .asking)
            case .correctAndRestore:
                let stored = try #require(try fixture.repository.load(sessionID: original.sessionID))
                #expect(stored.phase == .completed && stored.revision == original.revision + 1)
                #expect(stored.attempts.first?.answer == PracticePublicationFixture.correctedAnswer)
                #expect(stored.attempts.first?.revision == 1 && stored.attempts.first?.feedback == nil)
                #expect(controller.run?.revision == stored.revision && controller.run?.phase == .completed)
            }
            // Shutdown joins the pending handles retained at close. The route
            // seam cannot finish before deadline entry is recorded, avoiding a
            // timing assertion after normal deadline retirement. This existing
            // DelayProvider does not advance time or create a separate timer.
            try await fixture.close()
            #expect(await delay.requestedDurations.isEmpty,
                "A run retired during error-clear publication must never admit its deadline.")
            #expect(await fixture.provider.evaluationPhases.isEmpty)
        } catch {
            try? await fixture.close()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func uninterruptedEntryRetainsItsOneRealDeadlineAndEvaluation() async throws {
        let delay = PracticeEntryCountingDelay()
        let fixture = try PracticePublicationFixture(delayProvider: delay, waitForRoute: { await delay.waitForEntry() })
        do {
            let controller = fixture.controller
            controller.start(kind: .generalKnowledge, question: PracticePublicationFixture.originalQuestion,
                language: "en", criteria: ["State a boundary"], maxFollowUps: 0)
            controller.beginAnswer()
            controller.run?.draft = PracticePublicationFixture.originalAnswer
            fixture.observe(checkpoint: .completed)
            controller.submit()
            _ = try await TestEventWaitTrace(label: "PracticeEntryPublication.uninterrupted")
                .nextEvent(in: fixture.events.stream, event: "completed.publication")
            #expect(controller.run?.phase == .completed)
            #expect(controller.run?.attempts.first?.feedback != nil)
            try await fixture.close()
            #expect(await delay.requestedDurations == [90_000_000_000])
            #expect(await fixture.provider.evaluationPhases == ["primary", "critic"])
        } catch {
            try? await fixture.close()
            throw error
        }
    }

}

enum PracticePublicationInterruption: CaseIterable, Sendable {
    case newRunAtFeedback, newRunAtCompleted, correctionAtFeedback, correctionAtCompleted
    enum Action: Sendable { case startNewRun, correctAndRestore }
    var checkpoint: PracticePublicationCheckpoint {
        switch self { case .newRunAtFeedback, .correctionAtFeedback: return .feedback
        case .newRunAtCompleted, .correctionAtCompleted: return .completed }
    }
    var action: Action {
        switch self { case .newRunAtFeedback, .newRunAtCompleted: return .startNewRun
        case .correctionAtFeedback, .correctionAtCompleted: return .correctAndRestore }
    }
}
enum PracticeFailureOrigin: CaseIterable, Equatable, Sendable { case provider, configuration }
enum PracticeFailurePublicationScenario: CaseIterable, Sendable {
    case newRunAtProviderError, correctionAtProviderError, newRunAtConfigurationError, correctionAtConfigurationError
    var origin: PracticeFailureOrigin {
        switch self {
        case .newRunAtProviderError, .correctionAtProviderError: return .provider
        case .newRunAtConfigurationError, .correctionAtConfigurationError: return .configuration
        }
    }
    var action: PracticePublicationInterruption.Action {
        switch self {
        case .newRunAtProviderError, .newRunAtConfigurationError: return .startNewRun
        case .correctionAtProviderError, .correctionAtConfigurationError: return .correctAndRestore
        }
    }
}

enum PracticePublicationCheckpoint: Equatable { case feedback, completed }

@MainActor
private final class PracticePublicationJournal {
    var history: [String?] = []
    var arm: ((PracticeRun) throws -> Void)?
    var fired = false
    var callbackFailure: String?
    var tokenAtPublication: UUID?
    var errorAtPublication: String?
    var replacementSessionID: String?
}

@MainActor
private final class PracticePublicationFixture {
    static let originalQuestion = "Explain the admitted transition boundary."
    static let originalAnswer = "The rule applies only to admitted transitions."
    static let correctedAnswer = "The corrected rule also states its assumptions."
    static let reference = "State the admitted transitions and the assumptions under which the rule applies."
    let database: AppDatabase
    let consent: PersistenceConsent
    let repository: PracticeRepository
    let provider: PracticePublicationPacketProvider
    let journal: PracticePublicationJournal
    let controller: PracticeController
    let events = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    private var subscription: AnyCancellable?

    init(failureOrigin: PracticeFailureOrigin? = nil, delayProvider: any DelayProvider = RealDelayProvider(),
         waitForRoute: (@Sendable () async -> Void)? = nil) throws {
        let database = try AppDatabase(inMemory: true)
        self.database = database
        let repository = PracticeRepository(database: database)
        self.repository = repository
        let consent = PersistenceConsent()
        self.consent = consent
        let provider = PracticePublicationPacketProvider(failEvaluation: failureOrigin == .provider, waitForRoute: waitForRoute)
        self.provider = provider
        let journal = PracticePublicationJournal()
        self.journal = journal
        controller = PracticeController(dependencies: .init(
            repository: repository, sessions: SessionRepository(database: database),
            questions: SuggestionRepository(database: database), contexts: InterviewContextRepository(database: database),
            persistenceConsent: consent,
            context: { .init(historyEnabled: true, selection: .init(candidateProfileID: nil,
                opportunityContextID: nil, domainProfileID: .general), temporarySnapshotID: nil) },
            evaluationConfiguration: {
                if failureOrigin == .configuration { throw MaterialError.invalid("Controlled configuration failure.") }
                return (provider, "synthetic-publication")
            },
            selectedASRProvider: { .localParakeet }, isLiveCaptureActive: { false }, prepareForPractice: {},
            requestAudioPermissions: { _ in throw MaterialError.invalid("Audio is forbidden in this fixture.") },
            makeAudioProvider: { _ in throw MaterialError.invalid("Audio is forbidden in this fixture.") },
            historyDidChange: { journal.history.append($0) }, delayProvider: delayProvider))
    }

    func observe(checkpoint: PracticePublicationCheckpoint) {
        subscription = controller.runUpdates.sink { [weak self] incoming in
            // Every mutation in this fixture originates from the actual
            // MainActor controller. This checks that execution contract rather
            // than dispatching a later Task that would remove the reentry.
            MainActor.assumeIsolated {
                guard let self, let incoming, !self.journal.fired else { return }
                if incoming.phase == .failed {
                    self.journal.fired = true
                    self.journal.callbackFailure = self.controller.error ?? "Evaluation failed before the checkpoint."
                    self.events.continuation.yield(())
                    return
                }
                guard incoming.attempts.first?.feedback != nil else { return }
                if checkpoint == .feedback, incoming.phase != .evaluating { return }
                if checkpoint == .completed, incoming.phase != .completed { return }
                self.journal.fired = true // close recursion before the real action
                self.journal.tokenAtPublication = self.controller.ownershipToken
                do { try self.journal.arm?(incoming) }
                catch { self.journal.callbackFailure = error.localizedDescription }
                self.events.continuation.yield(())
            }
        }
    }
    func observeError() {
        subscription = controller.errorUpdates.sink { [weak self] incoming in
            MainActor.assumeIsolated {
                guard let self, let incoming, incoming.contains("Controlled"), !self.journal.fired else { return }
                self.journal.fired = true
                self.journal.errorAtPublication = incoming
                self.journal.tokenAtPublication = self.controller.ownershipToken
                do {
                    let current = try #require(self.controller.run)
                    try self.journal.arm?(current)
                } catch { self.journal.callbackFailure = error.localizedDescription }
                self.events.continuation.yield(())
            }
        }
    }
    func observeErrorClear() {
        subscription = controller.errorUpdates.sink { [weak self] incoming in
            MainActor.assumeIsolated {
                guard let self, incoming == nil, !self.journal.fired,
                      self.controller.run?.phase == .evaluating,
                      self.controller.run?.attempts.isEmpty == false else { return }
                self.journal.fired = true
                self.journal.tokenAtPublication = self.controller.ownershipToken
                do { try self.journal.arm?(try #require(self.controller.run)) }
                catch { self.journal.callbackFailure = error.localizedDescription }
                self.events.continuation.yield(())
            }
        }
    }
    func close() async throws {
        subscription?.cancel(); subscription = nil
        journal.arm = nil
        events.continuation.finish()
        await controller.shutdown() // actual owner joins its retired evaluation/deadline/audio tasks
        try database.close()
    }
}

private actor PracticePublicationPacketProvider: LocalLLMProvider {
    nonisolated let id = "synthetic-publication"
    nonisolated let displayName = "Explicit publication fixture packets"
    private(set) var evaluationPhases: [String] = []
    private let failEvaluation: Bool
    private let waitForRoute: (@Sendable () async -> Void)?
    init(failEvaluation: Bool = false, waitForRoute: (@Sendable () async -> Void)? = nil) {
        self.failEvaluation = failEvaluation; self.waitForRoute = waitForRoute
    }
    func healthCheck(modelName: String) async -> LocalLLMHealth {
        .init(ollamaRunning: true, selectedModel: modelName, modelInstalled: true,
            providerSource: .localQwen, lastError: nil)
    }
    nonisolated func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        let system = request.systemPrompt ?? ""
        let output: String
        if system.contains("Evaluate this practice answer") || system.contains("Independently critique the complete original answer") {
            let isReview = system.contains("Independently critique the complete original answer")
            let input = try JSONDecoder().decode([String: String].self, from: Data(request.prompt.utf8))
            guard input["answer"] == "The rule applies only to admitted transitions.",
                  input["rubric"] == "r0: State a boundary" else {
                throw MaterialError.invalid("Unexpected publication fixture input.")
            }
            evaluationPhases.append(isReview ? "critic" : "primary")
            if failEvaluation { throw MaterialError.invalid("Controlled evaluation failure.") }
            let packet = PracticeEvaluationPayload(coverage: ["r0": "The rule applies only to admitted transitions."],
                suggestion: "The requested boundary is stated.", followUp: nil,
                reason: "The supplied criterion is covered.",
                reference: "State the admitted transitions and the assumptions under which the rule applies.",
                reviewOutcome: isReview ? "accepted" : nil)
            output = String(decoding: try JSONEncoder().encode(packet), as: UTF8.self)
        } else {
            await waitForRoute?()
            output = #"{"task":"generalKnowledge","personalEvidence":"notRequired","basis":"generalKnowledge","relation":"independent","clarification":""}"#
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.init(text: output, source: .localQwen, modelName: request.modelName))
            continuation.finish()
        }
    }
}

/// Existing deadline injection seam, not an application scheduler or clock.
/// Records invocation even when its owned Task was cancelled before execution.
private actor PracticeEntryCountingDelay: DelayProvider {
    private(set) var requestedDurations: [UInt64] = []
    private nonisolated let entry: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    init() {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        entry = pair.stream; continuation = pair.continuation
    }
    nonisolated func waitForEntry() async {
        // AsyncStream cancellation releases an admitted route waiter. This is
        // one concrete deadline entry signal, never a sleep or global lock.
        for await _ in entry { break }
    }
    func sleep(nanoseconds: UInt64) async throws {
        requestedDurations.append(nanoseconds)
        continuation.yield(()); continuation.finish()
        try Task.checkCancellation()
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}
