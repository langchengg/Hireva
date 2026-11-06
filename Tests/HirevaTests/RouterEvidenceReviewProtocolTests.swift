import Foundation
import Testing
@testable import Hireva

/// Scripted transport validates the actual router's protocol, never model quality.
@Suite
struct RouterEvidenceReviewProtocolTests {
    @Test(arguments: [false, true])
    func uncertainEvidenceIsReviewedIndependentlyOfAnUnknownTask(isPast: Bool) async throws {
        let question = isPast
            ? "Which actions did you personally take in the incident we mean?"
            : "How would you approach a service that sends duplicate notifications?"
        let first = try wire(evidence: .uncertain, basis: .unknown,
            clarification: isPast ? "Which incident is meant?" : "")
        // Even if the second response rewrites task, it may only update evidence.
        let second = try wire(task: .behavioral, evidence: isPast ? .required : .notRequired,
            basis: isPast ? .candidateRecord : .generalKnowledge)
        let provider = EvidenceReviewTransport(plans: [.text(first), .text(second)])
        let result = try await InterviewQuestionRouter.resolve(.init(question: question, questionID: UUID().uuidString),
            provider: provider, model: "synthetic-evidence-review")
        #expect(result.task == .unknown)
        #expect(result.personalEvidence == (isPast ? .required : .notRequired))
        #expect(result.basis == (isPast ? .candidateRecord : .generalKnowledge))
        #expect(result.clarification == (isPast ? "Which incident is meant?" : ""))
        #expect(result.usesCandidateEvidence == isPast)
        #expect(result.failure == nil)
        #expect(result.modelRequests == 2)
        let requests = await provider.requests
        #expect(requests.count == 2)
        if requests.count == 2 {
            #expect(requests[0].prompt == requests[1].prompt)
            #expect(requests[0].responseSchema == requests[1].responseSchema)
            #expect(requests[1].systemPrompt != requests[0].systemPrompt)
            let audit = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
            #expect(audit["modelEvidenceReviews"] as? Int == 1)
            #expect(audit["modelFormatRepairs"] as? Int == 0)
            #expect(requests.allSatisfy { $0.temperature == 0 && $0.numPredict == 260 && !$0.thinkingEnabled })
        }
    }

    @Test(arguments: [false, true])
    func definiteEvidenceDecisionsDoNotSpendAReviewRequest(isPast: Bool) async throws {
        let provider = EvidenceReviewTransport(plans: [.text(try wire(evidence: isPast ? .required : .notRequired,
            basis: isPast ? .candidateRecord : .generalKnowledge))])
        let result = try await InterviewQuestionRouter.resolve(.init(question: "Synthetic evidence contract.", questionID: UUID().uuidString),
            provider: provider, model: "synthetic-evidence-review")
        #expect(result.personalEvidence == (isPast ? .required : .notRequired))
        #expect(result.modelRequests == 1)
        #expect(result.failure == nil)
        #expect(await provider.requests.count == 1)
    }

    @Test
    func repeatedUncertaintyDoesNotBecomeAPersonalFact() async throws {
        let output = try wire(evidence: .uncertain, basis: .unknown, clarification: "What kind of case is meant?")
        let provider = EvidenceReviewTransport(plans: [.text(output), .text(output)])
        let result = try await InterviewQuestionRouter.resolve(.init(question: "Can that other approach be considered?", questionID: UUID().uuidString),
            provider: provider, model: "synthetic-evidence-review")
        #expect(result.personalEvidence == .uncertain && result.basis == .unknown)
        #expect(!result.usesCandidateEvidence)
        #expect(result.clarification == "What kind of case is meant?")
        #expect(result.modelRequests == 2 && result.failure == nil)
        #expect(await provider.requests.count == 2)
    }

    @Test
    func formatRepairUsesTheSameLastRequestAndDoesNotAddAThird() async throws {
        let provider = EvidenceReviewTransport(plans: [.text("{\"task\":false}"), .text(try wire(evidence: .uncertain, basis: .unknown))])
        let result = try await InterviewQuestionRouter.resolve(.init(question: "Which context is relevant?", questionID: UUID().uuidString),
            provider: provider, model: "synthetic-evidence-review")
        #expect(result.personalEvidence == .uncertain && result.basis == .unknown)
        #expect(result.modelRequests == 2 && result.failure == nil)
        #expect(await provider.requests.count == 2)
        #expect(await provider.requests.last?.systemPrompt?.contains("FORMAT REPAIR") == true)
        let audit = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        #expect(audit["modelFormatRepairs"] as? Int == 1)
        #expect(audit["modelEvidenceReviews"] as? Int == 0)
    }

