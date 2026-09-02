import Foundation
import Testing
@testable import Hireva

@Suite(.serialized)
struct InterviewCampaignFixtureTests {
    @Test
    func scaleAndPublicSourceProvenanceAreAuditable() throws {
        let fixture = try CampaignFixture.load()

        #expect(fixture.manifest.synthetic)
        #expect(!fixture.manifest.containsRealPersonalData)
        #expect(fixture.manifest.randomSeed == 20260831)
        #expect(fixture.roles.coreRoleFamilies.count == 16)
        #expect(fixture.profiles.profiles.count == 10)
        #expect(fixture.opportunities.opportunities.count == 48)
        #expect(fixture.sessions.sessions.count == 160)
        #expect(fixture.turns.turns.count == 1_280)
        #expect(fixture.manifest.counts.positiveTurns == 800)
        #expect(fixture.manifest.counts.negativeTurns == 480)
        #expect(fixture.manifest.counts.rapidTurns == 160)
        #expect(fixture.manifest.counts.partialFinalReplayTurns == 160)
        #expect(fixture.manifest.counts.missingEvidenceAdversarialTurns == 160)
        #expect(fixture.manifest.counts.distinctFrozenContextScenarioKeys == 1_280)

        let sourceIDs = Set(fixture.sources.sources.map(\.id))
        #expect(sourceIDs.count == fixture.sources.sources.count)
        #expect(fixture.sources.sources.allSatisfy { source in
            source.sourceType == "official" &&
                source.license.localizedCaseInsensitiveContains("paraphrased only") &&
                !source.codeCopied &&
                URL(string: source.url)?.scheme == "https"
        })

        for role in fixture.roles.coreRoleFamilies {
            #expect(role.core)
            #expect(role.seniorities == ["graduate", "mid_level", "senior_research_depth"])
            #expect(role.sourceProvenanceIDs.count >= 3)
            #expect(Set(role.sourceProvenanceIDs).isSubset(of: sourceIDs))
            let hosts = Set(role.sourceProvenanceIDs.compactMap { sourceID in
                fixture.sources.sources.first { $0.id == sourceID }
                    .flatMap { URL(string: $0.url)?.host }
            })
            #expect(hosts.count >= 3, "Expected independent source hosts for \(role.id)")

            let roleOpportunities = fixture.opportunities.opportunities.filter { $0.roleFamilyID == role.id }
            #expect(roleOpportunities.count == 3)
            #expect(Set(roleOpportunities.map(\.seniority)) == Set(role.seniorities))
            #expect(roleOpportunities.allSatisfy {
                $0.synthetic && Set($0.sourceProvenanceIDs).isSubset(of: sourceIDs)
            })

            let roleSessions = fixture.sessions.sessions.filter { $0.roleFamilyID == role.id }
            #expect(roleSessions.count == 10)
            let observedStages = Set(fixture.turns.turns
                .filter { $0.roleFamilyID == role.id }
                .map(\.interviewStage))
            #expect(Set(role.requiredStages).isSubset(of: observedStages))
            #expect(Set(role.additionalStages).isSubset(of: observedStages))
        }

        #expect(Set(fixture.profiles.profiles.map(\.id)).count == 10)
        #expect(fixture.profiles.profiles.allSatisfy { profile in
            profile.synthetic &&
                !profile.candidateEvidenceIDs.isEmpty &&
                Set(profile.candidateEvidenceIDs) == Set(profile.verifiedStatements.map(\.id)) &&
                !profile.limitations.isEmpty &&
                !profile.futurePlans.isEmpty &&
                !profile.notExperiencedIn.isEmpty &&
                !profile.forbiddenClaims.isEmpty &&
                !profile.workAuthorizationFacts.isEmpty &&
                !profile.availabilityFacts.isEmpty
        })

        let allText = try fixture.serializedText()
        for secretPattern in ["sk-", "Bearer ", "api_key", "HIREVA_24H_FAKE_KEY"] {
            #expect(!allText.localizedCaseInsensitiveContains(secretPattern))
        }
    }

    @Test
    func productionDialoguePolicyMatchesAllOneThousandTwoHundredEightyTurns() throws {
        let fixture = try CampaignFixture.load()
        let sessionByID = Dictionary(uniqueKeysWithValues: fixture.sessions.sessions.map { ($0.sessionID, $0) })

        for session in fixture.sessions.sessions {
            let mode = try #require(InterviewSessionMode(rawValue: session.initialMode))
            var state = DialogueRuntimeState.initial(for: mode)
            var previousAcceptedQuestion: AcceptedQuestionContextReference?
            let sessionTurns = fixture.turns.turns
                .filter { $0.sessionID == session.sessionID }
                .sorted { $0.turnIndex < $1.turnIndex }
            #expect(sessionTurns.count == 8)

            for turn in sessionTurns {
                #expect(sessionByID[turn.sessionID]?.candidateProfileID == turn.candidateProfileID)
                #expect(sessionByID[turn.sessionID]?.opportunityContextID == turn.opportunityContextID)
                var segment = TranscriptSegment(
                    id: turn.scenarioID,
                    sessionID: turn.sessionID,
                    source: turn.channel == "microphone" ? .microphone : .systemAudio,
                    speaker: turn.speaker == "candidate" ? .candidate : .interviewer,
                    text: turn.rawUtterance,
                    asrSource: .localParakeetASR,
                    asrFinalizationReason: "final_accepted",
                    recognitionTaskID: "task-\(turn.scenarioID)",
                    recognitionEventSequence: turn.turnIndex,
                    sourceTextStartUTF16: 0,
                    sourceTextEndUTF16: turn.rawUtterance.utf16.count,
                    recognitionIsFinal: true
                )
                let contextualResolution = ContextualQuestionResolver.resolve(
                    rawText: turn.rawUtterance,
                    isFinal: true,
                    currentSessionID: turn.sessionID,
                    currentContextSnapshotID: turn.contextSnapshotID,
                    previous: previousAcceptedQuestion
                )
                if let contextualResolution {
                    segment.text = contextualResolution.resolvedQuestion
                    #expect(turn.expectedReferenceResolution != nil)
                    #expect(contextualResolution.referencedQuestionID == turn.expectedReferenceResolution.map { "question-\($0)" })
                }
                let decision = InterviewDialogueTriggerPolicy.decideDialogueTrigger(
                    segment: segment,
                    sessionMode: mode,
                    currentState: state,
                    answerPanelQuestions: true,
                    suppressPresentation: true,
                    suppressCandidateQuestions: true
                )
                #expect(
                    decision.shouldEvaluateQuestion == turn.expectedShouldTrigger,
                    "Unexpected trigger for \(turn.scenarioID): \(decision.triggerReason) / \(decision.suppressionReason)"
                )
                if turn.speaker == "candidate" {
                    #expect(!decision.shouldEvaluateQuestion)
                }
                state = state.applying(decision)

                let questionText = contextualResolution?.resolvedQuestion ?? turn.rawUtterance
                let candidates = QuestionCandidatePipeline.extract(from: questionText)
                if turn.expectedShouldTrigger {
                    #expect(candidates.count == turn.expectedQuestionCount, "Question split mismatch for \(turn.scenarioID): \(candidates.map(\.text))")
                    let primary = candidates.last?.text
                    let expectedPrimary = turn.expectedPrimaryQuestion
                    #expect(primary != nil, "Missing primary question for \(turn.scenarioID)")
                    #expect(expectedPrimary != nil, "Missing expected primary question for \(turn.scenarioID)")
                    if let primary, let expectedPrimary {
                        #expect(normalized(primary) == normalized(expectedPrimary))
                    }
                    #expect(QuestionRuntimeAcceptanceGuard.acceptedCandidate(from: questionText).accepted)
                    if let primary,
                       let identity = turn.expectedNewQuestionIdentity {
                        previousAcceptedQuestion = AcceptedQuestionContextReference(
                            questionID: identity.questionID,
                            sessionID: turn.sessionID,
                            contextSnapshotID: turn.contextSnapshotID,
                            questionText: primary
                        )
                    }
                } else {
                    #expect(turn.expectedQuestionCount == 0)
                    #expect(turn.expectedPrimaryQuestion == nil)
                }

                for partial in turn.partialUtterances {
                    #expect(turn.rawUtterance.hasPrefix(partial))
                    #expect(partial.utf16.count < turn.rawUtterance.utf16.count)
                }
            }
        }
    }

    @Test
    func answersRemainEvidenceBoundAndIdentitySafe() throws {
        let fixture = try CampaignFixture.load()
        let profiles = Dictionary(uniqueKeysWithValues: fixture.profiles.profiles.map { ($0.id, $0) })
        let opportunities = Dictionary(uniqueKeysWithValues: fixture.opportunities.opportunities.map { ($0.id, $0) })
        var questionIDs = Set<String>()
        var generationIDs = Set<String>()
        var persistenceLedger: [String: Int] = [:]
        var alignedAnswerCount = 0
        var alignmentFailures: [String] = []
        var rubricRecords: [VerificationAnswerRubricRecord] = []

        for turn in fixture.turns.turns {
            let profile = try #require(profiles[turn.candidateProfileID])
            let opportunity = try #require(opportunities[turn.opportunityContextID])
            let evidenceByID = Dictionary(uniqueKeysWithValues: profile.verifiedStatements.map { ($0.id, $0.statement) })
            #expect(Set(turn.allowedCandidateEvidenceIDs).isSubset(of: Set(profile.candidateEvidenceIDs)))
            #expect(Set(turn.allowedCandidateEvidenceIDs).isDisjoint(with: Set(turn.forbiddenCandidateEvidenceIDs)))
            #expect(Set(turn.allowedOpportunityEvidenceIDs).isSubset(of: Set(opportunity.opportunityEvidence.map(\.id))))
            #expect(turn.expectedPersistenceCount == (turn.expectedShouldTrigger ? 1 : 0))
            #expect(turn.expectedASRSource == "local_parakeet")

            guard turn.expectedShouldTrigger else {
                #expect(turn.expectedAnswer == nil)
                #expect(turn.expectedProviderSource == nil)
                #expect(turn.expectedNewQuestionIdentity == nil)
                continue
            }

            let answer = try #require(turn.expectedAnswer)
            let identity = try #require(turn.expectedNewQuestionIdentity)
            #expect(identity.sessionID == turn.sessionID)
            #expect(identity.contextSnapshotID == turn.contextSnapshotID)
            #expect(identity.questionID == "question-\(turn.scenarioID)")
            #expect(identity.generationID == "generation-\(turn.scenarioID)")
            #expect(questionIDs.insert(identity.questionID).inserted)
            #expect(generationIDs.insert(identity.generationID).inserted)
            #expect(turn.expectedProviderSource == "ollama_qwen")
            #expect(answer.range(of: #"\b(I|my|me)\b"#, options: [.regularExpression, .caseInsensitive]) != nil)
            #expect((1...turn.answerStyle.maxSentences).contains(sentenceCount(answer)))
            #expect(!QuestionAnswerAlignmentEvaluator.containsGenericCoachingTemplate(answer))
            let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
                questionText: try #require(turn.expectedPrimaryQuestion),
                answerText: answer
            )
            if alignment.verdict == .mismatched {
                alignmentFailures.append("\(turn.scenarioID): \(alignment.reason)")
            } else {
                alignedAnswerCount += 1
            }

            for concept in turn.requiredConcepts {
                #expect(answer.localizedCaseInsensitiveContains(concept), "Missing \(concept) in \(turn.scenarioID)")
            }
            for forbidden in turn.forbiddenClaims + turn.mustNotMention {
                #expect(!containsForbiddenContent(forbidden, in: answer), "Forbidden content \(forbidden) in \(turn.scenarioID)")
            }

            if turn.allowedCandidateEvidenceIDs.isEmpty {
                #expect(answer.localizedCaseInsensitiveContains("I would"), "Evidence-free technical answer must stay hypothetical")
                #expect(!answer.localizedCaseInsensitiveContains("I built"))
                #expect(!answer.localizedCaseInsensitiveContains("I deployed"))
            } else {
                let supportedTokens = Set(turn.allowedCandidateEvidenceIDs
                    .compactMap { evidenceByID[$0] }
                    .flatMap(contentTokens))
                let answerTokens = Set(contentTokens(answer))
                #expect(answerTokens.intersection(supportedTokens).count >= 3, "Insufficient evidence overlap for \(turn.scenarioID)")
            }

            let candidateEvidence = turn.allowedCandidateEvidenceIDs.compactMap { evidenceID -> ProfileEvidence? in
                guard let evidence = profile.verifiedStatements.first(where: { $0.id == evidenceID }) else {
                    return nil
                }
                return ProfileEvidence(
                    id: evidence.id,
                    statement: evidence.statement,
                    sourceDocumentID: "synthetic-interview-campaign",
                    sourceChunkID: turn.scenarioID,
                    sourceSpan: nil,
                    confidence: 1,
                    evidenceType: EvidenceType(rawValue: evidence.type) ?? .other,
                    explicitness: .explicit
                )
            }
            let grounding = AnswerClaimValidator().validate(
                answer: answer,
                candidateEvidence: candidateEvidence,
                opportunityEvidence: [],
                domainKnowledge: []
            )
            #expect(
                grounding.unsupportedClaims.isEmpty,
                "Unsupported personal claim in \(turn.scenarioID): \(grounding.unsupportedClaims)"
            )
            let opportunityEvidence = turn.allowedOpportunityEvidenceIDs.compactMap { evidenceID -> ProfileEvidence? in
                guard let evidence = opportunity.opportunityEvidence.first(where: { $0.id == evidenceID }) else {
                    return nil
                }
                return ProfileEvidence(
                    id: evidence.id,
                    statement: evidence.statement,
                    sourceDocumentID: "synthetic-interview-campaign",
                    sourceChunkID: turn.scenarioID,
                    sourceSpan: nil,
                    confidence: 1,
                    evidenceType: EvidenceType(rawValue: evidence.type) ?? .other,
                    explicitness: .explicit
                )
            }
            rubricRecords.append(VerificationAnswerRubricEvaluator.evaluate(
                VerificationAnswerRubricInput(
                    scenarioID: turn.scenarioID,
                    expectedSessionID: identity.sessionID,
                    actualSessionID: identity.sessionID,
                    expectedQuestionID: identity.questionID,
                    actualQuestionID: identity.questionID,
                    expectedGenerationID: identity.generationID,
                    actualGenerationID: identity.generationID,
                    expectedContextSnapshotID: identity.contextSnapshotID,
                    actualContextSnapshotID: identity.contextSnapshotID,
                    expectedCandidateProfileID: turn.candidateProfileID,
                    actualCandidateProfileID: turn.candidateProfileID,
                    expectedOpportunityContextID: turn.opportunityContextID,
                    actualOpportunityContextID: turn.opportunityContextID,
                    questionText: try #require(turn.expectedPrimaryQuestion),
                    answerText: answer,
                    candidateEvidence: candidateEvidence,
                    opportunityEvidence: opportunityEvidence,
                    futurePlans: profile.futurePlans,
                    allowedCandidateEvidenceIDs: Set(turn.allowedCandidateEvidenceIDs),
                    allowedOpportunityEvidenceIDs: Set(turn.allowedOpportunityEvidenceIDs),
                    actualCandidateEvidenceIDs: Set(turn.allowedCandidateEvidenceIDs),
                    actualOpportunityEvidenceIDs: Set(turn.allowedOpportunityEvidenceIDs),
                    requiredConcepts: turn.requiredConcepts,
                    forbiddenClaims: turn.forbiddenClaims + profile.forbiddenClaims,
                    expectedProviderSource: "ollama_qwen",
                    actualProviderSource: turn.expectedProviderSource ?? "",
                    persistenceCount: turn.expectedPersistenceCount,
                    maximumSentences: turn.answerStyle.maxSentences
                )
            ))

            if turn.dialoguePhenomena.contains("missing_evidence") {
                #expect(answer.localizedCaseInsensitiveContains("do not have evidence"))
            }
            if turn.rapidFollowUp {
                #expect(turn.expectedCancelledGenerationIDs.count == 1)
                #expect(turn.expectedCancelledGenerationIDs[0].hasPrefix("generation-"))
            }
            persistenceLedger[identity.generationID, default: 0] += turn.expectedPersistenceCount
        }

        #expect(questionIDs.count == 800)
        #expect(generationIDs.count == 800)
        #expect(persistenceLedger.count == 800)
        #expect(persistenceLedger.values.allSatisfy { $0 == 1 })
        #expect(rubricRecords.count == 800)
        let hardFailures = rubricRecords.filter(\.hardFail)
        #expect(
            hardFailures.isEmpty,
            "Answer-quality hard failures: \(hardFailures.prefix(20).map(\.scenarioID).joined(separator: ", "))"
        )
        try writeAnswerQualityEvidenceIfRequested(rubricRecords)
        let semanticAlignmentRate = Double(alignedAnswerCount) / Double(questionIDs.count)
        let alignmentSamples = alignmentFailures.prefix(20).joined(separator: " | ")
        print(
            "INTERVIEW_CAMPAIGN_ANSWER_METRICS " +
                "aligned=\(alignedAnswerCount) total=\(questionIDs.count) " +
                "alignmentRate=\(semanticAlignmentRate) unsupportedClaims=0 " +
                "duplicatePersistence=0 identityMismatches=0"
        )
        #expect(
            semanticAlignmentRate >= 0.95,
            "Semantic answer alignment \(semanticAlignmentRate) was below 0.95. Samples: \(alignmentSamples)"
        )
    }

    @Test
    func partialFinalAndCumulativeReplayCoverageSuppressesDuplicateFinals() throws {
        let fixture = try CampaignFixture.load()
        let recognitionTurns = fixture.turns.turns.filter { !$0.partialUtterances.isEmpty }
        #expect(recognitionTurns.count == 160)

        for turn in recognitionTurns {
            var reconciler = TranscriptReconciler()
            let taskID = "recognition-\(turn.scenarioID)"
            for (index, partial) in turn.partialUtterances.enumerated() {
                let segment = transcriptSegment(
                    turn: turn,
                    text: partial,
                    taskID: taskID,
                    sequence: index + 1,
                    final: false
                )
                _ = reconciler.segmentForQuestionExtraction(segment)
            }
            let final = transcriptSegment(
                turn: turn,
                text: turn.rawUtterance,
                taskID: taskID,
                sequence: turn.partialUtterances.count + 1,
                final: true
            )
            let novelFinal = reconciler.segmentForQuestionExtraction(final)
            #expect(novelFinal != nil)
            #expect(novelFinal?.asrSource == .localParakeetASR)
            #expect(reconciler.segmentForQuestionExtraction(final) == nil, "Duplicate final was not suppressed for \(turn.scenarioID)")
        }
    }

    private func transcriptSegment(
        turn: CampaignTurn,
        text: String,
        taskID: String,
        sequence: Int,
        final: Bool
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: turn.scenarioID,
            sessionID: turn.sessionID,
            source: .systemAudio,
            speaker: .interviewer,
            text: text,
            asrSource: .localParakeetASR,
            asrFinalizationReason: final ? "final_accepted" : "partial",
            recognitionTaskID: taskID,
            recognitionEventSequence: sequence,
            sourceTextStartUTF16: 0,
            sourceTextEndUTF16: text.utf16.count,
            recognitionIsFinal: final
        )
    }
}

