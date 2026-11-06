import Combine
import Foundation
import GRDB
import Testing
@testable import Hireva

@MainActor
struct TranscriptPersistenceOwnershipTests {
    // Four existing production entry points in active and completed-generation
    // orderings. No model, microphone, application launch or scheduling sleep.
    @Test(.timeLimit(.minutes(1)), arguments: Array(0..<8))
    func actualBackgroundWriteRemainsOwnedUntilExit(order: Int) async throws {
        let gate = TranscriptSQLWriteGate(order: order)
        // Install before any fixture setup. Parent cancellation can release the
        // blocked SQL callback synchronously, without waiting for MainActor.
        try await withTaskCancellationHandler {
            try await exercise(order: order, gate: gate)
        } onCancel: {
            gate.release()
        }
    }

    private func exercise(order: Int, gate: TranscriptSQLWriteGate) async throws {
        try Task.checkCancellation()
        let kind = order % 4
        let terminalBeforeSave = order >= 4
        let suite = "com.langcheng.Hireva.tests.transcriptOwnership." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let database = try await TestSupport.makeInMemoryDatabase()
        let app = AppState(database: database,
            questionRoutingProvider: HermeticQuestionRoutingProvider(),
            permissionService: HermeticPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            dialogueDefaults: defaults)
        let boundary = TranscriptOwnershipSignal()
        let completion = TranscriptOwnershipSignal()
        var shutdown: Task<Bool, Never>?
        var observation: AnyCancellable?
        var operationObservation: AnyCancellable?
        let actualCompletion = TranscriptOwnershipSignal()
        var baselineDiscardedHandle = false
        do {
            try Task.checkCancellation()
            app.settings.saveTranscriptsLocally = true
            let session = try app.sessionRepository.createSession(mode: .mock)
            app.currentSession = session
            let question = makeQuestion(id: "background-question", sessionID: session.id)
            try app.suggestionRepository.saveDetectedQuestion(question)
            let generationID = "background-generation"
            app.activateGeneration(question: question, generationID: generationID,
                triggerPath: .manualGenerate, requestStart: Date(), source: nil, speaker: nil)
            try #require(app.publishStreamingSections(.init(strategy: "Explanation",
                sayFirst: "A database transaction groups operations into an atomic unit. Atomicity means all operations commit together or roll back together, and isolation controls which concurrent changes each transaction can observe.",
                keyPoints: ["All operations commit together or roll back together.",
                    "Isolation controls which concurrent changes are visible."],
                followUpReady: [], caution: ""), cardID: "background-card",
                generationID: generationID, question: question, session: session,
                requestStart: Date(), stageBStreamStartedMS: nil, markFullCardVisible: true))
            let card = try #require(app.currentSuggestion)
            if terminalBeforeSave { app.markFullCardVisible(generationID: generationID) }

            let heldID = kind == 3 ? card.id : "held-write"
            let table = kind == 0 ? "transcript_segments"
                : kind == 3 ? "suggestion_cards" : "detected_questions"
            try await database.dbQueue.write { db in
                db.add(function: DatabaseFunction("hold_owned_write", argumentCount: 0) { _ in
                    try gate.hold()
                    return 1
                })
                // Only our one synthetic row is held; the second batch row is
                // intentionally not gated. These names/IDs are test-owned.
                try db.execute(sql: "CREATE TRIGGER hold_exact_write BEFORE INSERT ON " + table
                    + " WHEN NEW.id = '" + heldID + "' BEGIN SELECT hold_owned_write(); END;")
            }
            let segment = TranscriptSegment(id: "held-write", sessionID: session.id,
                source: .mock, speaker: .unknown, text: "Synthetic transcript for ownership.",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000), confidence: 1)
            let heldQuestion = makeQuestion(id: "held-write", sessionID: session.id)
            let secondQuestion = makeQuestion(id: "second-write", sessionID: session.id)
            operationObservation = app.$lastSQLiteOperation.dropFirst().sink { value in
                if value.hasPrefix("Saved ") || value.contains("save failed:") { actualCompletion.fire() }
            }
            switch kind {
            case 0: app.saveTranscriptSegmentInBackground(segment)
            case 1: app.saveDetectedQuestionInBackground(heldQuestion)
            case 2: app.saveDetectedQuestionsInBackground([heldQuestion, secondQuestion])
            default: app.saveSuggestionSnapshotInBackground(card, chunks: [],
                consentTicket: app.persistenceConsent.ticket())
            }
            // The SQL trigger proves the REAL helper reached the sync atomic
            // consent-protected write. Nothing is registered from the test.
            try await gate.waitUntilEntered()
            baselineDiscardedHandle = app.generationCoordinator.pendingCleanupTaskCount == 0
            #expect(app.generationCoordinator.pendingCleanupTaskCount == 1,
                "A live production write handle must remain in the unique retirement owner.")
            observation = app.generationCoordinator.objectWillChange.sink { _ in
                if app.isShuttingDown { boundary.fire() }
            }
            shutdown = Task { @MainActor in
                let result = await app.shutdownResources()
                completion.fire()
                return result
            }
            try await boundary.wait()
            #expect(app.isShuttingDown)
            #expect(app.generationCoordinator.pendingCleanupTaskCount == 1)
            #expect(!completion.fired)
            let stoppedOperation = app.lastSQLiteOperation
            let stoppedCard = app.currentSuggestion
            let stoppedState = app.generationUIState
            // The gate ignores Task cancellation; release it on every path
            // before any task/queue join. It also has an independent10s bound.
            gate.release()
            #expect(await shutdown?.value == true)
            // In the RED baseline only, settle the discarded helper through
            // its real last callback before closing our DB. This cleanup
            // condition cannot suppress the failed ownership assertions.
            if baselineDiscardedHandle { try await actualCompletion.wait() }
            #expect(app.generationCoordinator.pendingCleanupTaskCount == 0)
            #expect(completion.fired)
            #expect(app.lastSQLiteOperation == stoppedOperation)
            #expect(app.currentSuggestion == stoppedCard)
            #expect(app.generationUIState == stoppedState)
            switch kind {
            case 0: #expect(try app.transcriptRepository.segmentByID(segment.id) == segment)
            case 1: #expect(try app.suggestionRepository.questions(sessionID: session.id).contains { $0.id == heldQuestion.id })
            case 2:
                let ids = try app.suggestionRepository.questions(sessionID: session.id).map(\.id)
                #expect(ids.contains(heldQuestion.id))
                #expect(ids.contains(secondQuestion.id))
            default:
                #expect(try app.suggestionRepository.suggestions(sessionID: session.id).map(\.id) == [card.id])
                #expect(app.recentTranscriptRuntimeEvents.filter {
                    $0.name == "persistenceSucceeded" && $0.generationID == generationID
                }.count == 1, "An admitted write's historical audit survives the UI shutdown fence.")
            }
        } catch {
            gate.release()
            shutdown?.cancel()
            _ = await shutdown?.value
            await app.shutdownForTesting()
            // A queue read is also an actual write-exit barrier for baseline
            // failures whose old helper discarded its Task handle.
            _ = try? await database.dbQueue.read { try Int.fetchOne($0, sql: "SELECT 1") }
            operationObservation?.cancel()
            observation?.cancel()
            defaults.removePersistentDomain(forName: suite)
            try? database.close()
            throw error
        }
        gate.release()
        _ = await shutdown?.value
        await app.shutdownForTesting()
        _ = try await database.dbQueue.read { try Int.fetchOne($0, sql: "SELECT 1") }
        operationObservation?.cancel()
        observation?.cancel()
        defaults.removePersistentDomain(forName: suite)
        try database.close()
    }

    private func makeQuestion(id: String, sessionID: String) -> DetectedQuestion {
        .init(id: id, sessionID: sessionID, transcriptSegmentID: nil,
            questionText: "Explain database transactions and atomicity.",
            intent: .technical, answerStrategy: .directAnswer, confidence: 1,
            reason: "Synthetic ownership check", shouldTrigger: true,
            questionComplete: true, modelName: "fixture", promptVersion: "fixture", createdAt: Date())
    }
}

