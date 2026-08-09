import Foundation
import Testing
@testable import Hireva

@Suite(.serialized)
struct DialogueScenarioRuntimeTests {
    @Test
    func everyTriggeredTurnHasBoundIdentityGroundingAndPersistenceContract() throws {
        let manifest = try DialogueScenarioFixture.load()
        let profiles = Dictionary(uniqueKeysWithValues: manifest.profiles.map { ($0.id, $0) })
        let opportunities = Dictionary(uniqueKeysWithValues: manifest.opportunities.map { ($0.id, $0) })
        var questionIDs = Set<String>()
        var generationIDs = Set<String>()
        var persistenceLedger: [String: Int] = [:]

        for turn in manifest.turns {
            let profile = try #require(profiles[turn.profileID])
            let opportunity = try #require(opportunities[turn.opportunityID])
            let profileEvidenceIDs = Set(profile.evidence.map(\.id))
            let opportunityEvidenceIDs = Set(opportunity.evidence.map(\.id))

            #expect(Set(turn.allowedCandidateEvidenceIDs).isSubset(of: profileEvidenceIDs))
            #expect(Set(turn.allowedOpportunityEvidenceIDs).isSubset(of: opportunityEvidenceIDs))
            #expect(Set(turn.forbiddenCandidateEvidenceIDs).isDisjoint(with: profileEvidenceIDs))
            #expect(turn.expectedPersistenceCount == (turn.expectedShouldTrigger ? 1 : 0))

            guard turn.expectedShouldTrigger else {
                #expect(turn.expectedAnswer == nil)
                continue
            }

            let questionID = "question-\(turn.scenarioID)"
            let generationID = "generation-\(turn.scenarioID)"
            let contextSnapshotID = "snapshot-\(turn.sessionID)-\(turn.profileID)-\(turn.opportunityID)"
            let identity = GenerationIdentity(
                acceptedQuestionID: questionID,
                generationID: generationID,
                sessionID: turn.sessionID,
                questionText: try #require(turn.expectedPrimaryQuestion),
                promptPrimaryQuestion: try #require(turn.expectedPrimaryQuestion),
                contextSnapshotID: contextSnapshotID
            )
            #expect(identity.mismatchReason(comparedTo: identity) == nil)
            #expect(questionIDs.insert(questionID).inserted)
            #expect(generationIDs.insert(generationID).inserted)

            let staleIdentity = GenerationIdentity(
                acceptedQuestionID: questionID,
                generationID: generationID,
                sessionID: "stale-\(turn.sessionID)",
                questionText: turn.finalText,
                promptPrimaryQuestion: turn.finalText,
                contextSnapshotID: "stale-\(contextSnapshotID)"
            )
            #expect(staleIdentity.mismatchReason(comparedTo: identity) != nil)

            let answer = try #require(turn.expectedAnswer)
            #expect(answer.range(of: #"\b(I|my|me)\b"#, options: [.regularExpression, .caseInsensitive]) != nil)
            let sentenceCount = answer
                .components(separatedBy: CharacterSet(charactersIn: ".?!"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .count
            #expect((1...3).contains(sentenceCount))
            for concept in turn.mustContainConcepts {
                #expect(answer.localizedCaseInsensitiveContains(concept))
            }
            for concept in turn.mustNotContainConcepts {
                #expect(!answer.localizedCaseInsensitiveContains(concept))
            }
            var forbiddenMetadata = ["CV", "JD", "RAG", "Qwen", "system prompt", "model metadata"]
            if turn.finalText.localizedCaseInsensitiveContains("retrieval-augmented generation") {
                forbiddenMetadata.removeAll { $0 == "RAG" }
            }
            for metadata in forbiddenMetadata {
                #expect(!answer.localizedCaseInsensitiveContains(metadata))
            }
            #expect(!QuestionAnswerAlignmentEvaluator.containsGenericCoachingTemplate(answer))
            #expect(QuestionAnswerAlignmentEvaluator.evaluate(
                questionText: try #require(turn.expectedPrimaryQuestion),
                answerText: answer
            ).verdict != .mismatched, "Alignment rejected \(turn.scenarioID): \(turn.finalText) => \(answer)")

            persistenceLedger[generationID, default: 0] += turn.expectedPersistenceCount
        }

        let expectedPersisted = manifest.turns.filter(\.expectedShouldTrigger).count
        #expect(questionIDs.count == expectedPersisted)
        #expect(generationIDs.count == expectedPersisted)
        #expect(persistenceLedger.count == expectedPersisted)
        #expect(persistenceLedger.values.allSatisfy { $0 == 1 })
    }

    @Test
    func identicalQuestionRetrievesOnlyTheSelectedProfileAndOpportunity() throws {
        let manifest = try DialogueScenarioFixture.load()
        var answers = Set<String>()
        var snapshotIDs = Set<String>()

        for profile in manifest.profiles {
            let opportunity = try #require(manifest.opportunities.first {
                $0.id.replacingOccurrences(of: ".opportunity", with: "") ==
                    profile.id.replacingOccurrences(of: ".profile", with: "")
            })
            let candidateEvidence = profile.evidence.map { evidence($0, defaultType: .experience) }
            let opportunityEvidence = opportunity.evidence.map { evidence($0, defaultType: .requiredSkill) }
            let snapshotID = "snapshot-isolation-\(profile.id)"
            let snapshot = InterviewContextSnapshot(
                id: snapshotID,
                sessionID: "session-isolation-\(profile.id)",
                candidateProfileID: profile.id,
                candidateProfileVersion: 1,
                opportunityContextID: opportunity.id,
                opportunityContextVersion: 1,
                domainProfileID: profile.domain,
                candidateEvidence: candidateEvidence,
                opportunityEvidence: opportunityEvidence,
                createdAt: Date(timeIntervalSince1970: 1)
            )

            let result = DynamicInterviewContextEngine().profileSafeFallback(
                question: "Why are you interested in this role, and what experience makes you a strong fit?",
                snapshot: snapshot
            )
            #expect(result.status == .grounded)
            #expect(result.contextSnapshotID == snapshotID)
            #expect(result.unsupportedClaims.isEmpty)
            #expect(!result.candidateEvidenceIDs.isEmpty)
            #expect(Set(result.candidateEvidenceIDs).isSubset(of: Set(profile.evidence.map(\.id))))
            #expect(Set(result.opportunityEvidenceIDs).isSubset(of: Set(opportunity.evidence.map(\.id))))
            answers.insert(result.answer)
            snapshotIDs.insert(result.contextSnapshotID)
        }

        #expect(answers.count == 3)
        #expect(snapshotIDs.count == 3)
    }

    private func evidence(
        _ fixture: DialogueScenarioEvidence,
        defaultType: EvidenceType
    ) -> ProfileEvidence {
        ProfileEvidence(
            id: fixture.id,
            statement: fixture.statement,
            sourceDocumentID: "synthetic-\(fixture.id)",
            sourceChunkID: "synthetic-chunk-\(fixture.id)",
            sourceSpan: fixture.statement,
            confidence: 1,
            evidenceType: EvidenceType(rawValue: fixture.type) ?? defaultType,
            explicitness: .explicit
        )
    }
}
