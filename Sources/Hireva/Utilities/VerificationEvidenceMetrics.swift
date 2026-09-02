import Darwin
import Foundation

/// Writes privacy-safe verification records to a new external JSONL file.
///
/// The final hard-link operation is atomic and fails with `EEXIST` if another
/// process created the destination after the caller validated it. This keeps
/// evidence writers from silently replacing an earlier campaign artifact.
enum VerificationEvidenceFileWriter {
    static func writeFreshJSONLines<Value: Encodable>(
        _ values: [Value],
        to outputURL: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var payload = Data()
        for value in values {
            payload.append(try encoder.encode(value))
            payload.append(0x0A)
        }

        let directory = outputURL.deletingLastPathComponent()
        let stagingURL = directory.appendingPathComponent(
            ".\(outputURL.lastPathComponent).\(UUID().uuidString).staging",
            isDirectory: false
        )
        defer { try? FileManager.default.removeItem(at: stagingURL) }

        try payload.write(to: stagingURL, options: [.atomic])
        guard Darwin.link(stagingURL.path, outputURL.path) == 0 else {
            let errorCode = errno
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errorCode),
                userInfo: [NSLocalizedDescriptionKey: "Unable to create fresh verification evidence file."]
            )
        }
    }
}

/// Privacy-safe ASR comparison values for synthetic verification text.
///
/// The normalized strings are never retained. The record contains only the
/// operation counts needed to audit WER and normalized character distance.
struct VerificationTextMetrics: Codable, Equatable {
    static let normalizationVersion = "hireva-verification-v1"

    let normalizationVersion: String
    let referenceWordCount: Int
    let hypothesisWordCount: Int
    let substitutions: Int
    let deletions: Int
    let insertions: Int
    let wordEditDistance: Int
    let wordErrorRate: Double
    let referenceCharacterCount: Int
    let hypothesisCharacterCount: Int
    let characterEditDistance: Int
    let normalizedCharacterEditDistance: Double

    static func compare(reference: String, hypothesis: String) -> VerificationTextMetrics {
        let normalizedReference = normalize(reference)
        let normalizedHypothesis = normalize(hypothesis)
        let referenceWords = normalizedReference.split(separator: " ").map(String.init)
        let hypothesisWords = normalizedHypothesis.split(separator: " ").map(String.init)
        let alignment = alignWords(reference: referenceWords, hypothesis: hypothesisWords)
        let referenceCharacters = Array(normalizedReference)
        let hypothesisCharacters = Array(normalizedHypothesis)
        let characterDistance = editDistance(referenceCharacters, hypothesisCharacters)
        let characterDenominator = max(referenceCharacters.count, hypothesisCharacters.count)

        return VerificationTextMetrics(
            normalizationVersion: normalizationVersion,
            referenceWordCount: referenceWords.count,
            hypothesisWordCount: hypothesisWords.count,
            substitutions: alignment.substitutions,
            deletions: alignment.deletions,
            insertions: alignment.insertions,
            wordEditDistance: alignment.distance,
            wordErrorRate: wordErrorRate(
                substitutions: alignment.substitutions,
                deletions: alignment.deletions,
                insertions: alignment.insertions,
                referenceWordCount: referenceWords.count
            ),
            referenceCharacterCount: referenceCharacters.count,
            hypothesisCharacterCount: hypothesisCharacters.count,
            characterEditDistance: characterDistance,
            normalizedCharacterEditDistance: characterDenominator == 0
                ? 0
                : Double(characterDistance) / Double(characterDenominator)
        )
    }

