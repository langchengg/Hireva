import Combine
import Foundation
import os
import Testing
@testable import Hireva

/// The actual reviewed-transcript entry, registered watchdog and Stage B clear
/// run against controlled synthetic inputs. No audio device or network is used.
@MainActor
struct ManualFullDeadlineAdmissionTests {
    @Test(.timeLimit(.minutes(1)), arguments: DeadlineReplacementBoundary.allCases, [false, true])
    fileprivate func fullDeadlineCannotChangeReplacementManualState(
        boundary: DeadlineReplacementBoundary, replace: Bool
    ) async throws {
        let retrieval = ManualFullDeadlineHeldRetrieval()
        let fixture = try await ManualSnapshotFixture(retrieval: retrieval)
        fixture.app.delayProvider = fixture.clock
        let clock = fixture.clock
        var originalWorker: Task<Void, Never>?
        var originalDeadline: Task<Void, Never>?
        var originalFallback: Task<Void, Never>?
        var replacementAnswer: Task<String, Error>?
        var observation: AnyCancellable?
        var replaced = false
        let replacementID = UUID().uuidString
        let replacementQuestion = DetectedQuestion(id: UUID().uuidString, sessionID: fixture.session.id,
            transcriptSegmentID: nil, questionText: "Explain database isolation and concurrent transaction visibility.",
            intent: .technical, answerStrategy: .technicalExplanation, confidence: 1,
            reason: "Synthetic watchdog subscriber replacement", shouldTrigger: true, questionComplete: true,
            modelName: "synthetic-no-provider", promptVersion: "synthetic-no-provider", createdAt: Date())

        @MainActor func cleanup() async throws {
            observation?.cancel()
            retrieval.release()
            fixture.clock.cancelAll()
            originalWorker?.cancel()
            originalDeadline?.cancel()
            originalFallback?.cancel()
            await originalWorker?.value
            await originalDeadline?.value
            await originalFallback?.value
            _ = await replacementAnswer?.result
            try await fixture.close(originalWorker.map { [$0] } ?? [])
        }
        do {
            try await withTaskCancellationHandler {
                fixture.app.manualCaptureTranscript = "Explain database transactions and atomicity."
                fixture.app.manualCaptureState = .transcriptReady
                let fullPeriod = fixture.app.generationFullCardWatchdogNanoseconds
                fixture.app.sendManualCaptureToAI()
                let requiredOriginalWorker: Task<Void, Never> = try #require(fixture.app.generationCoordinator.stageBTask)
                originalWorker = requiredOriginalWorker
                let requiredOriginalDeadline: Task<Void, Never> = try #require(fixture.app.generationCoordinator.fullCardWatchdogTask)
                originalDeadline = requiredOriginalDeadline
                let requiredOriginalFallback: Task<Void, Never> = try #require(fixture.app.generationCoordinator.fallbackWatchdogTask)
                originalFallback = requiredOriginalFallback
                let originalIdentity = try #require(fixture.app.activeGenerationController?.identity)
                _ = try await TestEventWaitTrace(label: "manual-full-deadline.rag")
                    .nextEvent(in: retrieval.entered.stream, event: "held-retrieval")
                try await fixture.clock.waitUntilPending(nanoseconds: fullPeriod)
                try #require(fixture.app.lastDetectedQuestion?.id == originalIdentity.acceptedQuestionID)
                try #require(fixture.app.lastDetectedQuestion?.taskDescriptor?.decision != nil)
                try #require(fixture.app.generationCoordinator.stageBTask != nil)

                observation = fixture.app.generationCoordinator.objectWillChange.sink { _ in
                    guard replace, !replaced,
                          fixture.app.generationCoordinator.isCurrent(originalIdentity) else { return }
                    let reached: Bool
                    switch boundary {
                    case .stageBRetired:
                        reached = fixture.app.generationCoordinator.stageBTask == nil
                    case .terminal:
                        reached = fixture.app.terminalGenerationIDs.contains(originalIdentity.generationID)
                    }
                    guard reached else { return }
                    replaced = true
                    fixture.app.activateGeneration(question: replacementQuestion,
                        generationID: replacementID, triggerPath: .regenerate,
                        requestStart: Date(), source: .systemAudio, speaker: .unknown)
                    fixture.app.lastDetectedQuestion = replacementQuestion
                    fixture.app.manualCaptureState = .generatingSuggestion
                    fixture.app.manualCaptureSuggestion = nil
                    fixture.app.beginAction(ActionID.manualGenerate,
                        title: "Synthetic replacement pending", message: "Q2 retains its own loading state")
                    let answer = Task<String, Error> { "Finite Q2-owned answer" }
                    replacementAnswer = answer
                    fixture.app.registerStageATask(answer, generationID: replacementID)
                }
                fixture.clock.advance(by: fullPeriod)
                await originalDeadline?.value
                try Task.checkCancellation()
                observation?.cancel()
                if replace {
                    #expect(replaced, "The actual watchdog must reach the selected publication boundary")
                    #expect(fixture.app.currentGenerationID == replacementID)
                    #expect(fixture.app.activeQuestionID == replacementQuestion.id)
                    #expect(fixture.app.manualCaptureState == .generatingSuggestion,
                        "A retired Q1 watchdog cannot overwrite Q2's current manual state")
                    #expect(fixture.app.manualCaptureSuggestion == nil)
                    #expect(fixture.app.currentSuggestion == nil)
                    #expect(fixture.app.generationUIState == .preparing(questionID: replacementQuestion.id,
                        generationID: replacementID, triggerPath: .regenerate))
                    #expect(fixture.app.currentGenerationTelemetry.generationID == replacementID)
                    #expect(fixture.app.currentGenerationTelemetry.failureReason == nil)
                    #expect(fixture.app.isActionLoading(ActionID.manualGenerate))
                    #expect(fixture.app.generationCoordinator.stageATask == replacementAnswer)
                    #expect(replacementAnswer?.isCancelled == false)
                } else {
                    #expect(!replaced)
                    #expect(fixture.app.currentGenerationID == originalIdentity.generationID)
                    #expect(fixture.app.manualCaptureState == .suggestionError("Local answer timed out. Retry is available."))
                    #expect(fixture.app.terminalGenerationIDs.contains(originalIdentity.generationID))
                    #expect(fixture.app.generationUIState.isTerminal)
                    #expect(fixture.app.currentGenerationTelemetry.failureReason == "Local manual answer timed out.")
                    #expect(!fixture.app.isActionLoading(ActionID.manualGenerate))
                }
                #expect(originalWorker?.isCancelled == true)
                #expect(retrieval.callCount == 1)
                #expect(await fixture.original.requests().isEmpty)
                #expect(fixture.remote.requests().isEmpty)
                let history = try fixture.app.suggestionRepository.suggestions(sessionID: fixture.session.id)
                #expect(history.isEmpty, "A watchdog error is not a qualified persisted answer")
            } onCancel: {
                retrieval.release()
                clock.cancelAll()
            }
            try await cleanup()
            #expect(retrieval.exited)
            #expect(fixture.app.generationCoordinator.pendingCleanupTaskCount == 0)
        } catch {
            try? await cleanup()
            throw error
        }
    }

    enum ExistingManualDeadlineBranch: CaseIterable, Equatable, Sendable {
        case routeIncomplete, keepQualifiedFirstAnswer
    }

    /// Existing business branches run through actual submission, route/timer
    /// and first-answer display validation; no model or audio hardware is used.
    @Test(.timeLimit(.minutes(1)), arguments: ExistingManualDeadlineBranch.allCases)
    func actualFullDeadlinePreservesClassificationAndQualifiedFirstAnswerPolicy(
        branch: ExistingManualDeadlineBranch
    ) async throws {
        let retrieval = ManualFullDeadlineHeldRetrieval()
        let routeGate = ManualFullDeadlineHeldRetrieval()
        let fixture = try await ManualSnapshotFixture(mode: .deepSeekPrimary,
            useAnswerProviderForRouting: branch == .routeIncomplete, retrieval: retrieval)
        let clock = fixture.clock
        fixture.app.delayProvider = clock
        if branch == .routeIncomplete {
            fixture.app.localLLMProviderOverride = ManualFullDeadlineHeldRouter(gate: routeGate)
        }
        var worker: Task<Void, Never>?
        var deadline: Task<Void, Never>?
        var fallback: Task<Void, Never>?
        @MainActor func cleanup() async throws {
            routeGate.release(); retrieval.release(); clock.cancelAll()
            worker?.cancel(); deadline?.cancel(); fallback?.cancel()
            await worker?.value; await deadline?.value; await fallback?.value
            try await fixture.close([worker, deadline, fallback].compactMap { $0 })
        }
        do {
            try await withTaskCancellationHandler {
                fixture.app.manualCaptureState = .transcriptReady
                fixture.app.manualCaptureTranscript = "Explain database transactions and atomicity."
                fixture.app.sendManualCaptureToAI()
                let workflow = try #require(fixture.app.stageBTask)
                worker = workflow
                let full = try #require(fixture.app.fullCardWatchdogTask)
                deadline = full
                let first = try #require(fixture.app.softFallbackTask)
                fallback = first
                let identity = try #require(fixture.app.activeGenerationController?.identity)
                let gate = branch == .routeIncomplete ? routeGate : retrieval
                _ = try await TestEventWaitTrace(label: "manual-full-existing-branch")
                    .nextEvent(in: gate.entered.stream, event: "actual-worker-held")
                let fullPeriod = fixture.app.generationFullCardWatchdogNanoseconds
                try await clock.waitUntilPending(nanoseconds: fullPeriod)
                var visible: SuggestionCard?
                if branch == .keepQualifiedFirstAnswer {
                    try await clock.waitUntilPending(nanoseconds: 1_500_000_000)
                    let detected = try #require(fixture.app.lastDetectedQuestion)
                    // This fixture has no personal evidence, so its template is
                    // correctly empty. Supply a controlled general first answer
                    // through the actual display validator, not a template/model
                    // quality claim or an unvalidated currentSuggestion assignment.
                    var proposed = SuggestionCard(id: "synthetic-qualified-first-answer",
                        sessionID: identity.sessionID, questionID: identity.acceptedQuestionID,
                        strategy: "General technical explanation",
                        sayFirst: "A database transaction groups operations into an atomic unit. Atomicity means all operations commit together or roll back together, and isolation controls which concurrent changes each transaction can observe.",
                        keyPoints: [], followUpReady: [], confidence: 1, caution: nil,
                        evidenceUsed: [], riskLevel: .low, modelName: "synthetic-controlled-answer",
                        promptVersion: "synthetic-controlled-answer", createdAt: Date())
                    proposed.questionText = detected.questionText
                    proposed.promptPrimaryQuestion = detected.questionText
                    proposed.generationID = identity.generationID
                    proposed.contextSnapshotID = identity.contextSnapshotID
                    proposed.stageBCompleted = false
                    try #require(fixture.app.displaySuggestionIfAligned(proposed,
                        question: detected, generationID: identity.generationID, triggerPath: .manualCapture))
                    let qualified = try #require(fixture.app.currentSuggestion)
                    try #require(QuestionRuntimeAcceptanceGuard.validateSuggestionCardForPersistence(qualified).accepted)
                    fixture.app.manualCaptureSuggestion = qualified
                    fixture.app.manualCaptureState = .suggestionReady
                    visible = qualified
                    clock.advance(by: 1_500_000_000)
                    await first.value
                    #expect(fixture.app.currentSuggestion == qualified)
                    clock.advance(by: fullPeriod - 1_500_000_000)
                } else {
                    try #require(fixture.app.generationCoordinator.activeGeneration?.questionSnapshot?.taskDescriptor?.decision == nil)
                    clock.advance(by: fullPeriod)
                }
                await full.value
                #expect(fixture.app.generationUIState.isTerminal && fixture.app.terminalGenerationIDs.contains(identity.generationID))
                #expect(workflow.isCancelled && fixture.app.stageBTask == nil)
                if branch == .routeIncomplete {
                    #expect(fixture.app.manualCaptureState == .suggestionError("Question classification did not complete. Retry is available."))
                    #expect(fixture.app.currentGenerationTelemetry.failureReason == "Manual question classification did not complete.")
                    #expect(fixture.app.currentSuggestion == nil && fixture.app.manualCaptureSuggestion == nil)
                    #expect(retrieval.callCount == 0)
                } else {
                    #expect(fixture.app.currentGenerationTelemetry.failureReason == "Manual capture full answer timed out.")
                    #expect(fixture.app.currentSuggestion == visible && fixture.app.manualCaptureSuggestion == visible)
                    #expect(fixture.app.manualCaptureState == .suggestionReady)
                    #expect(fixture.app.latestActionFeedback(for: ActionID.manualGenerate)?.title == "First answer visible")
                    #expect(retrieval.callCount == 1)
                }
                #expect(!fixture.app.isActionLoading(ActionID.manualGenerate))
                let localRequests = await fixture.original.requests()
                #expect(fixture.remote.requests().isEmpty && localRequests.isEmpty)
                #expect(try fixture.app.suggestionRepository.suggestions(sessionID: fixture.session.id).isEmpty)
            } onCancel: { routeGate.release(); retrieval.release(); clock.cancelAll() }
            try await cleanup()
            #expect(fixture.app.generationCoordinator.pendingCleanupTaskCount == 0)
        } catch {
            try? await cleanup()
            throw error
        }
    }

    /// A replacement Stage B with the same complete identity is a later role,
    /// not permission for this fired deadline to terminate that replacement.
    @Test(.timeLimit(.minutes(1)))
    func actualFullDeadlineCannotTerminateSameIdentityReplacementStageB() async throws {
        let retrieval = ManualFullDeadlineHeldRetrieval()
        let fixture = try await ManualSnapshotFixture(retrieval: retrieval)
        let clock = fixture.clock
        let replacementClock = ControlledGenerationWatchdogClock()
        fixture.app.delayProvider = clock
        var worker: Task<Void, Never>?
        var deadline: Task<Void, Never>?
        var fallback: Task<Void, Never>?
        var replacement: Task<Void, Never>?
        var observation: AnyCancellable?
        var replaced = false
        let marker = "Synthetic same-identity replacement workflow"
        @MainActor func cleanup() async throws {
            observation?.cancel(); retrieval.release(); clock.cancelAll(); replacementClock.cancelAll()
            worker?.cancel(); deadline?.cancel(); fallback?.cancel(); replacement?.cancel()
            await worker?.value; await deadline?.value; await fallback?.value; await replacement?.value
            try await fixture.close([worker, deadline, fallback, replacement].compactMap { $0 })
        }
        do {
            try await withTaskCancellationHandler {
                fixture.app.manualCaptureState = .transcriptReady
                fixture.app.manualCaptureTranscript = "Explain database transactions and atomicity."
                fixture.app.sendManualCaptureToAI()
                let workflow = try #require(fixture.app.stageBTask)
                worker = workflow
                let full = try #require(fixture.app.fullCardWatchdogTask)
                deadline = full
                let first = try #require(fixture.app.softFallbackTask)
                fallback = first
                let identity = try #require(fixture.app.activeGenerationController?.identity)
                _ = try await TestEventWaitTrace(label: "manual-full-role-replacement")
                    .nextEvent(in: retrieval.entered.stream, event: "retrieval-held")
                let fullPeriod = fixture.app.generationFullCardWatchdogNanoseconds
                try await clock.waitUntilPending(nanoseconds: fullPeriod)
                observation = fixture.app.generationCoordinator.objectWillChange.sink { _ in
                    guard !replaced, fixture.app.generationCoordinator.isCurrent(identity),
                          fixture.app.stageBTask == nil else { return }
                    replaced = true
                    let newer = Task<Void, Never> {
                        _ = try? await replacementClock.sleep(nanoseconds: 2_500_000_000)
                    }
                    replacement = newer
                    fixture.app.registerStageBTask(newer, generationID: identity.generationID)
                    fixture.app.manualCaptureState = .generatingSuggestion
                    fixture.app.manualCaptureSuggestion = nil
                    fixture.app.generationUIState = .idle
                    fixture.app.beginAction(ActionID.manualGenerate, title: marker, message: marker)
                }
                clock.advance(by: fullPeriod)
                await full.value
                observation?.cancel()
                let newer = try #require(replacement)
                #expect(replaced && workflow.isCancelled)
                #expect(fixture.app.generationCoordinator.canPublish(identity))
                #expect(fixture.app.stageBTask == newer && !newer.isCancelled)
                #expect(fixture.app.manualCaptureState == .generatingSuggestion && fixture.app.manualCaptureSuggestion == nil)
                #expect(fixture.app.currentSuggestion == nil && fixture.app.generationUIState == .idle)
                #expect(fixture.app.isActionLoading(ActionID.manualGenerate))
                #expect(fixture.app.latestActionFeedback(for: ActionID.manualGenerate)?.title == marker)
                #expect(fixture.app.currentGenerationTelemetry.failureReason == nil)
                let localRequests = await fixture.original.requests()
                #expect(fixture.remote.requests().isEmpty && localRequests.isEmpty)
            } onCancel: { retrieval.release(); clock.cancelAll(); replacementClock.cancelAll() }
            try await cleanup()
            #expect(fixture.app.generationCoordinator.pendingCleanupTaskCount == 0)
        } catch {
            try? await cleanup()
            throw error
        }
    }
}

