import Combine
import Foundation
import Testing
@testable import Hireva

@MainActor
struct ManualWorkerPublicationAdmissionTests {
    enum Boundary: CaseIterable, Sendable { case transcript, detectedQuestion, retrievalTrace, localSuggestion, localReady }

    @Test(.timeLimit(.minutes(1)), arguments: Boundary.allCases)
    func realManualWorkerCannotPublishItsTailAfterSynchronousReplacement(boundary: Boundary) async throws {
        let fixture = try await ManualSnapshotFixture()
        var roots: [Task<Void, Never>] = []
        var replacementAnswer: Task<String, Error>?
        var observation: AnyCancellable?
        var replaced = false
        let replacementID = "synthetic-manual-worker-replacement"
        let question = DetectedQuestion(id: "synthetic-worker-next-question", sessionID: fixture.session.id,
            transcriptSegmentID: nil, questionText: "Explain transaction isolation and atomicity.",
            intent: .technical, answerStrategy: .directAnswer, confidence: 1, reason: "Synthetic next intent",
            shouldTrigger: true, questionComplete: true, modelName: "synthetic", promptVersion: "synthetic", createdAt: Date())
        @MainActor func replace() {
            guard !replaced else { return }
            replaced = true
            fixture.app.activateGeneration(question: question, generationID: replacementID,
                triggerPath: .regenerate, requestStart: Date(), source: .systemAudio, speaker: .unknown)
            fixture.app.lastDetectedQuestion = question
            fixture.app.updateDiagnostics { $0.lastRetrievalTrace = nil }
            fixture.app.manualCaptureSuggestion = nil
            fixture.app.manualCaptureState = .generatingSuggestion
            fixture.app.beginAction(ActionID.manualGenerate, title: "Synthetic next intent",
                message: "The next generation retains its own loading state.")
            let answer = Task<String, Error> { "Finite next-generation answer" }
            replacementAnswer = answer
            fixture.app.registerStageATask(answer, generationID: replacementID)
        }
        do {
            fixture.app.manualCaptureTranscript = "Explain database transactions and atomicity."
            fixture.app.manualCaptureState = .transcriptReady
            switch boundary {
            case .transcript:
                observation = fixture.app.liveInterview.$transcriptSegments.dropFirst().sink { value in
                    if value.contains(where: { $0.text == "Explain database transactions and atomicity." }) { replace() }
                }
            case .detectedQuestion:
                observation = fixture.app.liveInterview.detectedQuestionUpdates.dropFirst().sink { value in
                    if value?.questionText == "Explain database transactions and atomicity." { replace() }
                }
            case .retrievalTrace:
                observation = fixture.app.diagnosticsState.retrievalTraceChanges.sink { value in
                    if value?.query == "Explain database transactions and atomicity." { replace() }
                }
            case .localSuggestion:
                observation = fixture.app.manualCaptureController.suggestionUpdates.dropFirst().sink { value in
                    if value?.questionText == "Explain database transactions and atomicity." { replace() }
                }
            case .localReady:
                observation = fixture.app.manualCaptureController.stateUpdates.dropFirst().sink { value in
                    if value == .suggestionReady { replace() }
                }
            }
            fixture.app.sendManualCaptureToAI()
            let original = try #require(fixture.app.stageBTask)
            roots.append(original)
            try await fixture.join(original)
            observation?.cancel(); observation = nil
            #expect(replaced, "The real workflow must reach the selected synchronous publisher.")
            #expect(fixture.app.currentGenerationID == replacementID)
            #expect(fixture.app.lastDetectedQuestion?.id == question.id)
            #expect(fixture.app.diagnostics.lastRetrievalTrace == nil,
                "A replaced worker cannot attribute its retrieval to the next generation.")
            #expect(fixture.app.manualCaptureState == .generatingSuggestion)
            #expect(fixture.app.manualCaptureSuggestion == nil)
            #expect(fixture.app.isActionLoading(ActionID.manualGenerate))
            #expect(fixture.app.generationCoordinator.stageATask == replacementAnswer && replacementAnswer?.isCancelled == false)
            #expect(fixture.app.currentGenerationTelemetry.generationID == replacementID)
            #expect(fixture.app.currentGenerationTelemetry.failureReason == nil)
            if boundary == .transcript || boundary == .detectedQuestion || boundary == .retrievalTrace {
                #expect(await fixture.original.requests().isEmpty,
                    "A replaced entry must stop before starting its old local answer.")
            }
            #expect(fixture.remote.requests().isEmpty)
            replacementAnswer?.cancel()
            if let replacementAnswer { _ = try? await replacementAnswer.value }
            try await fixture.close(roots)
            #expect(fixture.app.generationCoordinator.pendingCleanupTaskCount == 0)
        } catch {
            observation?.cancel(); replacementAnswer?.cancel()
            if let replacementAnswer { _ = try? await replacementAnswer.value }
            try? await fixture.close(roots)
            throw error
        }
    }
}