    @Test(arguments: [false, true])
    func unavailableReviewPreservesTheValidAbstentionAndReportsItsFailure(invalidWire: Bool) async throws {
        let first = try wire(task: .systemDesign, evidence: .uncertain, basis: .unknown, clarification: "Which conditions apply?")
        let provider = EvidenceReviewTransport(plans: [.text(first), invalidWire ? .text("{\"task\":false}") : .failure])
        let result = try await InterviewQuestionRouter.resolve(.init(question: "How should the design handle this case?", questionID: UUID().uuidString),
            provider: provider, model: "synthetic-evidence-review")
        #expect(result.task == .systemDesign)
        #expect(result.personalEvidence == .uncertain && result.basis == .unknown)
        #expect(!result.usesCandidateEvidence)
        #expect(result.clarification == "Which conditions apply?")
        #expect(result.modelRequests == 2)
        #expect(result.failure == "evidenceReviewInvalidOrUnavailable")
        #expect(await provider.requests.count == 2)
    }

    @Test
    func selectedTaskAndMissingParentDoNotForcePersonalEvidence() async throws {
        let provider = EvidenceReviewTransport(plans: [
            .text(try wire(evidence: .uncertain, basis: .unknown, relation: .followUp, clarification: "Which design?")),
            .text(try wire(task: .behavioral, evidence: .notRequired, basis: .generalKnowledge, relation: .followUp))
        ])
        let result = try await InterviewQuestionRouter.resolve(.init(question: "How could another design respond?", questionID: UUID().uuidString,
            selectedTask: .project), provider: provider, model: "synthetic-evidence-review")
        #expect(result.task == .project)
        #expect(result.personalEvidence == .notRequired && result.basis == .generalKnowledge)
        #expect(result.relation == .independent)
        #expect(result.parentQuestionID == nil && result.parentQuestionText == nil && result.parentAnswerText == nil)
        #expect(!result.clarification.isEmpty)
        #expect(!result.usesCandidateEvidence)
        #expect(result.modelRequests == 2 && result.failure == nil)
    }

