import Foundation
import Testing
@testable import Hireva

@MainActor
struct AppShutdownAdmissionTests {
    @Test(arguments: [false, true])
    func resourceShutdownEndsCurrentSessionIndependentlyOfContentConsent(saveContent: Bool) async throws {
        try await withApplication { app, _ in
            app.settings.saveTranscriptsLocally = saveContent
            let session = try app.sessionRepository.createSession(mode: .mock)
            app.currentSession = session
            #expect(await app.shutdownResources())
            let persisted = try app.sessionRepository.session(id: session.id)
            #expect(persisted?.endedAt != nil)
            #expect(app.currentSession?.endedAt == persisted?.endedAt)
            #expect(await app.shutdownResources())
            #expect(try app.sessionRepository.session(id: session.id)?.endedAt == persisted?.endedAt)
            #expect(try app.transcriptRepository.segments(sessionID: session.id).isEmpty)
            #expect(try app.suggestionRepository.suggestions(sessionID: session.id).isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func failedSessionFinalizationRetriesOriginalIdentityWithoutEndingReplacement(hasKnownStopTime: Bool) async throws {
        try await withApplication { app, database in
            var original = try app.sessionRepository.createSession(mode: .mock)
            if hasKnownStopTime { original.endedAt = Date(timeIntervalSince1970: 1_700_000_000) }
            let replacement = try app.sessionRepository.createSession(mode: .mock)
            app.currentSession = original
            try setSessionEndWriteFailure(database, enabled: true)
            defer { try? setSessionEndWriteFailure(database, enabled: false) }
            #expect(await app.shutdownResources() == false)
            #expect(try app.sessionRepository.session(id: original.id)?.endedAt == nil)
            #expect(app.currentSession?.endedAt == original.endedAt)
            app.currentSession = replacement
            try setSessionEndWriteFailure(database, enabled: false)
            #expect(await app.shutdownResources())
            #expect(try app.sessionRepository.session(id: original.id)?.endedAt != nil)
            if let endedAt = original.endedAt {
                #expect(try app.sessionRepository.session(id: original.id)?.endedAt == endedAt)
            }
            #expect(try app.sessionRepository.session(id: replacement.id)?.endedAt == nil)
            #expect(app.currentSession?.id == replacement.id)
            #expect(app.currentSession?.endedAt == nil)
        }
    }

    @Test
    func stopWriteFailureDoesNotPublishAnUnsavedEndTime() async throws {
        try await withApplication { app, database in
            let session = try app.sessionRepository.createSession(mode: .mock)
            app.currentSession = session
            try setSessionEndWriteFailure(database, enabled: true)
            defer { try? setSessionEndWriteFailure(database, enabled: false) }
            app.stopListening()
            #expect(try app.sessionRepository.session(id: session.id)?.endedAt == nil)
            #expect(app.currentSession?.endedAt == nil)
            #expect(app.errorMessage != nil)
            try setSessionEndWriteFailure(database, enabled: false)
            #expect(await app.shutdownResources())
            #expect(try app.sessionRepository.session(id: session.id)?.endedAt != nil)
            #expect(app.currentSession?.endedAt != nil)
        }
    }

    @Test
    func lateShutdownDoesNotRecreateDeletedSession() async throws {
        try await withApplication { app, _ in
            let session = try app.sessionRepository.createSession(mode: .mock)
            app.currentSession = session
            try app.sessionRepository.deleteSession(id: session.id)
            #expect(await app.shutdownResources())
            #expect(try app.sessionRepository.session(id: session.id) == nil)
            #expect(try app.sessionRepository.listSessions().isEmpty)
        }
    }

    @Test
    func repeatedStopAndShutdownPreservePersistedEndTime() async throws {
        try await withApplication { app, database in
            let session = try app.sessionRepository.createSession(mode: .mock)
            let endedAt = Date(timeIntervalSince1970: 1_700_000_000)
            try await database.dbQueue.write { db in
                try db.execute(sql: "UPDATE interview_sessions SET ended_at = ? WHERE id = ?",
                    arguments: [DateCoding.string(from: endedAt), session.id])
            }
            app.currentSession = try app.sessionRepository.session(id: session.id)
            app.stopListening()
            app.stopListening()
            #expect(try app.sessionRepository.session(id: session.id)?.endedAt == endedAt)
            #expect(app.currentSession?.endedAt == endedAt)
            #expect(await app.shutdownResources())
            #expect(try app.sessionRepository.session(id: session.id)?.endedAt == endedAt)
            #expect(app.currentSession?.endedAt == endedAt)
        }
    }

    @Test
    func liveEntryCannotScheduleNewCaptureAfterShutdown() async throws {
        let database = try AppDatabase(inMemory: true)
        let app = AppState(database: database, permissionService: HermeticPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()), dialogueDefaults: nil)
        await app.shutdownForTesting()
        app.startListening(mode: .mock)
        let rejectedStartup = app.captureStartupTask
        #expect(rejectedStartup == nil)
        #expect(!app.isActionLoading(ActionID.startInterview))
        // The .mock path never opens an audio device. Retain and cancel the
        // mistakenly scheduled task before yielding, even on the red version.
        rejectedStartup?.cancel()
        app.stopListening()
        await rejectedStartup?.value
        await app.captureTeardownTask?.value
        await app.shutdownForTesting()
        try database.close()
    }

