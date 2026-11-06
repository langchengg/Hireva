import Combine
import Foundation
import Testing
@testable import Hireva

/// The real configured Manual service decodes this synthetic transport result.
/// This is publication/ownership evidence, not a real-model quality result.
@MainActor
struct ManualConfiguredResultPublicationTests {
    enum Boundary: CaseIterable, Sendable {
        case normal, providerLabel, acceptedSuggestion, acceptedReady
        case completionFeedback, auditTrace, auditQuestion
    }
    @Test(.timeLimit(.minutes(1)), arguments: Boundary.allCases)
    func configuredManualResultAndTerminalAuditCannotPublishIntoReplacement(boundary: Boundary) async throws {
        let answer = """
        {"strategy":"Explanation","say_first":"A database transaction groups operations into an atomic unit. Atomicity means all operations commit together or roll back together, and isolation controls which concurrent changes each transaction can observe.","key_points":["Atomicity commits or rolls back the entire transaction."],"follow_up_ready":["I can explain transaction isolation levels next."],"confidence":0.96,"caution":null,"evidence_used":[],"risk_level":"low"}
        """
        let fixture = try await ManualSnapshotFixture(mode: .deepSeekPrimary, configuredManualAnswer: answer)
        var roots: [Task<Void, Never>] = []
        var next: Task<String, Error>?
        var observation: AnyCancellable?
        var replaced = false
        var traceDeliveries = 0
        var questionDeliveries = 0
        let nextID = "synthetic-next-configured-manual"
        let nextQuestion = DetectedQuestion(id: "synthetic-next-configured-question", sessionID: fixture.session.id,
            transcriptSegmentID: nil, questionText: "Explain transaction isolation and atomicity.",
            intent: .technical, answerStrategy: .directAnswer, confidence: 1, reason: "Synthetic next intent",
            shouldTrigger: true, questionComplete: true, modelName: "synthetic", promptVersion: "synthetic", createdAt: Date())
        @MainActor func replace() {
            guard !replaced else { return }
            replaced = true
            fixture.app.activateGeneration(question: nextQuestion, generationID: nextID,
                triggerPath: .regenerate, requestStart: Date(), source: .systemAudio, speaker: .unknown)
            fixture.app.lastDetectedQuestion = nextQuestion
            fixture.app.manualCaptureSuggestion = nil
            fixture.app.manualCaptureState = .generatingSuggestion
            fixture.app.updateDiagnostics { $0.cleanedQuestion = "Synthetic next diagnostic" }
            fixture.app.beginAction(ActionID.manualGenerate, title: "Synthetic next intent", message: "Q2 owns loading.")
            let producer = Task<String, Error> { "Finite next configured provider" }
            next = producer
            fixture.app.registerStageATask(producer, generationID: nextID)
        }
        do {
            fixture.app.manualCaptureTranscript = "Explain database transactions and atomicity."
            fixture.app.manualCaptureState = .transcriptReady
            switch boundary {
            case .normal: break
            case .providerLabel:
                observation = fixture.app.$lastSuggestionGenerationProvider.dropFirst().sink { value in
                    if value != nil { replace() }
                }
            case .acceptedSuggestion:
                observation = fixture.app.manualCaptureController.suggestionUpdates.dropFirst().sink { value in
                    if value?.questionText == "Explain database transactions and atomicity." { replace() }
                }
            case .acceptedReady:
                observation = fixture.app.manualCaptureController.stateUpdates.dropFirst().sink { value in
                    if value == .suggestionReady { replace() }
                }
            case .completionFeedback:
                observation = fixture.app.activeActionFeedbacksUpdates.dropFirst().sink { values in
                    if values.contains(where: { $0.actionID == ActionID.manualGenerate && $0.kind == .success }) { replace() }
                }
            case .auditTrace:
                observation = fixture.app.diagnosticsState.retrievalTraceChanges.sink { value in
                    guard value != nil else { return }
                    traceDeliveries += 1
                    if traceDeliveries == 2 { replace() }
                }
            case .auditQuestion:
                observation = fixture.app.liveInterview.detectedQuestionUpdates.dropFirst().sink { value in
                    guard value?.questionText == "Explain database transactions and atomicity." else { return }
                    questionDeliveries += 1
                    if questionDeliveries == 2 { replace() }
                }
            }
            fixture.app.sendManualCaptureToAI()
            let original = try #require(fixture.app.stageBTask)
            roots.append(original)
            try await fixture.join(original)
            observation?.cancel(); observation = nil
            #expect(fixture.remote.requests().count == 1)
            #expect(await fixture.original.requests().isEmpty)
            if boundary == .normal {
                #expect(!replaced && fixture.app.manualCaptureState == .suggestionReady)
                #expect(fixture.app.manualCaptureSuggestion == fixture.app.currentSuggestion)
                #expect(fixture.app.currentSuggestion?.questionText == "Explain database transactions and atomicity.")
                #expect(fixture.app.currentSuggestion?.sayFirstSource != "rag_template_soft_fallback")
                #expect(fixture.app.generationUIState.isTerminal && !fixture.app.isActionLoading(ActionID.manualGenerate))
            } else {
                #expect(replaced, "The actual configured workflow must reach the selected publication.")
                #expect(fixture.app.currentGenerationID == nextID && fixture.app.lastDetectedQuestion?.id == nextQuestion.id)
                #expect(fixture.app.manualCaptureSuggestion == nil && fixture.app.manualCaptureState == .generatingSuggestion)
                #expect(fixture.app.isActionLoading(ActionID.manualGenerate))
                #expect(fixture.app.currentSuggestion == nil)
                #expect(fixture.app.generationCoordinator.stageATask == next && next?.isCancelled == false)
                #expect(fixture.app.providerStreamActive && !fixture.app.generationUIState.isTerminal)
                #expect(fixture.app.diagnostics.cleanedQuestion == "Synthetic next diagnostic")
            }
            next?.cancel()
            if let next { _ = try? await next.value }
            try await fixture.close(roots)
            #expect(fixture.app.generationCoordinator.pendingCleanupTaskCount == 0)
        } catch {
            observation?.cancel(); next?.cancel()
            if let next { _ = try? await next.value }
            try? await fixture.close(roots)
            throw error
        }
    }
}