private enum TranscriptWriteGateError: Error { case releaseDeadline }

// All storage is immutable SDK synchronization/stream handles. The only
// blocking wait runs inside our isolated SQL callback on GRDB's queue, never
// on MainActor. The10s bound is a last-resort fixture resource watchdog,
// never a product deadline or an AsyncStream readiness timeout. A fired
// watchdog throws, rolls back our write and fails the actual SQL assertion;
// it cannot produce a passing join. Normal scheduling uses explicit events,
// normal teardown and owning cancellation all release before joining.
private final class TranscriptSQLWriteGate: Sendable {
    private let released = DispatchSemaphore(value: 0)
    private let events: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let trace: TestEventWaitTrace
    init(order: Int) {
        trace = TestEventWaitTrace(label: "TranscriptSQLWriteOwnership.order.\(order)")
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        events = pair.stream
        continuation = pair.continuation
    }
    func hold() throws {
        trace.mark("sql.entered")
        continuation.yield(())
        continuation.finish()
        guard released.wait(timeout: .now() + 10) == .success else {
            trace.mark("sql.resource_deadline.expired")
            throw TranscriptWriteGateError.releaseDeadline
        }
        trace.mark("sql.released")
    }
    func waitUntilEntered() async throws {
        _ = try await trace.nextEvent(in: events, event: "actual_atomic_sql_write_entered")
        trace.mark("driver.entered.return")
    }
    func release() { trace.mark("driver.release"); released.signal() }
}

@MainActor
private final class TranscriptOwnershipSignal {
    private(set) var fired = false
    private let events: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    init() {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        events = pair.stream
        continuation = pair.continuation
    }
    func fire() {
        guard !fired else { return }
        fired = true
        continuation.yield(())
        continuation.finish()
    }
    func wait() async throws {
        if fired { return }
        _ = try await TestEventWaitTrace(label: "TranscriptOwnershipBoundary")
            .nextEvent(in: events, event: "shutdown_admission_closed")
    }
}
