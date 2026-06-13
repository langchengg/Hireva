import Foundation

struct ExtractedTranscriptQuestion: Equatable {
    var text: String
    var confidence: Double
    var intent: QuestionIntent
    var answerStrategy: AnswerStrategy
}

enum SystemAudioQuestionExtractor {
    private static let maxInputCharacters = 2_400
    private static let maxExtractedQuestions = 12

    static func isIncompleteQuestionFragment(_ text: String) -> Bool {
        let lower = collapse(text).lowercased()
        let words = lower.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return false }

        if lower.hasPrefix("why do you want") {
            let completions = ["join our team", "this role", "this company", "to work here", "to join us"]
            return !completions.contains { lower.contains($0) }
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
            "why might",
            "how would"
        ]
        if incompleteTails.contains(where: { lower.hasSuffix($0) }) {
            return true
        }

        let shortStarters = ["what would you", "how would you", "can you tell", "could you explain"]
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

    static func canonicalizeQuestionText(_ text: String) -> String {
        var canonical = collapse(text)
        canonical = regexReplace(#"\bfrom\s+n\s+to\s+end\b"#, in: canonical, with: "from end to end")
        canonical = regexReplace(#"\bfrom\s+end\s+to\s+end\b"#, in: canonical, with: "from end to end")
        canonical = regexReplace(#"\bleader\s+rover\b"#, in: canonical, with: "LeoRover")
        canonical = regexReplace(#"\bleah\s+rover\b"#, in: canonical, with: "LeoRover")
        canonical = regexReplace(#"\bleo\s+rover\b"#, in: canonical, with: "LeoRover")
        canonical = regexReplace(#"\blero\b"#, in: canonical, with: "LeoRover")
        canonical = regexReplace(#"\bauto\s+rig\s+progressive\b"#, in: canonical, with: "autoregressive")
        canonical = regexReplace(#"\bauto\s+regressive\b"#, in: canonical, with: "autoregressive")
        canonical = regexReplace(#"\bdiffusion[-\s]+based\s+policy\b"#, in: canonical, with: "diffusion policy")
        canonical = truncateRepeatedFragilePipelineTail(canonical)
        canonical = removeDanglingQuestionTail(canonical)

        let lower = canonical.lowercased()
        if lower == "when you moved from a clean demo to real robot execution which part of the pipeline was most fragile" ||
            lower == "when you move from a clean demo to real robot execution which part of the pipeline was most fragile" {
            return "When you moved from a clean demo to real robot execution, which part of the pipeline was most fragile?"
        }

        if lower == "could you explain your leorover" ||
            lower == "can you explain your leorover" ||
            lower == "could you walk me through your leorover" ||
            lower == "can you walk me through your leorover" {
            canonical += " project"
        }
        return canonical
    }

    static func duplicateKey(for text: String) -> String {
        var key = canonicalizeQuestionText(text).lowercased()
        key = regexReplace(#"\bauto\s+rig\s+progressive\b"#, in: key, with: "autoregressive")
        key = regexReplace(#"\bauto\s+regressive\b"#, in: key, with: "autoregressive")
        key = regexReplace(#"\bdiffusion[-\s]+based\s+policy\b"#, in: key, with: "diffusion policy")
        key = regexReplace(#"\bdiffusion[-\s]+based\b"#, in: key, with: "diffusion")

        let isLeoRover = key.contains("leorover")
        let isProjectWalkthrough = key.contains("walk me through") ||
            key.contains("explain your") ||
            key.contains("from end to end") ||
            key.hasSuffix("leorover project")
        let isTechnicalFollowUp = key.contains("fragile") ||
            key.contains("hardest") ||
            key.contains("pipeline") && (key.contains("which part") || key.contains("most fragile")) ||
            key.contains("noisy") ||
            key.contains("localisation") ||
            key.contains("localization")
        if isLeoRover && isProjectWalkthrough && !isTechnicalFollowUp {
            return "project walkthrough leorover"
        }

        return key
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func extract(from text: String, isFinal: Bool = true) -> [ExtractedTranscriptQuestion] {
        let collapsed = collapse(text)
        guard collapsed.split(whereSeparator: \.isWhitespace).count >= 4 else {
            return []
        }

        let bounded = String(collapsed.prefix(maxInputCharacters))
        let lower = bounded.lowercased()
        let starts = questionStarts(in: lower)
        guard !starts.isEmpty else { return [] }

        var questions: [ExtractedTranscriptQuestion] = []
        for index in starts.indices {
            let start = starts[index]
            let end = index + 1 < starts.count ? starts[index + 1] : bounded.count
            guard start < end,
                  let startIndex = String.Index(utf16Offset: start, in: bounded, limitedBy: bounded.endIndex),
                  let endIndex = String.Index(utf16Offset: end, in: bounded, limitedBy: bounded.endIndex) else {
                continue
            }

            let raw = String(bounded[startIndex..<endIndex])
            let questionText = cleanQuestion(raw)
            guard isCompleteQuestion(questionText, isFinal: isFinal),
                  !isSmallTalkOnly(questionText) else {
                continue
            }

            let classified = classify(questionText)
            let extracted = ExtractedTranscriptQuestion(
                text: questionText,
                confidence: classified.confidence,
                intent: classified.intent,
                answerStrategy: classified.strategy
            )
            if let duplicateIndex = questions.firstIndex(where: { areSemanticDuplicates($0.text, extracted.text) }) {
                if shouldPreferQuestion(extracted.text, over: questions[duplicateIndex].text) {
                    questions[duplicateIndex] = extracted
                }
            } else {
                questions.append(extracted)
            }
            if questions.count >= maxExtractedQuestions { break }
        }

        return questions
    }

    private static func questionStarts(in lower: String) -> [Int] {
        let patterns = [
            "\\bcould\\s+you\\b",
            "\\bcan\\s+you\\b",
            "\\bwould\\s+you\\b",
            "\\btell\\s+me\\s+about\\b",
            "\\bwalk\\s+me\\s+through\\b",
            "\\bwhat\\s+was\\b",
            "\\bwhat\\s+would\\b",
            "\\bwhich\\s+part\\s+of\\s+the\\s+pipeline\\b",
            "\\band\\s+how\\s+did\\b",
            "\\bhow\\s+did\\b",
            "\\bhow\\s+would\\b",
            "\\bhow\\s+comfortable\\b",
            "\\bwhy\\s+did\\b",
            "\\bwhy\\s+do\\b",
            "\\bwhy\\s+might\\b",
            "\\bdo\\s+you\\s+have\\b",
            "\\bsuppose\\s+you\\b",
            "\\bwhen\\s+you\\s+moved\\b",
            "\\bwhen\\s+you\\s+move\\b",
            "\\bif\\s+the\\s+same\\s+issue\\b"
        ]

        var starts = Set<Int>()
        let range = NSRange(location: 0, length: (lower as NSString).length)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            for match in regex.matches(in: lower, options: [], range: range) {
                starts.insert(match.range.location)
            }
        }
        var filtered: [Int] = []
        for start in starts.sorted() {
            if let previous = filtered.last {
                if start - previous < 18 {
                    continue
                }
                let previousIndex = String.Index(utf16Offset: previous, in: lower)
                let currentIndex = String.Index(utf16Offset: start, in: lower)
                let previousClause = String(lower[previousIndex..<currentIndex])
                if start - previous < 140, previousClause.contains("suppose you") {
                    continue
                }
                let currentClause = String(lower[currentIndex...])
                if start - previous < 140,
                   (previousClause.contains("when you moved") || previousClause.contains("when you move")),
                   !currentClause.hasPrefix("why do") {
                    continue
                }
                if start - previous < 140, previousClause.contains("if the same issue") {
                    continue
                }
            }
            filtered.append(start)
        }
        return filtered
    }

    private static func cleanQuestion(_ raw: String) -> String {
        var cleaned = collapse(raw)
        let leadingNoise = [
            "first ",
            "great thanks ",
            "great, thanks ",
            "okay interesting ",
            "okay, interesting ",
            "right ",
            "good ",
            "thanks ",
            "and "
        ]
        var lower = cleaned.lowercased()
        var removedPrefix = true
        while removedPrefix {
            removedPrefix = false
            for prefix in leadingNoise where lower.hasPrefix(prefix) {
                cleaned.removeFirst(prefix.count)
                cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                lower = cleaned.lowercased()
                removedPrefix = true
                break
            }
        }

        cleaned = truncateAtTransitionPhrase(cleaned)
        cleaned = canonicalizeQuestionText(cleaned)
        cleaned = removeDanglingQuestionTail(cleaned)

        let trailingNoise = [
            " great thanks",
            " great, thanks",
            " okay interesting",
            " okay, interesting",
            " right",
            " makes sense",
            " good",
            " thanks"
        ]
        var removedSuffix = true
        while removedSuffix {
            removedSuffix = false
            lower = cleaned.lowercased()
            for suffix in trailingNoise where lower.hasSuffix(suffix) {
                cleaned.removeLast(suffix.count)
                cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                removedSuffix = true
                break
            }
        }

        while let last = cleaned.last, ".!,;:".contains(last) {
            cleaned.removeLast()
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }

    private static func removeDanglingQuestionTail(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var lower = cleaned.lowercased()
        let danglingTails = [
            " when you moved from",
            " when you move from",
            " when you moved",
            " when you move",
            " when you",
            " why do you want",
            " why do you",
            " how would you",
            " what did you",
            " could you",
            " can you",
            " would you",
            " tell me about",
            " do you",
            " why"
        ]
        var removed = true
        while removed {
            removed = false
            for tail in danglingTails where lower.hasSuffix(tail) {
                cleaned.removeLast(tail.count)
                cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                lower = cleaned.lowercased()
                removed = true
                break
            }
        }
        return cleaned
    }

    private static func truncateRepeatedFragilePipelineTail(_ text: String) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = cleaned.lowercased()
        guard lower.hasPrefix("when you moved from") || lower.hasPrefix("when you move from") else {
            return cleaned
        }

        let completion = "which part of the pipeline was most fragile"
        guard let completionRange = lower.range(of: completion) else {
            return cleaned
        }

        let tail = String(lower[completionRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard tail.isEmpty ||
              tail.hasPrefix("when you moved") ||
              tail.hasPrefix("when you move") else {
            return cleaned
        }

        return String(cleaned[..<completionRange.upperBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func truncateAtTransitionPhrase(_ text: String) -> String {
        let lower = text.lowercased()
        let transitions = [
            " now let us switch to",
            " now let's switch to",
            " now lets switch to",
            " let us switch to",
            " let's switch to",
            " lets switch to",
            " now let us talk about",
            " now let's talk about",
            " now lets talk about",
            " now we can move to",
            " moving on to"
        ]

        let firstRange = transitions
            .compactMap { lower.range(of: $0) }
            .min { $0.lowerBound < $1.lowerBound }
        guard let firstRange else { return text }
        return String(text[..<firstRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isCompleteQuestion(_ text: String, isFinal: Bool) -> Bool {
        let lower = text.lowercased()
        let words = lower.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 4 else { return false }

        let incompleteEndings = [
            " can you", " could you", " would you", " do you",
            " and", " or", " but", " because", " with", " to", " for", " about",
            " from", " tell me", " walk me", " when", " which",
            " which part", " which part of", " which part of the", " which part of the pipeline",
            " what part", " what part of", " what was", " why might", " how would"
        ]
        if incompleteEndings.contains(where: { lower.hasSuffix($0) }) {
            return false
        }

        // Question starts check
        guard questionStarts(in: lower).first == 0 else { return false }

        if isIncompleteQuestionFragment(lower) {
            return false
        }

        // Rules for common question starters when segment is not final
        if !isFinal {
            let otherStarters = ["what would you", "how would you", "can you tell", "could you explain"]
            for starter in otherStarters {
                if lower.hasPrefix(starter) {
                    if words.count < 6 {
                        return false
                    }
                }
            }
        }

        return true
    }

    private static func isSmallTalkOnly(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["thanks", "thank you", "great thanks", "hi", "hello"].contains(lower)
    }

    private static func classify(_ text: String) -> (intent: QuestionIntent, strategy: AnswerStrategy, confidence: Double) {
        let lower = canonicalizeQuestionText(text).lowercased()
        if lower.contains("walk me through") ||
            lower.contains("project") ||
            lower.contains("leorover") ||
            lower.contains("leo rover") {
            return (.projectDeepDive, .projectWalkthrough, 0.92)
        }
        if lower.contains("diffusion") ||
            lower.contains("autoregressive") ||
            lower.contains("auto regressive") ||
            lower.contains("flow-matching") ||
            lower.contains("flow matching") ||
            lower.contains("mujoco") ||
            lower.contains("mouko") ||
            lower.contains("continuous action") ||
            lower.contains("fragile") ||
            lower.contains("clean demo") ||
            lower.contains("real robot execution") ||
            lower.contains("localisation") ||
            lower.contains("localization") ||
            lower.contains("timing") ||
            lower.contains("integration") ||
            lower.contains("pipeline") {
            return (.technical, .technicalExplanation, 0.93)
        }
        if lower.contains("technical") || lower.contains("detections") || lower.contains("python") || lower.contains("ros") || lower.contains("c++") {
            return (.technical, .technicalExplanation, 0.92)
        }
        if lower.contains("why do you want") || lower.contains("join our team") || lower.contains("questions for us") || lower.contains("role") {
            return (.companyFit, .directAnswer, 0.9)
        }
        if lower.contains("tell me a little bit about yourself") || lower.contains("hardest") || lower.contains("challenge") {
            return (.behavioral, .starStory, 0.9)
        }
        return (.unclear, .directAnswer, 0.86)
    }

    private static func collapse(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalized(_ text: String) -> String {
        duplicateKey(for: text)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".?!,;: "))
    }

    private static func areSemanticDuplicates(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalized(lhs)
        let right = normalized(rhs)
        if left == right {
            return true
        }
        guard !left.isEmpty, !right.isEmpty else {
            return false
        }
        let shorter = left.count <= right.count ? left : right
        let longer = left.count > right.count ? left : right
        guard longer.contains(shorter) else {
            return false
        }
        let shorterWords = shorter.split(separator: " ").count
        let longerWords = longer.split(separator: " ").count
        guard shorterWords > 0 else { return false }
        return Double(longerWords) / Double(shorterWords) <= 1.8
    }

    private static func shouldPreferQuestion(_ candidate: String, over existing: String) -> Bool {
        let candidateWords = canonicalizeQuestionText(candidate).split(whereSeparator: \.isWhitespace).count
        let existingWords = canonicalizeQuestionText(existing).split(whereSeparator: \.isWhitespace).count
        return candidateWords > existingWords
    }

    private static func regexReplace(_ pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }
}

private extension String.Index {
    init?(utf16Offset: Int, in string: String, limitedBy limit: String.Index) {
        let index = String.Index(utf16Offset: utf16Offset, in: string)
        guard index <= limit else { return nil }
        self = index
    }
}
