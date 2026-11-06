import Foundation
import os
import Testing
@testable import Hireva

/// Characterization of the new owner API, separate from the unchanged actual
/// entry regression. Apply after the RAG ownership production patch.
@MainActor
struct GenerationRAGOwnershipTests {
    @Test(.timeLimit(.minutes(1)))
    func ragOwnerKeepsTheExistingTupleProtocolAndFrozenValueInputs() async throws {
        let retrieval = RetainedRAGGate()
        let owner = GenerationCoordinator()
        let identity = makeIdentity(generation: "rag-parity")
        var request: Task<(context: RetrievedContext, trace: RetrievalTrace), Error>?
        do {
            activate(owner, identity: identity)
            let pending = Task {
                try await owner.retrieveContext(identity: identity, service: retrieval,
                    question: identity.questionText, intent: .technical, maxCVWords: 300,
                    maxJDWords: 180, strategy: .directAnswer)
            }
            request = pending
            #expect(try await retrieval.nextStart() == 1)
            #expect(owner.activeGeneration?.contextRetrievalTask != nil)
            #expect(owner.pendingCleanupTaskCount == 1)
            retrieval.release(1)
            let output = try await pending.value
            #expect(output.context.cvChunks.isEmpty)
            #expect(output.trace.query == identity.questionText)
            #expect(output.trace.intent == QuestionIntent.technical.rawValue)
            #expect(output.trace.cvWordBudget == 300)
            #expect(output.trace.jdWordBudget == 180)
            #expect(retrieval.calls == [.init(question: identity.questionText, intent: .technical,
                maxCVWords: 300, maxJDWords: 180, strategy: .directAnswer)])
            #expect(owner.activeGeneration?.contextRetrievalTask == nil)
            await owner.drainRetiredTasks()
            #expect(owner.pendingCleanupTaskCount == 0)
            #expect(retrieval.pendingGateCount == 0)
        } catch {
            request?.cancel(); retrieval.releaseAll()
            _ = await request?.result
            _ = await owner.shutdownAndDrain()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: Array(0..<20))
    func retiredRAGCannotReturnOrClearANewerExactRegistration(ordinal: Int) async throws {
        // Five fixed orderings, repeated four times. Every noncooperative
        // continuation is released and every caller is joined on all paths.
        let retrieval = RetainedRAGGate()
        let owner = GenerationCoordinator()
        let identity = makeIdentity(generation: "old-rag-\(ordinal)", snapshot: "old-context")
        var old: Task<(context: RetrievedContext, trace: RetrievalTrace), Error>?
        var new: Task<(context: RetrievedContext, trace: RetrievalTrace), Error>?
        do {
            activate(owner, identity: identity)
            let first = Task {
                try await owner.retrieveContext(identity: identity, service: retrieval,
                    question: identity.questionText, intent: .technical, maxCVWords: 300,
                    maxJDWords: 180, strategy: .directAnswer)
            }
            old = first
            #expect(try await retrieval.nextStart() == 1)
            let firstChild = try #require(owner.activeGeneration?.contextRetrievalTask)
            var next: GenerationIdentity?
            switch ordinal % 5 {
            case 0: first.cancel()
            case 1: owner.markTerminal(generationID: identity.generationID)
            case 2:
                next = makeIdentity(generation: "new-rag-\(ordinal)", snapshot: "new-context")
                activate(owner, identity: try #require(next))
            case 3:
                next = makeIdentity(generation: identity.generationID, snapshot: "new-context")
                activate(owner, identity: try #require(next))
            default: next = identity
            }
            if let next {
                let second = Task {
                    try await owner.retrieveContext(identity: next, service: retrieval,
                        question: next.questionText, intent: .technical, maxCVWords: 240,
                        maxJDWords: 120, strategy: .directAnswer)
                }
                new = second
                #expect(try await retrieval.nextStart() == 2)
                let secondChild = try #require(owner.activeGeneration?.contextRetrievalTask)
                #expect(firstChild.isCancelled)
                #expect(!secondChild.isCancelled)
                #expect(owner.retiringContextRetrievalTaskCount == 1)
                #expect(retrieval.pendingGateCount == 2)
                // Old cleanup runs while the newer retrieval remains held.
                retrieval.release(1)
                #expect(await cancelled(first))
                #expect(owner.activeGeneration?.contextRetrievalTask != nil)
                #expect(!secondChild.isCancelled)
                #expect(owner.isCurrent(next))
                #expect(retrieval.pendingGateCount == 1)
                retrieval.release(2)
                let output = try await second.value
                #expect(output.trace.cvWordBudget == 240)
                #expect(output.trace.jdWordBudget == 120)
            } else {
                retrieval.release(1)
                #expect(await cancelled(first))
            }
            #expect(owner.activeGeneration?.contextRetrievalTask == nil)
            await owner.drainRetiredTasks()
            #expect(owner.retiringContextRetrievalTaskCount == 0)
            #expect(owner.pendingCleanupTaskCount == 0)
            #expect(retrieval.pendingGateCount == 0)
        } catch {
            old?.cancel(); new?.cancel(); retrieval.releaseAll()
            _ = await old?.result; _ = await new?.result
            _ = await owner.shutdownAndDrain()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func shutdownDeadlineCannotClaimAnUnreleasedRetrievalHasExited() async throws {
        let retrieval = RetainedRAGGate()
        let owner = GenerationCoordinator()
        let identity = makeIdentity(generation: "rag-held-shutdown")
        let clock = ControlledGenerationWatchdogClock()
        var request: Task<(context: RetrievedContext, trace: RetrievalTrace), Error>?
        var shutdown: Task<Bool, Never>?
        do {
            activate(owner, identity: identity)
            let pending = Task {
                try await owner.retrieveContext(identity: identity, service: retrieval,
                    question: identity.questionText, intent: .technical, maxCVWords: 300,
                    maxJDWords: 180, strategy: .directAnswer)
            }
            request = pending
            #expect(try await retrieval.nextStart() == 1)
            let stopping = Task { await owner.shutdownAndDrain(timeout: 2, delayProvider: clock) }
            shutdown = stopping
            try await clock.waitUntilScheduled()
            clock.advance(by: 2_000_000_000)
            #expect(await stopping.value == false)
            #expect(owner.retiringContextRetrievalTaskCount == 1)
            #expect(owner.pendingCleanupTaskCount == 1)
            #expect(retrieval.pendingGateCount == 1)
            retrieval.releaseAll()
            #expect(await cancelled(pending))
            await owner.drainRetiredTasks()
            #expect(owner.pendingCleanupTaskCount == 0)
            #expect(retrieval.pendingGateCount == 0)
            clock.cancelAll()
        } catch {
            request?.cancel(); shutdown?.cancel(); clock.cancelAll(); retrieval.releaseAll()
            _ = await request?.result; _ = await shutdown?.value
            _ = await owner.shutdownAndDrain()
            throw error
        }
    }

    private func makeIdentity(generation: String, snapshot: String? = nil) -> GenerationIdentity {
        .init(acceptedQuestionID: "synthetic-rag-question", generationID: generation,
            sessionID: "synthetic-rag-session", questionText: "Explain database transactions and atomicity.",
            promptPrimaryQuestion: "Explain database transactions and atomicity.", contextSnapshotID: snapshot)
    }
    private func activate(_ owner: GenerationCoordinator, identity: GenerationIdentity) {
        owner.activate(identity: identity, persistenceTicket: 0, triggerPath: .manualGenerate,
            startedAt: Date(timeIntervalSince1970: 1))
    }
    private func cancelled(_ task: Task<(context: RetrievedContext, trace: RetrievalTrace), Error>) async -> Bool {
        switch await task.result {
        case .success: return false
        case .failure(let error): return error is CancellationError
        }
    }
}

/// One per-test checked lock. The only suspended continuations intentionally
/// ignore cancellation; releaseAll is synchronous and runs before every join.
private final class RetainedRAGGate: ContextRetrievalService, Sendable {
    struct Call: Equatable, Sendable {
        let question: String
        let intent: QuestionIntent
        let maxCVWords: Int
        let maxJDWords: Int
        let strategy: AnswerStrategy?
    }
    private struct State: Sendable {
        var calls: [Call] = []
        var released = Set<Int>()
        var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
        var closed = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let started = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(8))
    var calls: [Call] { state.withLock { $0.calls } }
    var pendingGateCount: Int { state.withLock { $0.waiters.count } }
    func nextStart() async throws -> Int {
        try await TestEventWaitTrace(label: "owned-rag.gate")
            .nextEvent(in: started.stream, event: "retrieval-entered")
    }
    func release(_ ordinal: Int) {
        let waiter = state.withLock { state in
            state.released.insert(ordinal)
            return state.waiters.removeValue(forKey: ordinal)
        }
        waiter?.resume()
    }
    func releaseAll() {
        let waiters = state.withLock { state in
            state.closed = true
            let pending = Array(state.waiters.values)
            state.waiters.removeAll()
            return pending
        }
        waiters.forEach { $0.resume() }
        started.continuation.finish()
    }
    func retrieveContextWithTrace(question: String, intent: QuestionIntent, maxCVWords: Int,
        maxJDWords: Int, strategy: AnswerStrategy?) async throws -> (context: RetrievedContext, trace: RetrievalTrace) {
        let ordinal = state.withLock { state in
            state.calls.append(.init(question: question, intent: intent, maxCVWords: maxCVWords,
                maxJDWords: maxJDWords, strategy: strategy))
            return state.calls.count
        }
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { state in
                guard !state.closed, !state.released.contains(ordinal) else { return true }
                state.waiters[ordinal] = continuation
                return false
            }
            started.continuation.yield(ordinal)
            if resumeNow { continuation.resume() }
        }
        // Deliberately return even after cancellation to exercise owner guards.
        return (RetrievedContext(cvChunks: [], jobDescriptionChunks: []),
            RetrievalTrace(id: UUID(), query: question, intent: intent.rawValue, createdAt: Date(),
                rankedCVChunks: [], rankedJDChunks: [], includedCVChunks: [], includedJDChunks: [],
                excludedCVChunks: [], excludedJDChunks: [], cvWordsUsed: 0, jdWordsUsed: 0,
                cvWordBudget: maxCVWords, jdWordBudget: maxJDWords, retrievalLatencyMS: 0,
                emptyQueryFallbackUsed: false, zeroScoreFallbackUsed: false))
    }
}
