import Foundation
import Combine
import Testing
@testable import Hireva

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct DocumentEmbeddingOwnershipTests {
    @Test
    func directObserversShareTheSamePublishedEmbeddingFacts() async throws {
        let fixture = try await EmbeddingOwnerFixture()
        try await fixture.run {
            // The concrete update publisher identifies the changed field.
            // Initial/current facts come from the one authoritative owner.
            var first = [fixture.owner.phase]
            var second = [fixture.owner.phase]
            var progress = [fixture.owner.progress]
            var coverage = [fixture.owner.coverage]
            let a = fixture.owner.updates.sink { update in
                if case .phase = update { first.append(fixture.owner.phase) }
            }
            let b = fixture.owner.updates.sink { update in
                if case .phase = update { second.append(fixture.owner.phase) }
            }
            let p = fixture.owner.updates.sink { update in
                if case .progress = update { progress.append(fixture.owner.progress) }
            }
            let c = fixture.owner.updates.sink { update in
                if case .coverage = update { coverage.append(fixture.owner.coverage) }
            }
            defer { a.cancel(); b.cancel(); p.cancel(); c.cancel() }
            let task = try fixture.start()
            try await fixture.expect(.entered("owner-model-A"))
            #expect(fixture.owner.isRebuilding)
            await fixture.a.release()
            await task.value
            #expect(first == second)
            #expect(first == [.idle, .running, .ready(1)])
            #expect(progress.last == 1)
            #expect(coverage.last.flatMap { $0 }?.chunksWithEmbeddings == 1)
            #expect(fixture.owner.coverage == (try fixture.repository.embeddingCoverage(currentProvider: "controlled-mock", currentModel: "owner-model-A")))
            #expect(fixture.owner.pendingTaskCount == 0)
        }
    }

    @Test(arguments: 0..<20)
    func retiredJobIsJoinedWithoutOverwritingOrCancellingItsReplacement(iteration: Int) async throws {
        // Each parameterized case owns its DB/provider gates and deterministically
        // orders two real jobs under the ordinary framework's parallel schedule.
        let fixture = try await EmbeddingOwnerFixture()
        try await fixture.run {
            let a = try fixture.start()
            try await fixture.expect(.entered("owner-model-A"))
            let previous = fixture.box.settings
            fixture.box.settings.embeddingModelName = "owner-model-B"
            fixture.owner.configurationDidChange(previous: previous, current: fixture.box.settings)
            try await fixture.expect(.cancelled("owner-model-A"))
            let b = try fixture.start()
            try await fixture.expect(.entered("owner-model-B"))
            #expect(a.isCancelled)
            #expect(!b.isCancelled)
            #expect(fixture.owner.pendingTaskCount == 2)
            await fixture.a.release()
            await a.value
            #expect(fixture.owner.pendingTaskCount == 1)
            #expect(fixture.owner.phase == .running)
            #expect(!b.isCancelled)
            #expect(try fixture.repository.allChunks().allSatisfy { $0.embedding == nil })
            await fixture.b.release()
            await b.value
            #expect(fixture.owner.phase == .ready(1))
            #expect(fixture.owner.pendingTaskCount == 0)
            #expect(try fixture.repository.allChunks().allSatisfy { $0.embeddingModel == "owner-model-B" })
        }
    }

    @Test
    func credentialsRevokeTheOriginatingJobBeforeAKeyWriteCanComplete() async throws {
        let fixture = try await EmbeddingOwnerFixture()
        try await fixture.run {
            let task = try fixture.start()
            try await fixture.expect(.entered("owner-model-A"))
            fixture.owner.credentialWillChange(account: "unrelated-synthetic-account")
            #expect(!task.isCancelled)
            fixture.owner.credentialWillChange(account: fixture.box.settings.embeddingApiKeyAccount)
            #expect(task.isCancelled)
            try await fixture.expect(.cancelled("owner-model-A"))
            await fixture.a.release()
            await task.value
            #expect(try fixture.repository.allChunks().allSatisfy { $0.embedding == nil })
            #expect(fixture.box.feedback.last?.kind == .warning)
            #expect(fixture.owner.phase == .cancelled)
        }
    }

    @Test
    func settingsCredentialActionReachesTheActualApplicationEmbeddingOwner() async throws {
        let fixture = try await EmbeddingOwnerFixture()
        try await fixture.run {
            let keychain = KeychainService(store: InMemoryMockKeychainStore())
            let app = AppState(database: fixture.database, permissionService: HermeticPermissionService(),
                keychainService: keychain, verificationMocksEnabled: false,
                embeddingProviderResolverOverride: { [provider = fixture.a] _ in provider })
            var retained: Task<Void, Never>?
            @MainActor func cleanup() async {
                await fixture.a.release()
                retained?.cancel()
                await retained?.value
                await app.shutdownForTesting()
            }
            do {
                var settings = fixture.box.settings
                settings.autoGenerateEmbeddingsOnDocumentSave = false
                app.settingsState.saveSettings(settings)
                app.rebuildAllEmbeddings()
                let task = try #require(app.activeEmbeddingRebuildTask)
                retained = task
                try await fixture.expect(.entered("owner-model-A"))
                app.settingsState.saveEmbeddingAPIKey("synthetic-embedding-test-key", account: settings.embeddingApiKeyAccount)
                #expect(task.isCancelled)
                try await fixture.expect(.cancelled("owner-model-A"))
                #expect(try keychain.loadAPIKey(account: settings.embeddingApiKeyAccount) == "synthetic-embedding-test-key")
                await fixture.a.release()
                await task.value
                #expect(try fixture.repository.allChunks().allSatisfy { $0.embedding == nil })
                #expect(app.documentsState.embeddings.phase == .cancelled)
                await cleanup()
            } catch {
                await cleanup()
                throw error
            }
        }
    }

    @Test
    func cleanIndexRevokesOldSourcesAndIsRetainedThroughItsRealExit() async throws {
        let fixture = try await EmbeddingOwnerFixture()
        try await fixture.run {
            let before = try fixture.repository.allChunks()
            let old = try fixture.start()
            try await fixture.expect(.entered("owner-model-A"))
            // Disable subsequent vector rebuilding, so only the clean-index
            // task and the retired held job exist in this exact scenario.
            fixture.box.settings.enableVectorRAG = false
            var callbackChunks: [DocumentChunk] = []
            let clean = try #require(fixture.owner.rebuildCleanIndex(willChangeSources: {
                callbackChunks = (try? fixture.repository.allChunks()) ?? []
            }))
            fixture.operations.append(clean)
            #expect(old.isCancelled)
            try await fixture.expect(.cancelled("owner-model-A"))
            await clean.value
            #expect(callbackChunks.map(\.id) == before.map(\.id))
            let after = try fixture.repository.allChunks()
            #expect(after.count == before.count)
            #expect(after.map(\.id) != before.map(\.id))
            #expect(fixture.owner.pendingTaskCount == 1)
            await fixture.a.release()
            await old.value
            #expect(try fixture.repository.allChunks().allSatisfy { $0.embedding == nil })
            #expect(fixture.owner.pendingTaskCount == 0)
            #expect(fixture.box.feedback.last?.actionID == ActionID.rebuildCleanRAG)
            #expect(fixture.box.feedback.last?.kind == .success)
        }
    }

    @Test
    func fileImportCallsTheExistingSourceHookBeforeReplacingStoredMaterial() async throws {
        let database = try await TestSupport.makeInMemoryDatabase()
        let repository = DocumentRepository(database: database)
        var owner: DocumentsState?
        do {
            _ = try repository.saveDocument(type: .cv, title: "Before import", content: EmbeddingOwnerFixture.original)
            let bytes = Data(EmbeddingOwnerFixture.replacement.utf8)
            let material = try MaterialExtractionService.extract(data: bytes, filename: "synthetic.md")
            var contentAtSourceHook: String?
            var originWasFileImport = false
            let state = DocumentsState(repository: repository, extractURL: { _ in (material, bytes) },
                willSave: { origin in
                    contentAtSourceHook = (try? repository.document(type: .cv))?.content
                    if case .fileImport = origin { originWasFileImport = true }
                })
            owner = state
            state.importDocument(from: URL(fileURLWithPath: "/HirevaSyntheticImport/synthetic.md"), as: .cv)
            let task = try #require(state.importTask)
            await task.value
            #expect(originWasFileImport)
            #expect(contentAtSourceHook == EmbeddingOwnerFixture.original)
            #expect(try repository.document(type: .cv)?.content == material.text)
            await state.shutdown()
            try database.close()
        } catch {
            await owner?.shutdown()
            try? database.close()
            throw error
        }
    }

    @Test
    func closedEmbeddingOwnerRejectsEveryNewEntryWithoutFeedbackOrDatabaseWrites() async throws {
        let fixture = try await EmbeddingOwnerFixture()
        try await fixture.run {
            await fixture.owner.shutdown()
            let feedback = fixture.box.feedback
            let chunks = try fixture.repository.allChunks()
            #expect(fixture.owner.rebuildAll() == nil)
            #expect(fixture.owner.generateAutomatically(type: .cv) == nil)
            #expect(fixture.owner.rebuildCleanIndex(willChangeSources: { Issue.record("Closed owner ran a source hook.") }) == nil)
            #expect(fixture.box.feedback == feedback)
            #expect(try fixture.repository.allChunks().map(\.id) == chunks.map(\.id))
            #expect(fixture.owner.pendingTaskCount == 0)
        }
    }
}

