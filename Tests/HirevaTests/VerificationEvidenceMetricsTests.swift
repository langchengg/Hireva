import Foundation
import Testing
@testable import Hireva

@Suite(.serialized)
struct VerificationEvidenceMetricsTests {
    private struct FileRecord: Codable, Equatable {
        let sequence: Int
        let status: String
    }

    @Test
    func freshEvidenceWriterCreatesJSONLAndNeverOverwritesExistingEvidence() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hireva-evidence-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("metrics.jsonl")
        let original = [
            FileRecord(sequence: 1, status: "accepted"),
            FileRecord(sequence: 2, status: "rejected")
        ]

        try VerificationEvidenceFileWriter.writeFreshJSONLines(original, to: outputURL)
        let originalData = try Data(contentsOf: outputURL)
        let lines = try #require(String(data: originalData, encoding: .utf8))
            .split(separator: "\n")
        #expect(lines.count == 2)
        #expect(try JSONDecoder().decode(FileRecord.self, from: Data(lines[0].utf8)) == original[0])

        #expect(throws: (any Error).self) {
            try VerificationEvidenceFileWriter.writeFreshJSONLines(
                [FileRecord(sequence: 3, status: "replacement")],
                to: outputURL
            )
        }
        #expect(try Data(contentsOf: outputURL) == originalData)
    }

    @Test
    func wordErrorsRetainSubstitutionInsertionDeletionAndAggregateCounts() {
        let substitutedAndInserted = VerificationTextMetrics.compare(
            reference: "alpha beta gamma",
            hypothesis: "alpha delta gamma extra"
        )
        let deleted = VerificationTextMetrics.compare(
            reference: "one two three",
            hypothesis: "one three"
        )

        #expect(substitutedAndInserted.normalizationVersion == "hireva-verification-v1")
        #expect(substitutedAndInserted.referenceWordCount == 3)
        #expect(substitutedAndInserted.hypothesisWordCount == 4)
        #expect(substitutedAndInserted.substitutions == 1)
        #expect(substitutedAndInserted.insertions == 1)
        #expect(substitutedAndInserted.deletions == 0)
        #expect(substitutedAndInserted.wordEditDistance == 2)
        #expect(abs(substitutedAndInserted.wordErrorRate - (2.0 / 3.0)) < 0.000_001)
        #expect(deleted.deletions == 1)

        let aggregate = VerificationTextMetrics.aggregate([substitutedAndInserted, deleted])
        #expect(aggregate.referenceWordCount == 6)
        #expect(aggregate.substitutions == 1)
        #expect(aggregate.insertions == 1)
        #expect(aggregate.deletions == 1)
        #expect(abs(aggregate.wordErrorRate - 0.5) < 0.000_001)
    }

    @Test
    func textNormalizationRemovesSpeechCommandsAndReportsCharacterDistance() {
        let exact = VerificationTextMetrics.compare(
            reference: "[[slnc 900]] Twenty percent — café",
            hypothesis: "twenty percent cafe"
        )
        let changed = VerificationTextMetrics.compare(
            reference: "robot",
            hypothesis: "robots"
        )

        #expect(exact.wordErrorRate == 0)
        #expect(exact.normalizedCharacterEditDistance == 0)
        #expect(changed.characterEditDistance == 1)
        #expect(abs(changed.normalizedCharacterEditDistance - (1.0 / 6.0)) < 0.000_001)
    }

    @Test
    func nearestRankSummaryIncludesAllRequiredPercentiles() {
        let summary = VerificationPercentiles.nearestRank([1, 2, 3, 4, 5, 6, 7, 8, 9, 10])

        #expect(summary.count == 10)
        #expect(summary.p50 == 5)
        #expect(summary.p90 == 9)
        #expect(summary.p95 == 10)
        #expect(summary.p99 == 10)
        #expect(summary.maximum == 10)
        #expect(VerificationPercentiles.nearestRank([]).count == 0)
    }

    @Test
    func answerRubricSeparatesScoresFromHardFailures() {
        let candidateEvidence = [evidence(
            id: "candidate.pipeline",
            statement: "Built a synthetic event pipeline and validated recovery with replay tests"
        )]
        let opportunityEvidence = [evidence(
            id: "role.observability",
            statement: "The role requires production observability and incident response"
        )]
        let safe = VerificationAnswerRubricEvaluator.evaluate(VerificationAnswerRubricInput(
            scenarioID: "safe",
            expectedSessionID: "session-1",
            actualSessionID: "session-1",
            expectedQuestionID: "question-1",
            actualQuestionID: "question-1",
            expectedGenerationID: "generation-1",
            actualGenerationID: "generation-1",
            expectedContextSnapshotID: "snapshot-1",
            actualContextSnapshotID: "snapshot-1",
            expectedCandidateProfileID: "profile-1",
            actualCandidateProfileID: "profile-1",
            expectedOpportunityContextID: "role-1",
            actualOpportunityContextID: "role-1",
            questionText: "How did you validate recovery in the event pipeline?",
            answerText: "I built a synthetic event pipeline and validated recovery with replay tests.",
            candidateEvidence: candidateEvidence,
            opportunityEvidence: opportunityEvidence,
            futurePlans: [],
            allowedCandidateEvidenceIDs: ["candidate.pipeline"],
            allowedOpportunityEvidenceIDs: ["role.observability"],
            actualCandidateEvidenceIDs: ["candidate.pipeline"],
            actualOpportunityEvidenceIDs: [],
            requiredConcepts: ["replay tests"],
            forbiddenClaims: ["one million users"],
            expectedProviderSource: "ollama_qwen",
            actualProviderSource: "ollama_qwen",
            persistenceCount: 1,
            maximumSentences: 4
        ))

        #expect(safe.relevance >= 4)
        #expect(safe.evidenceGrounding == 5)
        #expect(safe.directness == 3)
        #expect(safe.spokenFluency == 3)
        #expect(safe.completeness == 3)
        #expect(!safe.hardFail)

        let deniedMissingExperience = VerificationAnswerRubricEvaluator.evaluate(
            VerificationAnswerRubricInput(
                scenarioID: "denied-missing-experience",
                expectedSessionID: "session-1",
                actualSessionID: "session-1",
                expectedQuestionID: "question-2",
                actualQuestionID: "question-2",
                expectedGenerationID: "generation-2",
                actualGenerationID: "generation-2",
                expectedContextSnapshotID: "snapshot-2",
                actualContextSnapshotID: "snapshot-2",
                expectedCandidateProfileID: "profile-1",
                actualCandidateProfileID: "profile-1",
                expectedOpportunityContextID: "role-1",
                actualOpportunityContextID: "role-1",
                questionText: "Tell me about a difficult decision involving simulation and real-robot evaluation.",
                answerText: "I do not have evidence for a completed difficult decision about the requirement to compare simulation and real-robot behavior, so I would not invent one. I would test the options, choose an action, and measure the result before answering with a documented example.",
                candidateEvidence: [],
                opportunityEvidence: [evidence(
                    id: "role.requirement",
                    statement: "Compare simulation and real-robot behavior with a documented evaluation"
                )],
                futurePlans: [],
                allowedCandidateEvidenceIDs: [],
                allowedOpportunityEvidenceIDs: ["role.requirement"],
                actualCandidateEvidenceIDs: [],
                actualOpportunityEvidenceIDs: ["role.requirement"],
                requiredConcepts: ["do not have evidence", "decision"],
                forbiddenClaims: [],
                expectedProviderSource: "ollama_qwen",
                actualProviderSource: "ollama_qwen",
                persistenceCount: 1,
                maximumSentences: 4
            )
        )
        #expect(!deniedMissingExperience.jdToExperience)
        #expect(!deniedMissingExperience.hardFail)

        let unsafe = VerificationAnswerRubricEvaluator.evaluate(VerificationAnswerRubricInput(
            scenarioID: "unsafe",
            expectedSessionID: "session-1",
            actualSessionID: "session-2",
            expectedQuestionID: "question-1",
            actualQuestionID: "question-old",
            expectedGenerationID: "generation-1",
            actualGenerationID: "generation-old",
            expectedContextSnapshotID: "snapshot-1",
            actualContextSnapshotID: "snapshot-old",
            expectedCandidateProfileID: "profile-1",
            actualCandidateProfileID: "profile-old",
            expectedOpportunityContextID: "role-1",
            actualOpportunityContextID: "role-old",
            questionText: "How would you approach production observability?",
            answerText: "I delivered production observability to one million users.",
            candidateEvidence: candidateEvidence,
            opportunityEvidence: opportunityEvidence,
            futurePlans: ["Plan to add production observability after validation"],
            allowedCandidateEvidenceIDs: ["candidate.pipeline"],
            allowedOpportunityEvidenceIDs: ["role.observability"],
            actualCandidateEvidenceIDs: ["candidate.other"],
            actualOpportunityEvidenceIDs: ["role.observability"],
            requiredConcepts: ["incident response"],
            forbiddenClaims: ["one million users"],
            expectedProviderSource: "ollama_qwen",
            actualProviderSource: "apple_speech",
            persistenceCount: 2,
            maximumSentences: 4
        ))

        #expect(unsafe.unsupportedPersonalClaim)
        #expect(unsafe.wrongProfileEvidence)
        #expect(unsafe.wrongJobContext)
        #expect(unsafe.staleAnswer)
        #expect(unsafe.duplicatePersistence)
        #expect(unsafe.providerSourceMislabel)
        #expect(unsafe.answerQuestionIdentityMismatch)
        #expect(unsafe.jdToExperience)
        #expect(unsafe.futureToPast)
        #expect(unsafe.hardFail)
    }

    @Test
    func personalPastClaimRequiresAnExplicitPredicateAndKeepsCommonParaphrases() {
        #expect(roleClaimRecord("I've built and deployed production observability.").jdToExperience)
        #expect(roleClaimRecord("My team built and deployed production observability.").jdToExperience)
        #expect(!roleClaimRecord(
            "I have not built or deployed production observability. I would validate it before making that claim."
        ).jdToExperience)
    }

    private func roleClaimRecord(_ answer: String) -> VerificationAnswerRubricRecord {
        VerificationAnswerRubricEvaluator.evaluate(VerificationAnswerRubricInput(
            scenarioID: "role-claim",
            expectedSessionID: "session-1",
            actualSessionID: "session-1",
            expectedQuestionID: "question-1",
            actualQuestionID: "question-1",
            expectedGenerationID: "generation-1",
            actualGenerationID: "generation-1",
            expectedContextSnapshotID: "snapshot-1",
            actualContextSnapshotID: "snapshot-1",
            expectedCandidateProfileID: "profile-1",
            actualCandidateProfileID: "profile-1",
            expectedOpportunityContextID: "role-1",
            actualOpportunityContextID: "role-1",
            questionText: "Tell me about your production observability experience.",
            answerText: answer,
            candidateEvidence: [],
            opportunityEvidence: [evidence(
                id: "role.observability",
                statement: "Built and deployed production observability"
            )],
            futurePlans: [],
            allowedCandidateEvidenceIDs: [],
            allowedOpportunityEvidenceIDs: ["role.observability"],
            actualCandidateEvidenceIDs: [],
            actualOpportunityEvidenceIDs: ["role.observability"],
            requiredConcepts: [],
            forbiddenClaims: [],
            expectedProviderSource: "ollama_qwen",
            actualProviderSource: "ollama_qwen",
            persistenceCount: 1,
            maximumSentences: 4
        ))
    }

    private func evidence(id: String, statement: String) -> ProfileEvidence {
        ProfileEvidence(
            id: id,
            statement: statement,
            sourceDocumentID: "synthetic-verification",
            sourceChunkID: id,
            sourceSpan: nil,
            confidence: 1,
            evidenceType: .project,
            explicitness: .explicit
        )
    }
}
