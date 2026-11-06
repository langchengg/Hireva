import Foundation
import Testing
@testable import Hireva

/// Existing AppState submission/catch paths; no recorder, model, transport or
/// global legacy hook is used. Each fixture owns all gates and captured tasks.
@MainActor
struct ManualFrozenContextAndStaleCatchTests {
    @Test(.timeLimit(.minutes(1)))
    func captureKeepsSubmittedParentWhenAnotherCardArrivesBeforeWorkerStarts() async throws {
        let fixture = try await ManualSnapshotFixture()
        var tasks: [Task<Void, Never>] = []
        do {
            let original = fixture.parent(id: "submitted-capture-parent",
                answer: "Use bounded retries for transient transaction failures.")
            fixture.app.currentSuggestion = original
            submit("Explain database transactions and atomicity.", to: fixture.app)
            let request = try #require(fixture.app.stageBTask)
            tasks.append(request)
            fixture.app.currentSuggestion = fixture.parent(id: "later-capture-parent",
                answer: "A later visible card is a different parent.")
            try await join(request)
            let parent = try #require(fixture.app.lastDetectedQuestion?.taskDescriptor?.conversationContext)
            #expect(parent.questionID == original.questionID)
            #expect(parent.questionText == original.questionText)
            #expect(parent.answerText == original.sayFirst)
            #expect(parent.contextSnapshotID == original.contextSnapshotID)
            #expect(fixture.app.lastDetectedQuestion?.taskDescriptor?.conversationContextCaptured == true)
            #expect(fixture.remote.requests().isEmpty)
            try await fixture.close(tasks)
        } catch {
            try? await fixture.close(tasks)
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func submittedManualParentIsNotClearedByLaterDialogueModeSelection() async throws {
        let fixture = try await ManualSnapshotFixture()
        var tasks: [Task<Void, Never>] = []
        do {
            fixture.app.interviewSessionMode = .auto
            let original = fixture.parent(id: "submitted-auto-parent",
                answer: "Use bounded retries for transient transaction failures.")
            fixture.app.currentSuggestion = original
            submit("Explain database transactions and atomicity.", to: fixture.app)
            let request = try #require(fixture.app.stageBTask)
            tasks.append(request)
            let generation = try #require(fixture.app.currentGenerationID)
            // No MainActor suspension: the submitted question is frozen while
            // the worker is still queued. The existing mode policy keeps it.
            fixture.app.interviewSessionMode = .panelQuestions
            #expect(!request.isCancelled)
            #expect(fixture.app.currentGenerationID == generation)
            try await join(request)
            let parent = try #require(fixture.app.lastDetectedQuestion?.taskDescriptor?.conversationContext)
            #expect(parent.questionID == original.questionID)
            #expect(parent.questionText == original.questionText)
            #expect(parent.answerText == original.sayFirst)
            #expect(parent.mode == InterviewSessionMode.auto.rawValue,
                "A running request retains the mode of its frozen parent.")
            #expect(fixture.app.currentGenerationID == generation)
            #expect(fixture.app.manualCaptureState == .suggestionReady)
            #expect(fixture.remote.requests().isEmpty)
            try await fixture.close(tasks)
        } catch {
            try? await fixture.close(tasks)
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectedOldManualCatchCannotOverwriteReplacementDiagnostics() async throws {
        let retrieval = ManualLateFailureRetrieval()
        let fixture = try await ManualSnapshotFixture(retrieval: retrieval)
        fixture.app.delayProvider = fixture.clock
        var tasks: [Task<Void, Never>] = []
        do {
            let firstStarted = await retrieval.firstStartSignal()
            submit("Explain database transactions and atomicity.", to: fixture.app)
            let old = try #require(fixture.app.stageBTask)
            tasks.append(old)
            let oldGeneration = try #require(fixture.app.currentGenerationID)
            _ = try await TestEventWaitTrace(label: "manual-stale-catch.first-rag")
                .nextEvent(in: firstStarted, event: "entered")
            #expect(await retrieval.callCount() == 1)

            // Use actual settings policy to revoke the old request and clear
            // its action before a replacement; never alter owner IDs in tests.
            fixture.app.setSelectedAnswerProviderMode(.deepSeekPrimary)
            fixture.app.setSelectedAnswerProviderMode(.localQwenPrimary)
            #expect(old.isCancelled)
            #expect(!fixture.app.isActionLoading(ActionID.manualGenerate))
            submit("Explain transaction isolation and atomicity.", to: fixture.app)
            let replacement = try #require(fixture.app.stageBTask)
            tasks.append(replacement)
            let newGeneration = try #require(fixture.app.currentGenerationID)
            #expect(newGeneration != oldGeneration)
            try await join(replacement)
            #expect(fixture.app.manualCaptureState == .suggestionReady)
            #expect(fixture.app.currentSuggestion?.generationID == newGeneration)
            let before = fixture.app.diagnostics
            let cardBefore = fixture.app.currentSuggestion

            // The old detached retrieval deliberately ignores cancellation up
            // to this explicitly released latch, then returns a real error.
            await retrieval.releaseAll()
            try await join(old)
            let after = fixture.app.diagnostics
            #expect(after.lastError == before.lastError,
                "An old generation error is not the replacement's error.")
            #expect(after.rawTranscript == before.rawTranscript,
                "The old transcript cannot restore itself in current diagnostics.")
            #expect(after.cleanedQuestion == before.cleanedQuestion)
            #expect(fixture.app.currentGenerationID == newGeneration)
            #expect(fixture.app.currentSuggestion == cardBefore)
            #expect(fixture.app.manualCaptureState == .suggestionReady)
            #expect(fixture.remote.requests().isEmpty)
            #expect(await fixture.original.requests().count == 1)
            try await fixture.close(tasks)
        } catch {
            // Open before joining: cancellation alone cannot release this
            // intentionally non-cooperative test operation.
            await retrieval.releaseAll()
            try? await fixture.close(tasks)
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func sameSessionContextReplacementRejectsLateRegenerateRetrievalFailure() async throws {
        let retrieval = ManualLateFailureRetrieval()
        let fixture = try await ManualSnapshotFixture(retrieval: retrieval)
        fixture.app.delayProvider = fixture.clock
        var tasks: [Task<Void, Never>] = []
        do {
            await fixture.app.automaticContextBuildTask?.value
            let firstStarted = await retrieval.firstStartSignal()
            let text = "Explain database transactions and atomicity."
            fixture.app.lastDetectedQuestion = DetectedQuestion(
                id: UUID().uuidString, sessionID: fixture.session.id, transcriptSegmentID: nil,
                questionText: text, intent: .technical, answerStrategy: .directAnswer,
                confidence: 1, reason: "Synthetic accepted current question", shouldTrigger: true,
                questionComplete: true, modelName: "fixture", promptVersion: "fixture", createdAt: Date())
            // Actual Answer Fallback regenerates the accepted current question
            // through the coordinator-owned retrieval operation.
            fixture.app.answerCurrentQuestionOrTranscriptNow()
            let old = try #require(fixture.app.activeAITask)
            tasks.append(old)
            _ = try await TestEventWaitTrace(label: "regenerate-context-replacement.held-rag")
                .nextEvent(in: firstStarted, event: "entered")
            let identity = try #require(fixture.app.activeGenerationController?.identity)
            #expect(await retrieval.callCount() == 1)
            #expect(identity.contextSnapshotID == fixture.session.contextSnapshotID)

            // Context replacement revokes result admission even when the old
            // retriever ignores cancellation or no new request starts.
            var replacement = fixture.session
            replacement.contextSnapshotID = UUID().uuidString
            fixture.app.currentSession = replacement
            let replacementError = "Synthetic replacement-context feedback"
            fixture.app.errorMessage = replacementError
            fixture.app.updateDiagnostics { $0.lastError = "Synthetic replacement-context diagnostic" }
            let feedbackBefore = fixture.app.latestActionFeedback(for: ActionID.generateAnswer)
            let diagnosticsBefore = fixture.app.diagnostics
            let cardBefore = fixture.app.currentSuggestion
            let ragBefore = fixture.app.lastRAGOperation
            #expect(!old.isCancelled)
            #expect(fixture.app.generationCoordinator.canPublish(identity),
                "Retain the old coordinator identity; only the context boundary changed.")

            await retrieval.releaseAll()
            try await fixture.join(old)
            #expect(fixture.app.currentSession?.contextSnapshotID == replacement.contextSnapshotID)
            #expect(fixture.app.errorMessage == replacementError)
            #expect(fixture.app.latestActionFeedback(for: ActionID.generateAnswer) == feedbackBefore)
            #expect(fixture.app.diagnostics.lastError == diagnosticsBefore.lastError)
            #expect(fixture.app.diagnostics.rawTranscript == diagnosticsBefore.rawTranscript)
            #expect(fixture.app.diagnostics.cleanedQuestion == diagnosticsBefore.cleanedQuestion)
            #expect(fixture.app.lastRAGOperation == ragBefore)
            #expect(fixture.app.currentSuggestion == cardBefore)
            #expect(await fixture.original.requests().isEmpty)
            #expect(fixture.remote.requests().isEmpty)
            #expect(try fixture.app.suggestionRepository.suggestions(sessionID: fixture.session.id).isEmpty)
            try await fixture.close(tasks)
        } catch {
            // Open the deliberately non-cooperative latch before any join.
            await retrieval.releaseAll()
            try? await fixture.close(tasks)
            throw error
        }
    }

    private func submit(_ text: String, to app: AppState) {
        app.manualCaptureState = .transcriptReady
        app.manualCaptureTranscript = text
        app.sendManualCaptureToAI()
    }

    private func join(_ task: Task<Void, Never>) async throws {
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
    }
}

/// Holds only the first actual RAG request. Its entry event is cancellable;
/// its SDK-like request latch is explicitly opened by every fixture exit path.
private actor ManualLateFailureRetrieval: ContextRetrievalService {
    private let firstStarted = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private var count = 0
    private var released = false
    private var held: CheckedContinuation<Void, Never>?

    func callCount() -> Int { count }
    func firstStartSignal() -> AsyncStream<Void> { firstStarted.stream }
    func releaseAll() {
        released = true
        let continuation = held
        held = nil
        continuation?.resume()
        firstStarted.continuation.finish()
    }

    func retrieveContextWithTrace(question: String, intent: QuestionIntent,
        maxCVWords: Int, maxJDWords: Int, strategy: AnswerStrategy?) async throws
        -> (context: RetrievedContext, trace: RetrievalTrace) {
        count += 1
        if count == 1 {
            firstStarted.continuation.yield(())
            firstStarted.continuation.finish()
            if !released { await withCheckedContinuation { held = $0 } }
            throw ManualLateFailure.syntheticOldRetrieval
        }
        return (RetrievedContext(cvChunks: [], jobDescriptionChunks: []),
            RetrievalTrace(id: UUID(), query: question, intent: intent.rawValue, createdAt: Date(),
                rankedCVChunks: [], rankedJDChunks: [], includedCVChunks: [], includedJDChunks: [],
                excludedCVChunks: [], excludedJDChunks: [], cvWordsUsed: 0, jdWordsUsed: 0,
                cvWordBudget: maxCVWords, jdWordBudget: maxJDWords, retrievalLatencyMS: 0,
                emptyQueryFallbackUsed: false, zeroScoreFallbackUsed: false))
    }
}

private enum ManualLateFailure: LocalizedError {
    case syntheticOldRetrieval
    var errorDescription: String? { "Synthetic revoked manual retrieval failure." }
}