private enum EmbeddingOwnerEvent: Equatable, Sendable { case entered(String), cancelled(String) }
private actor EmbeddingOwnerProvider: EmbeddingProvider {
    nonisolated let providerID = "controlled-mock"
    nonisolated let modelName: String
    private let events: AsyncStream<EmbeddingOwnerEvent>.Continuation
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(model: String, events: AsyncStream<EmbeddingOwnerEvent>.Continuation) { modelName = model; self.events = events }
    var dimension: Int { get async throws { 3 } }
    func embed(text: String) async throws -> [Float] {
        let events = events, model = modelName
        await withTaskCancellationHandler {
            if !released {
                await withCheckedContinuation { continuation in
                    waiters.append(continuation)
                    events.yield(.entered(model))
                }
            }
        } onCancel: { events.yield(.cancelled(model)) }
        return [1, 0, 0]
    }
    func embedBatch(texts: [String]) async throws -> [[Float]] {
        var result: [[Float]] = []
        for text in texts { result.append(try await embed(text: text)) }
        return result
    }
    func release() {
        released = true
        let pending = waiters; waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
private final class EmbeddingOwnerBox {
    var settings = AppSettings.default
    var feedback: [ActionFeedback] = []
}
@MainActor
private final class EmbeddingOwnerFixture {
    static let original = "Synthetic source: I designed an isolated transactional service, reviewed its source locations, and validated cancellation and conditional persistence using controlled test gates."
    static let replacement = "Synthetic replacement: I designed a separate bounded document flow, reviewed its source locations, and validated cancellation and persistence using independent test material."
    let database: AppDatabase
    let repository: DocumentRepository
    let owner: DocumentEmbeddingState
    let box = EmbeddingOwnerBox()
    let a: EmbeddingOwnerProvider
    let b: EmbeddingOwnerProvider
    let trace = TestEventWaitTrace(label: "DocumentEmbeddingOwner")
    private let events: AsyncStream<EmbeddingOwnerEvent>
    private let continuation: AsyncStream<EmbeddingOwnerEvent>.Continuation
    var operations: [Task<Void, Never>] = []
    init() async throws {
        let prepared = try await TestSupport.makeInMemoryDatabase()
        database = prepared
        repository = DocumentRepository(database: prepared)
        do { _ = try repository.saveDocument(type: .cv, title: "Synthetic CV", content: Self.original) }
        catch { try? prepared.close(); throw error }
        let pair = AsyncStream<EmbeddingOwnerEvent>.makeStream(bufferingPolicy: .bufferingOldest(32))
        events = pair.stream; continuation = pair.continuation
        a = EmbeddingOwnerProvider(model: "owner-model-A", events: pair.continuation)
        b = EmbeddingOwnerProvider(model: "owner-model-B", events: pair.continuation)
        box.settings.embeddingProviderKind = .mock
        box.settings.embeddingModelName = a.modelName
        box.settings.embeddingDimension = 3
        box.settings.enableVectorRAG = true
        box.settings.autoGenerateEmbeddingsOnDocumentSave = true
        owner = DocumentEmbeddingState(repository: repository, configuration: { [box] in box.settings },
            resolveProvider: { [a, b] settings in settings.embeddingModelName == a.modelName ? a : b },
            feedback: { [box] in box.feedback.append($0) })
    }
    func start() throws -> Task<Void, Never> {
        let task = try #require(owner.rebuildAll())
        operations.append(task)
        return task
    }
    func expect(_ expected: EmbeddingOwnerEvent) async throws {
        let actual = try await trace.nextEvent(in: events, event: "control")
        #expect(actual == expected)
    }
    func run(_ operation: () async throws -> Void) async throws {
        do { try await operation(); try await cleanup() }
        catch { try await cleanup(); throw error }
    }
    private func cleanup() async throws {
        // The provider intentionally ignores cancellation. Release every gate,
        // then join exact retained tasks and the feature before closing its DB.
        await a.release(); await b.release()
        operations.forEach { $0.cancel() }
        await owner.shutdown()
        for task in operations { await task.value }
        continuation.finish()
        try database.close()
    }
}
