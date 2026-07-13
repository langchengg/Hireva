import Foundation

/// Final pure guard for runtime questions before generation or persistence.
///
/// The product pipeline can detect questions from local ASR segmentation,
/// provider-backed detection, manual retry, and tests. This guard keeps the
/// accepted question contract centralized without owning AppState, provider
/// calls, generation tasks, UI mutation, or DB writes.
enum QuestionRuntimeAcceptanceGuard {
    static func acceptedCandidate(
        from text: String,
        isFinal: Bool = true
    ) -> QuestionRuntimeAcceptanceResult {
        let collapsed = QuestionTextUtilities.collapse(text)
        guard !collapsed.isEmpty else {
            return .rejected(.emptyQuestion, diagnostic: "Question text is empty.")
        }

        let canonical = QuestionCanonicalizer.canonicalize(collapsed)
        if isVagueFollowUp(canonical) {
            return .rejected(.vagueFollowup, diagnostic: "Rejected vague follow-up without an explicit resolver: \(canonical)")
        }
        if isKnownIncompleteOrGenericPattern(canonical) {
            return .rejected(.genericKnownPattern, diagnostic: "Rejected incomplete/generic runtime pattern: \(canonical)")
        }
        if QuestionCompletenessGate.isIncompleteFragment(canonical) {
            return .rejected(.incompleteFragment, diagnostic: "Rejected incomplete question fragment: \(canonical)")
        }

        let candidates = QuestionCandidatePipeline.extract(from: canonical, isFinal: isFinal)
        guard !candidates.isEmpty else {
            return .rejected(.pipelineRejected, diagnostic: "QuestionCandidatePipeline did not accept: \(canonical)")
        }
        guard candidates.count == 1, let candidate = candidates.first else {
            return .rejected(.multipleQuestionsNeedSegmentation, diagnostic: "Question contains \(candidates.count) accepted questions and must be segmented first.")
        }
        if isVagueFollowUp(candidate.text) || isKnownIncompleteOrGenericPattern(candidate.text) {
            return .rejected(.genericKnownPattern, diagnostic: "Rejected accepted candidate with unsafe generic wording: \(candidate.text)")
        }

        return .accepted(candidate, diagnostic: "Accepted by QuestionCandidatePipeline: \(candidate.text)")
    }

    static func detectedQuestionForGeneration(
        _ question: DetectedQuestion,
        isFinal: Bool = true
    ) -> (question: DetectedQuestion, result: QuestionRuntimeAcceptanceResult)? {
        let result = acceptedCandidate(from: question.questionText, isFinal: isFinal)
        guard let candidate = result.candidate else { return nil }
        var accepted = question
        accepted.questionText = candidate.text
        accepted.intent = candidate.intent
        accepted.answerStrategy = candidate.answerStrategy
        accepted.confidence = max(question.confidence, candidate.confidence)
        accepted.shouldTrigger = true
        accepted.questionComplete = true
        accepted.reason = appendGuardDiagnostic(question.reason, result.diagnostic)
        return (accepted, result)
    }

    static func validateDetectedQuestionForGeneration(
        _ question: DetectedQuestion,
        isFinal: Bool = true
    ) -> QuestionRuntimeAcceptanceResult {
        acceptedCandidate(from: question.questionText, isFinal: isFinal)
    }

    static func validateSuggestionCardForPersistence(
        _ card: SuggestionCard,
        alignmentOverride: AnswerAlignmentResult? = nil
    ) -> QuestionPersistenceGuardResult {
        if card.isPartial {
            return .rejected(.partialCard, diagnostic: "Rejected partial suggestion card.")
        }

        let questionText = QuestionTextUtilities.collapse(
            card.questionText ?? card.promptPrimaryQuestion ?? card.promptQuestionText ?? ""
        )
        let promptQuestion = QuestionTextUtilities.collapse(
            card.promptPrimaryQuestion ?? card.promptQuestionText ?? questionText
        )

        let questionResult = acceptedCandidate(from: questionText, isFinal: true)
        guard let candidate = questionResult.candidate else {
            return .rejected(questionResult.reason ?? .pipelineRejected, diagnostic: "Rejected suggestion card question: \(questionResult.diagnostic)")
        }

        let promptResult = acceptedCandidate(from: promptQuestion, isFinal: true)
        guard let promptCandidate = promptResult.candidate else {
            return .rejected(promptResult.reason ?? .pipelineRejected, diagnostic: "Rejected suggestion card prompt question: \(promptResult.diagnostic)")
        }

        if normalizedComparisonKey(candidate.text) != normalizedComparisonKey(promptCandidate.text) {
            return .rejected(
                .promptQuestionMismatch,
                diagnostic: "Question text and prompt primary question do not match. question=\(candidate.text) prompt=\(promptCandidate.text)"
            )
        }

        let answerText = visibleAnswerText(for: card)
        guard !answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .rejected(.emptyAnswer, diagnostic: "Rejected suggestion card with empty visible answer.")
        }

