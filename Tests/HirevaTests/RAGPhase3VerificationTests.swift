import Foundation
import GRDB
import Testing
@testable import Hireva

@Suite
struct RAGPhase3VerificationTests {
    @Test
    func cleanRAGRebuildWorksWithoutEmbeddings() async throws {
        let fixture = try RAGTemporaryDatabaseFixture(prefix: "HirevaRAGPhase3-Keyword")
        var cleanupCompleted = false
        defer {
            if !cleanupCompleted {
                try? fixture.cleanup()
            }
        }
        let database = fixture.database
        let documents = DocumentRepository(database: database)

        _ = try documents.saveDocument(
            type: .cv,
            title: "Synthetic Service Profile",
            content: """
            \\documentclass{article}
            \\usepackage{geometry}
            \\begin{document}
            Event scheduling service: built idempotent workflows and queue retry controls.
            \\end{document}
            """
        )

        let result = try documents.rebuildCleanRAGIndex()
        #expect(result.chunksRebuilt > 0)

        let pollutedCount = try await database.dbQueue.read { db in
            try Int.fetchOne(db, sql: """
            SELECT COUNT(*)
            FROM document_chunks
            WHERE content LIKE '%documentclass%'
               OR content LIKE '%usepackage%'
               OR content LIKE '%geometry%'
               OR content LIKE '%begin{document}%'
            """) ?? 0
        }
        #expect(pollutedCount == 0)

        var settings = AppSettings.default
        settings.enableVectorRAG = true
        settings.embeddingProviderKind = .disabled

        let service = HybridContextRetrievalService(
            documentRepository: documents,
            settingsProvider: { settings },
            embeddingProviderResolver: { nil }
        )

        let (_, trace) = try await service.retrieveContextWithTrace(
            question: "Tell me about your event scheduling service.",
            intent: .technical,
            maxCVWords: 150,
            maxJDWords: 150
        )

        #expect(trace.retrievalMode == "keywordOnly")
        #expect(trace.queryEmbeddingGenerated == false)
        try fixture.cleanup()
        cleanupCompleted = true
    }

    @Test
    func cleanRAGRebuildWithMockCloudEmbeddingsGivesHybridRetrieval() async throws {
        let fixture = try RAGTemporaryDatabaseFixture(prefix: "HirevaRAGPhase3-Hybrid")
        var cleanupCompleted = false
        defer {
            if !cleanupCompleted {
                try? fixture.cleanup()
            }
        }
        let database = fixture.database
        let documents = DocumentRepository(database: database)

        _ = try documents.saveDocument(
            type: .cv,
            title: "Synthetic Service Profile",
            content: """
            Incident analytics service using structured logs and trace correlation for retry diagnosis.

            Event scheduling API using idempotency keys and queue backpressure.
            """
        )
        _ = try documents.saveDocument(
            type: .jobDescription,
            title: "Synthetic Service Opportunity",
            content: "Looking for a service engineer with incident analytics, trace correlation, and reliable queue processing experience."
        )

        _ = try documents.rebuildCleanRAGIndex()

        let provider = ControlledMockEmbeddingProvider()
        let chunks = try documents.allChunks()
        for chunk in chunks {
            let embedding = try await provider.embed(text: chunk.content)
            let hash = documents.calculateContentHash(
                content: chunk.content,
                sectionTitle: chunk.sectionTitle,
                provider: "cloudOpenAICompatible",
                modelName: provider.modelName,
                dimension: 384
            )
            try documents.updateChunkEmbedding(
                chunkID: chunk.id,
                embedding: embedding,
                model: provider.modelName,
                provider: "cloudOpenAICompatible",
                dimension: 384,
                contentHash: hash
            )
        }

        let coverage = try documents.embeddingCoverage(currentProvider: "cloudOpenAICompatible", currentModel: provider.modelName)
        #expect(coverage.totalChunks == chunks.count)
        #expect(coverage.chunksWithEmbeddings == chunks.count)
        #expect(coverage.coveragePercent == 100.0)

        var settings = AppSettings.default
        settings.enableVectorRAG = true
        settings.forceHybridRAG = true
        settings.embeddingProviderKind = .openAICompatibleCloud
        settings.embeddingModelName = provider.modelName
        settings.hybridSemanticWeight = 0.7
        settings.hybridKeywordWeight = 0.3

        let service = HybridContextRetrievalService(
            documentRepository: documents,
            settingsProvider: { settings },
            embeddingProviderResolver: { provider }
        )

        let (_, trace) = try await service.retrieveContextWithTrace(
            question: "Tell me about your incident analytics service experience.",
            intent: .technical,
            maxCVWords: 150,
            maxJDWords: 150
        )

        #expect(trace.retrievalMode == "hybrid")
        #expect(trace.queryEmbeddingGenerated == true)
        #expect(trace.rankedCVChunks.first?.semanticScore != nil)
        #expect(trace.rankedCVChunks.first?.finalHybridScore != nil)
        try fixture.cleanup()
        cleanupCompleted = true
    }

