import Combine
import Foundation
import Testing
@testable import Hireva

@MainActor
@Suite
struct PersistenceCompletionOwnershipTests {
    // Five executions of each of five explicit orderings. No scheduling sleep arranges
    // the race: the real DB write has finished before the owned gate opens.
    @Test(.serialized, .timeLimit(.minutes(1)), arguments: 0..<25)
    func historicalWriteCompletionCannotPolluteCurrentAnswerAccounting(order: Int) async throws {
        try await exercise(order: order)
    }

    private func exercise(order: Int) async throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "PersistenceCompletionOwnership")
        let app = AppState(database: database, questionRoutingProvider: HermeticQuestionRoutingProvider())
        let gate = PersistenceCompletionGate(label: "PersistenceCompletion:order_\(order)")
        var writes: [Task<Void, Never>] = []
        do {
            let session = try app.sessionRepository.createSession(mode: .mock)
            app.currentSession = session
            let first = question(sessionID: session.id, id: "completed-first-\(order)",
                text: "Explain database transactions and atomicity.")
            try app.suggestionRepository.saveDetectedQuestion(first)
            let firstGeneration = "completed-first-generation-\(order)"
            app.activateGeneration(question: first, generationID: firstGeneration,
                triggerPath: .manualGenerate, requestStart: Date(), source: nil, speaker: nil)
            try publish(app, question: first, session: session, generationID: firstGeneration)
            let firstCard = try #require(app.currentSuggestion)
            let write = try #require(app.persistSuggestionInBackground(firstCard, chunks: [],
                generationID: firstGeneration, requestStart: Date(),
                beforeCompletionPublication: { await gate.suspend() }))
            writes.append(write)
            try await gate.waitUntilStarted()
            // This observes the actual atomic consent-protected production save,
            // while its MainActor completion remains held by the test.
            let saved = try app.suggestionRepository.suggestions(sessionID: session.id)
            #expect(saved.count == 1)
            #expect(saved.first?.generationID == firstGeneration)
            app.markFullCardVisible(generationID: firstGeneration)

            // Preserve the original four orderings and add the real request
            // launch window before the next generation has been activated.
            let ordering = order < 20 ? order % 4 : 4
            if ordering == 0 {
                let refreshed = PersistenceCompletionSignal(label: "PersistenceCompletion:refresh_order_\(order)")
                let subscription = app.$lastSQLiteOperation.dropFirst().sink { value in
                    if value == "Refreshed latency averages" { refreshed.signal() }
                }
                defer { subscription.cancel() }
                await gate.release()
                await write.value
                // A current completion legitimately starts this separate query.
                // Settle its real publication before taking the Q2 snapshot.
                try await refreshed.wait()
            }
            if ordering == 3 {
                app.cancelActiveGenerationForStop()
                app.currentSession = nil
            } else if ordering == 4 {
                let requestID = app.beginGenerationRequest(triggerPath: .autoDetect)
                #expect(app.generationCoordinator.isCurrentRequest(requestID))
                #expect(app.currentGenerationID == nil)
                #expect(app.activeQuestionID == nil)
            } else {
                let second = question(sessionID: session.id, id: "current-second-\(order)",
                    text: "Explain database transactions and isolation.")
                try app.suggestionRepository.saveDetectedQuestion(second)
                let secondGeneration = "current-second-generation-\(order)"
                app.activateGeneration(question: second, generationID: secondGeneration,
                    triggerPath: .manualGenerate, requestStart: Date(), source: nil, speaker: nil)
                try publish(app, question: second, session: session, generationID: secondGeneration)
                if ordering == 2 { app.markFullCardVisible(generationID: secondGeneration) }
            }

            let currentCard = app.currentSuggestion
            let currentState = app.generationUIState
            let currentSource = app.finalVisibleSource
            let currentTelemetry = app.currentGenerationTelemetry
            let currentLoading = app.isActionLoading(ActionID.generateAnswer)
            let currentSQLiteOperation = app.lastSQLiteOperation
            await gate.release()
            await write.value

            #expect(app.staleAnswerDiscardCount == 0,
                "An admitted historical write's optional UI refresh is not a discarded answer.")
            #expect(app.staleCallbackDiscardCount == (ordering == 0 ? 0 : 1))
            #expect(app.currentSuggestion == currentCard)
            #expect(app.generationUIState == currentState)
            #expect(app.finalVisibleSource == currentSource)
            #expect(app.currentGenerationTelemetry == currentTelemetry)
            #expect(app.isActionLoading(ActionID.generateAnswer) == currentLoading)
            #expect(app.lastSQLiteOperation == currentSQLiteOperation)
            #expect(try app.suggestionRepository.suggestions(sessionID: session.id) == saved)
            #expect(app.recentTranscriptRuntimeEvents.filter {
                $0.name == "persistenceSucceeded" && $0.generationID == firstGeneration
            }.count == 1)
            #expect(app.recentTranscriptRuntimeEvents.filter {
                $0.name == "queuedAnswerPersisted" && $0.generationID == firstGeneration
            }.count == 1)
        } catch {
            writes.forEach { $0.cancel() }
            await gate.release()
            for write in writes { await write.value }
            await app.shutdownForTesting()
            try database.close()
            throw error
        }
        writes.forEach { $0.cancel() }
        await gate.release()
        for write in writes { await write.value }
        await app.shutdownForTesting()
        try database.close()
    }

    private func question(sessionID: String, id: String, text: String) -> DetectedQuestion {
        .init(id: id, sessionID: sessionID, transcriptSegmentID: nil, questionText: text,
            intent: .technical, answerStrategy: .directAnswer, confidence: 1,
            reason: "Synthetic persistence completion ordering", shouldTrigger: true,
            questionComplete: true, modelName: "fixture", promptVersion: "fixture", createdAt: Date())
    }

    private func publish(_ app: AppState, question: DetectedQuestion,
        session: InterviewSession, generationID: String) throws {
        try #require(app.publishStreamingSections(.init(strategy: "Explanation",
            sayFirst: "A database transaction groups operations into an atomic unit. Atomicity means all operations commit together or roll back together, and isolation controls which concurrent changes each transaction can observe.",
            keyPoints: ["All operations commit together or roll back together.",
                "Isolation controls which concurrent changes are visible."],
            followUpReady: [], caution: ""), cardID: "\(generationID)-card",
            generationID: generationID, question: question, session: session,
            requestStart: Date(), stageBStreamStartedMS: nil, markFullCardVisible: true))
    }
}

