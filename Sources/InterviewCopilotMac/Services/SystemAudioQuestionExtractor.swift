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

    static func extract(from text: String) -> [ExtractedTranscriptQuestion] {
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
            guard isCompleteQuestion(questionText),
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
            if !questions.contains(where: { normalized($0.text) == normalized(extracted.text) }) {
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
                if start - previous < 140, previousClause.contains("when you moved") || previousClause.contains("when you move") {
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

    private static func isCompleteQuestion(_ text: String) -> Bool {
        let lower = text.lowercased()
        let words = lower.split(whereSeparator: \.isWhitespace).count
        guard words >= 4 else { return false }

        let incompleteEndings = [
            " can you", " could you", " would you", " do you",
            " and", " or", " but", " because", " with", " to", " for", " about",
            " tell me", " walk me", " when", " which"
        ]
        if incompleteEndings.contains(where: { lower.hasSuffix($0) }) {
            return false
        }

        return questionStarts(in: lower).first == 0
    }

    private static func isSmallTalkOnly(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["thanks", "thank you", "great thanks", "hi", "hello"].contains(lower)
    }

    private static func classify(_ text: String) -> (intent: QuestionIntent, strategy: AnswerStrategy, confidence: Double) {
        let lower = text.lowercased()
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
        if lower.contains("walk me through") || lower.contains("project") || lower.contains("leorover") || lower.contains("leo rover") || lower.contains("leah rover") {
            return (.projectDeepDive, .projectWalkthrough, 0.92)
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
        collapse(text)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".?!,;: "))
    }
}

private extension String.Index {
    init?(utf16Offset: Int, in string: String, limitedBy limit: String.Index) {
        let index = String.Index(utf16Offset: utf16Offset, in: string)
        guard index <= limit else { return nil }
        self = index
    }
}