    @Test
    func historicalDecisionWithoutAuditCountsRetainsItsEvidenceAndIdentity() async throws {
        let provider = EvidenceReviewTransport(plans: [.text(try wire(evidence: .required, basis: .candidateRecord))])
        let input = InterviewRoutingInput(question: "Describe a real action you took.", questionID: UUID().uuidString,
            revision: 4, contextSnapshotID: "synthetic-frozen-context", artifactRevision: 2)
        let decision = try await InterviewQuestionRouter.resolve(input, provider: provider, model: "synthetic-evidence-review")
        var legacy = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(decision)) as? [String: Any])
        legacy.removeValue(forKey: "modelFormatRepairs")
        legacy.removeValue(forKey: "modelEvidenceReviews")
        let restored = try JSONDecoder().decode(InterviewQuestionDecision.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(restored.personalEvidence == .required && restored.basis == .candidateRecord)
        #expect(restored.usesCandidateEvidence)
        #expect(restored.questionID == input.questionID && restored.questionRevision == 4)
        #expect(restored.contextSnapshotID == input.contextSnapshotID && restored.artifactRevision == 2)
        #expect(restored.model == "synthetic-evidence-review")
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingTheReviewTerminatesTheActualProviderStreamWithoutPublishing() async throws {
        let provider = EvidenceReviewTransport(plans: [.text(try wire(evidence: .uncertain, basis: .unknown)), .held])
        let trace = TestEventWaitTrace(label: "router.evidence-review.cancel")
        let caller = Task {
            do {
                let result = try await InterviewQuestionRouter.resolve(.init(question: "Which kind of information is requested?", questionID: UUID().uuidString),
                    provider: provider, model: "synthetic-evidence-review")
                await provider.finishStartEvents()
                return result
            } catch {
                await provider.finishStartEvents()
                throw error
            }
        }
        do {
            #expect(try await trace.nextEvent(in: provider.started, event: "first_request") == 0)
            #expect(try await trace.nextEvent(in: provider.started, event: "review_request") == 1)
            caller.cancel()
            #expect(try await trace.nextEvent(in: provider.terminated, event: "review_terminated") == 1)
            do {
                _ = try await caller.value
                Issue.record("Cancelled routing published a decision.")
            } catch is CancellationError { }
            await provider.release()
            #expect(await provider.requests.count == 2)
        } catch {
            caller.cancel()
            await provider.release()
            _ = try? await caller.value
            throw error
        }
    }

    @Test(arguments: [false, true])
    func primaryExplanationRequestKeepsOperationAndActualFactsIndependent(actualPractice: Bool) async throws {
        let question = actualPractice
            ? "Explain the procedure you actually follow when teaching a teammate a new tool."
            : "Explain a proposed procedure for teaching a teammate a new tool in a hypothetical scenario."
        let evidence: PersonalEvidenceRequirement = actualPractice ? .required : .notRequired
        let basis: QuestionAnswerBasis = actualPractice ? .candidateRecord : .generalKnowledge
        // A scripted task label is deliberately the same in both packets. This
        // verifies request/admission independence, not live model classification.
        let provider = EvidenceReviewTransport(plans: [.text(try wire(task: .generalKnowledge, evidence: evidence, basis: basis))])
        let input = InterviewRoutingInput(question: question, questionID: UUID().uuidString,
            revision: 3, contextSnapshotID: "synthetic-operation-facts", artifactRevision: 2, language: "en")
        let result = try await InterviewQuestionRouter.resolve(input, provider: provider, model: "synthetic-operation-facts")
        #expect(result.task == .generalKnowledge && result.personalEvidence == evidence && result.basis == basis)
        #expect(result.usesCandidateEvidence == actualPractice)
        #expect(result.questionID == input.questionID && result.questionRevision == 3)
        #expect(result.contextSnapshotID == input.contextSnapshotID && result.artifactRevision == 2)
        #expect(result.modelRequests == 1 && result.failure == nil)
        let requests = await provider.requests
        let first = try #require(requests.first)
        #expect(requests.count == 1)
        let payload = try #require(try JSONSerialization.jsonObject(with: Data(first.prompt.utf8)) as? [String: Any])
        #expect(payload["question"] as? String == question && payload["hasParent"] as? Bool == false)
        #expect(Set(payload.keys) == ["question", "language", "hasParent"])
        #expect(first.responseSchema == InterviewQuestionRouter.Wire.schema)
        #expect(first.modelName == "synthetic-operation-facts" && first.temperature == 0 && first.numPredict == 260 && !first.thinkingEnabled)
        let system = try #require(first.systemPrompt)
        let scope = try #require(system.range(of: "Determine two independent properties: the requested operation (task), and the facts a truthful answer must assert"))
        let taskDefinitions = try #require(system.range(of: "\ntask: motivation ="))
        #expect(scope.lowerBound < taskDefinitions.lowerBound)
    }

    @Test(arguments: [false, true])
    func primaryFactsProtocolDoesNotReplaceExistingUncertainReview(actualPractice: Bool) async throws {
        let evidence: PersonalEvidenceRequirement = actualPractice ? .required : .notRequired
        let basis: QuestionAnswerBasis = actualPractice ? .candidateRecord : .generalKnowledge
        let provider = EvidenceReviewTransport(plans: [
            .text(try wire(task: .generalKnowledge, evidence: .uncertain, basis: .unknown)),
            .text(try wire(task: .behavioral, evidence: evidence, basis: basis))
        ])
        let question = actualPractice ? "Explain the checking procedure you actually use." : "Explain a hypothetical checking procedure."
        let result = try await InterviewQuestionRouter.resolve(.init(question: question, questionID: UUID().uuidString),
            provider: provider, model: "synthetic-operation-facts")
        #expect(result.task == .generalKnowledge && result.personalEvidence == evidence && result.basis == basis)
        #expect(result.modelRequests == 2 && result.modelEvidenceReviews == 1 && result.failure == nil)
        let requests = await provider.requests
        #expect(requests.count == 2)
        guard requests.count == 2 else { return }
        #expect(requests[0].prompt == requests[1].prompt && requests[0].responseSchema == requests[1].responseSchema)
        #expect(requests.allSatisfy { $0.temperature == 0 && $0.numPredict == 260 && !$0.thinkingEnabled })
        let first = try #require(requests[0].systemPrompt)
        let review = try #require(requests[1].systemPrompt)
        #expect(first.contains(InterviewQuestionRouter.evidenceDependencyPolicy))
        #expect(review.contains(InterviewQuestionRouter.evidenceDependencyPolicy))
        #expect(review.contains("Frozen task=generalKnowledge, relation=independent."))
        #expect(review.contains("An unknown task or unidentified referent does not determine personalEvidence"))
    }

    @Test(arguments: [false, true], [false, true])
    func unavailablePrimaryKeepsFactDependenceAndArtifactScope(isPast: Bool, hasArtifact: Bool) async throws {
        let provider = EvidenceReviewTransport(plans: [.failure])
        let input = InterviewRoutingInput(
            question: isPast ? "你之前是不是也遇到过？" : "If you had a failed prototype, how would you recover it?",
            questionID: UUID().uuidString, revision: 4, contextSnapshotID: "synthetic-fallback-scope",
            artifactRevision: 2, artifact: hasArtifact ? "A supplied fictional prototype exercise." : nil,
            selectedTask: .research)
        let result = try await InterviewQuestionRouter.resolve(input, provider: provider, model: "synthetic-fallback")
        let requiresFacts = isPast && !hasArtifact
        #expect(result.personalEvidence == (requiresFacts ? .required : .uncertain))
        #expect(result.basis == (requiresFacts ? .candidateRecord : .unknown))
        #expect(result.usesCandidateEvidence == requiresFacts)
        #expect(result.task == .research && result.source == "userTaskAndLocalEvidence")
        #expect(result.relation == .independent && result.parentQuestionID == nil)
        #expect(result.questionID == input.questionID && result.questionRevision == 4)
        #expect(result.contextSnapshotID == input.contextSnapshotID && result.artifactRevision == 2)
        #expect(result.failure == "invalidOrUnavailable" && result.modelRequests == 1)
        #expect(result.modelPersonalEvidence == nil && result.modelFormatRepairs == 0 && result.modelEvidenceReviews == 0)
        #expect(await provider.requests.count == 1)
    }

    @Test(arguments: [false, true], [false, true])
    func unavailableReviewAppliesPastBoundaryWithoutReplacingTheOperation(isPast: Bool, invalidWire: Bool) async throws {
        let first = try wire(task: .systemDesign, evidence: .uncertain, basis: .unknown,
            clarification: "Which incident is meant?")
        let provider = EvidenceReviewTransport(plans: [.text(first), invalidWire ? .text("{\"task\":false}") : .failure])
        let question = isPast ? "What did you change in your previous prototype?" : "How would you change a proposed prototype?"
        let result = try await InterviewQuestionRouter.resolve(.init(question: question, questionID: UUID().uuidString),
            provider: provider, model: "synthetic-fallback")
        #expect(result.personalEvidence == (isPast ? .required : .uncertain))
        #expect(result.basis == (isPast ? .candidateRecord : .unknown))
        #expect(result.usesCandidateEvidence == isPast)
        #expect(result.task == .systemDesign && result.source == "localStructuredWithEvidenceBoundary")
        #expect(result.relation == .independent && result.clarification == "Which incident is meant?")
        #expect(result.failure == "evidenceReviewInvalidOrUnavailable")
        #expect(result.modelRequests == 2 && result.modelPersonalEvidence == .uncertain)
        #expect(result.modelEvidenceReviews == 1 && result.modelFormatRepairs == 0)
        #expect(await provider.requests.count == 2)
    }

    @Test(arguments: [
        "What did you change in this solution?",
        "Optionally describe how you previously fixed a problem.",
        "In a fictional interview, what did you change in your prototype?"
    ])
    func unavailablePrimaryPreservesCurrentExerciseAndOptionalExclusions(question: String) async throws {
        let provider = EvidenceReviewTransport(plans: [.failure])
        let result = try await InterviewQuestionRouter.resolve(.init(question: question, questionID: UUID().uuidString,
            parentQuestionID: "synthetic-parent", previousQuestion: "Design a notification service."),
            provider: provider, model: "synthetic-fallback")
        #expect(result.personalEvidence == .uncertain && result.basis == .unknown && !result.usesCandidateEvidence)
        #expect(result.task == .unknown && result.source == "safeFallback")
        #expect(result.relation == .independent && result.parentQuestionID == nil && result.parentQuestionText == nil)
        #expect(result.failure == "invalidOrUnavailable" && result.modelRequests == 1)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func timedOutReviewKeepsFinalFactBoundaryAndJoinsItsActualStream(isPast: Bool) async throws {
        let provider = EvidenceReviewTransport(plans: [.text(try wire(evidence: .uncertain, basis: .unknown)), .held])
        let question = isPast ? "Have you ever recovered a failed project?" : "How would you recover a hypothetical failed project?"
        let trace = TestEventWaitTrace(label: "router.fallback.timeout.\(isPast)")
        let caller = Task {
            do {
                let result = try await InterviewQuestionRouter.resolve(.init(question: question, questionID: UUID().uuidString),
                    provider: provider, model: "synthetic-fallback")
                await provider.finishStartEvents()
                return result
            } catch {
                await provider.finishStartEvents()
                throw error
            }
        }
        do {
            #expect(try await trace.nextEvent(in: provider.started, event: "first_request") == 0)
            #expect(try await trace.nextEvent(in: provider.started, event: "review_request") == 1)
            let result = try await caller.value
            #expect(try await trace.nextEvent(in: provider.terminated, event: "review_terminated") == 1)
            await provider.release()
            #expect(result.personalEvidence == (isPast ? .required : .uncertain))
            #expect(result.basis == (isPast ? .candidateRecord : .unknown) && result.usesCandidateEvidence == isPast)
            #expect(result.task == .unknown && result.source == "safeFallback" && result.failure == "timeout")
            #expect(result.modelRequests == 2 && result.modelPersonalEvidence == .uncertain)
            #expect(result.modelEvidenceReviews == 1 && result.modelFormatRepairs == 0)
            #expect(await provider.requests.count == 2)
        } catch {
            caller.cancel()
            await provider.release()
            _ = try? await caller.value
            throw error
        }
    }

    @Test(arguments: [false, true])
    func inputBudgetFailureKeepsOnlyTheBoundedExplicitFactRequirement(isPast: Bool) async throws {
        let provider = EvidenceReviewTransport(plans: [])
        let result = try await InterviewQuestionRouter.resolve(.init(
            question: isPast ? "Have you ever recovered a failed project?" : "How would you recover a hypothetical project?",
            questionID: UUID().uuidString, previousAnswer: String(repeating: "x", count: 12001)),
            provider: provider, model: "synthetic-fallback")
        #expect(result.personalEvidence == (isPast ? .required : .uncertain))
        #expect(result.basis == (isPast ? .candidateRecord : .unknown) && result.usesCandidateEvidence == isPast)
        #expect(result.task == .unknown && result.source == "safeFallback" && result.failure == "inputBudget")
        #expect(result.modelRequests == 0 && result.modelPersonalEvidence == nil)
        #expect(await provider.requests.isEmpty)
    }

    private func wire(task: InterviewTaskKind = .unknown, evidence: PersonalEvidenceRequirement,
                      basis: QuestionAnswerBasis, relation: QuestionConversationRelation = .independent,
                      clarification: String = "") throws -> String {
        String(decoding: try JSONEncoder().encode(InterviewQuestionRouter.Wire(task: task,
            personalEvidence: evidence, basis: basis, relation: relation, clarification: clarification)), as: UTF8.self)
    }
}