    /// Corpus WER is the ratio of summed errors to summed reference words. It
    /// is intentionally not the arithmetic mean of utterance WER values.
    static func aggregate(_ rows: [VerificationTextMetrics]) -> VerificationTextMetrics {
        let referenceWords = rows.reduce(0) { $0 + $1.referenceWordCount }
        let hypothesisWords = rows.reduce(0) { $0 + $1.hypothesisWordCount }
        let substitutions = rows.reduce(0) { $0 + $1.substitutions }
        let deletions = rows.reduce(0) { $0 + $1.deletions }
        let insertions = rows.reduce(0) { $0 + $1.insertions }
        let referenceCharacters = rows.reduce(0) { $0 + $1.referenceCharacterCount }
        let hypothesisCharacters = rows.reduce(0) { $0 + $1.hypothesisCharacterCount }
        let characterDistance = rows.reduce(0) { $0 + $1.characterEditDistance }
        let characterDenominator = rows.reduce(0) {
            $0 + max($1.referenceCharacterCount, $1.hypothesisCharacterCount)
        }

        return VerificationTextMetrics(
            normalizationVersion: normalizationVersion,
            referenceWordCount: referenceWords,
            hypothesisWordCount: hypothesisWords,
            substitutions: substitutions,
            deletions: deletions,
            insertions: insertions,
            wordEditDistance: substitutions + deletions + insertions,
            wordErrorRate: wordErrorRate(
                substitutions: substitutions,
                deletions: deletions,
                insertions: insertions,
                referenceWordCount: referenceWords
            ),
            referenceCharacterCount: referenceCharacters,
            hypothesisCharacterCount: hypothesisCharacters,
            characterEditDistance: characterDistance,
            normalizedCharacterEditDistance: characterDenominator == 0
                ? 0
                : Double(characterDistance) / Double(characterDenominator)
        )
    }

    private struct WordAlignment {
        let distance: Int
        let substitutions: Int
        let deletions: Int
        let insertions: Int
    }

    private struct WordCell {
        let distance: Int
        let substitutions: Int
        let deletions: Int
        let insertions: Int
        let tiePriority: Int
    }

    private static func alignWords(reference: [String], hypothesis: [String]) -> WordAlignment {
        var matrix = Array(
            repeating: Array(
                repeating: WordCell(
                    distance: 0,
                    substitutions: 0,
                    deletions: 0,
                    insertions: 0,
                    tiePriority: 0
                ),
                count: hypothesis.count + 1
            ),
            count: reference.count + 1
        )
        if !reference.isEmpty {
            for index in 1...reference.count {
                matrix[index][0] = WordCell(
                    distance: index,
                    substitutions: 0,
                    deletions: index,
                    insertions: 0,
                    tiePriority: 1
                )
            }
        }
        if !hypothesis.isEmpty {
            for index in 1...hypothesis.count {
                matrix[0][index] = WordCell(
                    distance: index,
                    substitutions: 0,
                    deletions: 0,
                    insertions: index,
                    tiePriority: 2
                )
            }
        }

        if !reference.isEmpty, !hypothesis.isEmpty {
            for referenceIndex in 1...reference.count {
                for hypothesisIndex in 1...hypothesis.count {
                    if reference[referenceIndex - 1] == hypothesis[hypothesisIndex - 1] {
                        matrix[referenceIndex][hypothesisIndex] = matrix[referenceIndex - 1][hypothesisIndex - 1]
                        continue
                    }
                    let diagonal = matrix[referenceIndex - 1][hypothesisIndex - 1]
                    let above = matrix[referenceIndex - 1][hypothesisIndex]
                    let left = matrix[referenceIndex][hypothesisIndex - 1]
                    let candidates = [
                        WordCell(
                            distance: diagonal.distance + 1,
                            substitutions: diagonal.substitutions + 1,
                            deletions: diagonal.deletions,
                            insertions: diagonal.insertions,
                            tiePriority: 0
                        ),
                        WordCell(
                            distance: above.distance + 1,
                            substitutions: above.substitutions,
                            deletions: above.deletions + 1,
                            insertions: above.insertions,
                            tiePriority: 1
                        ),
                        WordCell(
                            distance: left.distance + 1,
                            substitutions: left.substitutions,
                            deletions: left.deletions,
                            insertions: left.insertions + 1,
                            tiePriority: 2
                        ),
                    ]
                    matrix[referenceIndex][hypothesisIndex] = candidates.min {
                        ($0.distance, $0.tiePriority) < ($1.distance, $1.tiePriority)
                    } ?? candidates[0]
                }
            }
        }

        let final = matrix[reference.count][hypothesis.count]
        return WordAlignment(
            distance: final.distance,
            substitutions: final.substitutions,
            deletions: final.deletions,
            insertions: final.insertions
        )
    }

