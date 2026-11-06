import Foundation
import GRDB
import Testing
@testable import Hireva

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct DocumentsEmbeddingLifecycleTests {
    @Test
    func cancelledRebuildRejectsLateVectorAndCannotReportCompletion() async throws {
        let fixture = try DocumentsEmbeddingFixture()
        try await fixture.run {
            let task = try fixture.startRebuild()
            try await fixture.waitForEmbedding()
            fixture.app.cancelEmbeddingRebuild()
            #expect(task.isCancelled)
            #expect(!fixture.app.isRebuildingEmbeddings)
            await fixture.provider.releaseAll()
            await task.value
            #expect(try fixture.currentChunks().allSatisfy { $0.embedding == nil })
            #expect(fixture.app.lastEmbeddingTestStatus != "Embedding rebuild complete.")
            #expect(fixture.app.latestActionFeedback(for: ActionID.rebuildEmbeddings)?.kind != .success)
            #expect(!fixture.app.isRebuildingEmbeddings)
        }
    }

    @Test(arguments: [EmbeddingSettingsIntent.modelChanged, .modelChangedThenRestored, .providerDisabled])
    func changedEmbeddingConfigurationPermanentlyRejectsOldResult(intent: EmbeddingSettingsIntent) async throws {
        let fixture = try DocumentsEmbeddingFixture()
        try await fixture.run {
            let task = try fixture.startRebuild()
            try await fixture.waitForEmbedding()
            var changed = fixture.app.settings
            switch intent {
            case .modelChanged, .modelChangedThenRestored: changed.embeddingModelName = "synthetic-model-B"
            case .providerDisabled: changed.embeddingProviderKind = .disabled
            }
            fixture.app.settingsState.saveSettings(changed)
            if intent == .modelChangedThenRestored {
                changed.embeddingModelName = fixture.provider.modelName
                fixture.app.settingsState.saveSettings(changed)
            }
            #expect(task.isCancelled, "A settings intent must revoke the old embedding job, including an ABA change.")
            await fixture.provider.releaseAll()
            await task.value
            #expect(try fixture.currentChunks().allSatisfy { $0.embedding == nil })
            #expect(fixture.app.lastEmbeddingTestStatus != "Embedding rebuild complete.")
            #expect(fixture.app.latestActionFeedback(for: ActionID.rebuildEmbeddings)?.kind != .success)
        }
    }

    @Test
    func deletedDocumentAndTypedReplacementCannotReceiveOldRebuildOrCompletion() async throws {
        let fixture = try DocumentsEmbeddingFixture()
        try await fixture.run {
            let original = try fixture.currentDocument()
            let originalChunk = try #require(try fixture.currentChunks().first)
            let task = try fixture.startRebuild()
            try await fixture.waitForEmbedding()
            fixture.app.deleteDocument(original)
            fixture.app.saveDocument(type: .cv, title: "Synthetic replacement", content: DocumentsEmbeddingFixture.replacement)
            let replacement = try fixture.currentDocument()
            #expect(replacement.id != original.id)
            #expect(task.isCancelled)
            await fixture.provider.releaseAll()
            await task.value
            #expect(try fixture.app.documentRepository.chunks(documentID: original.id).isEmpty)
            let chunks = try fixture.currentChunks()
            #expect(chunks.allSatisfy { $0.id != originalChunk.id && $0.embedding == nil })
            #expect(try fixture.currentDocument().content == DocumentsEmbeddingFixture.replacement)
            #expect(fixture.app.lastEmbeddingTestStatus != "Embedding rebuild complete.")
            #expect(fixture.app.latestActionFeedback(for: ActionID.rebuildEmbeddings)?.kind != .success)
        }
    }

    @Test
    func originalChunkContentMustStillMatchAtActualEmbeddingWrite() async throws {
        let fixture = try DocumentsEmbeddingFixture()
        try await fixture.run {
            let chunk = try #require(try fixture.currentChunks().first)
            let task = try fixture.startRebuild()
            try await fixture.waitForEmbedding()
            // This isolated DB writer deliberately retains the row identity.
            // It exercises the write admission boundary, rather than claiming
            // that ordinary saveDocument reuses its replaced chunk UUIDs.
            try fixture.replaceContentOfExistingChunk(chunk.id)
            await fixture.provider.releaseAll()
            await task.value
            let changed = try #require(try fixture.currentChunks().first)
            #expect(changed.id == chunk.id)
            #expect(changed.content == DocumentsEmbeddingFixture.replacement)
            #expect(changed.embedding == nil)
            #expect(changed.embeddingContentHash == nil)
            #expect(fixture.app.latestActionFeedback(for: ActionID.rebuildEmbeddings)?.kind != .success)
        }
    }

    @Test
    func shutdownJoinsRebuildButRejectsItsLateDatabaseAndUIEffects() async throws {
        let fixture = try DocumentsEmbeddingFixture()
        try await fixture.run {
            let task = try fixture.startRebuild()
            try await fixture.waitForEmbedding()
            let shutdown = fixture.beginShutdown()
            let event = try await fixture.nextControlEvent()
            #expect(event == .cancelled(.embedding))
            #expect(task.isCancelled)
            #expect(!fixture.shutdownReturned)
            await fixture.provider.releaseAll()
            await task.value
            await shutdown.value
            #expect(fixture.shutdownReturned)
            #expect(try fixture.currentChunks().allSatisfy { $0.embedding == nil })
            #expect(fixture.app.lastEmbeddingTestStatus != "Embedding rebuild complete.")
            #expect(fixture.app.latestActionFeedback(for: ActionID.rebuildEmbeddings)?.kind != .success)
        }
    }

    @Test
    func shutdownCancelsAndJoinsTheActualAutomaticEmbeddingTask() async throws {
        let fixture = try DocumentsEmbeddingFixture()
        try await fixture.run {
            let task = try fixture.startBackground()
            try await fixture.waitForEmbedding()
            let shutdown = fixture.beginShutdown()
            let event = try await fixture.nextControlEvent()
            // The old unregistered Task lets app shutdown return while this
            // provider is held. The event distinguishes that real early return
            // from missing readiness or an arbitrary wall-clock timeout.
            #expect(event == .cancelled(.embedding))
            #expect(task.isCancelled)
            #expect(!fixture.shutdownReturned)
            await fixture.provider.releaseAll()
            await task.value
            await shutdown.value
            #expect(fixture.shutdownReturned)
            #expect(try fixture.currentChunks().allSatisfy { $0.embedding == nil })
        }
    }

    @Test
    func automaticJobFrozenBeforeDimensionCannotEmbedATypedReplacement() async throws {
        let fixture = try DocumentsEmbeddingFixture(holdDimension: true)
        try await fixture.run {
            let original = try fixture.currentDocument()
            let task = try fixture.startBackground()
            try await fixture.waitForDimension()
            // Stop automatic work before the explicit replacement so this case
            // has only one actual background job, retained by the fixture.
            var settings = fixture.app.settings
            settings.autoGenerateEmbeddingsOnDocumentSave = false
            fixture.app.settingsState.saveSettings(settings)
            fixture.app.saveDocument(type: .cv, title: "Synthetic replacement", content: DocumentsEmbeddingFixture.replacement)
            let replacement = try fixture.currentDocument()
            // saveDocument preserves the document ID when replacing its type,
            // but deletes and recreates its chunk IDs and source material.
            #expect(replacement.id == original.id)
            #expect(task.isCancelled)
            await fixture.provider.releaseAll()
            await task.value
            let calls = await fixture.provider.embeddingCallCount
            #expect(calls == 0, "The old job must not fetch the replacement's chunks after its dimension await.")
            #expect(try fixture.currentChunks().allSatisfy { $0.embedding == nil })
            #expect(try fixture.currentDocument().content == DocumentsEmbeddingFixture.replacement)
        }
    }

    @Test
    func deletingAnUnrelatedDocumentDoesNotRevokeTheSavedMaterialJob() async throws {
        let fixture = try DocumentsEmbeddingFixture()
        try await fixture.run {
            let original = try fixture.currentDocument()
            let unrelated = try fixture.app.documentRepository.saveDocument(type: .jobDescription,
                title: "Synthetic JD", content: DocumentsEmbeddingFixture.unrelated)
            fixture.app.refreshAll()
            let task = try fixture.startBackground()
            try await fixture.waitForEmbedding()
            fixture.app.deleteDocument(unrelated)
            #expect(!task.isCancelled, "Unrelated document deletion and history-consent invalidation do not revoke this CV embedding job.")
            await fixture.provider.releaseAll()
            await task.value
            #expect(try fixture.currentDocument().id == original.id)
            #expect(try fixture.app.documentRepository.document(type: .jobDescription) == nil)
            #expect(try fixture.currentChunks().allSatisfy { $0.embedding != nil && $0.embeddingModel == fixture.provider.modelName })
        }
    }

    @Test
    func missingEmbeddingResultCannotBeReportedAsACompletedRebuild() async throws {
        let fixture = try DocumentsEmbeddingFixture(failEmbedding: true)
        try await fixture.run {
            let task = try fixture.startRebuild()
            try await fixture.waitForEmbedding()
            await fixture.provider.releaseAll()
            await task.value
            #expect(try fixture.currentChunks().allSatisfy { $0.embedding == nil })
            #expect(fixture.app.lastEmbeddingTestStatus != "Embedding rebuild complete.")
            #expect(fixture.app.latestActionFeedback(for: ActionID.rebuildEmbeddings)?.kind != .success)
            #expect(!fixture.app.isRebuildingEmbeddings)
        }
    }

    @Test
    func explicitEmbeddingOfSavedMaterialDoesNotRequireTranscriptHistoryConsent() async throws {
        let fixture = try DocumentsEmbeddingFixture()
        try await fixture.run {
            #expect(!fixture.app.settings.saveTranscriptsLocally)
            let task = try fixture.startRebuild()
            try await fixture.waitForEmbedding()
            await fixture.provider.releaseAll()
            await task.value
            let chunks = try fixture.currentChunks()
            #expect(chunks.count == 1)
            #expect(chunks.allSatisfy { $0.embedding != nil && $0.embeddingModel == fixture.provider.modelName })
            #expect(fixture.app.embeddingCoverage?.chunksWithEmbeddings == 1)
            #expect(fixture.app.latestActionFeedback(for: ActionID.rebuildEmbeddings)?.kind == .success)
            #expect(!fixture.app.isRebuildingEmbeddings)
        }
    }
}

