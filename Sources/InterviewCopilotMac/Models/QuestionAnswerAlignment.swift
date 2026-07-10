import Foundation

enum QABindingStatus: String, CaseIterable, Codable, Hashable {
    case matched
    case mismatched
    case missingSuggestion
    case missingQuestion
    case staleDiscarded
}

struct QABindingSnapshot: Equatable {
    var currentQuestionID: String?
    var currentQuestionText: String
    var currentSuggestionID: String?
    var currentSuggestionDetectedQuestionID: String?
    var currentSuggestionQuestionText: String
    var activeGenerationID: String?
    var activeGenerationQuestionID: String?
    var bindingStatus: QABindingStatus
    var lastAlignmentError: String

    static let empty = QABindingSnapshot(
        currentQuestionID: nil,
        currentQuestionText: "",
        currentSuggestionID: nil,
        currentSuggestionDetectedQuestionID: nil,
        currentSuggestionQuestionText: "",
        activeGenerationID: nil,
        activeGenerationQuestionID: nil,
        bindingStatus: .missingSuggestion,
        lastAlignmentError: ""
    )
}

enum AnswerAlignmentVerdict: String, CaseIterable, Codable, Hashable {
    case aligned
    case weaklyAligned
    case mismatched
    case unknown
}

struct AnswerAlignmentResult: Equatable {
    var score: Double
    var verdict: AnswerAlignmentVerdict
    var questionIntent: AnswerRelevanceIntent
    var answerIntent: AnswerRelevanceIntent
    var matchedThemes: [String]
    var missingThemes: [String]
    var wrongAnswerIndicators: [String]
    var reason: String
}

struct SuggestionAlignmentRecord: Identifiable, Equatable {
    var id: String
    var detectedQuestionID: String?
    var questionText: String
    var sayFirstPreview: String
    var alignmentScore: Double
    var alignmentVerdict: AnswerAlignmentVerdict
    var answerIntent: AnswerRelevanceIntent
    var expectedThemesMatched: [String]
    var suspectedMismatchReason: String
}

/// Domain-neutral relevance guard. Candidate factuality is handled separately
/// by `AnswerClaimValidator`; this evaluator checks question ownership,
/// speakability, dynamic topic overlap, and intent-appropriate answer shape.
enum QuestionAnswerAlignmentEvaluator {
    static func containsGenericCoachingTemplate(_ text: String) -> Bool {
        !genericCoachingIndicators(in: normalize(text)).isEmpty
    }

    static func isAnswerComplete(_ answer: String) -> Bool {
        incompleteAnswerReason(answer) == nil
    }

    static func incompleteAnswerReason(_ answer: String) -> String? {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 20 else { return "too short" }
        let lower = trimmed.lowercased()
        let unfinishedWords = ["because", "including", "such as", "whether", "while", "and", "or", "to"]
        let tail = lower.trimmingCharacters(in: CharacterSet(charactersIn: ".?!,;: "))
        if unfinishedWords.contains(where: { tail.hasSuffix(" " + $0) }) {
            return "ends with an incomplete clause"
        }
        if let last = trimmed.last, ",:;".contains(last) {
            return "ends with incomplete punctuation"
        }
        guard let last = trimmed.last, ".?!".contains(last) else {
            return "missing terminal punctuation"
        }
        return nil
    }

    static func usefulInterviewerQuestionCount(in answer: String) -> Int {
        let questionMarks = answer.filter { $0 == "?" }.count
        if questionMarks > 0 { return questionMarks }
        let openers: Set<String> = ["what", "how", "which", "who", "when", "where"]
        return TextChunker.tokenize(answer).filter { openers.contains($0) }.count
    }