    private static func editDistance<Element: Equatable>(_ lhs: [Element], _ rhs: [Element]) -> Int {
        guard !lhs.isEmpty else { return rhs.count }
        guard !rhs.isEmpty else { return lhs.count }
        var previous = Array(0...rhs.count)
        for (lhsIndex, lhsValue) in lhs.enumerated() {
            var current = Array(repeating: 0, count: rhs.count + 1)
            current[0] = lhsIndex + 1
            for (rhsIndex, rhsValue) in rhs.enumerated() {
                let substitution = previous[rhsIndex] + (lhsValue == rhsValue ? 0 : 1)
                current[rhsIndex + 1] = min(
                    substitution,
                    previous[rhsIndex + 1] + 1,
                    current[rhsIndex] + 1
                )
            }
            previous = current
        }
        return previous[rhs.count]
    }

    private static func normalize(_ text: String) -> String {
        var value = text.replacingOccurrences(
            of: #"\[\[[^\]]*\]\]"#,
            with: " ",
            options: .regularExpression
        )
        value = value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
        value = replacingNumbersWithWords(value)

        var normalized = ""
        var previousWasSpace = true
        for scalar in value.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                normalized.unicodeScalars.append(scalar)
                previousWasSpace = false
            } else if !previousWasSpace {
                normalized.append(" ")
                previousWasSpace = true
            }
        }
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacingNumbersWithWords(_ text: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?<![\p{L}\p{N}])\d[\d,]*(?:\.\d+)?(?![\p{L}\p{N}])"#
        ) else { return text }
        let decimal = NumberFormatter()
        decimal.locale = Locale(identifier: "en_US_POSIX")
        decimal.numberStyle = .decimal
        decimal.isLenient = false
        let spellOut = NumberFormatter()
        spellOut.locale = Locale(identifier: "en_US")
        spellOut.numberStyle = .spellOut

        var result = text
        let range = NSRange(location: 0, length: (result as NSString).length)
        for match in expression.matches(in: result, range: range).reversed() {
            let token = (result as NSString).substring(with: match.range)
            guard let number = decimal.number(from: token),
                  let words = spellOut.string(from: number) else { continue }
            result = (result as NSString).replacingCharacters(in: match.range, with: words)
        }
        return result
    }

    private static func wordErrorRate(
        substitutions: Int,
        deletions: Int,
        insertions: Int,
        referenceWordCount: Int
    ) -> Double {
        let errors = substitutions + deletions + insertions
        if referenceWordCount == 0 {
            return errors == 0 ? 0 : Double(errors)
        }
        return Double(errors) / Double(referenceWordCount)
    }
}

struct VerificationPercentileSummary: Codable, Equatable {
    let count: Int
    let p50: Double?
    let p90: Double?
    let p95: Double?
    let p99: Double?
    let maximum: Double?
}

enum VerificationPercentiles {
    static func nearestRank(_ values: [Double]) -> VerificationPercentileSummary {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else {
            return VerificationPercentileSummary(
                count: 0,
                p50: nil,
                p90: nil,
                p95: nil,
                p99: nil,
                maximum: nil
            )
        }
        func percentile(_ fraction: Double) -> Double {
            let rank = max(1, Int(ceil(fraction * Double(sorted.count))))
            return sorted[min(sorted.count - 1, rank - 1)]
        }
        return VerificationPercentileSummary(
            count: sorted.count,
            p50: percentile(0.50),
            p90: percentile(0.90),
            p95: percentile(0.95),
            p99: percentile(0.99),
            maximum: sorted.last
        )
    }
}

