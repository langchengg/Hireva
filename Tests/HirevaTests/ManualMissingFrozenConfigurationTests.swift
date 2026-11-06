import Foundation
import GRDB
import os
import Testing
@testable import Hireva

/// Actual synthetic Manual submission. The fault is deliberately a temporarily
/// read-only isolated database, not ordinary provider deletion: the router can
/// repair missing defaults, so deleting rows alone would not freeze nil.
@MainActor
struct ManualMissingFrozenConfigurationTests {
    @Test(.timeLimit(.minutes(1)))
    func configUnavailableAtSubmissionCannotUseAProviderSavedBeforeWorkerStarts() async throws {
        let fixture = try await ManualSnapshotFixture(mode: .deepSeekPrimary)
        let repository = SettingsRepository(database: fixture.database)
        var tasks: [Task<Void, Never>] = []
        do {
            fixture.app.delayProvider = fixture.clock
            fixture.app.activeRealtimeProvider = nil
            fixture.app.activeContextSnapshot = nil
            // A temporary, context-free session avoids a DB read before the
            // frozen lookup. GRDB.read resets query_only on its way out.
            let date = Date(timeIntervalSince1970: 1)
            fixture.app.currentSession = InterviewSession(id: UUID().uuidString,
                title: "Synthetic missing provider", startedAt: date,
                mode: .mock, createdAt: date)
            fixture.app.manualCaptureState = .transcriptReady
            fixture.app.manualCaptureTranscript = "Explain database transactions and atomicity."
            try setQueryOnly(fixture.database, enabled: true)
            #expect(throws: DatabaseError.self) {
                // ensureDefaultProviderConfigurations first performs UPDATE;
                // this proves the real synchronous lookup is unavailable.
                _ = try fixture.app.llmRouter.realtimeConfiguration()
            }
            fixture.app.sendManualCaptureToAI()
            let worker = try #require(fixture.app.stageBTask)
            tasks.append(worker)
            let generation = try #require(fixture.app.currentGenerationID)
            #expect(fixture.app.activeGenerationController?.providerConfiguration == nil,
                "The actual submission must have frozen missing configuration.")
            #expect(fixture.remote.requests().isEmpty)
            // No MainActor suspension above: the worker has not routed or
            // retrieved yet. Restore the owned database and select a later
            // valid provider before its first opportunity to run.
            try setQueryOnly(fixture.database, enabled: false)
            var later = LLMProviderConfiguration.deepSeekDefault(model: "synthetic-later-provider")
            later.id = UUID()
            later.name = "Synthetic later provider"
            try repository.saveProviderConfiguration(later)
            try repository.setActiveRealtimeProvider(id: later.id)
            fixture.app.activeRealtimeProvider = later
            #expect(try fixture.app.llmRouter.realtimeConfiguration().id == later.id)
            try await fixture.join(worker)
            #expect(fixture.remote.requests().isEmpty,
                "Frozen missing configuration cannot silently use a later global provider.")
            #expect(fixture.app.currentSuggestion == nil)
            #expect(fixture.app.manualCaptureSuggestion == nil)
            #expect(fixture.app.manualCaptureState == .suggestionError(
                "Manual answer provider at submission is not configured yet."))
            #expect(fixture.app.terminalGenerationIDs.contains(generation))
            #expect(!fixture.app.isActionLoading(ActionID.manualGenerate))
            try await fixture.close(tasks)
        } catch {
            // Restore query_only before any async join or shutdown DB work.
            try? setQueryOnly(fixture.database, enabled: false)
            try? await fixture.close(tasks)
            throw error
        }
    }

    // A synchronous helper selects GRDB's synchronous overload and preserves
    // the no-suspension boundary before actual Manual submission.
    private func setQueryOnly(_ database: AppDatabase, enabled: Bool) throws {
        try database.dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: enabled ? "PRAGMA query_only = ON" : "PRAGMA query_only = OFF")
            #expect(try Int.fetchOne(db, sql: "PRAGMA query_only") == (enabled ? 1 : 0))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func ownerRejectsMissingFrozenConfigWithoutRegisteringOrResolvingAProvider() async throws {
        // Separate owner-API characterization; this is not a substitute for
        // the unchanged production-entry regression above.
        let database = try await TestSupport.makeInMemoryDatabase()
        let repository = SettingsRepository(database: database)
        let client = MissingFrozenConfigurationClient()
        let service = SuggestionGenerationService(llmRouter: LLMRouter(
            settingsRepository: repository, clients: [.deepSeek: client]))
        let owner = GenerationCoordinator(dependencies: .init(suggestionGenerationService: service))
        let date = Date(timeIntervalSince1970: 1)
        let session = InterviewSession(id: "synthetic-owner-nil-session",
            title: "Synthetic missing snapshot", startedAt: date, mode: .mock, createdAt: date)
        let question = DetectedQuestion(id: "synthetic-owner-nil-question", sessionID: session.id,
            transcriptSegmentID: nil, questionText: "Explain database transactions and atomicity.",
            intent: .technical, answerStrategy: .directAnswer, confidence: 1,
            reason: "Synthetic frozen missing config", shouldTrigger: true, questionComplete: true,
            modelName: "unconfigured", promptVersion: "synthetic", rawJSON: nil, createdAt: date)
        let context = GenerationExecutionContext.make(session: session, question: question,
            generationID: "synthetic-owner-nil-generation", triggerPath: .manualCapture,
            provider: nil, retrievedContext: .init(cvChunks: [], jobDescriptionChunks: []),
            transcriptSnapshot: "", cvSummary: "", jdSummary: "", startedAt: date,
            source: .mock, speaker: .unknown, stage: .jsonCard)
        do {
            owner.activate(identity: context.identity, persistenceTicket: 0,
                triggerPath: .manualCapture, startedAt: date,
                providerConfiguration: nil, answerProviderMode: .deepSeekPrimary)
            let later = LLMProviderConfiguration.deepSeekDefault(model: "synthetic-owner-later")
            try repository.saveProviderConfiguration(later)
            try repository.setActiveRealtimeProvider(id: later.id)
            await #expect(throws: LLMProviderError.notConfigured("Manual answer provider at submission")) {
                _ = try await owner.generateManualSuggestion(context: context,
                    providerConfiguration: nil, timeoutInterval: 12)
            }
            #expect(client.callCount == 0)
            #expect(owner.activeGeneration?.manualProviderTask == nil)
            #expect(owner.pendingCleanupTaskCount == 0)
            #expect(await owner.shutdownAndDrain())
            try database.close()
        } catch {
            _ = await owner.shutdownAndDrain()
            try? database.close()
            throw error
        }
    }
}

