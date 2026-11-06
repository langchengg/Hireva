import Foundation
import os
import Testing
@testable import Hireva

@MainActor
struct HybridRetrievalCancellationContractTests {
    @Test(.timeLimit(.minutes(1)))
    func cancelledRealHybridQueryDoesNotBecomeASuccessfulKeywordFallback() async throws {
        let database = try AppDatabase(inMemory: true)
        let documents = DocumentRepository(database: database)
        let embedding = HybridCancellationEmbeddingGate()
        var pending: Task<(context: RetrievedContext, trace: RetrievalTrace), Error>?
        do {
            _ = try documents.saveDocument(type: .cv, title: "Synthetic transaction note",
                content: "Database transactions commit all operations together or roll back all operations together. Isolation controls concurrent changes.")
            var settings = AppSettings.default
            settings.enableVectorRAG = true
            settings.forceHybridRAG = true
            settings.embeddingProviderKind = .mock
            settings.embeddingModelName = embedding.modelName
            let configuration = settings
            let service = HybridContextRetrievalService(documentRepository: documents,
                configurationProvider: { (configuration, embedding) })
            let request = Task {
                try await service.retrieveContextWithTrace(question: "Explain database transaction atomicity.",
                    intent: .technical, maxCVWords: 300, maxJDWords: 180)
            }
            pending = request
            _ = try await TestEventWaitTrace(label: "hybrid.cancellation.entry")
                .nextEvent(in: embedding.entered.stream, event: "embedding-entered")
            request.cancel()
            // The real structured group owns this deliberately noncooperative
            // child. Release before joining, including every failure path.
            embedding.release()
            switch await request.result {
            case .success:
                Issue.record("A cancelled real Hybrid query returned successful context instead of cancellation.")
            case .failure(let error):
                #expect(error is CancellationError)
            }
            #expect(embedding.exited)
            try database.close()
        } catch {
            pending?.cancel(); embedding.release()
            _ = await pending?.result
            try? database.close()
            throw error
        }
    }
}

private final class HybridCancellationEmbeddingGate: EmbeddingProvider {
    let providerID = "synthetic-hybrid-cancellation"
    let modelName = "synthetic-hybrid-cancellation-model"
    var dimension: Int { get async throws { 2 } }
    private struct State: Sendable {
        var released = false
        var waiter: CheckedContinuation<Void, Never>?
        var exited = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    var exited: Bool { state.withLock { $0.exited } }
    func release() {
        let waiter = state.withLock { state in
            state.released = true
            let waiter = state.waiter
            state.waiter = nil
            return waiter
        }
        waiter?.resume()
    }
    func embed(text: String) async throws -> [Float] {
        defer { state.withLock { $0.exited = true } }
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { state in
                guard !state.released else { return true }
                state.waiter = continuation
                return false
            }
            entered.continuation.yield(()); entered.continuation.finish()
            if resumeNow { continuation.resume() }
        }
        return [1, 0]
    }
    func embedBatch(texts: [String]) async throws -> [[Float]] {
        var result: [[Float]] = []
        for text in texts { result.append(try await embed(text: text)) }
        return result
    }
}