fileprivate enum DeadlineReplacementBoundary: CaseIterable, Sendable { case stageBRetired, terminal }

/// Ignores cancellation only until its owning test opens the explicit latch.
/// This makes joining the real retired Stage B work observable and finite.
private final class ManualFullDeadlineHeldRetrieval: ContextRetrievalService, Sendable {
    private struct State: Sendable {
        var calls = 0
        var exited = false
        var released = false
        var waiter: CheckedContinuation<Void, Never>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    var callCount: Int { state.withLock { $0.calls } }
    var exited: Bool { state.withLock { $0.exited } }
    func release() {
        let waiter = state.withLock { state in
            state.released = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
        entered.continuation.finish()
    }
    func retrieveContextWithTrace(question: String, intent: QuestionIntent, maxCVWords: Int,
        maxJDWords: Int, strategy: AnswerStrategy?) async throws -> (context: RetrievedContext, trace: RetrievalTrace) {
        state.withLock { $0.calls += 1 }
        defer { state.withLock { $0.exited = true } }
        await withCheckedContinuation { continuation in
            let immediate = state.withLock { state in
                guard !state.released else { return true }
                state.waiter = continuation
                return false
            }
            entered.continuation.yield(())
            if immediate { continuation.resume() }
        }
        throw CancellationError()
    }
}


/// The route remains blocked until this test explicitly releases it. Its gate
/// and cancelled router child are retained and joined on every exit path.
private struct ManualFullDeadlineHeldRouter: LocalLLMProvider {
    let gate: ManualFullDeadlineHeldRetrieval
    let id = "synthetic-manual-full-deadline-held-router"
    var displayName: String { id }
    func healthCheck(modelName: String) async -> LocalLLMHealth {
        .init(ollamaRunning: true, selectedModel: modelName, modelInstalled: true,
            providerSource: .ollamaQwen, lastError: nil)
    }
    func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        _ = try await gate.retrieveContextWithTrace(question: "Synthetic route latch", intent: .technical,
            maxCVWords: 0, maxJDWords: 0, strategy: nil)
        try Task.checkCancellation()
        return try await HermeticQuestionRoutingProvider().generateAnswer(request: request)
    }
}
