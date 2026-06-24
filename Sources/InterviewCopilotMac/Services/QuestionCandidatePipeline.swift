import Foundation

struct RawTranscriptSegment: Equatable {
    var text: String
    var isFinal: Bool
}

struct AcceptedQuestionCandidate: Equatable {
    var text: String
    var confidence: Double
    var intent: QuestionIntent
    var answerStrategy: AnswerStrategy
    var answerRelevanceIntent: AnswerRelevanceIntent
    var duplicateKey: String
    var sourceStartUTF16: Int
    var sourceEndUTF16: Int
}

/// Pure transcript-to-question pipeline. It must not mutate UI state, write the
/// database, call providers, or own generation tasks.
enum QuestionCandidatePipeline {
    private static let maxInputCharacters = 2_400
    private static let maxExtractedQuestions = 12

    static func extract(from text: String, isFinal: Bool = true) -> [AcceptedQuestionCandidate] {
        extract(from: RawTranscriptSegment(text: text, isFinal: isFinal))
    }

    static func extract(from segment: RawTranscriptSegment) -> [AcceptedQuestionCandidate] {
        let collapsed = QuestionTextUtilities.collapse(segment.text)
        guard collapsed.split(whereSeparator: \.isWhitespace).count >= 4 else {
            return []
        }

        // Split against the recognizer's formatted source text so provenance
        // offsets remain stable. Canonicalization can change string length and
        // therefore happens independently inside each source slice.
        let bounded = String(collapsed.prefix(maxInputCharacters))
        let rawQuestions = MultiQuestionSplitter.splitWithRanges(bounded)
        var questions: [AcceptedQuestionCandidate] = []
        var sourceSliceWasTerminated: [Bool] = []

        for raw in rawQuestions {
            // A splitter slice extends to the next question start. When the
            // recognizer supplied punctuation, exclude any intervening
            // interviewer statement from both the candidate and its source
            // span.
            let sourceSlice: String
            if let questionMark = raw.text.firstIndex(of: "?"),
               !shouldKeepCompoundQuestionTail(after: questionMark, in: raw.text) {
                sourceSlice = String(raw.text[...questionMark])
            } else {
                sourceSlice = raw.text
            }
            let canonicalSlice = ASRCanonicalizer.canonicalizeTerms(sourceSlice)
            let questionText = RawQuestionCleaner.clean(canonicalSlice)
            guard QuestionCompletenessGate.isCompleteQuestion(questionText, isFinal: segment.isFinal),
                  !RawQuestionCleaner.isSmallTalkOnly(questionText) else {
                continue
            }

            let classified = IntentRouter.transcriptClassification(for: questionText)
            let extracted = AcceptedQuestionCandidate(
                text: questionText,
                confidence: classified.confidence,
                intent: classified.intent,
                answerStrategy: classified.strategy,
                answerRelevanceIntent: IntentRouter.answerIntent(for: questionText),
                duplicateKey: SemanticDuplicateKeyBuilder.key(for: questionText),
                sourceStartUTF16: raw.startUTF16,
                sourceEndUTF16: raw.startUTF16 + (sourceSlice as NSString).length
            )
            if let existingIndex = questions.firstIndex(where: {
                $0.duplicateKey == extracted.duplicateKey &&
                    max($0.sourceStartUTF16, extracted.sourceStartUTF16) < min($0.sourceEndUTF16, extracted.sourceEndUTF16)
            }) {
                if extracted.text.count >= questions[existingIndex].text.count {
                    questions[existingIndex] = extracted
                    sourceSliceWasTerminated[existingIndex] = sourceSlice.contains("?")
                }
                continue
            }
            if let existingIndex = questions.firstIndex(where: { $0.duplicateKey == extracted.duplicateKey }),
               !sourceSliceWasTerminated[existingIndex] {
                // Consecutive unpunctuated variants in one ASR callback are a
                // recognizer correction/expansion, not a second utterance.
                // Keep the more complete physical span. A terminated first
                // occurrence remains distinct so an explicit later repeat is
                // preserved.
                if extracted.text.count >= questions[existingIndex].text.count {
                    questions[existingIndex] = extracted
                    sourceSliceWasTerminated[existingIndex] = sourceSlice.contains("?")
                }
                continue
            }
            // Keep semantically repeated questions when they occupy distinct
            // source spans. Ingress provenance decides whether the later span
            // is an intentional repeat or cumulative replay.
            questions.append(extracted)
            sourceSliceWasTerminated.append(sourceSlice.contains("?"))
            if questions.count >= maxExtractedQuestions { break }
        }

        return questions
    }