private actor EvidenceReviewTransport: LocalLLMProvider {
    enum Plan: Sendable { case text(String), failure, held }
    nonisolated let id = "synthetic-evidence-review"
    nonisolated let displayName = "Synthetic evidence review"
    nonisolated let started: AsyncStream<Int>
    nonisolated let terminated: AsyncStream<Int>
    private let startContinuation: AsyncStream<Int>.Continuation
    private let terminationContinuation: AsyncStream<Int>.Continuation
    private let plans: [Plan]
    private var held: AsyncThrowingStream<LLMToken, Error>.Continuation?
    private(set) var requests: [LocalLLMRequest] = []

    init(plans: [Plan]) {
        self.plans = plans
        (started, startContinuation) = AsyncStream.makeStream(of: Int.self)
        (terminated, terminationContinuation) = AsyncStream.makeStream(of: Int.self)
    }
    func healthCheck(modelName: String) async -> LocalLLMHealth {
        .init(ollamaRunning: true, selectedModel: modelName, modelInstalled: true, providerSource: .localQwen, lastError: nil)
    }
    nonisolated func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> { AsyncThrowingStream { $0.finish() } }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        let index = requests.count
        requests.append(request)
        startContinuation.yield(index)
        guard index < plans.count else { throw MaterialError.invalid("Unexpected extra evidence request.") }
        switch plans[index] {
        case .failure: throw MaterialError.invalid("Synthetic transport failed.")
        case .text(let output):
            return AsyncThrowingStream { continuation in
                continuation.yield(.init(text: output, source: .localQwen, modelName: request.modelName))
                continuation.finish()
            }
        case .held:
            let pair = AsyncThrowingStream<LLMToken, Error>.makeStream()
            let termination = terminationContinuation
            pair.continuation.onTermination = { _ in termination.yield(index) }
            held = pair.continuation
            return pair.stream
        }
    }
    func finishStartEvents() { startContinuation.finish() }
    func release() { held?.finish(); held = nil; startContinuation.finish(); terminationContinuation.finish() }
}
