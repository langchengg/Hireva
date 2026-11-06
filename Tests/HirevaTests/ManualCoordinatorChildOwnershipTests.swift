import Foundation
import os
import Testing
@testable import Hireva

/// The real reviewed-transcript entry and router/retrieval implementations run
/// through per-test synthetic gates. Existing root cleanup is retained; these
/// tests distinguish explicit child authority from an already retained parent.
@MainActor
struct ManualCoordinatorChildOwnershipTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func actualManualRoutingIsRegisteredBeforeItsFrozenProviderStarts(cancel: Bool) async throws {
        let retrieval = ManualOwnedEntryRetrieval()
        let fixture = try await ManualSnapshotFixture(useAnswerProviderForRouting: true, retrieval: retrieval)
        let routing = ManualOwnedEntryRouter(answerProvider: fixture.original)
        let clock = fixture.clock
        fixture.app.localLLMProviderOverride = routing
        fixture.app.delayProvider = clock
        var worker: Task<Void, Never>?
        do {
            try await withTaskCancellationHandler {
                submit(to: fixture.app)
                let pending = try #require(fixture.app.generationCoordinator.stageBTask)
                worker = pending
                let identity = try #require(fixture.app.activeGenerationController?.identity)
                _ = try await TestEventWaitTrace(label: "manual-owner.routing")
                    .nextEvent(in: routing.gate.entered.stream, event: "route-provider-entered")
                #expect(routing.requests.count == 1)
                #expect(routing.requests.first?.modelName == fixture.originalModel)
                #expect(routing.requests.first?.prompt.contains(identity.questionText) == true)
                #expect(fixture.app.generationCoordinator.activeGeneration?.questionRoutingTask != nil,
                    "The real Manual route belongs to the existing Coordinator, not only an opaque Stage B root")
                #expect(fixture.app.generationCoordinator.activeGeneration?.questionSnapshot?.id == identity.acceptedQuestionID)
                #expect(fixture.app.generationCoordinator.activeGeneration?.questionSnapshot?.taskDescriptor?.decision == nil)
                let registeredChild = fixture.app.generationCoordinator.activeGeneration?.questionRoutingTask
                fixture.app.setSelectedQwenModelName("synthetic-later-model")
                fixture.app.localLLMProviderOverride = fixture.replacement
                if cancel {
                    fixture.app.cancelManualCapture()
                    #expect(pending.isCancelled)
                    #expect(registeredChild?.isCancelled == true)
                    #expect(fixture.app.currentGenerationID == nil)
                }
                routing.gate.release()
                if cancel {
                    retrieval.gate.release()
                } else {
                    _ = try await TestEventWaitTrace(label: "manual-owner.after-routing")
                        .nextEvent(in: retrieval.gate.entered.stream, event: "retrieval-entered")
                    let accepted = try #require(fixture.app.lastDetectedQuestion?.taskDescriptor?.decision)
                    #expect(fixture.app.generationCoordinator.activeGeneration?.questionSnapshot?.taskDescriptor?.decision == accepted)
                    #expect(accepted.model == fixture.originalModel)
                    #expect(fixture.app.generationCoordinator.activeGeneration?.questionRoutingTask == nil)
                    #expect(fixture.app.generationCoordinator.activeGeneration?.contextRetrievalTask != nil)
                    retrieval.gate.release()
                }
                await withTaskCancellationHandler { await pending.value } onCancel: { pending.cancel() }
                try Task.checkCancellation()
                #expect(routing.gate.exited)
                #expect(await fixture.replacement.requests().isEmpty)
                #expect(fixture.remote.requests().isEmpty)
                if cancel {
                    #expect(retrieval.calls.isEmpty)
                    #expect(await fixture.original.requests().isEmpty)
                    #expect(fixture.app.currentSuggestion == nil)
                } else {
                    #expect(fixture.app.currentSuggestion?.generationID == identity.generationID)
                    #expect(fixture.app.currentSuggestion?.detectedQuestionID == identity.acceptedQuestionID)
                    #expect(fixture.app.currentSuggestion?.modelName == fixture.originalModel)
                    #expect(fixture.app.manualCaptureState == .suggestionReady)
                    #expect(await fixture.original.requests().count == 1)
                    #expect(retrieval.calls.count == 1)
                }
            } onCancel: {
                routing.gate.release(); retrieval.gate.release(); clock.cancelAll()
            }
            routing.gate.release(); retrieval.gate.release()
            try await fixture.close(worker.map { [$0] } ?? [])
            #expect(fixture.app.generationCoordinator.pendingCleanupTaskCount == 0)
        } catch {
            routing.gate.release(); retrieval.gate.release(); clock.cancelAll(); worker?.cancel()
            await worker?.value
            try? await fixture.close(worker.map { [$0] } ?? [])
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func actualManualRetrievalRetainsItsFrozenDecisionAndOriginalBudgets(cancel: Bool) async throws {
        let retrieval = ManualOwnedEntryRetrieval()
        let fixture = try await ManualSnapshotFixture(retrieval: retrieval)
        let clock = fixture.clock
        fixture.app.delayProvider = clock
        var worker: Task<Void, Never>?
        do {
            try await withTaskCancellationHandler {
                submit(to: fixture.app)
                let pending = try #require(fixture.app.generationCoordinator.stageBTask)
                worker = pending
                _ = try await TestEventWaitTrace(label: "manual-owner.rag")
                    .nextEvent(in: retrieval.gate.entered.stream, event: "retrieval-entered")
                let identity = try #require(fixture.app.activeGenerationController?.identity)
                let acceptedQuestion = try #require(fixture.app.lastDetectedQuestion)
                let acceptedDecision = try #require(acceptedQuestion.taskDescriptor?.decision)
                #expect(fixture.app.generationCoordinator.activeGeneration?.questionSnapshot?.taskDescriptor?.decision == acceptedDecision,
                    "The completed Manual route is accepted before RAG can suspend")
                #expect(fixture.app.generationCoordinator.activeGeneration?.contextRetrievalTask != nil)
                #expect(retrieval.calls == [.init(question: identity.questionText, intent: .technical,
                    maxCVWords: 800, maxJDWords: 600, strategy: acceptedQuestion.answerStrategy)])
                let registeredChild = fixture.app.generationCoordinator.activeGeneration?.contextRetrievalTask
                if cancel {
                    fixture.app.cancelManualCapture()
                    #expect(pending.isCancelled)
                    #expect(registeredChild?.isCancelled == true)
                    #expect(fixture.app.generationCoordinator.retiringContextRetrievalTaskCount == 1,
                        "The real held child remains in the sole retirement registry until it exits")
                    #expect(fixture.app.currentGenerationID == nil)
                }
                retrieval.gate.release()
                await withTaskCancellationHandler { await pending.value } onCancel: { pending.cancel() }
                try Task.checkCancellation()
                #expect(retrieval.gate.exited)
                #expect(fixture.remote.requests().isEmpty)
                if cancel {
                    #expect(fixture.app.currentSuggestion == nil)
                    #expect(await fixture.original.requests().isEmpty)
                } else {
                    #expect(fixture.app.currentSuggestion?.generationID == identity.generationID)
                    #expect(fixture.app.currentSuggestion?.detectedQuestionID == acceptedQuestion.id)
                    #expect(fixture.app.manualCaptureState == .suggestionReady)
                    #expect(fixture.app.lastRetrievalTrace?.cvWordBudget == 800)
                    #expect(fixture.app.lastRetrievalTrace?.jdWordBudget == 600)
                    #expect(await fixture.original.requests().count == 1)
                }
            } onCancel: { retrieval.gate.release(); clock.cancelAll() }
            retrieval.gate.release()
            try await fixture.close(worker.map { [$0] } ?? [])
            #expect(fixture.app.generationCoordinator.pendingCleanupTaskCount == 0)
        } catch {
            retrieval.gate.release(); clock.cancelAll(); worker?.cancel()
            await worker?.value
            try? await fixture.close(worker.map { [$0] } ?? [])
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func actualCancelledManualCatchCannotClearASameIdentityReplacementWorkflow() async throws {
        let fixture = try await ManualSnapshotFixture(useAnswerProviderForRouting: true)
        let routing = ManualOwnedEntryRouter(answerProvider: fixture.original)
        let replacementGate = ManualOwnedEntryGate()
        let clock = fixture.clock
        fixture.app.localLLMProviderOverride = routing
        fixture.app.delayProvider = clock
        var original: Task<Void, Never>?
        var replacement: Task<Void, Never>?
        do {
            try await withTaskCancellationHandler {
                submit(to: fixture.app)
                let oldWorker = try #require(fixture.app.generationCoordinator.stageBTask)
                original = oldWorker
                _ = try await TestEventWaitTrace(label: "manual-owner.old-catch")
                    .nextEvent(in: routing.gate.entered.stream, event: "actual-routing-entered")
                let identity = try #require(fixture.app.activeGenerationController?.identity)
                let next = Task { @MainActor in await replacementGate.wait() }
                replacement = next
                fixture.app.registerStageBTask(next, generationID: identity.generationID)
                _ = try await TestEventWaitTrace(label: "manual-owner.replacement")
                    .nextEvent(in: replacementGate.entered.stream, event: "replacement-entered")
                #expect(fixture.app.generationCoordinator.isCurrent(identity))
                #expect(fixture.app.generationCoordinator.stageBTask == next)
                #expect(oldWorker.isCancelled)
                #expect(!next.isCancelled)
                routing.gate.release()
                try await fixture.join(oldWorker)
                #expect(routing.gate.exited)
                #expect(fixture.app.generationCoordinator.stageBTask == next,
                    "The actual old Manual catch must not clear a later workflow with the same full identity")
                #expect(!next.isCancelled)
                #expect(fixture.app.currentSuggestion == nil)
                #expect(fixture.remote.requests().isEmpty)
                #expect(await fixture.original.requests().isEmpty)
            } onCancel: {
                routing.gate.release(); replacementGate.release(); clock.cancelAll()
            }
            replacementGate.release()
            await replacement?.value
            try await fixture.close([original, replacement].compactMap { $0 })
            #expect(fixture.app.generationCoordinator.pendingCleanupTaskCount == 0)
        } catch {
            routing.gate.release(); replacementGate.release(); clock.cancelAll()
            original?.cancel(); replacement?.cancel()
            await original?.value
            await replacement?.value
            try? await fixture.close([original, replacement].compactMap { $0 })
            throw error
        }
    }

    private func submit(to app: AppState) {
        app.manualCaptureState = .transcriptReady
        app.manualCaptureTranscript = "Explain database transactions and atomicity."
        app.sendManualCaptureToAI()
    }
}