private final class MissingFrozenConfigurationClient: LLMClientProtocol {
    let providerKind: LLMProviderKind = .deepSeek
    private let count = OSAllocatedUnfairLock(initialState: 0)
    var callCount: Int { count.withLock { $0 } }
    func testConnection(configuration: LLMProviderConfiguration) async throws -> LLMConnectionTestResult {
        throw CancellationError()
    }
    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] { [] }
    func chatCompletion(configuration: LLMProviderConfiguration, messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?, options: LLMRequestOptions) async throws -> LLMChatResult {
        count.withLock { $0 += 1 }
        return .init(content: "{\"strategy\":\"Explanation\",\"say_first\":\"Transactions commit together or roll back atomically.\",\"key_points\":[],\"follow_up_ready\":[],\"confidence\":1,\"caution\":null,\"evidence_used\":[],\"risk_level\":\"low\"}",
            modelName: configuration.model, providerKind: .deepSeek,
            providerName: configuration.name, baseURL: configuration.baseURL,
            latencyMS: 0, isLocal: false, rawResponse: nil)
    }
    func chatCompletionStream(configuration: LLMProviderConfiguration, messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?, options: LLMRequestOptions) -> AsyncThrowingStream<String, Error> {
        count.withLock { $0 += 1 }
        return AsyncThrowingStream { $0.finish(throwing: CancellationError()) }
    }
}