struct VerificationAnswerRubricInput {
    let scenarioID: String
    let expectedSessionID: String
    let actualSessionID: String
    let expectedQuestionID: String
    let actualQuestionID: String
    let expectedGenerationID: String
    let actualGenerationID: String
    let expectedContextSnapshotID: String
    let actualContextSnapshotID: String
    let expectedCandidateProfileID: String
    let actualCandidateProfileID: String
    let expectedOpportunityContextID: String
    let actualOpportunityContextID: String
    let questionText: String
    let answerText: String
    let candidateEvidence: [ProfileEvidence]
    let opportunityEvidence: [ProfileEvidence]
    let futurePlans: [String]
    let allowedCandidateEvidenceIDs: Set<String>
    let allowedOpportunityEvidenceIDs: Set<String>
    let actualCandidateEvidenceIDs: Set<String>
    let actualOpportunityEvidenceIDs: Set<String>
    let requiredConcepts: [String]
    let forbiddenClaims: [String]
    let expectedProviderSource: String
    let actualProviderSource: String
    let persistenceCount: Int
    let maximumSentences: Int
}

struct VerificationAnswerRubricRecord: Codable, Equatable {
    let scenarioID: String
    let sessionID: String
    let questionID: String
    let generationID: String
    let contextSnapshotID: String
    let relevance: Int
    let evidenceGrounding: Int
    let directness: Int
    let spokenFluency: Int
    let completeness: Int
    let roleFit: Int
    let alignmentScore: Double
    let requiredConceptHits: Int
    let requiredConceptTotal: Int
    let forbiddenClaimHits: Int
    let candidateEvidenceUsedCount: Int
    let opportunityEvidenceUsedCount: Int
    let persistenceCount: Int
    let unsupportedPersonalClaim: Bool
    let wrongProfileEvidence: Bool
    let wrongJobContext: Bool
    let staleAnswer: Bool
    let duplicatePersistence: Bool
    let providerSourceMislabel: Bool
    let answerQuestionIdentityMismatch: Bool
    let contextBleed: Bool
    let jdToExperience: Bool
    let futureToPast: Bool
    let hardFail: Bool

    var eventFields: [String: Any] {
        [
            "scenarioID": scenarioID,
            "sessionID": sessionID,
            "questionID": questionID,
            "generationID": generationID,
            "contextSnapshotID": contextSnapshotID,
            "relevance": relevance,
            "evidenceGrounding": evidenceGrounding,
            "directness": directness,
            "spokenFluency": spokenFluency,
            "completeness": completeness,
            "roleFit": roleFit,
            "alignmentScore": alignmentScore,
            "requiredConceptHits": requiredConceptHits,
            "requiredConceptTotal": requiredConceptTotal,
            "forbiddenClaimHits": forbiddenClaimHits,
            "candidateEvidenceUsedCount": candidateEvidenceUsedCount,
            "opportunityEvidenceUsedCount": opportunityEvidenceUsedCount,
            "persistenceCount": persistenceCount,
            "unsupportedPersonalClaim": unsupportedPersonalClaim,
            "wrongProfileEvidence": wrongProfileEvidence,
            "wrongJobContext": wrongJobContext,
            "staleAnswer": staleAnswer,
            "duplicatePersistence": duplicatePersistence,
            "providerSourceMislabel": providerSourceMislabel,
            "answerQuestionIdentityMismatch": answerQuestionIdentityMismatch,
            "contextBleed": contextBleed,
            "jdToExperience": jdToExperience,
            "futureToPast": futureToPast,
            "hardFail": hardFail,
        ]
    }

    static let safeEventFieldsForTesting = VerificationAnswerRubricRecord(
        scenarioID: "scenario-1",
        sessionID: "session-1",
        questionID: "question-1",
        generationID: "generation-1",
        contextSnapshotID: "snapshot-1",
        relevance: 5,
        evidenceGrounding: 5,
        directness: 3,
        spokenFluency: 3,
        completeness: 3,
        roleFit: 3,
        alignmentScore: 1,
        requiredConceptHits: 1,
        requiredConceptTotal: 1,
        forbiddenClaimHits: 0,
        candidateEvidenceUsedCount: 1,
        opportunityEvidenceUsedCount: 0,
        persistenceCount: 1,
        unsupportedPersonalClaim: false,
        wrongProfileEvidence: false,
        wrongJobContext: false,
        staleAnswer: false,
        duplicatePersistence: false,
        providerSourceMislabel: false,
        answerQuestionIdentityMismatch: false,
        contextBleed: false,
        jdToExperience: false,
        futureToPast: false,
        hardFail: false
    ).eventFields
}