    static func evaluate(
        questionText: String,
        answerText: String,
        sayFirst: String? = nil,
        stageBCompleted: Bool = true
    ) -> AnswerAlignmentResult {
        let question = normalize(questionText)
        let answer = normalize(answerText)
        let visible = normalize(sayFirst ?? answerText)
        let questionIntent = IntentRouter.answerIntent(for: questionText)
        let answerIntent = inferredAnswerIntent(for: answerText, expected: questionIntent)
        var matched: [String] = []
        var missing: [String] = []
        var wrong = genericCoachingIndicators(in: answer)

        guard isCompleteQuestion(questionText) else {
            return result(
                score: 0,
                verdict: .mismatched,
                questionIntent: questionIntent,
                answerIntent: answerIntent,
                matched: [],
                missing: ["complete question"],
                wrong: wrong,
                reason: "Rejected incomplete question text."
            )
        }
        if let incomplete = incompleteAnswerReason(sayFirst ?? answerText), stageBCompleted {
            missing.append("complete spoken answer")
            return result(
                score: 0.1,
                verdict: .mismatched,
                questionIntent: questionIntent,
                answerIntent: answerIntent,
                matched: matched,
                missing: missing,
                wrong: wrong,
                reason: "Rejected incomplete answer: \(incomplete)."
            )
        }
        guard wrong.isEmpty else {
            return result(
                score: 0.1,
                verdict: .mismatched,
                questionIntent: questionIntent,
                answerIntent: answerIntent,
                matched: [],
                missing: ["direct spoken answer"],
                wrong: wrong,
                reason: "Rejected generic coaching template."
            )
        }

        let anchors = dynamicTopicTokens(questionText)
        let answerTokens = meaningfulTokens(answerText)
        let anchorMatches = Set(anchors.filter { anchor in
            answerTokens.contains { semanticTokenMatch(anchor, $0) }
        })
        let profileIndependentQuestion = [.candidateQuestions, .interviewerQuestions].contains(questionIntent)
        if !anchors.isEmpty, !profileIndependentQuestion {
            if anchorMatches.isEmpty { missing.append("question topic") }
            else { matched.append(contentsOf: anchorMatches.sorted().prefix(4)) }
        }

        evaluateShape(
            intent: questionIntent,
            question: question,
            answer: answer,
            visible: visible,
            matched: &matched,
            missing: &missing,
            wrong: &wrong
        )

        let requiredTopicOverlap = !profileIndependentQuestion && !anchors.isEmpty && anchorMatches.isEmpty
        let shapeFailed = !missing.isEmpty
        let score = max(0, min(1, 0.55 + Double(matched.count) * 0.1 - Double(missing.count) * 0.22 - Double(wrong.count) * 0.3))
        let verdict: AnswerAlignmentVerdict = (requiredTopicOverlap || shapeFailed || !wrong.isEmpty) ? .mismatched : .aligned
        let reason = verdict == .aligned
            ? "Answer matches the current question topic and expected response structure."
            : "Answer is missing: \(missing.joined(separator: ", "))." + (wrong.isEmpty ? "" : " Wrong-answer indicators: \(wrong.joined(separator: ", ")).")
        return result(
            score: score,
            verdict: verdict,
            questionIntent: questionIntent,
            answerIntent: answerIntent,
            matched: matched,
            missing: missing,
            wrong: wrong,
            reason: reason
        )
    }

    private static func evaluateShape(
        intent: AnswerRelevanceIntent,
        question: String,
        answer: String,
        visible: String,
        matched: inout [String],
        missing: inout [String],
        wrong: inout [String]
    ) {
        func require(_ name: String, _ terms: [String], in text: String? = nil) {
            if containsAny(text ?? answer, terms) { matched.append(name) }
            else { missing.append(name) }
        }

        switch intent {
        case .tellMeAboutYourself:
            require("candidate background", ["background", "experience", "studied", "worked", "built", "developed", "led"])
        case .projectWalkthrough:
            require("project action", ["built", "developed", "implemented", "designed", "led", "worked", "created", "project"])
            require("result or learning", ["result", "outcome", "learned", "improved", "reduced", "increased", "delivered", "validated"])
        case .technicalChallenge:
            require("challenge", ["challenge", "difficult", "hard", "failure", "problem", "issue", "constraint", "latency", "bottleneck", "variability", "variation", "uncertain", "uncertainty", "uncontrolled", "incident"])
            require("action", ["debug", "changed", "implemented", "tested", "isolated", "redesign", "mitigated", "resolved"])
        case .errorHandling, .perceptionDebugging:
            require("diagnosis", ["reproduce", "inspect", "logs", "trace", "isolate", "monitor", "measure", "debug"])
            require("mitigation or validation", ["validate", "test", "retry", "recover", "check", "guard", "fix"])
        case .modelComparison, .decoderComparison, .diffusionPolicy:
            require("comparison", ["compare", "compared", "versus", "than", "while", "whereas", "trade-off", "tradeoff"])
            let comparedTerms = dynamicTopicTokens(question).intersection(meaningfulTokens(answer))
            if comparedTerms.count < 2 { missing.append("compared alternatives from the question") }
            else { matched.append("compared alternatives") }
        case .technicalTradeoff:
            require("trade-off", ["trade-off", "tradeoff", "versus", "balanced", "cost", "latency", "complexity", "reliability", "accuracy"])
            require("decision", ["chose", "decided", "prioritized", "selected", "accepted", "rejected"])
        case .datasetAdaptation:
            require("transformation", ["mapped", "converted", "adapted", "migrated", "normalized", "transformed"])
            require("validation", ["validated", "checked", "tested", "verified"])
        case .simToRealDebugging:
            require("environment comparison", ["simulation", "simulator", "production", "real", "deployment", "environment"])
            require("isolated cause", ["isolate", "compare", "calibration", "timing", "latency", "distribution", "dynamics", "configuration"])
        case .projectComparison:
            require("explicit contrast", ["while", "whereas", "unlike", "difference", "compared", "both"])
        case .systemIntegrationDebugging:
            require("system boundary", ["system", "pipeline", "module", "component", "handoff", "integration", "interface", "method", "deployment", "environment", "real robot"])
            require("reliability action", ["logs", "trace", "timestamp", "validate", "check", "retry", "recover", "test", "isolate", "debug"])
        case .improvementPlan:
            require("specific priority", ["first", "priority", "improve", "change", "next"])
            require("concrete action", ["test", "measure", "add", "redesign", "evaluate", "validate", "instrument", "expand"])
        case .whyRole:
            require("motivation", ["interested", "motivated", "want", "drawn", "excited", "align"])
            require("target relevance", ["role", "team", "organisation", "organization", "research", "company", "responsibility"])
        case .skillComfort:
            require("experience scope", ["used", "worked", "built", "experience", "comfortable", "learning", "limited"])
        case .candidateQuestions:
            if usefulInterviewerQuestionCount(in: visible) < 1 { missing.append("at least one interviewer question") }
            else { matched.append("interviewer question") }
        case .interviewerQuestions:
            if usefulInterviewerQuestionCount(in: answer) < 3 { missing.append("at least three interviewer questions") }
            else { matched.append("interviewer question set") }
        case .generic:
            if answer.split(whereSeparator: \.isWhitespace).count < 6 { missing.append("substantive direct answer") }
            else { matched.append("substantive answer") }
        }

        if intent == .technicalTradeoff,
           containsAny(answer, ["marketing campaign", "social media calendar", "sales funnel"]),
           !containsAny(question, ["marketing", "sales", "campaign"]) {
            wrong.append("unrelated domain answer")
        }
    }