    @Test(arguments: ShutdownGenerationEntry.allCases)
    func manualGenerationEntryCannotReopenLoadingAfterShutdown(entry: ShutdownGenerationEntry) async throws {
        let database = try AppDatabase(inMemory: true)
        let app = AppState(database: database, questionRoutingProvider: HermeticQuestionRoutingProvider(),
            permissionService: HermeticPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()), dialogueDefaults: nil)
        let session = try app.createContextBoundSession(mode: .mock)
        app.currentSession = session
        let question = "Explain database transactions and atomicity."
        app.transcriptSegments = [.init(id: "synthetic-shutdown-transcript", sessionID: session.id,
            source: .mock, speaker: .interviewer, text: question)]
        app.manualCaptureTranscript = question
        app.manualCaptureState = .transcriptReady
        app.currentSuggestion = SuggestionCard(id: "synthetic-shutdown-card", sessionID: session.id,
            questionID: "synthetic-shutdown-question", strategy: "Explanation",
            sayFirst: "Transactions preserve atomicity.", keyPoints: [], followUpReady: [],
            confidence: 1, caution: nil, evidenceUsed: [], riskLevel: .low,
            modelName: "synthetic-shutdown", promptVersion: "synthetic-shutdown", rawJSON: nil, createdAt: Date())
        app.currentSuggestion?.questionText = question
        await app.shutdownForTesting()
        switch entry {
        case .answerNow: app.manualAnswerNow()
        case .regenerate: app.regenerateVisibleSuggestion()
        case .reviewedCapture: app.sendManualCaptureToAI()
        }
        #expect(!app.isActionLoading(ActionID.generateAnswer))
        #expect(!app.isActionLoading(ActionID.manualGenerate))
        #expect(app.generationCoordinator.pendingCleanupTaskCount == 0)
        await app.generationCoordinator.drainRetiredTasks()
        await app.shutdownForTesting()
        try database.close()
    }

    @Test
    func appShutdownPermanentlyClosesGenerationAdmission() async throws {
        let database = try AppDatabase(inMemory: true)
        let app = AppState(database: database, permissionService: HermeticPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()), dialogueDefaults: nil)
        await app.shutdownForTesting()
        let id = app.generationCoordinator.beginRequest(triggerPath: .manualGenerate)
        #expect(!app.generationCoordinator.isCurrentRequest(id),
            "App shutdown must close admission, not only cancel the previous generation.")
        app.generationCoordinator.invalidateAndCancel()
        await app.generationCoordinator.drainRetiredTasks()
        await app.shutdownForTesting()
        try database.close()
    }

    @Test
    func appShutdownPermanentlyClosesPreparationAdmission() async throws {
        let database = try AppDatabase(inMemory: true)
        let app = AppState(database: database, permissionService: HermeticPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()), dialogueDefaults: nil)
        let preparation = app.preparationState
        await app.shutdownForTesting()
        preparation.query = "SELECT COUNT(*) FROM customers;"
        preparation.runSQL()
        #expect(preparation.pendingTaskCount == 0,
            "A discarded view task is not a shutdown boundary for the feature.")
        await preparation.shutdown()
        await app.shutdownForTesting()
        try database.close()
    }

    private func setSessionEndWriteFailure(_ database: AppDatabase, enabled: Bool) throws {
        try database.dbQueue.write { db in
            try db.execute(sql: enabled ? """
                CREATE TEMP TRIGGER shutdown_session_end_failure
                BEFORE UPDATE OF ended_at ON interview_sessions
                BEGIN SELECT RAISE(ABORT, 'synthetic session finalization failure'); END
                """ : "DROP TRIGGER IF EXISTS shutdown_session_end_failure")
        }
    }

    private func withApplication(_ operation: @MainActor (AppState, AppDatabase) async throws -> Void) async throws {
        let database = try AppDatabase(inMemory: true)
        let app = AppState(database: database, permissionService: HermeticPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()), dialogueDefaults: nil)
        do { try await operation(app, database) }
        catch {
            await app.shutdownForTesting()
            try? database.close()
            throw error
        }
        await app.shutdownForTesting()
        try database.close()
    }
}

enum ShutdownGenerationEntry: String, CaseIterable, Sendable {
    case answerNow, regenerate, reviewedCapture
}
