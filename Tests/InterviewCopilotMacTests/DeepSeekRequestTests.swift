import Foundation
import Testing
@testable import InterviewCopilotMac

@Suite(.serialized)
struct DeepSeekRequestTests {
    @Test
    func deepSeekRequestConstructionUsesBearerAuthAndJSONResponseFormat() throws {
        let client = DeepSeekClient(baseURL: URL(string: "https://example.test")!)
        let request = ChatCompletionRequest(
            model: "deepseek-v4-flash",
            messages: [.system("system"), .user("user")],
            responseFormat: .jsonObject,
            stream: false,
            temperature: 0.1
        )

        let urlRequest = try client.makeURLRequest(apiKey: "test-token", request: request)
        let body = try #require(urlRequest.httpBody)
        let bodyObject = try JSONSerialization.jsonObject(with: body) as? [String: Any]

        #expect(urlRequest.url?.absoluteString == "https://example.test/chat/completions")
        #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        #expect(bodyObject?["model"] as? String == "deepseek-v4-flash")
        #expect(!(String(data: body, encoding: .utf8)?.contains("test-token") ?? true))

        let responseFormat = bodyObject?["response_format"] as? [String: Any]
        #expect(responseFormat?["type"] as? String == "json_object")
    }

    @Test
    func deepSeekClientDecodesCompletionWithMockNetwork() async throws {
        MockURLProtocol.requestHandler = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = Data("""
            {
              "id": "chatcmpl-test",
              "model": "deepseek-v4-flash",
              "choices": [
                { "index": 0, "message": { "role": "assistant", "content": "{\\"ok\\":true}" }, "finish_reason": "stop" }
              ]
            }
            """.utf8)
            return (response, data)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = DeepSeekClient(baseURL: URL(string: "https://example.test")!, session: session)
        let request = ChatCompletionRequest(
            model: "deepseek-v4-flash",
            messages: [.user("ping")],
            responseFormat: .jsonObject,
            stream: false,
            temperature: 0
        )

        let result = try await client.complete(apiKey: "test-token", request: request)

        #expect(result.response.model == "deepseek-v4-flash")
        #expect(result.response.choices.first?.message?.content == #"{"ok":true}"#)
        #expect(result.rawJSON.contains("chatcmpl-test"))
    }
}

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