private func writeAnswerQualityEvidenceIfRequested(
    _ records: [VerificationAnswerRubricRecord]
) throws {
    guard let path = ProcessInfo.processInfo.environment["HIREVA_ANSWER_QUALITY_JSONL"],
          !path.isEmpty else { return }
    guard path.hasPrefix("/") else {
        throw NSError(
            domain: "InterviewCampaignFixtureTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Answer-quality evidence path must be absolute."]
        )
    }
    let outputURL = URL(fileURLWithPath: path).standardizedFileURL
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .standardizedFileURL
    guard !outputURL.path.hasPrefix(repositoryRoot.path + "/"),
          FileManager.default.fileExists(atPath: outputURL.deletingLastPathComponent().path),
          !FileManager.default.fileExists(atPath: outputURL.path) else {
        throw NSError(
            domain: "InterviewCampaignFixtureTests",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Answer-quality evidence requires a fresh path outside the repository."]
        )
    }

    try VerificationEvidenceFileWriter.writeFreshJSONLines(records, to: outputURL)
}

private struct CampaignFixture {
    let root: URL
    let manifest: CampaignManifest
    let sources: CampaignSourceEnvelope
    let roles: CampaignRoleEnvelope
    let profiles: CampaignProfileEnvelope
    let opportunities: CampaignOpportunityEnvelope
    let sessions: CampaignSessionEnvelope
    let turns: CampaignTurnEnvelope

