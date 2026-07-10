import Foundation

enum SystemAudioUtteranceClassifier {
    private static let maxClassificationCharacters = 900

    static func classify(text: String, previousText: String? = nil) -> UtteranceIntentClassification {
        let cleaned = collapse(text)
        guard !cleaned.isEmpty else {
            return UtteranceIntentClassification(intent: .unknown, confidence: 0.0, reason: "empty utterance")
        }

        let bounded = String(cleaned.prefix(maxClassificationCharacters))
        let lower = bounded.lowercased()

        if let previousText {
            let previous = collapse(previousText).lowercased()
            if !previous.isEmpty && previous == lower {
                return UtteranceIntentClassification(intent: .duplicatePartial, confidence: 0.98, reason: "same utterance text already processed")
            }
        }

        if isCandidateStyleAnswer(lower), !hasStrongQuestionStructure(lower) {
            return UtteranceIntentClassification(intent: .candidateStyleAnswer, confidence: 0.92, reason: "answer-like system audio utterance")
        }

        if isSmallTalk(lower) {
            return UtteranceIntentClassification(intent: .smallTalk, confidence: 0.9, reason: "short backchannel or small talk")
        }

        if isAnswerWorthyQuestion(lower) {
            return UtteranceIntentClassification(intent: .answerWorthyQuestion, confidence: 0.9, reason: "current utterance contains a complete interview question")
        }

        if isCandidateStyleAnswer(lower) || isLongDeclarative(lower) {
            return UtteranceIntentClassification(intent: .candidateStyleAnswer, confidence: 0.86, reason: "declarative answer-like system audio utterance")
        }

        if lower.split(whereSeparator: \.isWhitespace).count >= 4 {
            return UtteranceIntentClassification(intent: .interviewerStatement, confidence: 0.75, reason: "statement without question structure")
        }

        return UtteranceIntentClassification(intent: .unknown, confidence: 0.45, reason: "not enough evidence for generation")
    }

    private static func collapse(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isSmallTalk(_ lower: String) -> Bool {
        let trimmed = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        let exact = [
            "okay", "ok", "great", "thanks", "thank you", "interesting",
            "right", "good", "makes sense", "that is useful", "that covers my questions"
        ]
        if exact.contains(trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ".!,"))) {
            return true
        }

        let words = trimmed.split(whereSeparator: \.isWhitespace).count
        guard words <= 12 else { return false }
        let prefixes = [
            "hi ", "hello ", "great, thanks", "okay, interesting", "okay. ",
            "right. ", "makes sense", "good.", "thanks.", "great."
        ]
        return prefixes.contains { trimmed.hasPrefix($0) } && !hasStrongQuestionStructure(trimmed)
    }

    private static func isCandidateStyleAnswer(_ lower: String) -> Bool {
        let prefixes = [
            "sure.", "sure ", "yes.", "yes ", "i'm ", "i’m ", "i am ",
            "my background ", "my role ", "the leorover project was",
            "the project was", "the goal was", "the hardest challenge was",
            "the hardest part was", "i handled ", "i used ", "we used ",
            "i would ", "i’m interested ", "i'm interested ", "recently, ",
            "this was ", "it was ", "in my evaluation", "the diffusion decoder performed better because"
        ]
        if prefixes.contains(where: { lower.hasPrefix($0) }) {
            return true
        }

        let answerPhrases = [
            " i handled this by ",
            " i handled it by ",
            " my role focused on ",
            " achieved seven out of ten ",
            " i became interested ",
            " i would improve ",
            " i am actively improving ",
            " i understand its importance "
        ]
        return answerPhrases.contains { lower.contains($0) }
    }

    private static func isLongDeclarative(_ lower: String) -> Bool {
        let words = lower.split(whereSeparator: \.isWhitespace).count
        guard words >= 18 else { return false }
        return !hasStrongQuestionStructure(lower)
    }

    private static func isAnswerWorthyQuestion(_ lower: String) -> Bool {
        if lower.contains("maybe the question is") {
            return false
        }
        if isCandidateStyleAnswer(lower), lower.hasPrefix("yes") || lower.hasPrefix("sure") {
            return false
        }

        if lower.contains("?") && hasStrongQuestionStructure(lower) {
            return true
        }

        return hasStrongQuestionStructure(lower) && isCompleteQuestionCandidate(lower)
    }

    private static func hasStrongQuestionStructure(_ lower: String) -> Bool {
        questionStarterRange(in: lower) != nil || isConfirmationTagQuestion(lower)
    }

    private static func isCompleteQuestionCandidate(_ lower: String) -> Bool {
        let words = lower.split(whereSeparator: \.isWhitespace).count
        guard words >= 4 else { return false }
        let incompleteEndings = [
            " can you", " could you", " would you", " do you", " are you",
            " and", " or", " but", " so", " because", " with", " to", " for", " about",
            " walk me", " tell me"
        ]
        return !incompleteEndings.contains { lower.hasSuffix($0) }
    }

    private static func questionStarterRange(in lower: String) -> Range<String.Index>? {
        let starters = [
            "what ", "how ", "why ", "where ", "who ", "when ",
            "and what ", "and how ", "and why ",
            "can you ", "could you ", "would you ", "should you ",
            "are you ", "do you ", "did you ", "have you ", "is there ",
            "was it ", "were you ", "will you ",
            "tell me ", "walk me through ", "describe ", "explain ",
            "can you walk ", "could you walk ", "suppose you ", "if the same issue "
        ]

        for starter in starters {
            if lower.hasPrefix(starter), let range = lower.range(of: starter) {
                return range
            }

            let sentencePatterns = [". \(starter)", "? \(starter)", "! \(starter)", ", \(starter)"]
            for pattern in sentencePatterns {
                if let range = lower.range(of: pattern) {
                    return range
                }
            }
        }

        return nil
    }

    private static func isConfirmationTagQuestion(_ lower: String) -> Bool {
        let trimmed = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.hasPrefix("you have ") || trimmed.hasPrefix("you've ")) &&
            (trimmed.hasSuffix("right?") || trimmed.hasSuffix("correct?") || trimmed.hasSuffix("right"))
    }
}