    @Test
    func deepSeekProviderCompletionUsesInjectedTransportAndCredential() async throws {
        let apiKeyStore = InMemoryAPIKeyStore()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [RAGSyntheticDeepSeekURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let client = DeepSeekLLMClient(apiKeyStore: apiKeyStore, session: session)
        var provider = LLMProviderConfiguration.deepSeekDefault(model: "deepseek-contract-model")
        provider.baseURL = "https://api.deepseek.com/v1"
        provider.apiKeyAccount = "synthetic.untrusted-account"
        let normalizedProvider = try provider.validatedForLiveUse()
        #expect(normalizedProvider.apiKeyAccount == KeychainConstants.deepSeekAccount)
        try apiKeyStore.saveAPIKey(
            "synthetic-test-token",
            account: try #require(normalizedProvider.apiKeyAccount)
        )

        let result = try await client.chatCompletion(
            configuration: provider,
            messages: [
                .system("You are a helpful assistant. Keep answers brief."),
                .user("Return a single short sentence confirming readiness.")
            ],
            responseFormat: nil,
            options: LLMRequestOptions(temperature: 0.1)
        )

        #expect(result.content == "Synthetic provider contract ready.")
        #expect(result.providerKind == .deepSeek)
        #expect(result.providerName == "DeepSeek")
        #expect(result.modelName == "deepseek-contract-model")
        #expect(result.baseURL == "https://api.deepseek.com/v1")
    }

}

private final class RAGTemporaryDatabaseFixture {
    let database: AppDatabase
    private let directory: URL
    private var cleanedUp = false

    init(prefix: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            database = try AppDatabase(path: directory.appendingPathComponent("test.sqlite"))
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func cleanup() throws {
        guard !cleanedUp else { return }
        try database.close()
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        cleanedUp = true
    }
}

private final class RAGSyntheticDeepSeekURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let body = try requestBody()
            let object = body.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            let methodMatches = request.httpMethod == "POST"
            let urlMatches = request.url?.absoluteString == "https://api.deepseek.com/v1/chat/completions"
            let authorizationMatches = request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-test-token"
            let modelMatches = object?["model"] as? String == "deepseek-contract-model"
            guard methodMatches, urlMatches, authorizationMatches, modelMatches else {
                throw NSError(
                    domain: "RAGSyntheticDeepSeekURLProtocol",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Synthetic DeepSeek request contract did not match: method=\(methodMatches), url=\(urlMatches), authorization=\(authorizationMatches), body=\(body != nil), model=\(modelMatches)."
                    ]
                )
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = Data("""
            {
              "id": "synthetic-rag-contract",
              "model": "deepseek-contract-model",
              "choices": [
                {
                  "index": 0,
                  "message": {
                    "role": "assistant",
                    "content": "Synthetic provider contract ready."
                  },
                  "finish_reason": "stop"
                }
              ]
            }
            """.utf8)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private func requestBody() throws -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 {
                throw stream.streamError ?? URLError(.cannotDecodeContentData)
            }
            if count == 0 {
                break
            }
            body.append(buffer, count: count)
        }
        return body
    }
}
