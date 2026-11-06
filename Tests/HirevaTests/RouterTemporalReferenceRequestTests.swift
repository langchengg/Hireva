import Foundation
import Testing
@testable import Hireva

/// Exercises real router requests and frozen identities with a scripted provider.
/// These tests protect request semantics; they do not measure model accuracy.
@Suite
struct RouterTemporalReferenceRequestTests {
    @Test(arguments: ["en", "zh"])
    func retrospectiveActionKeepsPersonalFactKindWithoutAnEventIdentifier(_ language: String) async throws {
        let question = language == "en" ? "What did you change at that point?" : "当时你采取了哪些调整？"
        let clarification = language == "en" ? "Which event is meant?" : "具体指哪次事件？"
        let decision = try await exercise(question: question, language: language,
            task: .unknown, evidence: .required, basis: .candidateRecord, clarification: clarification)
        #expect(decision.task == .unknown && decision.personalEvidence == .required)
        #expect(decision.basis == .candidateRecord && decision.usesCandidateEvidence)
        #expect(decision.clarification == clarification && decision.parentQuestionID == nil)
    }

    @Test(arguments: ["en", "zh"])
    func occurrenceConfirmationCanBeAnsweredWithATruthfulDenial(_ language: String) async throws {
        let question = language == "en"
            ? "Was that the first time you encountered such a constraint?"
            : "你此前碰到过所指的约束吗？"
        let clarification = language == "en" ? "Which constraint do you mean?" : "具体指哪项约束？"
        let decision = try await exercise(question: question, language: language,
            task: .unknown, evidence: .required, basis: .candidateRecord, clarification: clarification)
        #expect(decision.personalEvidence == .required && decision.basis == .candidateRecord)
        #expect(decision.clarification == clarification)
        #expect(decision.evidencePolicy.contains("A question or submitted answer is not confirmed biographical evidence."))
    }

    @Test(arguments: ["en", "zh"])
    func counterfactualPastTenseDoesNotCreateCandidateHistory(_ language: String) async throws {
        let question = language == "en"
            ? "If you had observed a delay in a fictional service, how would you propose a retry method?"
            : "假设你在虚构服务中已观察到延迟，你会怎样提出重试方案？"
        let decision = try await exercise(question: question, language: language,
            task: .systemDesign, evidence: .notRequired, basis: .generalKnowledge)
        #expect(decision.task == .systemDesign && decision.personalEvidence == .notRequired)
        #expect(decision.basis == .generalKnowledge && !decision.usesCandidateEvidence)
    }

    @Test(arguments: ["en", "zh"])
    func suppliedFictionalPastStaysInsideTheExercise(_ language: String) async throws {
        let question = language == "en"
            ? "In this role-play, what did you decide after the alarm?"
            : "在这段角色练习中，警报后你作了什么决定？"
        let artifact = language == "en"
            ? "Fictional role-play: you are an operator. An alarm sounded and you checked the indicator."
            : "虚构角色练习：你扮演操作员。警报响起后，你检查了指示器。"
        let decision = try await exercise(question: question, language: language, artifact: artifact,
            task: .generalKnowledge, evidence: .notRequired, basis: .providedArtifact)
        #expect(decision.personalEvidence == .notRequired && decision.basis == .providedArtifact)
        #expect(!decision.usesCandidateEvidence && decision.artifactRevision == 6)
    }

    @Test(arguments: ["en", "zh"])
    func unresolvedFutureMethodCanRemainNonPersonalAndUnknown(_ language: String) async throws {
        let question = language == "en"
            ? "If we alter the unspecified component next, what would you propose?"
            : "如果接下来调整尚未说明的组件，你会提出什么方案？"
        let clarification = language == "en" ? "Which component and goal are meant?" : "具体指哪个组件和目标？"
        let decision = try await exercise(question: question, language: language,
            task: .unknown, evidence: .notRequired, basis: .unknown, clarification: clarification)
        #expect(decision.task == .unknown && decision.personalEvidence == .notRequired)
        #expect(decision.basis == .unknown && !decision.usesCandidateEvidence)
        #expect(decision.clarification == clarification)
    }

    @Test(arguments: ["en", "zh"])
    func genuinelyUnresolvedFactKindRetainsUncertain(_ language: String) async throws {
        let question = language == "en" ? "Could you explain the unspecified reference?" : "能解释尚未说明的指代吗？"
        let clarification = language == "en" ? "What reference do you mean?" : "具体指什么对象？"
        let decision = try await exercise(question: question, language: language,
            task: .unknown, evidence: .uncertain, basis: .unknown, clarification: clarification)
        #expect(decision.personalEvidence == .uncertain && decision.basis == .unknown)
        #expect(!decision.usesCandidateEvidence && decision.clarification == clarification)
    }