enum EmbeddingSettingsIntent: Sendable, Equatable { case modelChanged, modelChangedThenRestored, providerDisabled }
private enum EmbeddingHeldStage: Sendable, Equatable { case dimension, embedding }
private enum EmbeddingLifecycleEvent: Sendable, Equatable {
    case entered(EmbeddingHeldStage)
    case cancelled(EmbeddingHeldStage)
    case shutdownReturned(allProviderWorkReleased: Bool)
}

/// Ignores cancellation until the fixture releases its real provider await.
/// onCancel only yields an immutable event; it creates no cleanup Task.
private actor HeldDocumentEmbeddingProvider: EmbeddingProvider {
    nonisolated let providerID = "controlled-mock"
    nonisolated let modelName = "synthetic-model-A"
    nonisolated let trace = TestEventWaitTrace(label: "DocumentsEmbedding:provider")
    private let events: AsyncStream<EmbeddingLifecycleEvent>.Continuation
    private let failEmbedding: Bool
    private let holdDimension: Bool
    private(set) var embeddingCallCount = 0
    private var released = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    init(events: AsyncStream<EmbeddingLifecycleEvent>.Continuation, failEmbedding: Bool, holdDimension: Bool) {
        self.events = events
        self.failEmbedding = failEmbedding
        self.holdDimension = holdDimension
    }
    var dimension: Int {
        get async throws {
            if holdDimension { await hold(.dimension) }
            return 3
        }
    }
    func embed(text: String) async throws -> [Float] {
        embeddingCallCount += 1
        await hold(.embedding)
        if failEmbedding { throw EmbeddingProviderError.invalidEmbeddingResponse("Synthetic held provider failure") }
        return [0.25, 0.5, 0.75]
    }
    private func hold(_ stage: EmbeddingHeldStage) async {
        let id = UUID()
        let events = events
        let trace = trace
        await withTaskCancellationHandler {
            if !released {
                await withCheckedContinuation { continuation in
                    waiters[id] = continuation
                    trace.mark("producer.\(stage).entered")
                    events.yield(.entered(stage))
                }
            }
        } onCancel: {
            trace.mark("producer.\(stage).cancel_requested")
            events.yield(.cancelled(stage))
        }
        trace.mark("producer.\(stage).returned")
    }
    func embedBatch(texts: [String]) async throws -> [[Float]] {
        var results: [[Float]] = []
        for text in texts { results.append(try await embed(text: text)) }
        return results
    }
    func releaseAll() {
        released = true
        let waiting = Array(waiters.values)
        waiters.removeAll()
        waiting.forEach { $0.resume() }
    }
    func allWorkReleased() -> Bool { released }
}

