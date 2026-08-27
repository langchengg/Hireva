import Foundation
import Testing
@testable import Hireva

@Suite
struct ProviderErrorPrivacyTests {
    private let syntheticAPIKey = "sk-synthetic-provider-privacy-canary-000000"
    private let syntheticTranscript = "TRANSCRIPT_PRIVACY_CANARY"
    private let syntheticCV = "CV_PRIVACY_CANARY"
    private let syntheticJD = "JD_PRIVACY_CANARY"
    private let syntheticPath = "/Users/synthetic/private/provider-fixture"
    private let syntheticUserInfo = "USERINFO_PRIVACY_CANARY"
    private let syntheticQuery = "QUERY_PRIVACY_CANARY"

    @Test
    func configuredBaseURLDoesNotEnterLocalizedError() throws {
        let baseURL = "https://\(syntheticUserInfo):\(syntheticAPIKey)@api.example.invalid\(syntheticPath)" +
            "?transcript=\(syntheticTranscript)&cv=\(syntheticCV)&jd=\(syntheticJD)&marker=\(syntheticQuery)"
        let error = LLMProviderError.invalidBaseURL(baseURL)

        try expectLocalizedDescription(
            error,
            excludes: [baseURL, syntheticAPIKey, syntheticTranscript, syntheticCV, syntheticJD, syntheticPath,
                       syntheticUserInfo, syntheticQuery, "?transcript="]
        )
        #expect(error.category == .configuration)
        #expect(error.code == .invalidBaseURL)
        #expect(error.httpStatusCode == nil)
    }

    @Test
    func serverResponseBodyDoesNotEnterLocalizedError() throws {
        let responseBody = """
        {"error":"\(syntheticTranscript)","cv":"\(syntheticCV)","jd":"\(syntheticJD)",
         "path":"\(syntheticPath)","apiKey":"\(syntheticAPIKey)"}
        """
        let error = LLMProviderError.serverError(
            providerName: "DeepSeek",
            statusCode: 503,
            body: responseBody
        )

        let description = try expectLocalizedDescription(
            error,
            excludes: [responseBody, syntheticAPIKey, syntheticTranscript, syntheticCV, syntheticJD, syntheticPath]
        )
        #expect(description.contains("DeepSeek"))
        #expect(description.contains("HTTP 503"))
        #expect(description.contains(LLMProviderErrorCode.serverError.rawValue))
        #expect(error.providerKind == .deepSeek)
        #expect(error.category == .server)
        #expect(error.code == .serverError)
        #expect(error.httpStatusCode == 503)
    }

    @Test
    func arbitraryAssociatedValuesDoNotEnterLocalizedErrors() throws {
        let privateValue = "https://\(syntheticUserInfo):\(syntheticAPIKey)@api.example.invalid" +
            "\(syntheticPath)?marker=\(syntheticQuery)&transcript=\(syntheticTranscript)" +
            "&cv=\(syntheticCV)&jd=\(syntheticJD)"
        let errors: [LLMProviderError] = [
            .notConfigured(privateValue),
            .missingAPIKey(providerName: privateValue),
            .modelNotFound(privateValue),
            .invalidResponse(privateValue),
            .emptyResponse(providerName: privateValue),
            .rateLimited(providerName: privateValue),
            .invalidAPIKey(providerName: privateValue),
            .networkFailure(providerName: privateValue, message: privateValue)
        ]

        for error in errors {
            let description = try expectLocalizedDescription(
                error,
                excludes: [privateValue, syntheticAPIKey, syntheticTranscript, syntheticCV, syntheticJD, syntheticPath,
                           syntheticUserInfo, syntheticQuery]
            )
            #expect(description.contains(error.code.rawValue))
            #expect(error.providerKind == nil)
        }
    }

    @Test
    func typedMetadataCoversEveryProviderErrorCase() {
        let cases: [(LLMProviderError, LLMProviderErrorCategory, LLMProviderErrorCode)] = [
            (.notConfigured("DeepSeek"), .configuration, .notConfigured),
            (.invalidBaseURL("synthetic invalid URL"), .configuration, .invalidBaseURL),
            (.missingAPIKey(providerName: "OpenAI"), .authentication, .missingAPIKey),
            (.modelNotFound("synthetic-model"), .model, .modelNotFound),
            (.invalidResponse("synthetic decoder detail"), .response, .invalidResponse),
            (.emptyResponse(providerName: "Anthropic"), .response, .emptyResponse),
            (.rateLimited(providerName: "Gemini"), .rateLimit, .rateLimited),
            (.invalidAPIKey(providerName: "Custom OpenAI-compatible"), .authentication, .invalidAPIKey),
            (.serverError(providerName: "DeepSeek", statusCode: 502, body: "synthetic"), .server, .serverError),
            (.networkFailure(providerName: "OpenAI", message: "synthetic"), .network, .networkFailure)
        ]

        for (error, category, code) in cases {
            #expect(error.category == category)
            #expect(error.code == code)
        }

        #expect(cases[0].0.providerKind == .deepSeek)
        #expect(cases[2].0.providerKind == .openAI)
        #expect(cases[5].0.providerKind == .anthropic)
        #expect(cases[6].0.providerKind == .gemini)
        #expect(cases[7].0.providerKind == .openAICompatible)
    }

    @discardableResult
    private func expectLocalizedDescription(
        _ error: LLMProviderError,
        excludes forbiddenValues: [String]
    ) throws -> String {
        let errorDescription = try #require(error.errorDescription)
        let localizedDescription = error.localizedDescription

        #expect(localizedDescription == errorDescription)
        for value in forbiddenValues {
            #expect(!errorDescription.contains(value))
            #expect(!localizedDescription.contains(value))
        }
        return errorDescription
    }
}