/// One exactly retained continuation, released on every normal/cancel/error path.
/// It deliberately ignores child cancellation before release, so a cancelled
/// caller cannot pretend that the synthetic SDK operation has already exited.
private final class ManualOwnedEntryGate: Sendable {
    private struct State: Sendable {
        var released = false
        var entered = false
        var exited = false
        var waiter: CheckedContinuation<Void, Never>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
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
    func wait() async {
        await withCheckedContinuation { continuation in
            let immediate = state.withLock { state in
                precondition(!state.entered, "Each synthetic child gate is used once")
                state.entered = true
                guard !state.released else { return true }
                state.waiter = continuation
                return false
            }
            entered.continuation.yield(())
            if immediate { continuation.resume() }
        }
        state.withLock { $0.exited = true }
    }
}

private final class ManualOwnedEntryRouter: LocalLLMProvider, Sendable {
    let id = "synthetic-manual-owner-route"
    var displayName: String { id }
    let gate = ManualOwnedEntryGate()
    private let captured = OSAllocatedUnfairLock(initialState: [LocalLLMRequest]())
    private let answerProvider: ManualSnapshotLocalProvider
    var requests: [LocalLLMRequest] { captured.withLock { $0 } }
    init(answerProvider: ManualSnapshotLocalProvider) { self.answerProvider = answerProvider }
    func healthCheck(modelName: String) async -> LocalLLMHealth {
        .init(ollamaRunning: true, selectedModel: modelName, modelInstalled: true,
            providerSource: .ollamaQwen, lastError: nil)
    }
    func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        if request.responseSchema == nil { return try await answerProvider.generateAnswer(request: request) }
        captured.withLock { $0.append(request) }
        await gate.wait()
        try Task.checkCancellation()
        return try await HermeticQuestionRoutingProvider().generateAnswer(request: request)
    }
}

