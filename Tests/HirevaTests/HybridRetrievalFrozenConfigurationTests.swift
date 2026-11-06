import Foundation
import Testing
@testable import Hireva

@MainActor
struct HybridRetrievalFrozenConfigurationTests {
    @Test(.timeLimit(.minutes(1)))
    func heldQueryKeepsItsSingleSettingsProviderPairAfterSettingsChange() async throws {
        let suite = "HybridFrozenConfiguration-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = try AppDatabase(inMemory: true)
        let originalGate = FrozenHybridQueryGate(hold: true)
        let replacementGate = FrozenHybridQueryGate(hold: false)
        let original = FrozenHybridQueryProvider(providerID: "synthetic-original-embedding",
            modelName: "synthetic-original-model", gate: originalGate)
        let replacement = FrozenHybridQueryProvider(providerID: "synthetic-replacement-embedding",
            modelName: "synthetic-replacement-model", gate: replacementGate)
        let app = AppState(database: database, questionRoutingProvider: HermeticQuestionRoutingProvider(),
            permissionService: HermeticPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            dialogueDefaults: defaults,
            embeddingProviderResolverOverride: { settings in
                settings.embeddingModelName == original.modelName ? original : replacement
            })
        var request: Task<(context: RetrievedContext, trace: RetrievalTrace), Error>?
        do {
            let documents = DocumentRepository(database: database)
            _ = try documents.saveDocument(type: .cv, title: "Synthetic database note",
                content: "Database transactions commit all operations together or roll back all operations together.")
            let chunks = try documents.chunks(type: .cv)
            try #require(!chunks.isEmpty)
            var initial = app.settings
            initial.enableVectorRAG = true
            initial.forceHybridRAG = true
            initial.embeddingProviderKind = .mock
            initial.embeddingModelName = original.modelName
            initial.hybridSemanticWeight = 0.8
            initial.hybridKeywordWeight = 0.2
            app.settings = initial
            let resolutions = FrozenHybridResolutionObservations()
            let service = HybridContextRetrievalService(documentRepository: documents,
                configurationProvider: { [weak app] in
                    guard let app else { return (.default, nil) }
                    let settings = app.settings
                    let provider = app.resolveEmbeddingProvider(settings: settings)
                    resolutions.record(settings: settings, provider: provider)
                    return (settings, provider)
                })
            let pending = Task {
                try await service.retrieveContextWithTrace(question: "Explain database transaction atomicity.",
                    intent: .technical, maxCVWords: 100, maxJDWords: 100)
            }
            request = pending
            // No short private timer: the case budget bounds readiness, and
            // every failure path releases and joins the actual query task.
            try await originalGate.waitUntilEntered()
            var changed = initial
            changed.enableVectorRAG = false
            changed.forceHybridRAG = false
            changed.embeddingProviderKind = .disabled
            changed.embeddingModelName = replacement.modelName
            changed.hybridSemanticWeight = 0.1
            changed.hybridKeywordWeight = 0.9
            app.settings = changed
            await originalGate.release()
            let output = try await withTaskCancellationHandler {
                try await pending.value
            } onCancel: {
                pending.cancel()
            }
            #expect(resolutions.calls == 1)
            #expect(resolutions.models == [original.modelName])
            #expect(resolutions.providerIDs == [original.providerID])
            let oldCalls = await originalGate.callCount()
            let newCalls = await replacementGate.callCount()
            let embedThreads = await originalGate.mainThreadObservations()
            #expect(oldCalls == 1)
            #expect(newCalls == 0)
            #expect(embedThreads == [false])
            #expect(output.trace.embeddingProvider == original.providerID)
            #expect(output.trace.embeddingModel == initial.embeddingModelName)
            #expect(output.trace.hybridSemanticWeight == initial.hybridSemanticWeight)
            #expect(output.trace.hybridKeywordWeight == initial.hybridKeywordWeight)
            #expect(output.trace.embeddingCoveragePercent == 0)
            #expect(app.settings.embeddingModelName == replacement.modelName)
            #expect(app.settings.enableVectorRAG == false)
            // Entering embed with zero SQL vector coverage proves that this
            // call used forceHybrid=true. The real 450ms product deadline is
            // unchanged; query latency/success is not this ownership assertion.
            await app.shutdownForTesting()
            try database.close()
        } catch {
            request?.cancel()
            await originalGate.release()
            await replacementGate.release()
            _ = await request?.result
            await app.shutdownForTesting()
            try? database.close()
            throw error
        }
    }
}

@MainActor
private final class FrozenHybridResolutionObservations {
    private(set) var calls = 0
    private(set) var models: [String] = []
    private(set) var providerIDs: [String] = []
    func record(settings: AppSettings, provider: EmbeddingProvider?) {
        calls += 1
        models.append(settings.embeddingModelName)
        providerIDs.append(provider?.providerID ?? "nil")
    }
}

private struct FrozenHybridQueryProvider: EmbeddingProvider {
    let providerID: String
    let modelName: String
    let gate: FrozenHybridQueryGate
    var dimension: Int { get async throws { 2 } }
    // Sample this executor before the query gate's actor hop.
    private var isOnMainThread: Bool { Thread.isMainThread }
    func embed(text: String) async throws -> [Float] {
        let isMainThread = isOnMainThread
        return await gate.embed(isMainThread: isMainThread)
    }
    func embedBatch(texts: [String]) async throws -> [[Float]] {
        var result: [[Float]] = []
        for text in texts { result.append(try await embed(text: text)) }
        return result
    }
}

private actor FrozenHybridQueryGate {
    private let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private let hold: Bool
    private var calls = 0
    private var threads: [Bool] = []
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    init(hold: Bool) { self.hold = hold }
    func embed(isMainThread: Bool) async -> [Float] {
        calls += 1
        threads.append(isMainThread)
        entered.continuation.yield(())
        entered.continuation.finish()
        if hold && !released { await withCheckedContinuation { waiter = $0 } }
        return [1, 0]
    }
    func waitUntilEntered() async throws {
        _ = try await TestEventWaitTrace(label: "hybrid.frozen_pair.query")
            .nextEvent(in: entered.stream, event: "provider_entered")
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
    func callCount() -> Int { calls }
    func mainThreadObservations() -> [Bool] { threads }
}
