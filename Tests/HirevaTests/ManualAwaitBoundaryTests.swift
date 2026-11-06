import Combine
import Foundation
import Testing
@testable import Hireva

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ManualAwaitBoundaryTests {
    @Test(arguments: [PolicyChange.context, .mode])
    func policyCancellationDuringManualRetrievalAllowsAnotherAnswerNow(change: PolicyChange) async throws {
        let trace = TestEventWaitTrace(label: #function + "." + change.rawValue)
        trace.mark("body.entered")
        let retrieval = ManualAwaitRetrieval(trace: trace)
        let fixture = try await ManualSnapshotFixture(mode: .deepSeekPrimary, retrieval: retrieval, trace: trace)
        trace.mark("fixture.ready")
        fixture.app.delayProvider = fixture.clock
        var pending: [Task<Void, Never>] = []
        do {
            fixture.setTranscript("Explain database transactions and atomicity.")
            let firstSignal = await retrieval.startSignal(for: 1)
            fixture.app.manualAnswerNow()
            trace.mark("manual.submitted")
            let old = try #require(fixture.app.activeAITask)
            pending.append(old)
            try await waitForStart(firstSignal)
            trace.mark("retrieval.started.observed")
            #expect(fixture.app.liveState == .generatingSuggestion)
            #expect(fixture.remote.requests().count == 1)
            switch change {
            case .context: fixture.app.selectInterviewDomain(.roboticsResearch)
            case .mode: fixture.app.setSelectedAnswerProviderMode(.localQwenPrimary)
            }
            trace.mark("policychanged")
            #expect(old.isCancelled)
            #expect(fixture.app.currentGenerationID == nil)
            #expect(!fixture.app.isActionLoading(ActionID.generateAnswer))
            await retrieval.release(1)
            try await fixture.join(old, onWaitEntered: { trace.mark("old.join.wait_entered") })
            trace.mark("oldjoined")
            #expect(fixture.app.currentSuggestion == nil)
            #expect(fixture.remote.requests().count == 1, "Only the first detector ran; revoked retrieval must not reach an answer provider.")
            #expect(fixture.app.liveState.canAnswerNow)
            #expect(!fixture.app.primaryHomeActionShouldStop, "No capture was started; cancelled generation must not leave a phantom Stop action.")

            let nextSignal = await retrieval.startSignal(for: 2)
            fixture.app.manualAnswerNow()
            trace.mark("retry.submitted")
            let next = try #require(fixture.app.activeAITask)
            pending.append(next)
            try await waitForStart(nextSignal)
            trace.mark("retry.retrieval.started.observed")
            let identity = try #require(fixture.app.activeGenerationController?.identity)
            await retrieval.release(2)
            try await fixture.join(next, onWaitEntered: { trace.mark("retry.join.wait_entered") })
            trace.mark("retry.root.joined")
            if let expansion = fixture.app.stageBTask {
                pending.append(expansion)
                try await fixture.join(expansion, onWaitEntered: { trace.mark("retry.expansion.wait_entered") })
                trace.mark("retry.expansion.joined")
            }
            trace.mark("retry.joined")
            #expect(fixture.app.currentSuggestion?.generationID == identity.generationID)
            #expect(fixture.app.currentSuggestion?.sessionID == fixture.session.id)
            #expect(fixture.app.currentSuggestion?.contextSnapshotID == identity.contextSnapshotID)
            #expect(fixture.app.currentSuggestion?.questionText == (change == .mode
                ? "Explain database transactions and atomicity" : "Explain database transactions and atomicity."))
            #expect(!fixture.app.isActionLoading(ActionID.generateAnswer))
            await retrieval.releaseAll()
            try await fixture.close(pending)
            trace.mark("fixtureclosed")
        } catch {
            trace.mark("body.catch")
            await retrieval.releaseAll()
            try? await fixture.close(pending)
            trace.mark("cleanup.returned_after_error")
            throw error
        }
    }

    @Test
    func currentSessionDeletionIsRejectedButUnrelatedDeletionKeepsManualGeneration() async throws {
        let retrieval = ManualAwaitRetrieval()
        let fixture = try await ManualSnapshotFixture(retrieval: retrieval)
        var pending: [Task<Void, Never>] = []
        do {
            fixture.setTranscript("Explain database transactions and atomicity.")
            let other = try fixture.app.sessionRepository.createSession(mode: .mock, title: "Synthetic unrelated session")
            let signal = await retrieval.startSignal(for: 1)
            fixture.app.manualAnswerNow()
            let request = try #require(fixture.app.activeAITask)
            pending.append(request)
            try await waitForStart(signal)
            let identity = try #require(fixture.app.activeGenerationController?.identity)
            let ticket = fixture.app.persistenceConsent.ticket()
            #expect(fixture.app.primaryHomeActionShouldStop)

            // The actual UI policy rejects deleting an active session. It does
            // not pretend deletion was admitted or invent a cancellation rule.
            fixture.app.deleteSession(fixture.session)
            #expect(try fixture.app.sessionRepository.session(id: fixture.session.id) != nil)
            #expect(fixture.app.persistenceConsent.ticket() == ticket)
            #expect(!request.isCancelled)
            fixture.app.deleteSession(other)
            #expect(try fixture.app.sessionRepository.session(id: other.id) == nil)
            #expect(fixture.app.persistenceConsent.ticket() != ticket)
            #expect(!request.isCancelled)
            #expect(fixture.app.currentGenerationID == identity.generationID)
            #expect(fixture.app.currentSession?.id == fixture.session.id)
            await retrieval.release(1)
            try await fixture.join(request)
            #expect(fixture.app.currentSuggestion?.generationID == identity.generationID)
            #expect(fixture.app.currentSuggestion?.questionText == "Explain database transactions and atomicity")
            #expect(await fixture.original.requests().count == 1)
            #expect(fixture.remote.requests().isEmpty)
            #expect(try fixture.app.suggestionRepository.suggestions(sessionID: fixture.session.id).isEmpty)
            await retrieval.releaseAll()
            try await fixture.close(pending)
        } catch {
            await retrieval.releaseAll()
            try? await fixture.close(pending)
            throw error
        }
    }

    @Test
    func busyRegenerateIsSingleRequestAndSupersededLateRAGCannotWriteNewRequest() async throws {
        let retrieval = ManualAwaitRetrieval()
        let fixture = try await ManualSnapshotFixture(retrieval: retrieval)
        var pending: [Task<Void, Never>] = []
        do {
            var visible = fixture.parent(id: "continuous-visible", answer:
                "A database transaction groups operations into an atomic unit.")
            visible.questionText = "Explain database transactions and atomicity."
            fixture.app.currentSuggestion = visible
            let firstSignal = await retrieval.startSignal(for: 1)
            fixture.app.regenerateVisibleSuggestion()
            let old = try #require(fixture.app.activeAITask)
            pending.append(old)
            try await waitForStart(firstSignal)
            let oldRequestID = try #require(fixture.app.generationCoordinator.activeRequest?.id)
            let oldGenerationID = try #require(fixture.app.currentGenerationID)
            fixture.app.regenerateVisibleSuggestion()
            #expect(fixture.app.generationCoordinator.activeRequest?.id == oldRequestID)
            #expect(fixture.app.currentGenerationID == oldGenerationID)
            #expect(await retrieval.startCount() == 1)
            #expect(await fixture.original.requests().isEmpty)

            let replacement = question(fixture: fixture, id: "replacement-question",
                text: "Explain transaction isolation and atomicity.")
            #expect(fixture.app.cancelActiveGenerationForContextChange())
            fixture.app.lastDetectedQuestion = replacement
            let nextSignal = await retrieval.startSignal(for: 2)
            fixture.app.answerCurrentQuestionOrTranscriptNow()
            let next = try #require(fixture.app.activeAITask)
            pending.append(next)
            #expect(old.isCancelled)
            try await waitForStart(nextSignal)
            let nextIdentity = try #require(fixture.app.activeGenerationController?.identity)
            let visibleBeforeLate = fixture.app.currentSuggestion
            let retrievalBeforeLate = fixture.app.lastRAGOperation
            #expect(nextIdentity.acceptedQuestionID == replacement.id)
            #expect(nextIdentity.generationID != oldGenerationID)
            await retrieval.release(1)
            try await fixture.join(old)
            #expect(fixture.app.currentGenerationID == nextIdentity.generationID)
            #expect(fixture.app.currentSuggestion == visibleBeforeLate)
            #expect(fixture.app.lastRAGOperation == retrievalBeforeLate)
            #expect(await fixture.original.requests().isEmpty)
            await retrieval.release(2)
            try await fixture.join(next)
            #expect(fixture.app.currentSuggestion?.generationID == nextIdentity.generationID)
            #expect(fixture.app.currentSuggestion?.detectedQuestionID == replacement.id)
            #expect(fixture.app.currentSuggestion?.questionText == replacement.questionText)
            #expect(await fixture.original.requests().count == 1)
            #expect(fixture.remote.requests().isEmpty)
            await retrieval.releaseAll()
            try await fixture.close(pending)
        } catch {
            await retrieval.releaseAll()
            try? await fixture.close(pending)
            throw error
        }
    }

    @Test
    func acceptedQuestionRegenerationFreezesQuestionTranscriptProviderAndModelAtSubmission() async throws {
        let fixture = try await ManualSnapshotFixture()
        var pending: [Task<Void, Never>] = []
        do {
            let original = question(fixture: fixture, id: "submitted-failed-question",
                text: "Explain database transactions and atomicity.")
            fixture.app.lastDetectedQuestion = original
            fixture.app.answerCurrentQuestionOrTranscriptNow()
            pending.append(try #require(fixture.app.activeAITask))
            // The MainActor has not yielded: the accepted visible question and provider
            // must already be frozen, even though the operation has not run.
            fixture.app.lastDetectedQuestion = question(fixture: fixture, id: "later-visible-question",
                text: "Explain transaction isolation and atomicity.")
            fixture.app.setSelectedQwenModelName("replacement-retry-model")
            fixture.app.localLLMProviderOverride = fixture.replacement
            try await fixture.join(try #require(pending.last))
            let requests = await fixture.original.requests()
            #expect(requests.count == 1)
            #expect(requests.first?.modelName == fixture.originalModel)
            #expect(requests.first?.prompt.contains(original.questionText) == true)
            #expect(await fixture.replacement.requests().isEmpty)
            #expect(fixture.remote.requests().isEmpty)
            #expect(fixture.app.currentSuggestion?.detectedQuestionID == original.id)
            #expect(fixture.app.currentSuggestion?.questionText == original.questionText)
            #expect(fixture.app.currentSuggestion?.modelName == fixture.originalModel)
            try await fixture.close(pending)
        } catch {
            try? await fixture.close(pending)
            throw error
        }
    }

    @Test
    func cancelledManualLocalProviderCannotPublishAfterItsAwaitReturns() async throws {
        let gate = ManualAwaitRetrieval()
        let fixture = try await ManualSnapshotFixture()
        let provider = ManualAwaitLocalProvider(gate: gate)
        fixture.app.localLLMProviderOverride = provider
        var pending: [Task<Void, Never>] = []
        do {
            fixture.setTranscript("Explain database transactions and atomicity.")
            let signal = await gate.startSignal(for: 1)
            fixture.app.manualAnswerNow()
            let request = try #require(fixture.app.activeAITask)
            pending.append(request)
            try await waitForStart(signal)
            #expect(await provider.requests().count == 1)
            fixture.app.setSelectedAnswerProviderMode(.deepSeekPrimary)
            #expect(request.isCancelled)
            #expect(fixture.app.currentGenerationID == nil)
            let providerBeforeLate = fixture.app.lastProviderOperation
            let sourceBeforeLate = fixture.app.finalVisibleSource
            await gate.release(1)
            try await fixture.join(request)
            #expect(fixture.app.currentSuggestion == nil)
            #expect(fixture.app.currentGenerationID == nil)
            #expect(fixture.app.lastProviderOperation == providerBeforeLate)
            #expect(fixture.app.finalVisibleSource == sourceBeforeLate)
            #expect(!fixture.app.isActionLoading(ActionID.generateAnswer))
            #expect(fixture.remote.requests().isEmpty)
            #expect(try fixture.app.suggestionRepository.suggestions(sessionID: fixture.session.id).isEmpty)
            await gate.releaseAll()
            try await fixture.close(pending)
        } catch {
            await gate.releaseAll()
            try? await fixture.close(pending)
            throw error
        }
    }

    @Test(arguments: ["liveError", "loadingClear"])
    func manualDetectionFailureCannotClearFeedbackFromAReplacedContext(phase: String) async throws {
        let fixture = try await ManualSnapshotFixture()
        let app = fixture.app
        let incomplete = "Explain database transactions and"
        let replacementContextID = UUID().uuidString
        let replacementError = "Synthetic replacement-context feedback"
        var replaced = false
        var roots: [Task<Void, Never>] = []
        func replaceContext() {
            guard !replaced, case .error = app.liveState else { return }
            replaced = true
            var replacement = fixture.session
            replacement.contextSnapshotID = replacementContextID
            app.currentSession = replacement
            app.errorMessage = replacementError
        }
        let liveObserver = app.liveInterview.objectWillChange.sink { _ in
            if phase == "liveError" { replaceContext() }
        }
        let loadingObserver = app.actionLoadingStatesUpdates.sink { states in
            if phase == "loadingClear", states[ActionID.generateAnswer] == false { replaceContext() }
        }
        defer { liveObserver.cancel(); loadingObserver.cancel() }
        do {
            #expect(SystemAudioQuestionExtractor.extract(from: incomplete, allowContextDependent: true).isEmpty)
            fixture.setTranscript(incomplete)
            app.manualAnswerNow()
            let root = try #require(app.activeAITask)
            roots.append(root)
            try await fixture.join(root)
            #expect(replaced, "The actual legacy manual-detection failure publication must execute.")
            #expect(app.currentSession?.contextSnapshotID == replacementContextID)
            #expect(app.errorMessage == replacementError)
            #expect(app.latestActionFeedback(for: ActionID.generateAnswer)?.kind != .error)
            #expect(await fixture.original.requests().isEmpty)
            #expect(fixture.remote.requests().isEmpty)
            try await fixture.close(roots)
        } catch {
            try? await fixture.close(roots)
            throw error
        }
    }

    @Test(arguments: ["liveError", "loadingClear"])
    func regenerateRejectionCannotClearFeedbackFromAReplacedContext(phase: String) async throws {
        let fixture = try await ManualSnapshotFixture()
        let app = fixture.app
        await app.automaticContextBuildTask?.value
        let accepted = question(fixture: fixture, id: "synthetic-incomplete-accepted-question",
            text: "Explain database transactions and")
        let rejected = QuestionRuntimeAcceptanceGuard.validateDetectedQuestionForGeneration(accepted)
        let replacementContextID = UUID().uuidString
        let replacementError = "Synthetic replacement-context feedback"
        let replacementDiagnostic = "Synthetic replacement-context diagnostic"
        var replaced = false
        var feedbackAtReplacement: ActionFeedback?
        var roots: [Task<Void, Never>] = []
        func replaceContext() {
            // generateSuggestion's rejection sets ready/listening. Only the
            // actual Regenerate outer catch publishes this error state.
            guard !replaced, case .error = app.liveState else { return }
            replaced = true
            feedbackAtReplacement = app.latestActionFeedback(for: ActionID.generateAnswer)
            var replacement = fixture.session
            replacement.contextSnapshotID = replacementContextID
            app.currentSession = replacement
            app.errorMessage = replacementError
            app.updateDiagnostics { $0.lastError = replacementDiagnostic }
        }
        let liveObserver = app.liveInterview.objectWillChange.sink { _ in
            if phase == "liveError" { replaceContext() }
        }
        let loadingObserver = app.actionLoadingStatesUpdates.sink { states in
            if phase == "loadingClear", states[ActionID.generateAnswer] == false { replaceContext() }
        }
        defer { liveObserver.cancel(); loadingObserver.cancel() }
        do {
            let rejectionReason = try #require(rejected.reason)
            #expect(!rejected.accepted)
            app.lastDetectedQuestion = accepted
            app.answerCurrentQuestionOrTranscriptNow()
            let root = try #require(app.activeAITask)
            roots.append(root)
            try await fixture.join(root)
            #expect(replaced, "The actual Regenerate RuntimeQuestionRejectedError catch must execute.")
            #expect(app.lastRegenerateQuestionID == accepted.id)
            #expect(app.lastRegenerateSourceTextKind == "accepted_question")
            #expect(app.lastRegenerateRejectionReason == rejectionReason.rawValue)
            #expect(app.currentSession?.contextSnapshotID == replacementContextID)
            #expect(app.errorMessage == replacementError)
            #expect(app.latestActionFeedback(for: ActionID.generateAnswer) == feedbackAtReplacement)
            #expect(app.diagnostics.lastError == replacementDiagnostic)
            #expect(app.currentSuggestion == nil)
            #expect(await fixture.original.requests().isEmpty)
            #expect(fixture.remote.requests().isEmpty)
            try await fixture.close(roots)
        } catch {
            try? await fixture.close(roots)
            throw error
        }
    }

    private func question(fixture: ManualSnapshotFixture, id: String, text: String) -> DetectedQuestion {
        DetectedQuestion(id: id, sessionID: fixture.session.id, transcriptSegmentID: nil,
            questionText: text, intent: .technical, answerStrategy: .directAnswer,
            confidence: 1, reason: "Synthetic Manual ownership fixture", shouldTrigger: true,
            questionComplete: true, modelName: "synthetic", promptVersion: "synthetic",
            rawJSON: nil, createdAt: Date())
    }

    private func waitForStart(_ signal: AsyncStream<Void>) async throws {
        // This is a cooperative fixture-readiness wait. Cancellation terminates
        // AsyncStream.next; the noncooperative production request is explicitly
        // released by catch before cleanup joins it.
        try await GenerationCoordinator.withTimeout(seconds: 30) {
            var iterator = signal.makeAsyncIterator()
            guard await iterator.next() != nil else { throw CancellationError() }
            try Task.checkCancellation()
        }
    }

    enum PolicyChange: String { case context, mode }
}

/// Each request intentionally ignores cancellation only until the test releases
/// its own latch. Every failure path opens all latches before joining root tasks.
private actor ManualAwaitRetrieval: ContextRetrievalService {
    private let trace: TestEventWaitTrace?
    init(trace: TestEventWaitTrace? = nil) { self.trace = trace }
    private var count = 0
    private var released = Set<Int>()
    private var stopped = false
    private var pending: [Int: CheckedContinuation<Void, Never>] = [:]
    private var startedSignals: [Int: [AsyncStream<Void>.Continuation]] = [:]

    func startCount() -> Int { count }

    func startSignal(for ordinal: Int) -> AsyncStream<Void> {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        if count >= ordinal {
            pair.continuation.yield(())
            pair.continuation.finish()
        } else if stopped {
            pair.continuation.finish()
        } else {
            startedSignals[ordinal, default: []].append(pair.continuation)
        }
        return pair.stream
    }

    func release(_ ordinal: Int) {
        released.insert(ordinal)
        pending.removeValue(forKey: ordinal)?.resume()
    }

    func releaseAll() {
        stopped = true
        let held = Array(pending.values)
        pending.removeAll()
        held.forEach { $0.resume() }
        let signals = startedSignals.values.flatMap { $0 }
        startedSignals.removeAll()
        signals.forEach { $0.finish() }
    }

    func holdCall() async {
        count += 1
        let ordinal = count
        trace?.mark("retrieval.started.\(ordinal)")
        let signals = startedSignals.removeValue(forKey: ordinal) ?? []
        signals.forEach { $0.yield(()); $0.finish() }
        if !stopped && !released.contains(ordinal) {
            await withCheckedContinuation { pending[ordinal] = $0 }
        }
    }

    func retrieveContextWithTrace(question: String, intent: QuestionIntent, maxCVWords: Int,
        maxJDWords: Int, strategy: AnswerStrategy?) async throws -> (context: RetrievedContext, trace: RetrievalTrace) {
        await holdCall()
        return (RetrievedContext(cvChunks: [], jobDescriptionChunks: []),
            RetrievalTrace(id: UUID(), query: question, intent: intent.rawValue, createdAt: Date(),
                rankedCVChunks: [], rankedJDChunks: [], includedCVChunks: [], includedJDChunks: [],
                excludedCVChunks: [], excludedJDChunks: [], cvWordsUsed: 0, jdWordsUsed: 0,
                cvWordBudget: maxCVWords, jdWordBudget: maxJDWords, retrievalLatencyMS: 0,
                emptyQueryFallbackUsed: false, zeroScoreFallbackUsed: false))
    }
}

private actor ManualAwaitLocalProvider: LocalLLMProvider {
    nonisolated let id = "synthetic-held-manual-local"
    nonisolated var displayName: String { id }
    private let gate: ManualAwaitRetrieval
    private var captured: [LocalLLMRequest] = []
    init(gate: ManualAwaitRetrieval) { self.gate = gate }
    func requests() -> [LocalLLMRequest] { captured }
    func healthCheck(modelName: String) async -> LocalLLMHealth {
        .init(ollamaRunning: true, selectedModel: modelName, modelInstalled: true,
            providerSource: .ollamaQwen, lastError: nil)
    }
    nonisolated func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        captured.append(request)
        // Deliberately does not cooperate with cancellation until the test
        // releases its owned gate, so the real post-await guard is exercised.
        await gate.holdCall()
        return AsyncThrowingStream { continuation in
            continuation.yield(.init(text: "A database transaction groups operations into an atomic unit. Atomicity means all operations commit together or roll back together, and isolation controls which concurrent changes each transaction can observe.",
                source: .ollamaQwen, modelName: request.modelName))
            continuation.finish()
        }
    }
}