@MainActor
private final class DocumentsEmbeddingFixture {
    static let original = "Synthetic document: I designed an isolated transactional service, reviewed its source references, and validated cancellation and persistence with controlled tests."
    static let replacement = "Synthetic replacement: I designed a different bounded document workflow, reviewed exact source locations, and verified its persistence with independent synthetic records."
    static let unrelated = "Synthetic job requirements: design a transactional service with bounded concurrency, write cancellation regressions, and document measurable ownership and persistence boundaries."
    let database: AppDatabase
    let app: AppState
    let provider: HeldDocumentEmbeddingProvider
    private let events: AsyncStream<EmbeddingLifecycleEvent>
    private let eventContinuation: AsyncStream<EmbeddingLifecycleEvent>.Continuation
    private var operations: [Task<Void, Never>] = []
    private var shutdowns: [Task<Void, Never>] = []
    private(set) var shutdownReturned = false

    init(failEmbedding: Bool = false, holdDimension: Bool = false) throws {
        let pair = AsyncStream<EmbeddingLifecycleEvent>.makeStream(bufferingPolicy: .bufferingOldest(32))
        events = pair.stream; eventContinuation = pair.continuation
        let provider = HeldDocumentEmbeddingProvider(events: pair.continuation, failEmbedding: failEmbedding, holdDimension: holdDimension)
        self.provider = provider
        database = try AppDatabase(inMemory: true)
        app = AppState(database: database, permissionService: HermeticPermissionService(), verificationMocksEnabled: false,
            embeddingProviderResolverOverride: { settings in settings.embeddingProviderKind == .disabled ? nil : provider })
        var settings = app.settings
        settings.saveTranscriptsLocally = false
        settings.autoGenerateEmbeddingsOnDocumentSave = false
        settings.enableVectorRAG = true
        settings.embeddingProviderKind = .mock
        settings.embeddingModelName = provider.modelName
        settings.embeddingDimension = 3
        app.settingsState.saveSettings(settings)
        app.saveDocument(type: .cv, title: "Synthetic CV", content: Self.original)
        #expect(try currentChunks().count == 1)
    }

