import Foundation
import Testing
@testable import Hireva

@Suite(.serialized, .sharedRuntimeResources)
struct RapidFollowUpSupersessionTests {
    @Test @MainActor
    func distinctTranscriptSegmentSupersedesBeforeFirstAnswerBecomesVisible() throws {
        let appState = try AppState(database: AppDatabase(inMemory: true))
        let session = try appState.sessionRepository.createSession(mode: .microphone)
        appState.currentSession = session
        let first = try question(
            id: "rapid-first",
            sessionID: session.id,
            segmentID: "segment-a",
            text: "How do you prevent stale answers from reaching the interface?"
        )
        let distinctFollowUp = try question(
            id: "rapid-second",
            sessionID: session.id,
            segmentID: "segment-b",
            text: "What should happen next?"
        )
        let sameSegmentClause = try question(
            id: "rapid-same-segment",
            sessionID: session.id,
            segmentID: "segment-a",
            text: "How did you verify the result?"
        )

        appState.activateGeneration(
            question: first,
            generationID: "generation-a",
            triggerPath: .autoDetect,
            requestStart: Date(),
            source: .systemAudio,
            speaker: .interviewer
        )

        #expect(appState.shouldImmediatelySupersedeActiveGeneration(for: distinctFollowUp))
        #expect(!appState.shouldImmediatelySupersedeActiveGeneration(for: sameSegmentClause))
    }

    private func question(
        id: String,
        sessionID: String,
        segmentID: String,
        text: String
    ) throws -> DetectedQuestion {
        let candidate = try #require(
            QuestionRuntimeAcceptanceGuard.acceptedCandidate(from: text).candidate
        )
        let ingress = TranscriptQuestionIngressIdentity(
            recognitionTaskID: "task-\(segmentID)",
            recognitionEventSequence: 1,
            sourceSegmentID: segmentID,
            sourceStartUTF16: 0,
            sourceEndUTF16: text.utf16.count,
            normalizedText: SemanticDuplicateKeyBuilder.key(for: text),
            eventTimestamp: Date(),
            isFinal: true
        )
        return DetectedQuestion(
            id: id,
            sessionID: sessionID,
            transcriptSegmentID: segmentID,
            questionText: candidate.text,
            intent: candidate.intent,
            answerStrategy: candidate.answerStrategy,
            confidence: candidate.confidence,
            reason: "Rapid follow-up regression fixture.",
            shouldTrigger: true,
            questionComplete: true,
            modelName: "fixture",
            promptVersion: "fixture-v1",
            rawJSON: nil,
            createdAt: Date(),
            ingressIdentity: ingress
        )
    }
}