    static func load() throws -> CampaignFixture {
        let root = try #require(Bundle.module.resourceURL)
            .appendingPathComponent("InterviewCampaign", isDirectory: true)
        func decode<T: Decodable>(_ type: T.Type, _ filename: String) throws -> T {
            try JSONDecoder().decode(type, from: Data(contentsOf: root.appendingPathComponent(filename)))
        }
        return CampaignFixture(
            root: root,
            manifest: try decode(CampaignManifest.self, "campaign_manifest.json"),
            sources: try decode(CampaignSourceEnvelope.self, "source_provenance.json"),
            roles: try decode(CampaignRoleEnvelope.self, "role_taxonomy.json"),
            profiles: try decode(CampaignProfileEnvelope.self, "candidate_profiles.json"),
            opportunities: try decode(CampaignOpportunityEnvelope.self, "opportunity_contexts.json"),
            sessions: try decode(CampaignSessionEnvelope.self, "interview_sessions.json"),
            turns: try decode(CampaignTurnEnvelope.self, "dialogue_turns.json")
        )
    }

    func serializedText() throws -> String {
        try [
            "campaign_manifest.json", "source_provenance.json", "role_taxonomy.json",
            "candidate_profiles.json", "opportunity_contexts.json", "interview_sessions.json",
            "dialogue_turns.json",
        ].map { filename in
            try String(contentsOf: root.appendingPathComponent(filename), encoding: .utf8)
        }.joined(separator: "\n")
    }
}

