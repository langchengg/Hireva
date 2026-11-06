import Foundation
import Combine
import Testing
@testable import Hireva

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct DocumentEmbeddingPublicationReentryTests {
    @Test
    func replacementRequestedInsideTerminalNotificationKeepsItsOwnPhaseAndFeedback() async throws {
        let database = try AppDatabase(inMemory: true)
        let repository = DocumentRepository(database: database)
        _ = try repository.saveDocument(type: .cv, title: "Synthetic source", content: Self.source)
        let pair = AsyncStream<PublicationEvent>.makeStream(bufferingPolicy: .bufferingOldest(16))
        let a = PublicationProvider(model: "publication-A", initiallyReleased: true, events: pair.continuation)
        let b = PublicationProvider(model: "publication-B", initiallyReleased: false, events: pair.continuation)
        let box = PublicationBox()
        box.settings.embeddingProviderKind = .mock
        box.settings.embeddingModelName = a.modelName
        box.settings.embeddingDimension = 3
        let owner = DocumentEmbeddingState(repository: repository, configuration: { box.settings },
            resolveProvider: { $0.embeddingModelName == a.modelName ? a : b }, feedback: { box.feedback.append($0) })
        let trace = TestEventWaitTrace(label: "EmbeddingPublicationReplacement")
        var replaced = false
        let observation = owner.updates.sink { update in
            guard case .phase = update, owner.phase == .ready(1), !replaced else { return }
            replaced = true
            let old = box.settings
            box.settings.embeddingModelName = b.modelName
            owner.configurationDidChange(previous: old, current: box.settings)
            if let replacement = owner.rebuildAll() { box.operations.append(replacement) }
        }
        @MainActor func cleanup() async throws {
            observation.cancel()
            await a.release(); await b.release()
            box.operations.forEach { $0.cancel() }
            await owner.shutdown()
            for task in box.operations { await task.value }
            pair.continuation.finish()
            try database.close()
        }
        do {
            let original = try #require(owner.rebuildAll())
            box.operations.append(original)
            let eventA = try await trace.nextEvent(in: pair.stream, event: "A_entered")
            #expect(eventA == .entered(a.modelName))
            await original.value
            #expect(replaced)
            #expect(box.operations.count == 2)
            let eventB = try await trace.nextEvent(in: pair.stream, event: "B_entered")
            // A's cancellation notification is allowed before B's real entry.
            if eventB == .cancelled(a.modelName) {
                #expect(try await trace.nextEvent(in: pair.stream, event: "B_entered_after_A_cancel") == .entered(b.modelName))
            } else { #expect(eventB == .entered(b.modelName)) }
            let replacement = try #require(box.operations.first { !$0.isCancelled })
            #expect(!replacement.isCancelled)
            #expect(owner.phase == .running)
            #expect(owner.progress == 0)
            #expect(box.feedback.last?.kind == .loading)
            #expect(!box.feedback.contains { $0.kind == .success })
            #expect(owner.pendingTaskCount == 1)
            await b.release()
            await replacement.value
            #expect(owner.phase == .ready(1))
            #expect(box.feedback.last?.kind == .success)
            #expect(try repository.allChunks().allSatisfy { $0.embeddingModel == b.modelName })
            #expect(owner.pendingTaskCount == 0)
            try await cleanup()
        } catch { try await cleanup(); throw error }
    }

    @Test
    func providerAwaitDoesNotKeepTheFeatureOwnerAliveAndCancellationStillNeedsARealJoin() async throws {
        let database = try AppDatabase(inMemory: true)
        let repository = DocumentRepository(database: database)
        _ = try repository.saveDocument(type: .cv, title: "Synthetic source", content: Self.source)
        let pair = AsyncStream<PublicationEvent>.makeStream(bufferingPolicy: .bufferingOldest(16))
        let provider = PublicationProvider(model: "publication-A", initiallyReleased: false, events: pair.continuation)
        var settings = AppSettings.default
        settings.embeddingProviderKind = .mock
        settings.embeddingModelName = provider.modelName
        settings.embeddingDimension = 3
        var owner: DocumentEmbeddingState? = DocumentEmbeddingState(repository: repository,
            configuration: { settings }, resolveProvider: { _ in provider })
        weak var weakOwner = owner
        var task: Task<Void, Never>?
        let trace = TestEventWaitTrace(label: "EmbeddingWeakOwner")
        @MainActor func cleanup() async throws {
            await provider.release()
            task?.cancel()
            await task?.value
            await owner?.shutdown()
            owner = nil
            pair.continuation.finish()
            try database.close()
        }
        do {
            let actual = try #require(owner?.rebuildAll())
            task = actual
            #expect(try await trace.nextEvent(in: pair.stream, event: "entered") == .entered(provider.modelName))
            owner = nil
            #expect(weakOwner == nil)
            #expect(actual.isCancelled)
            #expect(try await trace.nextEvent(in: pair.stream, event: "cancelled") == .cancelled(provider.modelName))
            // The held provider ignores cancellation. The test, rather than a
            // deinit assertion, releases it and awaits the exact resource task.
            await provider.release()
            await actual.value
            #expect(try repository.allChunks().allSatisfy { $0.embedding == nil })
            try await cleanup()
        } catch { try await cleanup(); throw error }
    }

    private static let source = "Synthetic source: I designed an isolated feature and validated its publication identity, cancellation lifecycle, and conditional document storage using independent test inputs."
}

private enum PublicationEvent: Equatable, Sendable { case entered(String), cancelled(String) }
private actor PublicationProvider: EmbeddingProvider {
    nonisolated let providerID = "controlled-mock"
    nonisolated let modelName: String
    private let events: AsyncStream<PublicationEvent>.Continuation
    private var released: Bool
    private var pending: [CheckedContinuation<Void, Never>] = []
    init(model: String, initiallyReleased: Bool, events: AsyncStream<PublicationEvent>.Continuation) {
        modelName = model; released = initiallyReleased; self.events = events
    }
    var dimension: Int { get async throws { 3 } }
    func embed(text: String) async throws -> [Float] {
        let events = events, model = modelName
        events.yield(.entered(model))
        await withTaskCancellationHandler {
            if !released { await withCheckedContinuation { pending.append($0) } }
        } onCancel: { events.yield(.cancelled(model)) }
        return [1, 0, 0]
    }
    func embedBatch(texts: [String]) async throws -> [[Float]] {
        var result: [[Float]] = []
        for text in texts { result.append(try await embed(text: text)) }
        return result
    }
    func release() { released = true; let old = pending; pending.removeAll(); old.forEach { $0.resume() } }
}
@MainActor
private final class PublicationBox {
    var settings = AppSettings.default
    var feedback: [ActionFeedback] = []
    var operations: [Task<Void, Never>] = []
}