        if let incompleteReason = QuestionAnswerAlignmentEvaluator.incompleteAnswerReason(card.sayFirst) {
            return .rejected(
                .incompleteAnswer,
                diagnostic: "Rejected incomplete visible say_first: \(incompleteReason)."
            )
        }

        if candidate.answerRelevanceIntent == .interviewerQuestions,
           QuestionAnswerAlignmentEvaluator.usefulInterviewerQuestionCount(in: card.sayFirst) < 2 {
            return .rejected(
                .interviewerQuestionsIncomplete,
                diagnostic: "Rejected interviewer-questions answer without at least two concrete questions."
            )
        }

        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: candidate.text,
            answerText: answerText,
            sayFirst: card.sayFirst,
            stageBCompleted: card.stageBCompleted ?? true
        )
        let effectiveAlignment = alignmentOverride ?? alignment
        guard effectiveAlignment.verdict == .aligned else {
            return .rejected(
                rejectionReason(for: alignment.verdict),
                diagnostic: "Rejected persistence for \(alignment.verdict.rawValue) answer. \(alignment.reason)"
            )
        }

        return .accepted(
            candidate,
            alignment: effectiveAlignment,
            diagnostic: "Suggestion card accepted for persistence: \(candidate.text)"
        )
    }

    static func sanitizedSuggestionCardForPersistence(
        _ card: SuggestionCard,
        result: QuestionPersistenceGuardResult
    ) -> SuggestionCard {
        guard let candidate = result.candidate else { return card }
        var sanitized = card
        sanitized.questionText = candidate.text
        sanitized.promptQuestionText = candidate.text
        sanitized.promptPrimaryQuestion = candidate.text
        sanitized.questionIntent = candidate.answerRelevanceIntent
        sanitized.promptTokenEstimate = sanitized.promptTokenEstimate ?? AnswerRelevancePolicy.estimateTokens(candidate.text)
        if let alignment = result.alignment {
            sanitized.alignmentScore = alignment.score
            sanitized.alignmentVerdict = alignment.verdict
            sanitized.answerIntent = alignment.answerIntent
            sanitized.mismatchReason = alignment.verdict == .mismatched ? alignment.reason : nil
        }
        return sanitized
    }

    static func isVagueFollowUp(_ text: String) -> Bool {
        let lower = normalizedComparisonKey(text)
        let exact = [
            "what did you learn from it",
            "what did you learn from that",
            "what did you learn from this",
            "how did you solve it",
            "how did you solve that",
            "how did you solve this",
            "why did you choose that",
            "why did you choose this",
            "what was the result of that",
            "what did that teach you"
        ]
        if exact.contains(lower) { return true }

        let vaguePronouns = [" it", " that", " this", " them", " those"]
        let vagueStems = [
            "what did you learn from",
            "how did you solve",
            "how did you handle",
            "why did you choose",
            "what was difficult about",
            "what was hard about"
        ]
        return vagueStems.contains { stem in
            lower.hasPrefix(stem) && vaguePronouns.contains { lower.hasSuffix($0) }
        } || unresolvedSameIssueFollowUp(lower)
    }

    static func isKnownIncompleteOrGenericPattern(_ text: String) -> Bool {
        let lower = normalizedComparisonKey(text)
        let exactOrPrefixFragments = [
            "what did you learn from comp",
            "what did you learn from comparing",
            "tell me about a time you had",
            "what questions would you ask us about the",
            "what was the biggest technical trade off",
            "what was the biggest technical tradeoff",
            "can you explain the difference",
            "how did you adapt",
            "how would you diagnose"
        ]

        for fragment in exactOrPrefixFragments {
            if lower == fragment { return true }
        }

        if lower.hasPrefix("what did you learn from comp") && lower.split(separator: " ").count < 8 {
            return true
        }
        if lower.hasPrefix("what did you learn from comparing") && lower.split(separator: " ").count < 9 {
            return true
        }
        if lower.hasPrefix("tell me about a time you had") &&
            !lower.contains("debug") && !lower.contains("system integration") {
            return true
        }
        if lower.hasPrefix("what questions would you ask us about the") &&
            !(lower.contains("team") || lower.contains("role") || lower.contains("offer")) {
            return true
        }

        return false
    }

    static func normalizedComparisonKey(_ text: String) -> String {
        ASRCanonicalizer.canonicalizeTerms(text)
            .lowercased()
            .replacingOccurrences(of: "c++", with: "c plus plus")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func appendGuardDiagnostic(_ existing: String?, _ diagnostic: String) -> String {
        guard let existing, !existing.isEmpty else { return diagnostic }
        return "\(existing) \(diagnostic)"
    }

    private static func unresolvedSameIssueFollowUp(_ normalizedLower: String) -> Bool {
        guard normalizedLower.hasPrefix("if the same issue") ||
              normalizedLower.hasPrefix("if that issue") ||
              normalizedLower.hasPrefix("if this issue") else {
            return false
        }
        let tokens = normalizedLower.split(separator: " ").map(String.init)
        let generic: Set<String> = ["if", "the", "same", "that", "this", "issue", "happened", "again", "how", "would", "you", "handle", "it"]
        return tokens.filter { !generic.contains($0) }.count < 2
    }

    private static func visibleAnswerText(for card: SuggestionCard) -> String {
        ([card.sayFirst] + card.keyPoints + card.followUpReady)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " ")
    }

    private static func rejectionReason(for verdict: AnswerAlignmentVerdict) -> QuestionRuntimeRejectionReason {
        switch verdict {
        case .aligned:
            return .pipelineRejected
        case .weaklyAligned:
            return .weakAlignment
        case .mismatched:
            return .mismatchedAlignment
        case .unknown:
            return .unknownAlignment
        }
    }
}

