import Foundation

enum OllamaFailureCategory: String, Codable, Equatable, Hashable, Sendable {
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

enum OllamaResponseSchema: String, Codable, Equatable, Hashable, Sendable {
    case chatMessageContent = "chat.message.content"
    case generateResponse = "generate.response"
}

struct OllamaProviderDiagnostics: Equatable, Hashable, Sendable {
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
    var promptEvalCount: Int? = nil
    var evalCount: Int? = nil
    // Optional server timings are observations, never answer admission or deadlines.
    var totalDurationNS: UInt64? = nil
    var loadDurationNS: UInt64? = nil
    var promptEvalDurationNS: UInt64? = nil
    var evalDurationNS: UInt64? = nil
    // Provider lifetime; counts transport attempts, including failed responses.
    var transportRequestCount: Int = 0
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
        let promptEvalCount: Int?
        let evalCount: Int?
        let totalDurationNS: UInt64?
        let loadDurationNS: UInt64?
        let promptEvalDurationNS: UInt64?
        let evalDurationNS: UInt64?

        enum CodingKeys: String, CodingKey {
            case message
            case response
            case thinking
            case done
            case doneReason = "done_reason"
            case error
            case promptEvalCount = "prompt_eval_count"
            case evalCount = "eval_count"
            case totalDurationNS = "total_duration"
            case loadDurationNS = "load_duration"
            case promptEvalDurationNS = "prompt_eval_duration"
            case evalDurationNS = "eval_duration"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            message = try values.decodeIfPresent(Message.self, forKey: .message)
            response = try values.decodeIfPresent(String.self, forKey: .response)
            thinking = try values.decodeIfPresent(String.self, forKey: .thinking)
            done = try values.decodeIfPresent(Bool.self, forKey: .done)
            doneReason = try values.decodeIfPresent(String.self, forKey: .doneReason)
            error = try values.decodeIfPresent(String.self, forKey: .error)
            // Optional usage metadata must not change content admission.
            promptEvalCount = try? values.decodeIfPresent(Int.self, forKey: .promptEvalCount)
            evalCount = try? values.decodeIfPresent(Int.self, forKey: .evalCount)
            totalDurationNS = try? values.decodeIfPresent(UInt64.self, forKey: .totalDurationNS)
            loadDurationNS = try? values.decodeIfPresent(UInt64.self, forKey: .loadDurationNS)
            promptEvalDurationNS = try? values.decodeIfPresent(UInt64.self, forKey: .promptEvalDurationNS)
            evalDurationNS = try? values.decodeIfPresent(UInt64.self, forKey: .evalDurationNS)
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
            diagnostics.promptEvalCount = envelope.promptEvalCount
            diagnostics.evalCount = envelope.evalCount
            diagnostics.totalDurationNS = envelope.totalDurationNS
            diagnostics.loadDurationNS = envelope.loadDurationNS
            diagnostics.promptEvalDurationNS = envelope.promptEvalDurationNS
            diagnostics.evalDurationNS = envelope.evalDurationNS
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
    var scopedClaim: String? = nil
}

enum LocalQwenAnswerParser {
    static let scopedPropertyOrder = ["scoped_claim", "say_first"]
    static let scopedResponseSchema: LocalJSONValue = .object([
        "type": .string("object"), "additionalProperties": .boolean(false),
        "properties": .object([
            "scoped_claim": .object(["type": .string("string"),
                "description": .string("One complete concise sentence, at least 20 characters and ending with punctuation, with the conditions that actually apply to the question.")]),
            "say_first": .object(["type": .string("string"),
                "description": .string("Spoken version of scoped_claim, 1 to 3 sentences, covering every requested part of the question. Retain its applicable conditions and conclusions; do not add further guarantees, personal experience or unsupported outcomes.")])
        ]), "required": .array(scopedPropertyOrder.map(LocalJSONValue.string))
    ])
    static let scopedOutputInstructions = "Return only valid JSON matching the supplied public response schema. Give a concise conclusion with its actual conditions, and say_first as a direct 1 to 3 sentence spoken answer covering every requested concept and result in the exact current question. Keep say_first consistent with scoped_claim. These are public answer fields, not private reasoning.\n" + JSONParsing.jsonString(scopedResponseSchema)

    static func parse(_ raw: String, responseSchema: LocalJSONValue? = nil) -> LocalQwenParsedAnswer {
        if responseSchema == scopedResponseSchema {
            // Exactly two string fields also rejects duplicate keys, including escaped aliases.
            let string = #""(?:[^"\\\x00-\x1F]|\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4}))*""#
            let field = "\(string)\\s*:\\s*\(string)"
            let grammar = "\\A\\s*\\{\\s*\(field)\\s*,\\s*\(field)\\s*\\}\\s*\\z"
            guard raw.range(of: grammar, options: .regularExpression) != nil,
                  let values = try? JSONDecoder().decode([String: String].self, from: Data(raw.utf8)),
                  Set(values.keys) == Set(scopedPropertyOrder),
                  let claim = values["scoped_claim"], let spoken = values["say_first"],
                  !claim.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return LocalQwenParsedAnswer(sayFirst: "", sectionParserResult: "invalid_scoped_json",
                    failureCategory: .answerSectionParserRejectedContent)
            }
            let answer = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !answer.isEmpty else {
                return LocalQwenParsedAnswer(sayFirst: "", sectionParserResult: "invalid_scoped_json",
                    failureCategory: .answerSectionParserRejectedContent)
            }
            return LocalQwenParsedAnswer(sayFirst: answer, sectionParserResult: "scoped_json_answer",
                failureCategory: nil, scopedClaim: claim.trimmingCharacters(in: .whitespacesAndNewlines))
        }
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
    static func validate(
        _ answer: String,
        question: DetectedQuestion,
        interviewContextSnapshot: InterviewContextSnapshot?
    ) -> LocalQwenAnswerValidationResult {
        guard !QuestionAnswerAlignmentEvaluator.containsGenericCoachingTemplate(answer),
              QuestionAnswerAlignmentEvaluator.incompleteAnswerReason(answer) == nil else {
            return .rejected(
                category: .alignmentRejectedNonemptyContent,
                diagnostic: "generic_or_incomplete"
            )
        }
        do {
            let grounding = AnswerClaimValidator().validate(
                answer: answer,
                candidateEvidence: interviewContextSnapshot?.candidateEvidence ?? [],
                opportunityEvidence: interviewContextSnapshot?.opportunityEvidence ?? [],
                domainKnowledge: InterviewDomainProfile.profile(
                    for: InterviewDomainID(rawValue: interviewContextSnapshot?.domainProfileID ?? "") ?? .general
                ).domainKnowledge
            )
            guard grounding.unsupportedClaims.isEmpty else {
                return .rejected(
                    category: .alignmentRejectedNonemptyContent,
                    diagnostic: "unsupported_personal_claim"
                )
            }
        }
        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: question.questionText,
            answerText: answer,
            sayFirst: answer,
            stageBCompleted: true,
            decision: question.taskDescriptor?.decision
        )
        guard alignment.verdict == .aligned else {
            return .rejected(
                category: .alignmentRejectedNonemptyContent,
                diagnostic: alignment.reason
            )
        }
        return .accepted(alignment.verdict.rawValue)
    }

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