    private static func shouldKeepCompoundQuestionTail(after questionMark: String.Index, in text: String) -> Bool {
        let tailStart = text.index(after: questionMark)
        guard tailStart < text.endIndex else { return false }
        let tail = String(text[tailStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerTail = tail.lowercased()
        guard lowerTail.hasPrefix("what made ") else { return false }
        let prefix = String(text[..<questionMark]).lowercased()
        return prefix.contains("system") ||
            prefix.contains("project") ||
            prefix.contains("pipeline") ||
            prefix.contains("leorover")
    }
}

enum MultiQuestionSplitter {
    struct QuestionSlice: Equatable {
        let text: String
        let startUTF16: Int
        let endUTF16: Int
    }

    static func split(_ text: String) -> [String] {
        splitWithRanges(text).map(\.text)
    }

    static func splitWithRanges(_ text: String) -> [QuestionSlice] {
        let bounded = QuestionTextUtilities.collapse(text)
        let lower = bounded.lowercased()
        let starts = questionStarts(in: lower)
        guard !starts.isEmpty else { return [] }

        var questions: [QuestionSlice] = []
        for index in starts.indices {
            let start = starts[index]
            let end = index + 1 < starts.count ? starts[index + 1] : bounded.count
            guard start < end else { continue }
            let startIndex = String.Index(utf16Offset: start, in: bounded)
            let endIndex = String.Index(utf16Offset: end, in: bounded)
            guard startIndex <= endIndex, endIndex <= bounded.endIndex else {
                continue
            }
            questions.append(QuestionSlice(
                text: String(bounded[startIndex..<endIndex]),
                startUTF16: start,
                endUTF16: end
            ))
        }
        return questions
    }

    static func questionStarts(in lower: String) -> [Int] {
        let patterns = [
            "\\bcould\\s+you\\b",
            "\\bcan\\s+you\\b",
            "\\bwould\\s+you\\b",
            "\\btell\\s+me\\s+about\\b",
            "\\bwalk\\s+me\\s+through\\b",
            "\\bwhat\\s+did\\b",
            "\\bwhat\\s+questions\\b",
            "\\bwhat\\s+was\\b",
            "\\bwhat\\s+would\\b",
            "\\bwhich\\s+part\\s+of\\s+the\\s+pipeline\\b",
            "\\balso,?\\s+if\\b",
            "\\bnow,?\\s+if\\b",
            "\\band\\s+if\\b",
            "\\bwhat\\s+about\\s+if\\b",
            "\\bif\\s+your\\b",
            "\\bif\\s+you\\s+had\\s+one\\s+more\\s+month\\b",
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
        if lower.hasPrefix("what made ") {
            starts.insert(0)
        }
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
                if start - previous < 220,
                   !previousClause.contains("?"),
                   isConditionalAntecedent(previousClause),
                   isQuestionTail(currentClause) {
                    continue
                }
                if start - previous < 260,
                   !previousClause.contains("?"),
                   isMitigationTail(currentClause),
                   previousClause.contains("real world execution") || previousClause.contains("demo environment") {
                    continue
                }
                if start - previous < 180,
                   !previousClause.contains("?"),
                   previousClause.contains("if your") || previousClause.contains("also if") {
                    continue
                }
                if start - previous < 180,
                   !previousClause.contains("?"),
                   currentClause.hasPrefix("if your"),
                   previousClause.contains("how would") {
                    continue
                }
            }
            filtered.append(start)
        }
        return filtered
    }

    private static func isConditionalAntecedent(_ clause: String) -> Bool {
        let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("if ") ||
            trimmed.contains(" if ") ||
            trimmed.hasPrefix("also if ") ||
            trimmed.hasPrefix("and if ") ||
            trimmed.hasPrefix("when ") ||
            trimmed.contains(" when ")
    }

    private static func isQuestionTail(_ clause: String) -> Bool {
        let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("how would") ||
            trimmed.hasPrefix("what would") ||
            trimmed.hasPrefix("would you") ||
            trimmed.hasPrefix("which part") ||
            trimmed.hasPrefix("what part") ||
            trimmed.hasPrefix("how did") ||
            trimmed.hasPrefix("why was")
    }

    private static func isMitigationTail(_ clause: String) -> Bool {
        let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("and how did you mitigate") ||
            trimmed.hasPrefix("how did you mitigate") ||
            trimmed.hasPrefix("and how would you mitigate") ||
            trimmed.hasPrefix("how would you mitigate")
    }
}

enum RawQuestionCleaner {
    static func clean(_ raw: String) -> String {
        var cleaned = QuestionTextUtilities.collapse(raw)
        let leadingNoise = [
            "first ",
            "great thanks ",
            "great, thanks ",
            "okay interesting ",
            "okay, interesting ",
            "right ",
            "good ",
            "thanks ",
            "also, ",
            "also ",
            "now, ",
            "now ",
            "what about ",
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
        cleaned = QuestionCanonicalizer.canonicalize(cleaned)
        cleaned = QuestionCanonicalizer.removeDanglingQuestionTail(cleaned)
        cleaned = removeTrailingNoise(cleaned)

        while let last = cleaned.last, ".!,;:".contains(last) {
            cleaned.removeLast()
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return normalizeLeadingCapitalization(cleaned)
    }

    static func isSmallTalkOnly(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["thanks", "thank you", "great thanks", "hi", "hello"].contains(lower)
    }

    private static func removeTrailingNoise(_ text: String) -> String {
        var cleaned = text
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
            let lower = cleaned.lowercased()
            for suffix in trailingNoise where lower.hasSuffix(suffix) {
                cleaned.removeLast(suffix.count)
                cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                removedSuffix = true
                break
            }
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

    private static func normalizeLeadingCapitalization(_ text: String) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
