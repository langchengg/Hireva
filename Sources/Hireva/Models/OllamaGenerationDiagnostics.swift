import Foundation

enum OllamaFailureCategory: String, Codable, Equatable, Hashable {
    case providerReturnedNoContent = "provider_returned_no_content"
    case streamParserDroppedContent = "stream_parser_dropped_content"
    case responseSchemaMismatch = "response_schema_mismatch"
    case reasoningReceivedWithoutFinalAnswer = "reasoning_received_without_final_answer"
    case answerSectionParserRejectedContent = "answer_section_parser_rejected_content"
    case alignmentRejectedNonemptyContent = "alignment_rejected_nonempty_content"
    case requestCancelled = "request_cancelled"
    case requestTimedOut = "request_timed_out"
    case staleGeneration = "stale_generation"
    case staleContextSnapshot = "stale_context_snapshot"
    case malformedStreamEvent = "malformed_stream_event"
    case providerHTTPError = "provider_http_error"

    static func classify(_ error: Error, httpStatusCode: Int? = nil) -> OllamaFailureCategory {
        if httpStatusCode != nil {
            return .providerHTTPError
        }
        if error is CancellationError {
            return .requestCancelled
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return .requestCancelled
            case .timedOut:
                return .requestTimedOut
            default:
                return .providerHTTPError
            }
        }
        if let providerError = error as? OllamaQwenProviderError {
            return providerError.category
        }
        return .providerHTTPError
    }
}

enum OllamaResponseSchema: String, Codable, Equatable, Hashable {
    case chatMessageContent = "chat.message.content"
    case generateResponse = "generate.response"
}

struct OllamaProviderDiagnostics: Equatable, Hashable {
    var endpoint: String
    var model: String
    var streamMode: Bool
    var responseSchema: OllamaResponseSchema
    var requestMessageCount: Int
    var systemPromptCharacters: Int
    var userPromptCharacters: Int
    var chunksReceived: Int
    var contentChunksReceived: Int
    var malformedEvents: Int
    var rawContentCharacters: Int
    var parsedContentCharacters: Int
    var reasoningCharacters: Int
    var firstContentObserved: Bool
    var streamCompleted: Bool
    var doneReason: String?
    var sectionParserResult: String
    var alignmentDecision: String
    var cancellationReason: String?
    var contextSnapshotMatched: Bool?
    var finalErrorCategory: OllamaFailureCategory?

    static func empty(schema: OllamaResponseSchema = .chatMessageContent) -> OllamaProviderDiagnostics {
        OllamaProviderDiagnostics(
            endpoint: "None",
            model: "None",
            streamMode: false,
            responseSchema: schema,
            requestMessageCount: 0,
            systemPromptCharacters: 0,
            userPromptCharacters: 0,
            chunksReceived: 0,
            contentChunksReceived: 0,
            malformedEvents: 0,
            rawContentCharacters: 0,
            parsedContentCharacters: 0,
            reasoningCharacters: 0,
            firstContentObserved: false,
            streamCompleted: false,
            doneReason: nil,
            sectionParserResult: "not_started",
            alignmentDecision: "not_started",
            cancellationReason: nil,
            contextSnapshotMatched: nil,
            finalErrorCategory: nil
        )
    }
}

struct OllamaLifecycleEvent: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let timestamp: Date
    let sessionID: String
    let questionID: String
    let generationID: String
    let contextSnapshotID: String?
    let candidateProfileID: String?
    let candidateProfileVersion: Int?
    let opportunityContextID: String?
    let opportunityContextVersion: Int?
    let domainProfileID: String?
    let model: String
    let endpoint: String
    let streamMode: Bool
    let requestMessageCount: Int
    let systemPromptCharacters: Int
    let userPromptCharacters: Int
    let candidateEvidenceCount: Int
    let opportunityEvidenceCount: Int
    let dialogueEvidenceCount: Int
    let estimatedPromptTokens: Int
    let responseChunkCount: Int
    let rawContentCharacters: Int
    let parsedContentCharacters: Int
    let alignmentDecision: String
    let failureCategory: OllamaFailureCategory?
}

struct OllamaParsedResponse: Equatable {
    let content: String
    let diagnostics: OllamaProviderDiagnostics
}

struct OllamaResponseAccumulator {
    private struct Envelope: Decodable {
        struct Message: Decodable {
            let content: String?
            let thinking: String?
        }

        let message: Message?
        let response: String?
        let thinking: String?
        let done: Bool?
        let doneReason: String?
        let error: String?

        enum CodingKeys: String, CodingKey {
            case message
            case response
            case thinking
            case done
            case doneReason = "done_reason"
            case error
        }
    }

    private let schema: OllamaResponseSchema
    private var content = ""
    private var diagnostics: OllamaProviderDiagnostics
    private var schemaMismatchObserved = false

    var currentDiagnostics: OllamaProviderDiagnostics {
        diagnostics
    }