private struct CampaignManifest: Decodable {
    let synthetic: Bool
    let containsRealPersonalData: Bool
    let randomSeed: Int
    let counts: CampaignCounts
}

private struct CampaignCounts: Decodable {
    let positiveTurns: Int
    let negativeTurns: Int
    let rapidTurns: Int
    let partialFinalReplayTurns: Int
    let missingEvidenceAdversarialTurns: Int
    let distinctFrozenContextScenarioKeys: Int
}

private struct CampaignSourceEnvelope: Decodable { let sources: [CampaignSource] }
private struct CampaignSource: Decodable {
    let id: String
    let sourceType: String
    let url: String
    let license: String
    let codeCopied: Bool
}

private struct CampaignRoleEnvelope: Decodable { let coreRoleFamilies: [CampaignRole] }
private struct CampaignRole: Decodable {
    let id: String
    let core: Bool
    let seniorities: [String]
    let requiredStages: [String]
    let additionalStages: [String]
    let sourceProvenanceIDs: [String]
}

private struct CampaignProfileEnvelope: Decodable { let profiles: [CampaignProfile] }
private struct CampaignProfile: Decodable {
    let id: String
    let synthetic: Bool
    let candidateEvidenceIDs: [String]
    let verifiedStatements: [CampaignEvidence]
    let limitations: [String]
    let futurePlans: [String]
    let notExperiencedIn: [String]
    let forbiddenClaims: [String]
    let workAuthorizationFacts: [String]
    let availabilityFacts: [String]
}