private final class ManualOwnedEntryRetrieval: ContextRetrievalService, Sendable {
    struct Call: Equatable, Sendable {
        let question: String
        let intent: QuestionIntent
        let maxCVWords: Int
        let maxJDWords: Int
        let strategy: AnswerStrategy?
    }
    let gate = ManualOwnedEntryGate()
    private let captured = OSAllocatedUnfairLock(initialState: [Call]())
    var calls: [Call] { captured.withLock { $0 } }
    func retrieveContextWithTrace(question: String, intent: QuestionIntent, maxCVWords: Int,
        maxJDWords: Int, strategy: AnswerStrategy?) async throws -> (context: RetrievedContext, trace: RetrievalTrace) {
        captured.withLock { $0.append(.init(question: question, intent: intent,
            maxCVWords: maxCVWords, maxJDWords: maxJDWords, strategy: strategy)) }
        await gate.wait()
        try Task.checkCancellation()
        return (RetrievedContext(cvChunks: [], jobDescriptionChunks: []),
            RetrievalTrace(id: UUID(), query: question, intent: intent.rawValue, createdAt: Date(),
                rankedCVChunks: [], rankedJDChunks: [], includedCVChunks: [], includedJDChunks: [],
                excludedCVChunks: [], excludedJDChunks: [], cvWordsUsed: 0, jdWordsUsed: 0,
                cvWordBudget: maxCVWords, jdWordBudget: maxJDWords, retrievalLatencyMS: 0,
                emptyQueryFallbackUsed: false, zeroScoreFallbackUsed: false))
    }
}