    func startRebuild() throws -> Task<Void, Never> {
        app.rebuildAllEmbeddings()
        let task = try #require(app.activeEmbeddingRebuildTask)
        operations.append(task)
        return task
    }
    func startBackground() throws -> Task<Void, Never> {
        var settings = app.settings
        settings.autoGenerateEmbeddingsOnDocumentSave = true
        app.settingsState.saveSettings(settings)
        let task = try #require(app.triggerEmbeddingGeneration(for: .cv))
        operations.append(task)
        return task
    }
    func currentChunks() throws -> [DocumentChunk] { try app.documentRepository.chunks(type: .cv) }
    func currentDocument() throws -> DocumentRecord { try #require(try app.documentRepository.document(type: .cv)) }
    func replaceContentOfExistingChunk(_ id: String) throws {
        try database.dbQueue.write { db in
            try db.execute(sql: "UPDATE document_chunks SET content = ? WHERE id = ?", arguments: [Self.replacement, id])
        }
    }
    func waitForDimension() async throws {
        let event = try await nextControlEvent()
        #expect(event == .entered(.dimension))
    }
    func waitForEmbedding() async throws {
        let event = try await nextControlEvent()
        #expect(event == .entered(.embedding))
    }
    func nextControlEvent() async throws -> EmbeddingLifecycleEvent {
        try await provider.trace.nextEvent(in: events, event: "control")
    }
    func beginShutdown() -> Task<Void, Never> {
        let task = Task { @MainActor in
            await app.shutdownForTesting()
            shutdownReturned = true
            let released = await provider.allWorkReleased()
            eventContinuation.yield(.shutdownReturned(allProviderWorkReleased: released))
        }
        shutdowns.append(task)
        return task
    }
    func run(_ operation: () async throws -> Void) async throws {
        do {
            try await operation()
            try await cleanup()
        } catch {
            try await cleanup()
            throw error
        }
    }
    private func cleanup() async throws {
        // Always release first: cancellation intentionally does not free the
        // fake provider. Both the app-owned and fixture-retained handles join.
        await provider.releaseAll()
        for task in operations { task.cancel(); await task.value }
        for task in shutdowns { await task.value }
        await app.shutdownForTesting()
        eventContinuation.finish()
        try database.close()
    }
}