    init(schema: OllamaResponseSchema) {
        self.schema = schema
        diagnostics = .empty(schema: schema)
    }

    mutating func ingest(_ line: String) throws -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        diagnostics.chunksReceived += 1

        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: Data(trimmed.utf8))
        } catch {
            diagnostics.malformedEvents += 1
            return nil
        }

        if let providerError = envelope.error?.trimmingCharacters(in: .whitespacesAndNewlines),
           !providerError.isEmpty {
            diagnostics.finalErrorCategory = .providerHTTPError
            throw OllamaQwenProviderError.categorized(.providerHTTPError, providerError)
        }

        let expectedContent: String?
        let alternateContent: String?
        switch schema {
        case .chatMessageContent:
            expectedContent = envelope.message?.content
            alternateContent = envelope.response
        case .generateResponse:
            expectedContent = envelope.response
            alternateContent = envelope.message?.content
        }

        if let alternateContent, !alternateContent.isEmpty, expectedContent?.isEmpty != false {
            schemaMismatchObserved = true
        }

        let reasoning = [envelope.message?.thinking, envelope.thinking]
            .compactMap { $0 }
            .joined()
        diagnostics.reasoningCharacters += reasoning.count

        var emitted: String?
        if let expectedContent, !expectedContent.isEmpty {
            content += expectedContent
            diagnostics.contentChunksReceived += 1
            diagnostics.rawContentCharacters = content.count
            diagnostics.firstContentObserved = true
            emitted = expectedContent
        }

        if envelope.done == true {
            diagnostics.streamCompleted = true
            diagnostics.doneReason = envelope.doneReason
        }
        return emitted
    }

    mutating func finish(requireDone: Bool) throws -> OllamaParsedResponse {
        if schemaMismatchObserved {
            return try fail(.responseSchemaMismatch, "Ollama response did not match the selected endpoint schema.")
        }
        if content.isEmpty {
            if diagnostics.reasoningCharacters > 0 {
                return try fail(.reasoningReceivedWithoutFinalAnswer, "Ollama returned reasoning metadata without a final answer.")
            }
            if diagnostics.malformedEvents > 0 && diagnostics.malformedEvents == diagnostics.chunksReceived {
                return try fail(.malformedStreamEvent, "Ollama returned no decodable response events.")
            }
            return try fail(.providerReturnedNoContent, "Ollama returned no final answer content.")
        }
        if requireDone && !diagnostics.streamCompleted {
            return try fail(.streamParserDroppedContent, "Ollama response ended before a done event.")
        }
        diagnostics.rawContentCharacters = content.count
        diagnostics.parsedContentCharacters = content.count
        diagnostics.finalErrorCategory = nil
        return OllamaParsedResponse(content: content, diagnostics: diagnostics)
    }

    private mutating func fail(_ category: OllamaFailureCategory, _ message: String) throws -> OllamaParsedResponse {
        diagnostics.finalErrorCategory = category
        throw OllamaQwenProviderError.categorized(category, message)
    }
}

struct LocalQwenParsedAnswer: Equatable {
    let sayFirst: String
    let sectionParserResult: String
    let failureCategory: OllamaFailureCategory?
}

enum LocalQwenAnswerParser {
    static func parse(_ raw: String) -> LocalQwenParsedAnswer {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = AnswerQualityValidator.localCleanupAnswer(trimmed)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return LocalQwenParsedAnswer(
                sayFirst: "",
                sectionParserResult: trimmed.isEmpty ? "empty_input" : "rejected_nonempty_input",
                failureCategory: trimmed.isEmpty ? .providerReturnedNoContent : .answerSectionParserRejectedContent
            )
        }

        let lower = cleaned.lowercased()
        if let start = lower.range(of: "say first:") {
            let answerStart = start.upperBound
            let remainder = String(cleaned[answerStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let answer: String
            if let keyPoints = remainder.range(of: "key points:", options: .caseInsensitive) {
                answer = String(remainder[..<keyPoints.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                answer = remainder
            }
            if !answer.isEmpty {
                return LocalQwenParsedAnswer(sayFirst: answer, sectionParserResult: "say_first_section", failureCategory: nil)
            }
        }
        return LocalQwenParsedAnswer(sayFirst: cleaned, sectionParserResult: "direct_answer", failureCategory: nil)
    }
}

struct LocalQwenAnswerValidationResult: Equatable {
    let accepted: Bool
    let failureCategory: OllamaFailureCategory?
    let diagnostic: String

    static func accepted(_ diagnostic: String = "aligned") -> LocalQwenAnswerValidationResult {
        LocalQwenAnswerValidationResult(accepted: true, failureCategory: nil, diagnostic: diagnostic)
    }

    static func rejected(
        category: OllamaFailureCategory,
        diagnostic: String
    ) -> LocalQwenAnswerValidationResult {
        LocalQwenAnswerValidationResult(accepted: false, failureCategory: category, diagnostic: diagnostic)
    }
}