enum QuestionRuntimeRejectionReason: String, Equatable {
    case emptyQuestion = "rejected_empty_question"
    case incompleteFragment = "rejected_incomplete_fragment"
    case vagueFollowup = "rejected_vague_followup"
    case genericKnownPattern = "rejected_generic_known_pattern"
    case pipelineRejected = "rejected_by_question_candidate_pipeline"
    case multipleQuestionsNeedSegmentation = "rejected_multiple_questions_need_segmentation"
    case promptQuestionMismatch = "rejected_prompt_question_mismatch"
    case emptyAnswer = "rejected_empty_answer"
    case incompleteAnswer = "rejected_incomplete_answer"
    case partialCard = "rejected_partial_card"
    case weakAlignment = "rejected_weak_alignment"
    case unknownAlignment = "rejected_unknown_alignment"
    case mismatchedAlignment = "rejected_mismatched_alignment"
    case interviewerQuestionsIncomplete = "rejected_incomplete_interviewer_questions_answer"
    case unrelatedTechnicalTradeoff = "rejected_unrelated_technical_tradeoff_answer"
    case duplicateSuppressed = "duplicate_suppressed"
}

struct QuestionRuntimeAcceptanceResult: Equatable {
    var candidate: AcceptedQuestionCandidate?
    var reason: QuestionRuntimeRejectionReason?
    var diagnostic: String

    var accepted: Bool { candidate != nil && reason == nil }

    static func accepted(
        _ candidate: AcceptedQuestionCandidate,
        diagnostic: String
    ) -> QuestionRuntimeAcceptanceResult {
        QuestionRuntimeAcceptanceResult(candidate: candidate, reason: nil, diagnostic: diagnostic)
    }

    static func rejected(
        _ reason: QuestionRuntimeRejectionReason,
        diagnostic: String
    ) -> QuestionRuntimeAcceptanceResult {
        QuestionRuntimeAcceptanceResult(candidate: nil, reason: reason, diagnostic: diagnostic)
    }
}

struct QuestionPersistenceGuardResult: Equatable {
    var candidate: AcceptedQuestionCandidate?
    var alignment: AnswerAlignmentResult?
    var reason: QuestionRuntimeRejectionReason?
    var diagnostic: String

    var accepted: Bool { candidate != nil && reason == nil }

    static func accepted(
        _ candidate: AcceptedQuestionCandidate,
        alignment: AnswerAlignmentResult,
        diagnostic: String
    ) -> QuestionPersistenceGuardResult {
        QuestionPersistenceGuardResult(candidate: candidate, alignment: alignment, reason: nil, diagnostic: diagnostic)
    }

    static func rejected(
        _ reason: QuestionRuntimeRejectionReason,
        diagnostic: String
    ) -> QuestionPersistenceGuardResult {
        QuestionPersistenceGuardResult(candidate: nil, alignment: nil, reason: reason, diagnostic: diagnostic)
    }
}

struct RuntimeQuestionRejectedError: LocalizedError, Equatable {
    var reason: QuestionRuntimeRejectionReason
    var diagnostic: String

    var errorDescription: String? {
        "Question was not accepted for generation: \(reason.rawValue). \(diagnostic)"
    }
}

extension DetectedQuestion {
    func runtimeAcceptedForGeneration() -> (question: DetectedQuestion, result: QuestionRuntimeAcceptanceResult)? {
        QuestionRuntimeAcceptanceGuard.detectedQuestionForGeneration(self)
    }
}
