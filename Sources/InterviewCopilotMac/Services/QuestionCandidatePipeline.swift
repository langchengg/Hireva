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
        let prefix = String(text[..<questionMark]).lowercased()
        if lowerTail.hasPrefix("what made ") {
            return prefix.contains("system") ||
                prefix.contains("project") ||
                prefix.contains("pipeline") ||
                prefix.contains("leorover")
        }
        return prefix.hasPrefix("what did you do before manchester") &&
            lowerTail.hasPrefix("were you with robotics") &&
            (lowerTail.contains("background") || lowerTail.contains("projects"))
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
        let auxiliaryQuestionStarts = [
            "\\bcould\\s+you\\b",
            "\\bcan\\s+you\\b",
            "\\bwould\\s+you\\b",
            "\\bdo\\s+you\\s+have\\b",
            "\\bdid\\s+you\\b",
            "\\bhave\\s+you\\b",
            "\\bis\\s+there\\b",
            "\\bwas\\s+it\\b",
            "\\bwere\\s+you\\b",
            "\\bwill\\s+you\\b",
            "\\byou\\s+have\\b.{0,140}\\b(?:right|correct)\\b"
        ]
        let imperativeQuestionStarts = [
            "\\btell\\s+me\\s+about\\b",
            "\\bwalk\\s+me\\s+through\\b",
            "\\bdescribe\\b",
            "\\bexplain\\b",
            "\\bgive\\s+me\\s+an\\s+example\\b",
            "\\btalk\\s+about\\b",
            "\\belaborate\\b",
            "\\bimagine(?:\\s+that)?\\b"
        ]
        let conditionalQuestionStarts = [
            "\\balso,?\\s+if\\b",
            "\\bnow,?\\s+if\\b",
            "\\band\\s+if\\b",
            "\\bwhat\\s+about\\s+if\\b",
            "\\bif\\s+(?:your|you|the|same)\\b",
            "\\bsuppose\\s+you\\b"
        ]
        let whQuestionStarts = [
            "\\bwhat\\s+happened\\b",
            "\\bwhat\\s+questions?\\s+(?:would|do|should|could)\\b",
            "\\bwhat\\s+(?:did|does|do|was|were|would|could|should|made|makes)\\b",
            "\\bwhat\\s+(?!(?:is|are)\\b)(?:[a-z0-9'’]+\\s+){1,5}(?:did|does|do|was|were|would|could|should|created|caused|needed|mattered|failed)\\b",
            "\\bwhich\\s+robots?\\s+have\\s+you\\b",
            "\\bwhich\\s+(?:[a-z0-9'’]+\\s+){0,8}(?:did|does|do|was|were|would|could|should|became|created|caused|made|failed|mattered|part|component|module|subsystem|stage|step)\\b",
            "\\band\\s+how\\s+did\\b",
            "\\bbefore\\b.{0,140}\\bwhat\\s+(?:[a-z0-9'’]+\\s+){0,8}(?:did|does|do|was|were|would|could|should|needed|mattered|failed)\\b",
            "\\bhow\\s+did\\b",
            "\\bhow\\s+do\\b",
            "\\bhow\\s+does\\b",
            "\\bhow\\s+would\\b",
            "\\bhow\\s+should\\b",
            "\\bhow\\s+comfortable\\b",
            "\\bwhy\\s+did\\b",
            "\\bwhy\\s+do\\b",
            "\\bwhy\\s+might\\b"
        ]
        let contextualQuestionStarts = [
            "\\bprior\\s+to\\s+your\\s+msc\\b"
        ]
        let temporalQuestionStarts = [
            "\\bwhen\\b",
            "\\bwhen\\b.{0,120}\\b(?:how|what|which|why)\\b",
            "\\bwhen\\s+you\\s+(?:moved|move)\\b",
            "\\bbefore\\b.{0,140}\\b(?:how|what|which|why)\\b"
        ]
        let patterns = auxiliaryQuestionStarts +
            imperativeQuestionStarts +
            conditionalQuestionStarts +
            whQuestionStarts +
            temporalQuestionStarts +
            contextualQuestionStarts

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
            let currentIndex = String.Index(utf16Offset: start, in: lower)
            let currentClause = String(lower[currentIndex...])
            let precedingText = String(lower[..<currentIndex])
            if isNarrativeImperative(precedingText: precedingText, currentClause: currentClause) {
                continue
            }
            if isBeforeInterviewerPrefaceBeforeIndependentQuestion(currentClause) {
                continue
            }
            if let previous = filtered.last {
                if start - previous < 18 {
                    continue
                }
                let previousIndex = String.Index(utf16Offset: previous, in: lower)
                let previousClause = String(lower[previousIndex..<currentIndex])
                if isBackgroundCompoundContinuation(previousClause: previousClause, currentClause: currentClause) {
                    continue
                }
                if previousClause.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("prior to your msc"),
                   currentClause.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("what ") {
                    continue
                }
                if start - previous < 260,
                   (previousClause.contains("suppose you") ||
                    previousClause.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("imagine")) {
                    continue
                }
                if start - previous < 140,
                   (previousClause.contains("when you moved") || previousClause.contains("when you move")),
                   !currentClause.hasPrefix("why do") {
                    continue
                }
                if isBeforeGerundPhraseBeforeIndependentQuestion(currentClause) {
                    continue
                }
                if start - previous < 140, previousClause.contains("if the same issue") {
                    continue
                }
                if start - previous < 220,
                   !previousClause.contains("?"),
                   isInlineTemporalTail(currentClause),
                   clauseAlreadyStartedQuestion(previousClause) {
                    continue
                }
                if start - previous < 220,
                   !previousClause.contains("?"),
                   isConditionalAntecedent(previousClause),
                   isQuestionTail(currentClause) {
                    if !antecedentAlreadyContainsQuestionComplement(previousClause) {
                        continue
                    }
                }
                if start - previous < 180,
                   !previousClause.contains("?"),
                   isClauseConnectorExpectingTail(previousClause),
                   isQuestionTail(currentClause) {
                    continue
                }
                if start - previous < 180,
                   !previousClause.contains("?"),
                   isDependentIfClause(currentClause),
                   !conditionalClauseContainsOwnQuestionComplement(currentClause),
                   clauseAlreadyStartedQuestion(previousClause) {
                    continue
                }
                if start - previous < 220,
                   !previousClause.contains("?"),
                   isDependentTemporalClause(currentClause),
                   !temporalClauseContainsQuestionComplement(currentClause),
                   clauseAlreadyStartedQuestion(previousClause) {
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
            trimmed.hasPrefix("before ") ||
            trimmed.hasPrefix("also if ") ||
            trimmed.hasPrefix("and if ") ||
            trimmed.hasPrefix("when ") ||
            trimmed.contains(" when ")
    }

    private static func antecedentAlreadyContainsQuestionComplement(_ clause: String) -> Bool {
        let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        let complementMarkers = [
            " what ", ", what ",
            " how ", ", how ",
            " which ", ", which ",
            " why ", ", why "
        ]
        return complementMarkers.contains { trimmed.contains($0) }
    }

    private static func isClauseConnectorExpectingTail(_ clause: String) -> Bool {
        let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix(" and") ||
            trimmed.hasSuffix(", and") ||
            trimmed.hasSuffix(" or") ||
            trimmed.hasSuffix(", or")
    }

    private static func isDependentIfClause(_ clause: String) -> Bool {
        let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("if ")
    }

    private static func conditionalClauseContainsOwnQuestionComplement(_ clause: String) -> Bool {
        let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        let complementMarkers = [
            " how ", ", how ",
            " what ", ", what ",
            " which ", ", which "
        ]
        guard let complementIndex = firstMarkerIndex(in: trimmed, markers: complementMarkers) else {
            return false
        }
        let laterIndependentStarts = [
            " why do ", " why did ", " why might ",
            " how comfortable ",
            " do you have ",
            " could you ", " can you ", " would you ",
            " tell me ", " walk me "
        ]
        guard let boundaryIndex = firstMarkerIndex(in: trimmed, markers: laterIndependentStarts) else {
            return true
        }
        return complementIndex < boundaryIndex
    }

    private static func isDependentTemporalClause(_ clause: String) -> Bool {
        let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("when ") ||
            trimmed.hasPrefix("while ") ||
            trimmed.hasPrefix("after ") ||
            trimmed.hasPrefix("before ")
    }

    private static func isInlineTemporalTail(_ clause: String) -> Bool {
        let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("before it ") ||
            trimmed.hasPrefix("before they ") ||
            trimmed.hasPrefix("before that ") ||
            trimmed.hasPrefix("before this ") ||
            trimmed.hasPrefix("after it ") ||
            trimmed.hasPrefix("after they ") ||
            trimmed.hasPrefix("when it ") ||
            trimmed.hasPrefix("when they ") ||
            trimmed.hasPrefix("while it ") ||
            trimmed.hasPrefix("while they ")
    }

    private static func isBeforeGerundPhraseBeforeIndependentQuestion(_ clause: String) -> Bool {
        let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("before ") else { return false }
        let words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 3, words[1].hasSuffix("ing") else { return false }
        return [" how ", " what ", " which ", " why "].contains { trimmed.contains($0) }
    }

    private static func isBeforeInterviewerPrefaceBeforeIndependentQuestion(_ clause: String) -> Bool {
        let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        let startsWithPreface = trimmed.hasPrefix("before i ask") ||
            trimmed.hasPrefix("before we ask") ||
            trimmed.hasPrefix("before i explain") ||
            trimmed.hasPrefix("before we explain") ||
            trimmed.hasPrefix("before i tell") ||
            trimmed.hasPrefix("before we tell")
        guard startsWithPreface else { return false }
        return [
            " can you ", " could you ", " would you ",
            " what ", " how ", " why ", " which "
        ].contains { trimmed.contains($0) }
    }

    private static func isNarrativeImperative(precedingText: String, currentClause: String) -> Bool {
        let clause = currentClause.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clause.hasPrefix("explain ") ||
                clause.hasPrefix("describe ") ||
                clause.hasPrefix("talk about ") ||
                clause.hasPrefix("elaborate ") ||
                clause.hasPrefix("imagine ") else {
            return false
        }
        let sentencePrefix = precedingText
            .split(whereSeparator: { ".!?".contains($0) })
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !sentencePrefix.isEmpty else { return false }

        let directRequestPrefixes = [
            "i want you to", "we want you to",
            "i'd like you to", "we'd like you to",
            "i’d like you to", "we’d like you to",
            "i would like you to", "we would like you to"
        ]
        if directRequestPrefixes.contains(sentencePrefix) {
            return false
        }

        let promptQualifiers: Set<String> = [
            "please", "briefly", "kindly", "now", "next", "then", "and", "also", "finally"
        ]
        let prefixWords = sentencePrefix.split(whereSeparator: \.isWhitespace).map(String.init)
        return prefixWords.isEmpty || !prefixWords.allSatisfy(promptQualifiers.contains)
    }

    private static func temporalClauseContainsQuestionComplement(_ clause: String) -> Bool {
        let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        let complementMarkers = [
            " how ", ", how ",
            " what ", ", what ",
            " which ", ", which ",
            " why ", ", why "
        ]
        return complementMarkers.contains { trimmed.contains($0) }
    }

    private static func clauseAlreadyStartedQuestion(_ clause: String) -> Bool {
        let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("what ") ||
            trimmed.hasPrefix("how ") ||
            trimmed.hasPrefix("why ") ||
            trimmed.hasPrefix("which ") ||
            trimmed.hasPrefix("can you ") ||
            trimmed.hasPrefix("could you ") ||
            trimmed.hasPrefix("would you ") ||
            trimmed.hasPrefix("do you ") ||
            trimmed.hasPrefix("did you ") ||
            trimmed.hasPrefix("have you ") ||
            trimmed.hasPrefix("is there ") ||
            trimmed.hasPrefix("was it ") ||
            trimmed.hasPrefix("were you ") ||
            trimmed.hasPrefix("you have ") ||
            trimmed.hasPrefix("prior to your msc") ||
            trimmed.hasPrefix("tell me ") ||
            trimmed.hasPrefix("walk me ") ||
            trimmed.hasPrefix("describe ") ||
            trimmed.hasPrefix("explain ") ||
            trimmed.hasPrefix("imagine ")
    }

    private static func isQuestionTail(_ clause: String) -> Bool {
        let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("how would") ||
            trimmed.hasPrefix("what would") ||
            trimmed.hasPrefix("what ") ||
            trimmed.hasPrefix("how ") ||
            trimmed.hasPrefix("would you") ||
            trimmed.hasPrefix("which part") ||
            trimmed.hasPrefix("which ") ||
            trimmed.hasPrefix("what part") ||
            trimmed.hasPrefix("how did") ||
            trimmed.hasPrefix("were you") ||
            trimmed.hasPrefix("did you") ||
            trimmed.hasPrefix("have you") ||
            trimmed.hasPrefix("why was")
    }

    private static func isBackgroundCompoundContinuation(previousClause: String, currentClause: String) -> Bool {
        let previous = previousClause.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = currentClause.trimmingCharacters(in: .whitespacesAndNewlines)
        guard previous.hasPrefix("what did you do before manchester") else { return false }
        if current.hasPrefix("were you with robotics") {
            return current.contains("background") || current.contains("projects")
        }
        guard previous.contains("were you with robotics") else { return false }
        return current.hasPrefix("what was your background") ||
            current.hasPrefix("what projects") ||
            current.hasPrefix("were you involved")
    }

    private static func isMitigationTail(_ clause: String) -> Bool {
        let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("and how did you mitigate") ||
            trimmed.hasPrefix("how did you mitigate") ||
            trimmed.hasPrefix("and how did mitigate") ||
            trimmed.hasPrefix("how did mitigate") ||
            trimmed.hasPrefix("and how would you mitigate") ||
            trimmed.hasPrefix("how would you mitigate") ||
            trimmed.hasPrefix("and how would mitigate") ||
            trimmed.hasPrefix("how would mitigate")
    }

    private static func firstMarkerIndex(in text: String, markers: [String]) -> String.Index? {
        markers
            .compactMap { text.range(of: $0, options: [.caseInsensitive])?.lowerBound }
            .min()
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
        if lower.hasPrefix("when you when you moved ") {
            cleaned = "When you moved " + String(cleaned.dropFirst("when you when you moved ".count))
            lower = cleaned.lowercased()
        } else if lower.hasPrefix("when you when you move ") {
            cleaned = "When you move " + String(cleaned.dropFirst("when you when you move ".count))
            lower = cleaned.lowercased()
        }

        cleaned = truncateAtTransitionPhrase(cleaned)
        cleaned = QuestionCanonicalizer.canonicalize(cleaned)
        cleaned = QuestionCanonicalizer.removeDanglingQuestionTail(cleaned)
        cleaned = removeTrailingNoise(cleaned)

        while let last = cleaned.last, ".!,;:".contains(last) {
            cleaned.removeLast()
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        cleaned = normalizeDependentTemporalQuestion(cleaned)
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

    private static func normalizeDependentTemporalQuestion(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = cleaned.lowercased()
        guard lower.hasPrefix("before ") else { return cleaned }

        let markers = [" what ", " how ", " which ", " why "]
        guard let markerRange = markers
            .compactMap({ cleaned.range(of: $0, options: [.caseInsensitive]) })
            .min(by: { $0.lowerBound < $1.lowerBound })
        else { return cleaned }

        let prefix = String(cleaned[..<markerRange.lowerBound])
        if !prefix.contains(",") {
            cleaned.insert(",", at: markerRange.lowerBound)
        }

        let normalized = cleaned.lowercased()
        let asksQuestion = [
            " did ", " does ", " do ", " was ", " were ",
            " would ", " could ", " should ", " needed "
        ].contains { normalized.contains($0) }
        if asksQuestion, !cleaned.hasSuffix("?") {
            cleaned.append("?")
        }
        return cleaned
    }
}
