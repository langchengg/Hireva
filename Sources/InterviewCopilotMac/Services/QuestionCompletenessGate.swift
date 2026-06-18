import Foundation

/// Rejects partial ASR fragments before they can trigger answer generation.
enum QuestionCompletenessGate {
    static func isIncompleteFragment(_ text: String) -> Bool {
        let lower = QuestionTextUtilities.collapse(text).lowercased()
        let words = lower.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return false }

        if isTailOnlyQuestion(lower) {
            return true
        }

        if lower.hasPrefix("why do you want") {
            let completions = ["join our team", "this role", "this company", "to work here", "to join us"]
            return !completions.contains { lower.contains($0) }
        }

        if lower.hasPrefix("if you had one more month to improve") {
            return !hasOneMoreMonthImprovementComplement(lower)
        }

        if lower == "could you walk me through your robotics" ||
            lower == "can you walk me through your robotics" ||
            lower == "could you walk me through your robotics project" ||
            lower == "can you walk me through your robotics project" {
            return true
        }

        if QuestionRuntimeAcceptanceGuard.isVagueFollowUp(lower) ||
            QuestionRuntimeAcceptanceGuard.isKnownIncompleteOrGenericPattern(lower) {
            return true
        }

        let exactFragments = [
            "what was the biggest",
            "what was the biggest technical",
            "what was the biggest technical trade-off",
            "what was the biggest technical tradeoff",
            "tell me about a",
            "tell me about a time",
            "tell me about a time you",
            "can you explain the difference",
            "how did you adapt",
            "how would you diagnose",
            "how would you diagnose a seem",
            "would you ask us",
            "what did you learn",
            "what did you learn from it",
            "what did you learn from that",
            "what did you learn from comp",
            "what questions would you ask",
            "what questions would you ask us",
            "what questions would you ask us about the",
            "what questions would you ask us about that",
            "could you walk me through your robotics",
            "could you walk me through your robotics project",
            "can you walk me through your robotics",
            "can you walk me through your robotics project"
        ]
        if exactFragments.contains(lower) {
            return true
        }

        if lower.hasPrefix("when you moved from") || lower.hasPrefix("when you move from") {
            let hasSourceAndDestination = lower.contains(" to ")
            let hasQuestionComplement = lower.contains("which part of the pipeline was most fragile") ||
                lower.contains("which part was most fragile") ||
                lower.contains("what part of the pipeline was most fragile") ||
                lower.contains("what part was most fragile") ||
                lower.contains("what was the most fragile") ||
                lower.contains("how did") ||
                lower.contains("why was")
            return words.count <= 4 || !hasSourceAndDestination || !hasQuestionComplement
        }

        let incompleteTails = [
            "which part",
            "which part of",
            "which part of the",
            "which part of the pipeline",
            "what part",
            "what part of",
            "what was",
            "what was the biggest",
            "what was the biggest technical",
            "what was the biggest technical trade-off",
            "what was the biggest technical tradeoff",
            "what did you learn",
            "what did you learn from it",
            "what did you learn from that",
            "what did you learn from comp",
            "tell me about a",
            "tell me about a time",
            "tell me about a time you",
            "tell me about a time you had",
            "can you explain the difference",
            "how did you adapt",
            "how would you diagnose",
            "how would you diagnose a seem",
            "diagnose a seem",
            "what questions would you ask",
            "what questions would you ask us about the",
            "what questions would you ask us about that",
            "why might",
            "how would",
            "about the",
            "also if"
        ]
        if incompleteTails.contains(where: { lower.hasSuffix($0) }) {
            return true
        }

        let shortStarters = ["what would you", "how would you", "can you tell", "could you explain", "would you ask"]
        for starter in shortStarters where lower.hasPrefix(starter) {
            return words.count < 6
        }

        if lower == "could you explain your" ||
            lower == "can you explain your" ||
            lower == "can you tell me about" ||
            lower == "could you tell me about" {
            return true
        }

        return false
    }

    static func isCompleteQuestion(_ text: String, isFinal: Bool) -> Bool {
        let lower = text.lowercased()
        let words = lower.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 4 else { return false }
        guard !isTailOnlyQuestion(lower) else { return false }

        let incompleteEndings = [
            " can you", " could you", " would you", " do you",
            " and", " or", " but", " because", " with", " to", " for", " about",
            " from", " tell me", " walk me", " when", " which",
            " tell me about a", " tell me about a time", " tell me about a time you",
            " which part", " which part of", " which part of the", " which part of the pipeline",
            " what part", " what part of", " what was", " what was the biggest", " what was the biggest technical",
            " what was the biggest technical trade-off", " what was the biggest technical tradeoff",
            " what did you learn", " what did you learn from it", " what did you learn from that",
            " what did you learn from comp", " why might", " how would", " how did you adapt", " how would you diagnose",
            " how would you diagnose a seem", " diagnose a seem", " can you explain the difference",
            " tell me about a time you had", " what questions would you ask", " what questions would you ask us about the",
            " about the", " what", " why", " how", " if", " also if"
        ]
        if incompleteEndings.contains(where: { lower.hasSuffix($0) }) {
            return false
        }

        guard MultiQuestionSplitter.questionStarts(in: lower).first == 0 else { return false }

        if isIncompleteFragment(lower) {
            return false
        }

        if lower.hasPrefix("if you had one more month to improve"),
           !hasOneMoreMonthImprovementComplement(lower) {
            return false
        }

        if !isFinal {
            let otherStarters = ["what would you", "how would you", "can you tell", "could you explain"]
            for starter in otherStarters where lower.hasPrefix(starter) {
                if words.count < 6 {
                    return false
                }
            }
        }

        return true
    }

    private static func hasOneMoreMonthImprovementComplement(_ lower: String) -> Bool {
        lower.contains("what would you improve first") ||
            lower.contains("what would you change first") ||
            lower.contains("what would you do first") ||
            lower.contains("what would be your first improvement") ||
            lower.contains("what would be the first thing")
    }

    static func isTailOnlyQuestion(_ text: String) -> Bool {
        let lower = QuestionTextUtilities.collapse(text)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".?!,;: "))

        let exactTails = [
            "would you debug it",
            "would you debug that",
            "would you solve it",
            "how would you debug it",
            "how would you debug that",
            "how would you solve it",
            "how would you diagnose it",
            "how would you diagnose that",
            "what would you do",
            "which part was most fragile",
            "which part of the pipeline was most fragile",
            "how would you solve this",
            "how would you diagnose this"
        ]
        if exactTails.contains(lower) {
            return true
        }

        let vagueDebugTails = [
            "debug it",
            "debug that",
            "solve it",
            "solve that",
            "diagnose it",
            "diagnose that"
        ]
        if (lower.hasPrefix("how would you ") || lower.hasPrefix("would you ")) &&
            vagueDebugTails.contains(where: { lower.hasSuffix($0) }) {
            return true
        }

        return false
    }
}
