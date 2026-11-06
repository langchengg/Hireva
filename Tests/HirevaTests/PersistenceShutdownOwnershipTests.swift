import Combine
import Foundation
import Testing
@testable import Hireva

@MainActor
struct PersistenceShutdownOwnershipTests {
    // These are two resource interleavings, not a latency benchmark. Each owns
    // an in-memory database and uses the real atomic save and app shutdown.
    @Test(.timeLimit(.minutes(1)))
    func admittedHistoricalPersistenceRemainsOwnedThroughAppShutdown() async throws {
        for terminalBeforeShutdown in [false, true] {
            try await exercise(terminalBeforeShutdown: terminalBeforeShutdown)
        }
    }

    private func exercise(terminalBeforeShutdown: Bool) async throws {
        let database = try AppDatabase(inMemory: true)
        let app = AppState(database: database,
            questionRoutingProvider: HermeticQuestionRoutingProvider(),
            permissionService: HermeticPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            dialogueDefaults: nil)
        let label = "PersistenceShutdown:terminal_\(terminalBeforeShutdown)"
        let gate = PersistenceShutdownCompletionGate(label: label)
        let boundary = PersistenceShutdownSignal(label: label + ":admission_closed")
        let completion = PersistenceShutdownSignal(label: label + ":shutdown_returned")
        var persistence: Task<Void, Never>?
        var shutdown: Task<Bool, Never>?
        var subscription: AnyCancellable?
        do {
            let session = try app.sessionRepository.createSession(mode: .mock)
            app.currentSession = session
            let question = DetectedQuestion(id: "synthetic-shutdown-question",
                sessionID: session.id, transcriptSegmentID: nil,
                questionText: "Explain database transactions and atomicity.",
                intent: .technical, answerStrategy: .directAnswer, confidence: 1,
                reason: "Synthetic persistence resource ownership", shouldTrigger: true,
                questionComplete: true, modelName: "fixture", promptVersion: "fixture",
                createdAt: Date())
            try app.suggestionRepository.saveDetectedQuestion(question)
            let generationID = "synthetic-shutdown-generation"
            app.activateGeneration(question: question, generationID: generationID,
                triggerPath: .manualGenerate, requestStart: Date(), source: nil, speaker: nil)
            try #require(app.publishStreamingSections(.init(strategy: "Explanation",
                sayFirst: "A database transaction groups operations into an atomic unit. Atomicity means all operations commit together or roll back together, and isolation controls which concurrent changes each transaction can observe.",
                keyPoints: ["All operations commit together or roll back together.",
                    "Isolation controls which concurrent changes are visible."],
                followUpReady: [], caution: ""), cardID: "synthetic-shutdown-card",
                generationID: generationID, question: question, session: session,
                requestStart: Date(), stageBStreamStartedMS: nil, markFullCardVisible: true))
            let visible = try #require(app.currentSuggestion)
            let requiredPersistenceTask: Task<Void, Never> = try #require(app.persistSuggestionInBackground(visible, chunks: [],
                generationID: generationID, requestStart: Date(),
                beforeCompletionPublication: { await gate.suspend() }))
            persistence = requiredPersistenceTask
            try await gate.waitUntilEntered()
            let saved = try app.suggestionRepository.suggestions(sessionID: session.id)
            #expect(saved.count == 1)
            #expect(saved.first?.id == visible.id)
            #expect(saved.first?.generationID == generationID)
            #expect(saved.first?.dbPersistedMS != nil)
            if terminalBeforeShutdown { app.markFullCardVisible(generationID: generationID) }

            // Do not register this task from the test. Its real production
            // helper must retain it before returning, including terminal answers.
            #expect(app.generationCoordinator.pendingCleanupTaskCount == 1,
                "A saved card's completion is still suspended in a real production task.")
            subscription = app.generationCoordinator.objectWillChange.sink { _ in
                if app.isShuttingDown { boundary.signal() }
            }
            shutdown = Task { @MainActor in
                let result = await app.shutdownResources()
                completion.signal()
                return result
            }
            try await boundary.wait()
            #expect(app.isShuttingDown)
            #expect(app.generationCoordinator.pendingCleanupTaskCount == 1,
                "App shutdown must retain and join this admitted task until actual exit.")
            #expect(!completion.fired,
                "Shutdown cannot report success while an owned completion is held.")
            let rejectedRequest = app.generationCoordinator.beginRequest(triggerPath: .regenerate)
            #expect(!app.generationCoordinator.isCurrentRequest(rejectedRequest))
            #expect(app.generationCoordinator.pendingCleanupTaskCount == 1)
            let stoppedCard = app.currentSuggestion
            let stoppedState = app.generationUIState
            let stoppedTelemetry = app.currentGenerationTelemetry
            let stoppedSource = app.finalVisibleSource
            let stoppedLoading = app.isActionLoading(ActionID.generateAnswer)
            let stoppedSQLiteOperation = app.lastSQLiteOperation

            // Always release before joining. Cancellation cannot force this
            // deliberately noncooperative post-write hook to leave by itself.
            await gate.release()
            await persistence?.value
            #expect(await shutdown?.value == true)
            let endedSession = try app.sessionRepository.session(id: session.id)
            #expect(endedSession?.endedAt != nil)
            #expect(app.currentSession?.endedAt == endedSession?.endedAt)
            #expect(completion.fired)
            #expect(app.generationCoordinator.pendingCleanupTaskCount == 0)
            #expect(app.currentSuggestion == stoppedCard)
            #expect(app.generationUIState == stoppedState)
            #expect(app.currentGenerationTelemetry == stoppedTelemetry)
            #expect(app.finalVisibleSource == stoppedSource)
            #expect(app.isActionLoading(ActionID.generateAnswer) == stoppedLoading)
            #expect(app.lastSQLiteOperation == stoppedSQLiteOperation)
            #expect(app.staleAnswerDiscardCount == 0)
            #expect(try app.suggestionRepository.suggestions(sessionID: session.id) == saved)
            #expect(app.recentTranscriptRuntimeEvents.filter {
                $0.name == "persistenceSucceeded" && $0.generationID == generationID
            }.count == 1)
            #expect(app.recentTranscriptRuntimeEvents.filter {
                $0.name == "queuedAnswerPersisted" && $0.generationID == generationID
            }.count == 1)
        } catch {
            subscription?.cancel()
            shutdown?.cancel()
            persistence?.cancel()
            await gate.release()
            await persistence?.value
            _ = await shutdown?.value
            await app.shutdownForTesting()
            try? database.close()
            throw error
        }
        subscription?.cancel()
        await gate.release()
        await persistence?.value
        _ = await shutdown?.value
        await app.shutdownForTesting()
        try database.close()
    }
}

@MainActor
private final class PersistenceShutdownSignal {
    private let trace: TestEventWaitTrace
    private(set) var fired = false
    private let events: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init(label: String) {
        trace = TestEventWaitTrace(label: label)
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        events = pair.stream
        continuation = pair.continuation
    }

    func signal() {
        guard !fired else { return }
        fired = true
        trace.mark("producer.event")
        continuation.yield(())
        continuation.finish()
    }

    func wait() async throws {
        try Task.checkCancellation()
        if fired { return }
        _ = try await trace.nextEvent(in: events, event: "boundary")
    }
}

/// The save has already been admitted atomically when this hook runs. It ignores
/// cancellation deliberately, and every success/failure path releases and joins.
private actor PersistenceShutdownCompletionGate {
    nonisolated let trace: TestEventWaitTrace
    private var entered = false
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
        entered = true
        trace.mark("producer.admitted_write_completed")
        continuation.yield(())
        continuation.finish()
        if released { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func waitUntilEntered() async throws {
        try Task.checkCancellation()
        if entered { return }
        _ = try await trace.nextEvent(in: starts, event: "admitted_write_completed")
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}