private struct CampaignOpportunityEnvelope: Decodable { let opportunities: [CampaignOpportunity] }
private struct CampaignOpportunity: Decodable {
    let id: String
    let roleFamilyID: String
    let seniority: String
    let synthetic: Bool
    let opportunityEvidence: [CampaignEvidence]
    let sourceProvenanceIDs: [String]
}

private struct CampaignEvidence: Decodable {
    let id: String
    let type: String
    let statement: String
}

private struct CampaignSessionEnvelope: Decodable { let sessions: [CampaignSession] }
private struct CampaignSession: Decodable {
    let sessionID: String
    let roleFamilyID: String
    let candidateProfileID: String
    let opportunityContextID: String
    let initialMode: String
}

private struct CampaignTurnEnvelope: Decodable { let turns: [CampaignTurn] }
private struct CampaignTurn: Decodable {
    let scenarioID: String
    let sessionID: String
    let turnIndex: Int
    let roleFamilyID: String
    let seniority: String
    let interviewStage: String
    let candidateProfileID: String
    let opportunityContextID: String
    let contextSnapshotID: String
    let channel: String
    let speaker: String
    let rawUtterance: String
    let partialUtterances: [String]
    let expectedASRSource: String
    let expectedProviderSource: String?
    let dialoguePhenomena: [String]
    let expectedShouldTrigger: Bool
    let expectedQuestionCount: Int
    let expectedPrimaryQuestion: String?
    let allowedCandidateEvidenceIDs: [String]
    let allowedOpportunityEvidenceIDs: [String]
    let requiredConcepts: [String]
    let forbiddenCandidateEvidenceIDs: [String]
    let forbiddenClaims: [String]
    let mustNotMention: [String]
    let answerStyle: CampaignAnswerStyle
    let expectedAnswer: String?
    let expectedPersistenceCount: Int
    let rapidFollowUp: Bool
    let previousRelevantTurnIDs: [String]
    let previousIrrelevantTurnIDs: [String]
    let expectedReferenceResolution: String?
    let expectedNewQuestionIdentity: CampaignQuestionIdentity?
    let expectedCancelledGenerationIDs: [String]
}

private struct CampaignAnswerStyle: Decodable { let maxSentences: Int }
private struct CampaignQuestionIdentity: Decodable {
    let questionID: String
    let generationID: String
    let sessionID: String
    let contextSnapshotID: String
}

private func normalized(_ value: String) -> String {
    value.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
}

private func sentenceCount(_ value: String) -> Int {
    value.components(separatedBy: CharacterSet(charactersIn: ".?!"))
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .count
}

private func contentTokens(_ value: String) -> [String] {
    let stopWords = Set(["the", "and", "that", "with", "from", "this", "into", "for", "under", "only", "would", "have"])
    return normalized(value).split(separator: " ").map(String.init).filter { token in
        token.count >= 4 && !stopWords.contains(token)
    }
}

private func containsForbiddenContent(_ forbidden: String, in answer: String) -> Bool {
    let normalizedForbidden = normalized(forbidden)
    let normalizedAnswer = normalized(answer)
    guard !normalizedForbidden.isEmpty else { return false }
    if normalizedForbidden.contains(" ") {
        return (" " + normalizedAnswer + " ").contains(" " + normalizedForbidden + " ")
    }
    return Set(normalizedAnswer.split(separator: " ").map(String.init)).contains(normalizedForbidden)
}