enum VerificationAnswerRubricEvaluator {
    static func evaluate(_ input: VerificationAnswerRubricInput) -> VerificationAnswerRubricRecord {
        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: input.questionText,
            answerText: input.answerText,
            sayFirst: input.answerText,
            stageBCompleted: true
        )
        let grounding = AnswerClaimValidator().validate(
            answer: input.answerText,
            candidateEvidence: input.candidateEvidence,
            opportunityEvidence: input.opportunityEvidence,
            domainKnowledge: []
        )
        let normalizedAnswer = normalize(input.answerText)
        let requiredHits = input.requiredConcepts.filter {
            normalizedAnswer.contains(normalize($0))
        }.count
        let forbiddenHits = input.forbiddenClaims.filter {
            normalizedAnswer.contains(normalize($0))
        }.count
        let wrongProfile = input.expectedCandidateProfileID != input.actualCandidateProfileID ||
            !input.actualCandidateEvidenceIDs.isSubset(of: input.allowedCandidateEvidenceIDs)
        let wrongJob = input.expectedOpportunityContextID != input.actualOpportunityContextID ||
            !input.actualOpportunityEvidenceIDs.isSubset(of: input.allowedOpportunityEvidenceIDs)
        let answerQuestionIdentityMismatch = input.expectedQuestionID != input.actualQuestionID
        let contextBleed = input.expectedContextSnapshotID != input.actualContextSnapshotID
        let staleAnswer = input.expectedSessionID != input.actualSessionID ||
            input.expectedGenerationID != input.actualGenerationID ||
            answerQuestionIdentityMismatch || contextBleed
        let duplicatePersistence = input.persistenceCount > 1
        let providerSourceMislabel = input.expectedProviderSource != input.actualProviderSource
        let unsupported = !grounding.unsupportedClaims.isEmpty || forbiddenHits > 0
        let jdToExperience = personalPastClaim(
            in: input.answerText,
            overlaps: input.opportunityEvidence.map(\.statement),
            butNot: input.candidateEvidence.map(\.statement)
        )
        let futureToPast = personalPastClaim(
            in: input.answerText,
            overlaps: input.futurePlans,
            butNot: input.candidateEvidence.map(\.statement)
        )
        let complete = QuestionAnswerAlignmentEvaluator.isAnswerComplete(input.answerText)
        let firstPerson = containsFirstPerson(input.answerText)
        let generic = QuestionAnswerAlignmentEvaluator.containsGenericCoachingTemplate(input.answerText)
        let wordCount = normalizedAnswer.split(separator: " ").count
        let sentences = sentenceCount(input.answerText)
        let conceptsComplete = input.requiredConcepts.isEmpty || requiredHits == input.requiredConcepts.count

        let relevance: Int
        switch alignment.verdict {
        case .aligned:
            relevance = max(3, min(5, Int((alignment.score * 5).rounded())))
        case .weaklyAligned:
            relevance = max(2, min(3, Int((alignment.score * 5).rounded())))
        case .mismatched:
            relevance = min(2, max(0, Int((alignment.score * 5).rounded())))
        case .unknown:
            relevance = 0
        }
        let evidenceGrounding = (!unsupported && !wrongProfile && !wrongJob) ? 5 : 0
        let directness = firstPerson && !generic ? 3 : (input.answerText.isEmpty ? 0 : (firstPerson ? 2 : 1))
        let spokenFluency: Int
        if complete, wordCount <= 90, (1...max(1, input.maximumSentences)).contains(sentences) {
            spokenFluency = 3
        } else if complete, wordCount <= 150 {
            spokenFluency = 2
        } else {
            spokenFluency = input.answerText.isEmpty ? 0 : 1
        }
        let completeness = complete && conceptsComplete ? 3 : (complete ? 2 : (input.answerText.isEmpty ? 0 : 1))
        let roleFit = alignment.verdict == .aligned && !wrongJob ? 3 : (alignment.verdict == .mismatched ? 0 : 2)
        let hardFail = unsupported || wrongProfile || wrongJob || staleAnswer ||
            input.persistenceCount != 1 || providerSourceMislabel ||
            jdToExperience || futureToPast

