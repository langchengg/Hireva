import Foundation
import Testing
@testable import InterviewCopilotMac

@Suite(.serialized)
struct CloudEmbeddingProviderTests {
    @Test
    func cloudEmbeddingProviderUsesOpenAICompatibleEmbeddingsEndpoint() async throws {
        let keyStore = InMemoryAPIKeyStore()
        try keyStore.saveAPIKey("embed-secret-1234", account: KeychainConstants.defaultEmbeddingAccount)

        MockURLProtocol.handlers["https://embeddings.example.test"] = { request in
            #expect(request.url?.absoluteString == "https://embeddings.example.test/embeddings")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer embed-secret-1234")

            let bodyData = try #require(Self.requestBodyData(request))
            let object = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            #expect(object?["model"] as? String == "cloud-embedding-model")
            #expect(object?["input"] as? [String] == ["first text", "second text"])

            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data = Data("""
            {
              "object": "list",
              "model": "cloud-embedding-model",
              "data": [
                { "object": "embedding", "index": 0, "embedding": [0.1, 0.2, 0.3] },
                { "object": "embedding", "index": 1, "embedding": [0.4, 0.5, 0.6] }
              ]
            }
            """.utf8)
            return (response, data)
        }

        let provider = CloudEmbeddingProvider(
            providerID: "cloudOpenAICompatible",
            displayName: "Cloud Embeddings",
            baseURL: "https://embeddings.example.test",
            apiKeyAccount: KeychainConstants.defaultEmbeddingAccount,
            modelName: "cloud-embedding-model",
            dimensions: 3,
            requestFormat: .openAICompatible,
            apiKeyStore: keyStore,
            session: makeMockSession()
        )

        let embeddings = try await provider.embedBatch(texts: ["first text", "second text"])

        #expect(embeddings == [[0.1, 0.2, 0.3], [0.4, 0.5, 0.6]])
        #expect(try await provider.dimension == 3)
    }

    @Test
    func cloudEmbeddingProviderMissingKeyThrowsCleanError() async throws {
        let keyStore = InMemoryAPIKeyStore()
        let provider = CloudEmbeddingProvider(
            providerID: "cloudOpenAICompatible",
            displayName: "Cloud Embeddings",
            baseURL: "https://embeddings.example.test",
            apiKeyAccount: KeychainConstants.defaultEmbeddingAccount,
            modelName: "cloud-embedding-model",
            dimensions: 3,
            requestFormat: .openAICompatible,
            apiKeyStore: keyStore,
            session: makeMockSession()
        )

        await #expect(throws: EmbeddingProviderError.missingAPIKey(providerName: "Cloud Embeddings")) {
            _ = try await provider.embed(text: "hello")
        }
    }

    private func makeMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func requestBodyData(_ request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read > 0 {
                data.append(buffer, count: read)
            } else {
                break
            }
        }
        return data
    }
}
