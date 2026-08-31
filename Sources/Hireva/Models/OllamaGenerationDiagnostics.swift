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
            throw OllamaQwenProviderError.categorized(.providerHTTPError)
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
            return try fail(.responseSchemaMismatch)
        }
        if content.isEmpty {
            if diagnostics.reasoningCharacters > 0 {
                return try fail(.reasoningReceivedWithoutFinalAnswer)
            }
            if diagnostics.malformedEvents > 0 && diagnostics.malformedEvents == diagnostics.chunksReceived {
                return try fail(.malformedStreamEvent)
            }
            return try fail(.providerReturnedNoContent)
        }
        if requireDone && !diagnostics.streamCompleted {
            return try fail(.streamParserDroppedContent)
        }
        diagnostics.rawContentCharacters = content.count
        diagnostics.parsedContentCharacters = content.count
        diagnostics.finalErrorCategory = nil
        return OllamaParsedResponse(content: content, diagnostics: diagnostics)
    }

    private mutating func fail(_ category: OllamaFailureCategory) throws -> OllamaParsedResponse {
        diagnostics.finalErrorCategory = category
        throw OllamaQwenProviderError.categorized(category)
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

enum LocalQwenGroundedFailureParser {
    static func parse(
        _ raw: String,
        candidateEvidence: [String]
    ) -> LocalQwenParsedAnswer {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["failure", "evidence"]),
              let requestedFailure = object["failure"] as? String,
              let requestedEvidence = object["evidence"] as? String else {
            return rejected()
        }

        let failure = requestedFailure.trimmingCharacters(in: .whitespacesAndNewlines)
        let evidence = requestedEvidence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !failure.isEmpty,
              !evidence.isEmpty,
              failure.count <= 160,
              evidence.count <= 800,
              failure.rangeOfCharacter(from: CharacterSet(charactersIn: ".?!;:\n")) == nil,
              let matchedEvidence = exactSupportedStatement(evidence, in: candidateEvidence),
              let matchedFailure = exactSupportedSubstring(failure, in: [matchedEvidence]),
              preservesFailurePolarity(failure: matchedFailure, evidence: matchedEvidence) else {
            return rejected()
        }

        let evidenceSentence = firstPersonSentence(from: matchedEvidence)
        guard !evidenceSentence.isEmpty else { return rejected() }
        let answer = "I can support \(matchedFailure) as the closest documented failure. \(evidenceSentence)"
        return LocalQwenParsedAnswer(
            sayFirst: answer,
            sectionParserResult: "grounded_failure_json",
            failureCategory: nil
        )
    }

    private static func exactSupportedSubstring(
        _ requested: String,
        in evidence: [String]
    ) -> String? {
        let requestedCore = requested.trimmingCharacters(
            in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".?!"))
        )
        guard requestedCore.count >= 3 else { return nil }
        for statement in evidence {
            if let range = statement.range(
                of: requestedCore,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) {
                return String(statement[range])
            }
        }
        return nil
    }

    private static func exactSupportedStatement(
        _ requested: String,
        in evidence: [String]
    ) -> String? {
        let requestedCore = statementCore(requested)
        guard requestedCore.count >= 3 else { return nil }
        for statement in evidence {
            let supportedCore = statementCore(statement)
            guard !supportedCore.isEmpty else { continue }
            if supportedCore.compare(
                requestedCore,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame {
                return supportedCore
            }
        }
        return nil
    }

    private static func statementCore(_ statement: String) -> String {
        statement.trimmingCharacters(
            in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".?!"))
        )
    }

    private static func preservesFailurePolarity(failure: String, evidence: String) -> Bool {
        polarityMarkers(in: evidence).isSubset(of: polarityMarkers(in: failure))
    }

    private static func polarityMarkers(in text: String) -> Set<String> {
        let standaloneMarkers: Set<String> = [
            "not", "never", "no", "without", "cannot", "failed", "unable", "lacked", "missing"
        ]
        var markers = Set(TextChunker.tokenize(text)).intersection(standaloneMarkers)
        let normalized = text.lowercased().replacingOccurrences(of: "’", with: "'")
        for contraction in ["can't", "didn't", "doesn't", "wasn't", "weren't"]
            where normalized.contains(contraction) {
            markers.insert(contraction)
        }
        return markers
    }

    private static func firstPersonSentence(from evidence: String) -> String {
        let core = evidence.trimmingCharacters(
            in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".?!"))
        )
        guard !core.isEmpty else { return "" }
        let lower = core.lowercased()
        let sentence: String
        if lower.hasPrefix("i ") || lower.hasPrefix("i'") || lower.hasPrefix("i’") ||
            lower.hasPrefix("my ") || lower.hasPrefix("we ") || lower.hasPrefix("our ") {
            sentence = core
        } else if let first = core.first,
                  let action = TextChunker.tokenize(core).first,
                  subjectSafeActionPrefixes.contains(action) {
            sentence = "I " + String(first).lowercased() + core.dropFirst()
        } else {
            return ""
        }
        return sentence + "."
    }

    private static let subjectSafeActionPrefixes: Set<String> = [
        "addressed", "analysed", "analyzed", "built", "completed", "compared", "contributed",
        "coordinated", "created", "debugged", "delivered", "demonstrated", "designed", "detected",
        "developed", "diagnosed", "encountered", "established", "evaluated", "experienced", "fixed",
        "handled", "identified", "implemented", "improved", "integrated", "investigated", "isolated",
        "launched", "led", "maintained", "measured", "migrated", "mitigated", "observed", "operated",
        "owned", "published", "recovered", "reduced", "resolved", "studied", "tested", "traced",
        "trained", "used", "validated", "worked"
    ]

    private static func rejected() -> LocalQwenParsedAnswer {
        LocalQwenParsedAnswer(
            sayFirst: "",
            sectionParserResult: "grounded_failure_json_rejected",
            failureCategory: .answerSectionParserRejectedContent
        )
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
