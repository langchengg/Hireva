import Foundation
import Testing
@testable import Hireva

@Suite(.serialized)
struct DialogueScenarioTests {
    @Test
    func manifestDefinesRequiredSyntheticCoverage() throws {
        let manifest = try DialogueScenarioFixture.load()

        #expect(manifest.synthetic)
        #expect(manifest.turns.count == 128)
        #expect(manifest.sessions.count == 24)
        #expect(manifest.profiles.count == 3)
        #expect(manifest.opportunities.count == 3)
        #expect(Set(manifest.sessions.map(\.initialMode)) == Set([
            InterviewSessionMode.auto.rawValue,
            InterviewSessionMode.presentation.rawValue,
            InterviewSessionMode.panelQuestions.rawValue,
            InterviewSessionMode.candidateQuestions.rawValue,
        ]))

        let requiredCategories = Set([
            "opening_motivation", "project_deep_dive", "technical_knowledge",
            "system_design", "behavioral_star", "compound", "follow_up",
            "ellipsis", "correction", "asr_partial_final", "duplicate",
            "small_talk", "candidate_speech", "presentation", "panel_interview",
        ])
        #expect(requiredCategories.isSubset(of: Set(manifest.turns.map(\.category))))
        #expect(Set(manifest.turns.map(\.scenarioID)).count == 128)
        #expect(Set(manifest.sessions.map(\.sessionID)).count == 24)
        #expect(manifest.sessions.allSatisfy { session in
            manifest.turns.filter { $0.sessionID == session.sessionID }.count >= 5
        })
        #expect(manifest.turns.filter { !$0.partialTexts.isEmpty }.count >= 3)
        #expect(manifest.turns.filter(\.rapidFollowUp).count >= 6)
        #expect(manifest.turns.filter(\.profileSwitch).count >= 2)

        let encoded = try #require(String(data: JSONEncoder().encode(manifest), encoding: .utf8))
        for forbidden in ["sk-", "Bearer ", "api_key", "real personal data"] {
            #expect(!encoded.localizedCaseInsensitiveContains(forbidden))
        }
    }

    @Test
    func productionPolicyMatchesAllTurnsAndSessionTransitions() throws {
        let manifest = try DialogueScenarioFixture.load()
        let sessions = Dictionary(uniqueKeysWithValues: manifest.sessions.map { ($0.sessionID, $0) })

        for session in manifest.sessions {
            let mode = try #require(InterviewSessionMode(rawValue: session.initialMode))
            var state = DialogueRuntimeState.initial(for: mode)
            let turns = manifest.turns
                .filter { $0.sessionID == session.sessionID }
                .sorted { $0.turnIndex < $1.turnIndex }

            for turn in turns {
                #expect(sessions[turn.sessionID]?.profileID == turn.profileID)
                #expect(sessions[turn.sessionID]?.opportunityID == turn.opportunityID)
                let segment = TranscriptSegment(
                    id: turn.scenarioID,
                    sessionID: turn.sessionID,
                    source: turn.channel == "microphone" ? .microphone : .systemAudio,
                    speaker: turn.speaker == "candidate" ? .candidate : .interviewer,
                    text: turn.finalText,
                    asrSource: .localParakeetASR,
                    asrFinalizationReason: "final_accepted",
                    recognitionTaskID: "task-\(turn.scenarioID)",
                    recognitionEventSequence: turn.turnIndex,
                    sourceTextStartUTF16: 0,
                    sourceTextEndUTF16: (turn.finalText as NSString).length,
                    recognitionIsFinal: true
                )
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
                    "Unexpected policy result for \(turn.scenarioID): \(decision.triggerReason) \(decision.suppressionReason)"
                )
                state = state.applying(decision)
                #expect(state.resolvedSessionPhase.rawValue == turn.expectedSessionPhase)

                if turn.expectedShouldTrigger {
                    let candidates = QuestionCandidatePipeline.extract(from: turn.finalText)
                    #expect(turn.expectedQuestionCount == 1)
                    #expect(candidates.count == turn.expectedQuestionCount)
                    #expect(candidates.last?.text == turn.expectedPrimaryQuestion)
                    #expect(QuestionRuntimeAcceptanceGuard.acceptedCandidate(from: turn.finalText).accepted)
                } else {
                    #expect(turn.expectedQuestionCount == 0)
                    #expect(turn.expectedPrimaryQuestion == nil)
                }

                for partial in turn.partialTexts {
                    #expect(turn.finalText.hasPrefix(partial))
                    #expect((partial as NSString).length < (turn.finalText as NSString).length)
                }
            }
        }
    }
}

enum DialogueScenarioFixture {
    static func load() throws -> DialogueScenarioManifest {
        let url = try #require(Bundle.module.url(
            forResource: "dialogue_scenarios_128",
            withExtension: "json"
        ))
        return try JSONDecoder().decode(DialogueScenarioManifest.self, from: Data(contentsOf: url))
    }
}

struct DialogueScenarioManifest: Codable {
    let synthetic: Bool
    let profiles: [DialogueScenarioProfile]
    let opportunities: [DialogueScenarioOpportunity]
    let sessions: [DialogueScenarioSession]
    let turns: [DialogueScenarioTurn]
}

struct DialogueScenarioProfile: Codable {
    let id: String
    let displayName: String
    let domain: String
    let evidence: [DialogueScenarioEvidence]
}

struct DialogueScenarioOpportunity: Codable {
    let id: String
    let title: String
    let evidence: [DialogueScenarioEvidence]
}

struct DialogueScenarioEvidence: Codable {
    let id: String
    let type: String
    let statement: String
}

struct DialogueScenarioSession: Codable {
    let sessionID: String
    let profileID: String
    let opportunityID: String
    let initialMode: String
}

struct DialogueScenarioTurn: Codable {
    let scenarioID: String
    let sessionID: String
    let turnIndex: Int
    let channel: String
    let speaker: String
    let category: String
    let partialTexts: [String]
    let finalText: String
    let expectedShouldTrigger: Bool
    let expectedQuestionCount: Int
    let expectedPrimaryQuestion: String?
    let expectedIntent: String
    let expectedSessionPhase: String
    let profileID: String
    let opportunityID: String
    let allowedCandidateEvidenceIDs: [String]
    let allowedOpportunityEvidenceIDs: [String]
    let forbiddenCandidateEvidenceIDs: [String]
    let mustContainConcepts: [String]
    let mustNotContainConcepts: [String]
    let expectedPersistenceCount: Int
    let expectedAnswer: String?
    let rapidFollowUp: Bool
    let profileSwitch: Bool
}
