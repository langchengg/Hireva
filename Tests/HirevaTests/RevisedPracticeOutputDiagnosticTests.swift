// Model output diagnostic for revision1; not correction persistence or end-to-end workflow acceptance.
import Foundation
import Testing
@testable import Hireva

@Suite(.serialized)
@MainActor
struct RevisedPracticeOutputDiagnosticTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HIREVA_RUN_LOCAL_REVISED_PRACTICE_DIAGNOSTIC"] == "1"))
    func revisedInputEvaluatesWithoutOriginalSuccessDependency() async throws {
        let question = "Explain a retry policy with bounded attempts, exponential backoff and jitter."
        let answer = "A retry policy repeats failed requests at most three times. Exponential backoff doubles the delay; jitter randomizes it to spread concurrent requests."
        let model = "qwen3.5:4b"
        var task = InterviewTaskDescriptor(question: question, kind: .generalKnowledge, language: "en")
        task.apply(InterviewQuestionDecision(task: .generalKnowledge, personalEvidence: .notRequired,
            basis: .generalKnowledge, relation: .independent, parentQuestionID: nil,
            parentQuestionText: nil, parentAnswerText: nil, source: "synthetic-revised-only-diagnostic",
            routerVersion: InterviewQuestionRouter.version, language: "en", clarification: "",
            questionID: "synthetic-revised-only", questionRevision: 1, contextSnapshotID: nil,
            artifactRevision: 0, model: model, failure: nil, latencyMS: 0))
        task.criteria = ["Correct explanation / 解释正确", "Assumptions and distinctions / 条件与区别", "Example or reasoning / 示例或推理", "Limits / 局限"]
        let attempt = PracticeAttempt(questionID: "synthetic-revised-only", question: question,
            answer: answer, contextSnapshotID: nil, revision: 1, hinted: true, skipped: false,
            source: "synthetic-text-model-diagnostic", task: task)
        let provider = SyntheticCaptureProvider(suffix: "revised-only-diagnostic")
        #expect(await provider.healthCheck(modelName: model).isReady)
        let feedback = try await GenerationCoordinator.withTimeout(seconds: 90) { @MainActor in
            try await PracticeController.evaluate(attempt: attempt, task: task, attachment: nil,
                evidence: [], provider: provider, model: model)
        }
        #expect(feedback.covered.allSatisfy { answer.contains($0.quote) })
        #expect(feedback.missing.isEmpty || feedback.followUp?.isEmpty == false)
        // Nonempty followUp is only the existing mechanical contract. Human relevance remains reviewable.
    }
}
