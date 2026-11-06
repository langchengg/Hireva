import Foundation
import Testing
import os
@testable import Hireva

/// Actual reviewed-transcript entry and Stop/settings policy; no microphone,
/// remote call or detached test task is used. The RAG gate is always released
/// before joining owned work, including failing assertion/require paths.
@MainActor
struct ManualRetrievalCancellationOwnershipTests {
    @Test(.serialized, .timeLimit(.minutes(1)), arguments: 0..<20)
    func reviewedManualCancellationReachesItsCooperativeRetrieval(order: Int) async throws {
        // Original alternating stop/mode order, ten executions of each.
        let action = CancellationAction.allCases[order % CancellationAction.allCases.count]
        let repetition = order / CancellationAction.allCases.count
        try await exercise(action: action, repetition: repetition)
    }

    private func exercise(action: CancellationAction, repetition: Int) async throws {
        let retrieval = ManualCooperativeRetrievalGate()
        let fixture = try await ManualSnapshotFixture(retrieval: retrieval)
        fixture.app.delayProvider = fixture.clock
        var owned: Task<Void, Never>?
        do {
            fixture.app.manualCaptureState = .transcriptReady
            fixture.app.manualCaptureTranscript = "Explain database transactions and atomicity."
            fixture.app.sendManualCaptureToAI()
            let task = try #require(fixture.app.stageBTask)
            owned = task
            _ = try await TestEventWaitTrace(label: "manual-rag-cancel-\(action.rawValue)-\(repetition)")
                .nextEvent(in: retrieval.entered.stream, event: "retrieval-entered")
            #expect(retrieval.callCount == 1)
            #expect(await fixture.original.requests().isEmpty)

            switch action {
            case .stop: fixture.app.cancelManualCapture()
            case .mode: fixture.app.setSelectedAnswerProviderMode(.deepSeekPrimary)
            }
            #expect(task.isCancelled)
            #expect(fixture.app.currentGenerationID == nil)
            // The original implementation's unstructured RAG operation is not
            // cancelled. Release it explicitly so the red run cannot hang.
            retrieval.release()
            await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            #expect(retrieval.observedCancellation,
                "The actual cooperative RAG request must receive cancellation, not merely have its answer rejected afterwards.")
            #expect(retrieval.exited)
            #expect(fixture.app.currentSuggestion == nil)
            #expect(await fixture.original.requests().isEmpty)
            #expect(fixture.remote.requests().isEmpty)
            #expect(!fixture.app.isActionLoading(ActionID.manualGenerate))
            #expect(try fixture.app.suggestionRepository.suggestions(sessionID: fixture.session.id).isEmpty)
            try await fixture.close([task])
            #expect(fixture.app.generationCoordinator.pendingCleanupTaskCount == 0)
        } catch {
            retrieval.release()
            owned?.cancel()
            await owned?.value
            try? await fixture.close(owned.map { [$0] } ?? [])
            throw error
        }
    }

    private enum CancellationAction: String, CaseIterable { case stop, mode }
}

/// Immutable transport-like channels and one checked lock protect the facts
/// observed by this fixture. No ordinary lock is held across suspension.
private final class ManualCooperativeRetrievalGate: ContextRetrievalService, Sendable {
    private struct State: Sendable {
        var calls = 0
        var cancellation = false
        var exited = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private let releaseGate = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    var callCount: Int { state.withLock { $0.calls } }
    var observedCancellation: Bool { state.withLock { $0.cancellation } }
    var exited: Bool { state.withLock { $0.exited } }

    func release() { releaseGate.continuation.yield(()); releaseGate.continuation.finish() }

    func retrieveContextWithTrace(question: String, intent: QuestionIntent, maxCVWords: Int,
        maxJDWords: Int, strategy: AnswerStrategy?) async throws -> (context: RetrievedContext, trace: RetrievalTrace) {
        state.withLock { $0.calls += 1 }
        defer { state.withLock { $0.exited = true } }
        entered.continuation.yield(())
        entered.continuation.finish()
        await withTaskCancellationHandler {
            var iterator = releaseGate.stream.makeAsyncIterator()
            _ = await iterator.next()
        } onCancel: {
            self.state.withLock { $0.cancellation = true }
        }
        try Task.checkCancellation()
        return (RetrievedContext(cvChunks: [], jobDescriptionChunks: []),
            RetrievalTrace(id: UUID(), query: question, intent: intent.rawValue, createdAt: Date(),
                rankedCVChunks: [], rankedJDChunks: [], includedCVChunks: [], includedJDChunks: [],
                excludedCVChunks: [], excludedJDChunks: [], cvWordsUsed: 0, jdWordsUsed: 0,
                cvWordBudget: maxCVWords, jdWordBudget: maxJDWords, retrievalLatencyMS: 0,
                emptyQueryFallbackUsed: false, zeroScoreFallbackUsed: false))
    }
}
