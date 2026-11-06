import Foundation
import Testing
@testable import Hireva

/// Actual production extractor/builder regressions. One document prevents the
/// next-document cancellation check from masking a cancelled final extraction.
struct AutomaticEvidenceExtractionCancellationTests {
    @Test(.timeLimit(.minutes(1)))
    func cancelledStartingExtractorNeverReturnsGroundedFacts() async throws {
        let provider = HeldEvidenceExtractionProvider()
        let pending = Task {
            try await LocalQwenDocumentEvidenceExtractor(provider: provider, modelName: "synthetic-extraction")
                .extract(documentID: "cancelled-source", classification: .resume,
                    content: Self.content, persistedChunks: [])
        }
        do {
            try await provider.gate.waitUntilEntered()
            pending.cancel()
            await provider.gate.release()
            expectCancellation(await pending.result)
            await provider.gate.release()
        } catch {
            pending.cancel()
            await provider.gate.release()
            _ = await pending.result
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelledLastDocumentCannotBecomeSuccessfulDeterministicFallback() async throws {
        let provider = HeldEvidenceExtractionProvider()
        let namespace = "cancelled-context-" + UUID().uuidString
        let pending = Task {
            let builder = AutomaticInterviewContextBuilder(
                evidenceExtractor: LocalQwenDocumentEvidenceExtractor(provider: provider, modelName: "synthetic-extraction"),
                cacheNamespace: namespace)
            return try await builder.buildContext(from: [Self.document()], previousConfirmedProfile: nil)
        }
        do {
            try await provider.gate.waitUntilEntered()
            pending.cancel()
            await provider.gate.release()
            expectCancellation(await pending.result)
            await provider.gate.release()
        } catch {
            pending.cancel()
            await provider.gate.release()
            _ = await pending.result
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func genuineUnavailableProviderStillUsesVerifiedLocalFallback() async throws {
        let provider = HeldEvidenceExtractionProvider(failure: URLError(.cannotConnectToHost))
        await provider.gate.release()
        let builder = AutomaticInterviewContextBuilder(
            evidenceExtractor: LocalQwenDocumentEvidenceExtractor(provider: provider, modelName: "synthetic-extraction"),
            cacheNamespace: "unavailable-context-" + UUID().uuidString)
        let result = try await builder.buildContext(from: [Self.document()], previousConfirmedProfile: nil)
        #expect(!result.metrics.usedLocalQwen)
        #expect(result.warnings.contains { $0.code == .localLLMFallback })
        let profile = try #require(result.candidateProfile)
        #expect(profile.allEvidence.contains { $0.sourceSpan?.contains("database transactions") == true })
    }

    private func expectCancellation<T>(_ result: Result<T, Error>) {
        switch result {
        case .success: Issue.record("Cancelled extraction returned a usable build instead of cancellation")
        case .failure(let error): #expect(error is CancellationError)
        }
    }

    private static let content = """
    Synthetic candidate: isolated test material, no real person.
    Projects
    - I implemented database transactions.
    """
    private static func document() -> DocumentRecord {
        .init(id: "synthetic-extraction-source", type: .cv, title: "Synthetic CV", content: content,
            createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1))
    }
}

private struct HeldEvidenceExtractionProvider: LocalLLMProvider {
    let id = "synthetic-held-extraction"
    let displayName = "Synthetic held extraction"
    let gate = HeldEvidenceExtractionStartup()
    var failure: URLError? = nil
    func healthCheck(modelName: String) async -> LocalLLMHealth {
        .init(ollamaRunning: true, selectedModel: modelName, modelInstalled: true,
            providerSource: .ollamaQwen, lastError: nil)
    }
    func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        await gate.hold()
        if let failure { throw failure }
        // Intentionally ignores startup cancellation. The consumer/builder must
        // reject late completion independently; every test releases this gate.
        return AsyncThrowingStream { continuation in
            continuation.yield(.init(text: #"{"facts":[{"statement":"I implemented database transactions.","source_span":"I implemented database transactions.","evidence_type":"project","confidence":1.0}]}"#,
                source: .ollamaQwen, modelName: request.modelName))
            continuation.finish()
        }
    }
}

private actor HeldEvidenceExtractionStartup {
    nonisolated let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func hold() async {
        entered.continuation.yield(())
        if !released { await withCheckedContinuation { waiter = $0 } }
    }
    func release() {
        released = true
        waiter?.resume(); waiter = nil
        entered.continuation.finish()
    }
    nonisolated func waitUntilEntered() async throws {
        _ = try await TestEventWaitTrace(label: "actual-evidence-extractor-startup")
            .nextEvent(in: entered.stream, event: "started")
    }
}
