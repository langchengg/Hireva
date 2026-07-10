import Foundation

struct LocalQuestionHeuristicResult {
    let shouldTrigger: Bool
    let confidence: Double
    let reason: String
}

final class QuestionDetectionService {
    private let llmRouter: LLMRouter

    init(llmRouter: LLMRouter) {
        self.llmRouter = llmRouter
    }

    func isLikelyQuestion(_ text: String) -> LocalQuestionHeuristicResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty {
            return LocalQuestionHeuristicResult(shouldTrigger: false, confidence: 0.0, reason: "Empty text")
        }
        
        if trimmed.contains("?") {
            return LocalQuestionHeuristicResult(shouldTrigger: true, confidence: 0.95, reason: "Contains question mark")
        }
        
        // Professional interview prompts
        let prompts = [
            "walk me through",
            "tell me about",
            "give me an example",
            "talk about",
            "describe",
            "explain",
            "imagine",
            "elaborate",
            "let's discuss",
            "let’s discuss",
            "i'd like to hear about",
            "i’d like to hear about"
        ]
        
        for prompt in prompts {
            if trimmed.hasPrefix(prompt) || trimmed.contains(" " + prompt) {
                return LocalQuestionHeuristicResult(shouldTrigger: true, confidence: 0.9, reason: "Matches interview prompt: '\(prompt)'")
            }
        }
        
        // Typical question starter words
        let starters = [
            "what", "how", "why", "where", "who", "when", 
            "can you", "could you", "would you", "should you",
            "are you", "do you", "have you", "is there"
        ]
        
        for starter in starters {
            if trimmed.hasPrefix(starter) || trimmed.contains(" " + starter) {
                return LocalQuestionHeuristicResult(shouldTrigger: true, confidence: 0.85, reason: "Matches question starter: '\(starter)'")
            }
        }
        