    @Test
    func explicitlyOptionalPastIllustrationDoesNotBecomeMandatory() async throws {
        let decision = try await exercise(
            question: "Explain a generic handover method; you may optionally illustrate with a past personal example.",
            language: "en", task: .generalKnowledge, evidence: .optional, basis: .mixed)
        #expect(decision.personalEvidence == .optional && decision.basis == .mixed)
    }

    @Test
    func userTaskPreferenceDoesNotRemoveEstablishedPersonalFactDependence() async throws {
        let decision = try await exercise(question: "What did you actually revise during the unspecified event?",
            language: "en", selectedTask: .coding, task: .unknown, evidence: .required,
            basis: .candidateRecord, clarification: "Which event is meant?")
        #expect(decision.task == .coding && decision.personalEvidence == .required)
        #expect(decision.source == "userTaskAndLocalEvidence")
    }

    private func exercise(question: String, language: String, artifact: String? = nil,
                          selectedTask: InterviewTaskKind? = nil, task: InterviewTaskKind,
                          evidence: PersonalEvidenceRequirement, basis: QuestionAnswerBasis,
                          clarification: String = "") async throws -> InterviewQuestionDecision {
        let first = InterviewQuestionRouter.Wire(task: task, personalEvidence: .uncertain,
            basis: .unknown, relation: .independent, clarification: clarification)
        let reviewed = InterviewQuestionRouter.Wire(task: task, personalEvidence: evidence,
            basis: basis, relation: .independent, clarification: clarification)
        let outputs = try [first, reviewed].map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        let provider = TemporalReferenceTransport(outputs: outputs)
        let input = InterviewRoutingInput(question: question, questionID: UUID().uuidString,
            revision: 9, contextSnapshotID: "synthetic-temporal-reference", artifactRevision: 6,
            artifact: artifact, selectedTask: selectedTask, language: language)
        let decision = try await InterviewQuestionRouter.resolve(input, provider: provider, model: "synthetic-temporal-reference")
        let requests = await provider.requests
        try #require(requests.count == 2)
        #expect(requests[0].prompt == requests[1].prompt)
        let payload = try #require(try JSONSerialization.jsonObject(with: Data(requests[0].prompt.utf8)) as? [String: Any])
        #expect(payload["question"] as? String == question && payload["language"] as? String == language)
        #expect(payload["hasParent"] as? Bool == false)
        #expect(payload["artifact"] as? String == artifact)
        #expect(payload["selectedTask"] as? String == selectedTask?.rawValue)
        #expect(payload["previousQuestion"] == nil && payload["previousAnswer"] == nil)
        for request in requests {
            let system = try #require(request.systemPrompt)
            #expect(system.contains("Determine two independent properties:"))
            #expect(system.contains("An unidentified event does not make an explicitly past personal answer general:"))
            #expect(system.contains("Use uncertain only when the kind of facts cannot be established."))
            #expect(system.contains("An unknown task, missing parent or absent CV does not determine fact dependence."))
            #expect(system.contains("If a personal illustration is explicitly optional, keep optional rather than required or notRequired."))
            #expect(request.temperature == 0 && request.numPredict == 260 && !request.thinkingEnabled)
            #expect(request.responseSchema == InterviewQuestionRouter.Wire.schema)
        }
        let review = try #require(requests[1].systemPrompt)
        #expect(review.contains("Frozen task=\(task.rawValue), relation=independent."))
        #expect(decision.questionID == input.questionID && decision.questionRevision == 9)
        #expect(decision.contextSnapshotID == input.contextSnapshotID && decision.artifactRevision == 6)
        #expect(decision.language == language && decision.model == "synthetic-temporal-reference")
        #expect(decision.routerVersion == InterviewQuestionRouter.version)
        #expect(decision.relation == .independent && decision.parentQuestionText == nil)
        #expect(decision.modelRequests == 2 && decision.modelEvidenceReviews == 1 && decision.modelFormatRepairs == 0)
        #expect(decision.failure == nil && InterviewQuestionRouter.timeoutSeconds == 8)
        return decision
    }
}

private actor TemporalReferenceTransport: LocalLLMProvider {
    nonisolated let id = "synthetic-temporal-reference"
    nonisolated let displayName = "Synthetic temporal reference"
    private let outputs: [String]
    private(set) var requests: [LocalLLMRequest] = []
    init(outputs: [String]) { self.outputs = outputs }
    func healthCheck(modelName: String) async -> LocalLLMHealth {
        .init(ollamaRunning: true, selectedModel: modelName, modelInstalled: true, providerSource: .localQwen, lastError: nil)
    }
    nonisolated func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        let index = requests.count
        requests.append(request)
        guard index < outputs.count else { throw MaterialError.invalid("Unexpected extra temporal-reference request.") }
        let output = outputs[index]
        return AsyncThrowingStream { continuation in
            continuation.yield(.init(text: output, source: .localQwen, modelName: request.modelName))
            continuation.finish()
        }
    }
}