        return VerificationAnswerRubricRecord(
            scenarioID: input.scenarioID,
            sessionID: input.actualSessionID,
            questionID: input.actualQuestionID,
            generationID: input.actualGenerationID,
            contextSnapshotID: input.actualContextSnapshotID,
            relevance: relevance,
            evidenceGrounding: evidenceGrounding,
            directness: directness,
            spokenFluency: spokenFluency,
            completeness: completeness,
            roleFit: roleFit,
            alignmentScore: alignment.score,
            requiredConceptHits: requiredHits,
            requiredConceptTotal: input.requiredConcepts.count,
            forbiddenClaimHits: forbiddenHits,
            candidateEvidenceUsedCount: input.actualCandidateEvidenceIDs.count,
            opportunityEvidenceUsedCount: input.actualOpportunityEvidenceIDs.count,
            persistenceCount: input.persistenceCount,
            unsupportedPersonalClaim: unsupported,
            wrongProfileEvidence: wrongProfile,
            wrongJobContext: wrongJob,
            staleAnswer: staleAnswer,
            duplicatePersistence: duplicatePersistence,
            providerSourceMislabel: providerSourceMislabel,
            answerQuestionIdentityMismatch: answerQuestionIdentityMismatch,
            contextBleed: contextBleed,
            jdToExperience: jdToExperience,
            futureToPast: futureToPast,
            hardFail: hardFail
        )
    }

    private static func normalize(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }

    private static func containsFirstPerson(_ text: String) -> Bool {
        let tokens = Set(normalize(text).split(separator: " ").map(String.init))
        return !tokens.isDisjoint(with: ["i", "my", "me", "we", "our", "us"])
    }

    private static func sentenceCount(_ text: String) -> Int {
        text.components(separatedBy: CharacterSet(charactersIn: ".?!"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .count
    }

    private static func personalPastClaim(
        in answer: String,
        overlaps evidence: [String],
        butNot candidateEvidence: [String]
    ) -> Bool {
        guard !evidence.isEmpty else { return false }
        let pastPattern = #"\b(?:i|we|my|our)\b[^.!?\n]{0,100}\b(?:built|developed|implemented|led|owned|worked|used|designed|delivered|improved|reduced|completed|published|deployed|trained|evaluated|validated|tested|integrated|contributed|achieved|demonstrated)\b"#
        let sentences = answer.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
        for sentence in sentences where sentence.range(
            of: pastPattern,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            let claimTokens = meaningfulTokens(sentence)
            let evidenceOverlap = evidence.map(meaningfulTokens).map { claimTokens.intersection($0).count }.max() ?? 0
            let candidateOverlap = candidateEvidence.map(meaningfulTokens).map { claimTokens.intersection($0).count }.max() ?? 0
            if evidenceOverlap >= 2, candidateOverlap < evidenceOverlap {
                return true
            }
        }
        return false
    }

    private static func meaningfulTokens(_ text: String) -> Set<String> {
        let stop: Set<String> = [
            "the", "and", "that", "with", "from", "this", "into", "for", "was", "were",
            "have", "has", "had", "will", "would", "plan", "after", "before", "role", "requires",
            "i", "my", "we", "our", "to", "a", "an", "of", "in", "on",
        ]
        return Set(normalize(text).split(separator: " ").map(String.init).filter {
            $0.count > 2 && !stop.contains($0)
        })
    }
}