        return LocalQuestionHeuristicResult(shouldTrigger: false, confidence: 0.0, reason: "No question markers found")
    }

    func detect(
        transcriptContext: String,
        sessionID: String,
        transcriptSegmentID: String?,
        model: String? = nil
    ) async throws -> (question: DetectedQuestion, response: LLMChatResult) {
        let heuristic = isLikelyQuestion(transcriptContext)
        if !heuristic.shouldTrigger {
            let question = DetectedQuestion(
                id: UUID().uuidString,
                sessionID: sessionID,
                transcriptSegmentID: transcriptSegmentID,
                questionText: "",
                intent: .unclear,
                answerStrategy: .directAnswer,
                confidence: 0.0,
                reason: "Bypassed by local question heuristics: \(heuristic.reason)",
                shouldTrigger: false,
                questionComplete: false,
                modelName: "local-heuristic",
                promptVersion: "local-v1",
                providerKind: .openAICompatible,
                providerName: "Internal Heuristic",
                providerBaseURL: "",
                latencyMS: 0,
                isLocal: false,
                rawJSON: nil,
                createdAt: Date()
            )
            return (question, LLMChatResult(
                content: "{}",
                modelName: "local-heuristic",
                providerKind: .openAICompatible,
                providerName: "Internal Heuristic",
                baseURL: "",
                latencyMS: 0,
                isLocal: false,
                rawResponse: nil
            ))
        }

        let prompt = PromptLibrary.questionDetector
        let userPrompt = """
        Recent transcript:
        \(ContextBudgeter.limitWords(transcriptContext, maxWords: 800))

        Decide whether the interviewer has asked a complete question or prompt that the candidate should answer now.
        """

        do {
            let response = try await llmRouter.chatForRealtime(
                messages: [.system(prompt.text), .user(userPrompt)],
                responseFormat: .jsonObject,
                options: LLMRequestOptions(temperature: 0.0)
            )
            let providerPayload = try JSONParsing.decodeObject(QuestionDetectionPayload.self, from: response.content)
            let payload = normalizeProviderDetection(
                providerPayload,
                transcriptContext: transcriptContext,
                heuristic: heuristic
            )
            let question = DetectedQuestion(
                id: UUID().uuidString,
                sessionID: sessionID,
                transcriptSegmentID: transcriptSegmentID,
                questionText: payload.questionText,
                intent: payload.intent,
                answerStrategy: payload.answerStrategy,
                confidence: max(0, min(1, payload.confidence)),
                reason: payload.reason,
                shouldTrigger: payload.shouldTrigger,
                questionComplete: payload.questionComplete,
                modelName: response.modelName,
                promptVersion: prompt.versionTag,
                providerKind: response.providerKind,
                providerName: response.providerName,
                providerBaseURL: response.baseURL,
                latencyMS: response.latencyMS,
                isLocal: response.isLocal,
                rawJSON: response.content,
                createdAt: Date()
            )
            return (question, response)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return localFallbackDetection(
                transcriptContext: transcriptContext,
                sessionID: sessionID,
                transcriptSegmentID: transcriptSegmentID,
                heuristic: heuristic,
                error: error
            )
        }
    }

    private func normalizeProviderDetection(
        _ payload: QuestionDetectionPayload,
        transcriptContext: String,
        heuristic: LocalQuestionHeuristicResult
    ) -> QuestionDetectionPayload {
        let providerQuestionText = SystemAudioQuestionExtractor.canonicalizeQuestionText(
            payload.questionText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let providerGuard = QuestionRuntimeAcceptanceGuard.acceptedCandidate(from: providerQuestionText)
        if payload.shouldTrigger,
           !providerQuestionText.isEmpty,
           let rejectedReason = providerGuard.reason {
            var rejected = payload
            rejected.shouldTrigger = false
            rejected.questionComplete = false
            rejected.questionText = providerQuestionText
            rejected.answerStrategy = .wait
            rejected.confidence = min(payload.confidence, 0.5)
            rejected.reason = "\(payload.reason) Runtime question guard rejected this before generation: \(rejectedReason.rawValue). \(providerGuard.diagnostic)"
            return rejected
        }

        let candidate = fallbackQuestionCandidate(from: transcriptContext)
        let fallbackGuard = QuestionRuntimeAcceptanceGuard.acceptedCandidate(from: candidate.text)
        guard heuristic.shouldTrigger,
              heuristic.confidence >= 0.8,
              candidate.isComplete,
              isStrongCompleteQuestion(candidate.text),
              fallbackGuard.candidate != nil else {
            var canonicalPayload = payload
            canonicalPayload.questionText = providerGuard.candidate?.text ?? providerQuestionText
            return canonicalPayload
        }

        let providerSuppressedAnswer = !payload.shouldTrigger
            || !payload.questionComplete
            || payload.answerStrategy == .wait
            || payload.confidence < 0.75
        guard providerSuppressedAnswer else {
            return payload
        }

        let classified = classifyFallbackQuestion(candidate.text)
        var normalized = payload
        normalized.shouldTrigger = true
        normalized.questionComplete = true
        normalized.questionText = providerGuard.candidate?.text ?? fallbackGuard.candidate?.text ?? (providerQuestionText.isEmpty ? candidate.text : providerQuestionText)
        if normalized.intent == .unclear {
            normalized.intent = classified.intent
        }
        if normalized.answerStrategy == .wait || normalized.answerStrategy == .clarifyFirst {
            normalized.answerStrategy = classified.strategy
        }
        normalized.confidence = max(payload.confidence, min(0.9, heuristic.confidence))
        normalized.reason = "\(payload.reason) Local guardrail treated this as a complete interviewer prompt: \(heuristic.reason)."
        return normalized
    }

    private func isStrongCompleteQuestion(_ text: String) -> Bool {
        let lower = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard lower.split(whereSeparator: \.isWhitespace).count >= 4 else {
            return false
        }
        if SystemAudioQuestionExtractor.isIncompleteQuestionFragment(lower) {
            return false
        }

        let incompleteEndings = [
            " can you", " could you", " would you", " do you", " are you",
            " and", " or", " but", " so", " because", " with", " to", " for", " about", " from"
        ]
        if incompleteEndings.contains(where: { lower.hasSuffix($0) }) {
            return false
        }

        let strongPrefixes = [
            "what ", "how ", "why ", "where ", "who ", "when ",
            "can you ", "could you ", "would you ", "should you ",
            "are you ", "do you ", "have you ", "is there ",
            "walk me through ", "tell me about ", "give me an example ",
            "talk about ", "describe ", "explain ", "elaborate ", "imagine "
        ]
        return strongPrefixes.contains { lower.hasPrefix($0) }
    }

    private func localFallbackDetection(
        transcriptContext: String,
        sessionID: String,
        transcriptSegmentID: String?,
        heuristic: LocalQuestionHeuristicResult,
        error: Error
    ) -> (question: DetectedQuestion, response: LLMChatResult) {
        let candidate = fallbackQuestionCandidate(from: transcriptContext)
        let classified = classifyFallbackQuestion(candidate.text)
        let guardResult = QuestionRuntimeAcceptanceGuard.acceptedCandidate(from: candidate.text)
        let acceptedCandidate = guardResult.candidate
        let shouldTrigger = candidate.isComplete && acceptedCandidate != nil
        let questionText = acceptedCandidate?.text ?? candidate.text
        let confidence = shouldTrigger ? heuristic.confidence : min(heuristic.confidence, 0.5)
        let reason = "Local fallback used after question detector failed: \(error.localizedDescription). \(heuristic.reason)"
        let rawJSON = """
        {"should_trigger":\(shouldTrigger),"question_complete":\(shouldTrigger),"question_text":\(jsonString(questionText)),"intent":"\(classified.intent.rawValue)","answer_strategy":"\(shouldTrigger ? classified.strategy.rawValue : AnswerStrategy.wait.rawValue)","confidence":\(confidence),"reason":\(jsonString(shouldTrigger ? reason : "\(reason) Runtime question guard rejected fallback question: \(guardResult.reason?.rawValue ?? "unknown"). \(guardResult.diagnostic)"))}
        """
        let question = DetectedQuestion(
            id: UUID().uuidString,
            sessionID: sessionID,
            transcriptSegmentID: transcriptSegmentID,
            questionText: questionText,
            intent: classified.intent,
            answerStrategy: shouldTrigger ? classified.strategy : .wait,
            confidence: confidence,
            reason: shouldTrigger ? reason : "\(reason) Runtime question guard rejected fallback question: \(guardResult.reason?.rawValue ?? "unknown"). \(guardResult.diagnostic)",
            shouldTrigger: shouldTrigger,
            questionComplete: shouldTrigger,
            modelName: "local-question-fallback",
            promptVersion: "local-fallback-v1",
            providerKind: .openAICompatible,
            providerName: "Local Question Fallback",
            providerBaseURL: "",
            latencyMS: 0,
            isLocal: true,
            rawJSON: rawJSON,
            createdAt: Date()
        )
        let response = LLMChatResult(
            content: rawJSON,
            modelName: "local-question-fallback",
            providerKind: .openAICompatible,
            providerName: "Local Question Fallback",
            baseURL: "",
            latencyMS: 0,
            isLocal: true,
            rawResponse: rawJSON
        )
        return (question, response)
    }

    private func fallbackQuestionCandidate(from transcriptContext: String) -> (text: String, isComplete: Bool) {
        let lines = transcriptContext
            .components(separatedBy: .newlines)
            .map(cleanSpeakerPrefix)
            .filter { !$0.isEmpty }

        let rawCandidate = lines.reversed().first { isLikelyQuestion($0).shouldTrigger }
            ?? cleanSpeakerPrefix(transcriptContext)
        return sanitizeFallbackQuestion(rawCandidate)
    }

    private func cleanSpeakerPrefix(_ text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let lower = collapsed.lowercased()
        for prefix in ["interviewer:", "candidate:", "unknown:"] {
            if lower.hasPrefix(prefix) {
                return String(collapsed.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return collapsed
    }

    private func sanitizeFallbackQuestion(_ text: String) -> (text: String, isComplete: Bool) {
        var cleaned = SystemAudioQuestionExtractor.canonicalizeQuestionText(cleanSpeakerPrefix(text))
        while cleaned.hasSuffix(".") || cleaned.hasSuffix(",") || cleaned.hasSuffix(";") || cleaned.hasSuffix(":") {
            cleaned.removeLast()
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let lower = cleaned.lowercased()
        let trailingFragments = [
            " can you", " could you", " would you", " do you", " are you",
            " and", " or", " but", " so", " because", " with", " to", " for"
        ]
        var removedIncompleteTail = false
        for fragment in trailingFragments where lower.hasSuffix(fragment) {
            cleaned.removeLast(fragment.count)
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            removedIncompleteTail = true
            break
        }

        let wordCount = cleaned.split(whereSeparator: \.isWhitespace).count
        let isComplete = wordCount >= 4 &&
            (!cleaned.isEmpty || !removedIncompleteTail) &&
            !SystemAudioQuestionExtractor.isIncompleteQuestionFragment(cleaned) &&
            isStrongCompleteQuestion(cleaned)
        return (cleaned.isEmpty ? cleanSpeakerPrefix(text) : cleaned, isComplete)
    }

    private func classifyFallbackQuestion(_ text: String) -> (intent: QuestionIntent, strategy: AnswerStrategy) {
        let lower = SystemAudioQuestionExtractor.canonicalizeQuestionText(text).lowercased()
        if lower.contains("leorover") || lower.contains("project") || lower.contains("built") || lower.contains("worked on") {
            return (.projectDeepDive, .projectWalkthrough)
        }
        if lower.contains("technical") || lower.contains("architecture") || lower.contains("algorithm") || lower.contains("system design") {
            return (.technical, .technicalExplanation)
        }
        if lower.contains("why") || lower.contains("role") || lower.contains("company") || lower.contains("join") {
            return (.companyFit, .directAnswer)
        }
        if lower.contains("example") || lower.contains("challenge") || lower.contains("conflict") || lower.contains("tell me about") {
            return (.behavioral, .starStory)
        }
        return (.unclear, .directAnswer)
    }

    private func jsonString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let encoded = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return encoded
    }
}