    private static func inferredAnswerIntent(for answer: String, expected: AnswerRelevanceIntent) -> AnswerRelevanceIntent {
        return expected
    }

    private static func isCompleteQuestion(_ text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count >= 4 else { return false }
        let lower = normalize(text)
        if [" how did ", " what did ", " why did ", " how would ", " what would ", " what did you learn "].contains(lower) {
            return false
        }
        if lower.contains(" a seem ") || lower.hasSuffix(" a seem ") {
            return false
        }
        let incompleteTails = [" how did ", " why did ", " what did ", " tell me about ", " walk me through "]
        return !incompleteTails.contains { lower == $0 }
    }

    private static func dynamicTopicTokens(_ text: String) -> Set<String> {
        let generic: Set<String> = [
            "a", "an", "the", "what", "when", "where", "which", "who", "why", "how", "tell", "about", "your", "you", "would", "could",
            "please", "walk", "through", "describe", "explain", "project", "experience", "worked", "work", "most", "difficult",
            "challenge", "technical", "technically", "faced", "role", "question", "questions", "team", "did", "does", "have", "with", "from", "that", "this", "into",
            "before", "after", "first", "one", "more", "make", "made", "using", "used"
        ]
        return meaningfulTokens(text).subtracting(generic)
    }

    private static func meaningfulTokens(_ text: String) -> Set<String> {
        Set(TextChunker.tokenize(text).filter { $0.count > 2 && Int($0) == nil })
    }

    private static func semanticTokenMatch(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        guard lhs.count >= 5, rhs.count >= 5 else { return false }
        return lhs.prefix(5) == rhs.prefix(5)
    }

    private static func genericCoachingIndicators(in text: String) -> [String] {
        [
            "you should say", "you could say", "a strong answer", "structure your answer", "use the star method",
            "connect it to", "mention your", "here is how to answer", "as an ai", "based on the prompt"
        ].filter { text.contains($0) }
    }

    private static func containsAny(_ text: String, _ terms: [String]) -> Bool {
        terms.contains { text.contains($0) }
    }

    private static func normalize(_ text: String) -> String {
        " " + text.lowercased()
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ") + " "
    }

    private static func result(
        score: Double,
        verdict: AnswerAlignmentVerdict,
        questionIntent: AnswerRelevanceIntent,
        answerIntent: AnswerRelevanceIntent,
        matched: [String],
        missing: [String],
        wrong: [String],
        reason: String
    ) -> AnswerAlignmentResult {
        AnswerAlignmentResult(
            score: score,
            verdict: verdict,
            questionIntent: questionIntent,
            answerIntent: answerIntent,
            matchedThemes: Array(Set(matched)).sorted(),
            missingThemes: Array(Set(missing)).sorted(),
            wrongAnswerIndicators: Array(Set(wrong)).sorted(),
            reason: reason
        )
    }
}