@MainActor
private final class PersistenceCompletionSignal {
    private let trace: TestEventWaitTrace
    private var fired = false
    private let events: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init(label: String) {
        trace = TestEventWaitTrace(label: label)
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        events = pair.stream
        continuation = pair.continuation
    }

    func signal() {
        trace.mark("producer.refresh.yield.before")
        fired = true
        let yielded = continuation.yield(())
        trace.mark("producer.refresh.yield.\(yielded)")
        continuation.finish()
    }

    func wait() async throws {
        try Task.checkCancellation()
        guard !fired else { return }
        _ = try await trace.nextEvent(in: events, event: "refresh")
    }
}

private actor PersistenceCompletionGate {
    nonisolated let trace: TestEventWaitTrace
    private var started = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    private let starts: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init(label: String) {
        trace = TestEventWaitTrace(label: label)
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        starts = pair.stream
        continuation = pair.continuation
    }
    func suspend() async {
        trace.mark("producer.db_completed.yield.before")
        started = true
        let yielded = continuation.yield(())
        trace.mark("producer.db_completed.yield.\(yielded)")
        continuation.finish()
        guard !released else { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func waitUntilStarted() async throws {
        try Task.checkCancellation()
        guard !started else { return }
        _ = try await trace.nextEvent(in: starts, event: "db_completed")
    }
    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}
