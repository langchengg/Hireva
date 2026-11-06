import Foundation
import Testing
@testable import Hireva

/// The real evaluator constructs both requests and frozen repair fields.
/// Scripted prose is not evidence of real-model semantic quality.
@Suite
@MainActor
struct PracticeQuestionScopeRequestTests {
    @Test(arguments: Array(0..<10))
    func initialAndFocusedFeedbackPreserveFrozenEvidenceMode(_ variant: Int) async throws {
        let language = variant % 2 == 0 ? "en" : "zh"
        let mode = variant / 2
        let required = mode == 2
        let evidence: PersonalEvidenceRequirement = required ? .required : mode == 3 ? .optional : .notRequired
        let kind: InterviewTaskKind = required ? .behavioral : mode == 1 ? .systemDesign : .generalKnowledge
        var question: String
        let answer: String
        let criteria: [String]
        if required {
            question = language == "en" ? "Describe a real team disagreement and the actual outcome." : "描述一次真实团队分歧与实际结果。"
            answer = language == "en" ? "We disagreed about a meeting format. We plan to test another format next month." : "我们对会议形式有分歧。我们计划下个月测试另一种形式。"
            criteria = language == "en" ? ["Situation", "Observed outcome"] : ["场景", "已观察结果"]
        } else if mode == 1 {
            question = language == "en" ? "How would you prevent duplicate ticket issuance and explain your trade-off?" : "你会怎样防止重复发放票据，并解释取舍？"
            answer = language == "en" ? "The worker stores a claim under a unique database constraint." : "工作进程使用数据库唯一约束保存领取记录。"
            criteria = language == "en" ? ["Proposed mechanism", "Trade-off"] : ["拟用机制", "取舍"]
        } else {
            question = language == "en" ? "Compare an append-only log with a mutable record and explain a limitation." : "比较只追加日志与可修改记录，并解释一个限制。"
            if mode == 3 { question += language == "en" ? " A personal example is optional." : "个人经历示例可选。" }
            answer = language == "en" ? "An append-only log adds records without replacing older entries." : "只追加日志添加记录，而不替换已有条目。"
            criteria = language == "en" ? ["Explain adding records", "Modification limit"] : ["解释添加记录", "修改限制"]
        }
        let quote = required
            ? (language == "en" ? "We disagreed about a meeting format." : "我们对会议形式有分歧。")
            : answer
        let questionID = UUID().uuidString
        var task = InterviewTaskDescriptor(question: question, kind: kind, language: language)
        task.apply(InterviewQuestionDecision(task: kind, personalEvidence: evidence,
            basis: required ? .candidateRecord : mode == 4 ? .providedArtifact : .generalKnowledge, relation: .independent,
            parentQuestionID: nil, parentQuestionText: nil, parentAnswerText: nil,
            source: "synthetic-question-scope", routerVersion: InterviewQuestionRouter.version,
            language: language, clarification: "", questionID: questionID, questionRevision: 2,
            contextSnapshotID: "synthetic-question-scope", artifactRevision: 0,
            model: "synthetic-question-scope", failure: nil, latencyMS: 0))
        task.criteria = criteria
        let attempt = PracticeAttempt(questionID: questionID, question: question, answer: answer,
            contextSnapshotID: "synthetic-question-scope", revision: 2, hinted: false, skipped: false,
            source: "synthetic-question-scope", task: task)
        let followUp = required
            ? (language == "en" ? "What has actually been observed so far, if anything?" : "目前实际观察到了什么，如果有的话？")
            : mode == 1
                ? (language == "en" ? "What trade-off would the proposed mechanism make?" : "拟用机制会做什么取舍？")
                : (language == "en" ? "What limits apply to modifying existing entries?" : "修改已有条目有哪些限制？")
        let initial = ["r0": quote, "r1": "", "followUp": followUp,
                       "reason": language == "en" ? "The second criterion remains missing." : "第二项仍缺失。",
                       "suggestion": language == "en" ? "Add the requested missing information." : "补充所问的缺失信息。",
                       "reference": language == "en" ? "Describe the applicable mechanism and limitation." : "说明适用机制与限制。"]
        let reviewedReference = mode == 1
            ? (language == "en" ? "A unique claim can coordinate admission; external issuance also needs bounded ownership and idempotent effects, with contention as a trade-off." : "唯一领取记录可协调接纳；外部发放还需要有界所有权和幂等副作用，争用是其中的取舍。")
            : (language == "en" ? "An append-only log retains older entries and adds new records; correcting an entry requires a later record rather than replacing it." : "只追加日志保留旧条目并添加新记录；纠正条目通过后续记录表达，而不是替换旧记录。")
        let provider = ScopeRequestTransport(initial: try scriptedPracticePacket(initial, fulfilledIDs: ["r0"]), followUp: followUp, reviewedReference: reviewedReference)
        let feedback = try await PracticeController.evaluate(attempt: attempt, task: task, attachment: nil,
            evidence: [], provider: provider, model: "synthetic-question-scope")
        #expect(feedback.covered.map(\.quote) == [quote])
        #expect(feedback.missing == [criteria[1]])
        #expect(feedback.followUp == followUp)
        let requests = await provider.requests
        try #require(requests.count == 2)
        for request in requests {
            let system = try #require(request.systemPrompt)
            #expect(system.contains("A question or submitted answer is not confirmed biographical evidence.") == (mode != 0))
            #expect(system.contains("In all cases, any claim of personal accomplishments or metrics must pass source validation.") == (mode != 0))
            #expect(system.contains("Never turn external requirements or generated text into candidate facts."))
            if mode == 4 { #expect(system.contains("Use only the current question artifact/solution and its frozen version, not past projects.")) }
            if required {
                #expect(system.contains("Activities stated as future plans remain future."))
                #expect(system.contains("Do not ask for a planned activity's result or ask whether that future activity has already happened."))
                #expect(system.contains("A future test is not the only possible outcome of the past event."))
                #expect(!system.contains("This question does not require personal history."))
            } else if mode == 3 {
                #expect(system.contains("Personal illustration remains optional."))
                #expect(system.contains("Preserve a relevant source-supported illustration if one is supplied"))
                #expect(system.contains("never demand an absent past experience, personal source or observed result merely to answer a general criterion."))
                #expect(system.contains("Even when all criteria are covered, suggestions must not add a past-experience requirement."))
            } else {
                #expect(system.contains("This question does not require personal history."))
                #expect(system.contains("never require what the candidate previously did, encountered, measured or observed in practice."))
                #expect(system.contains("An example can be hypothetical."))
                #expect(system.contains("Even when all criteria are covered, suggestions must not add a past-experience requirement."))
            }
            #expect(request.temperature == 0 && request.numPredict == 1200)
            #expect(request.modelName == "synthetic-question-scope")
            let payload = try JSONDecoder().decode([String: String].self, from: Data(request.prompt.utf8))
            #expect(payload["question"] == question && payload["answer"] == answer)
            #expect(payload["source_evidence"] == "" && payload["attachment"] == "")
        }
        let repair = requests[1]
        let payload = try JSONDecoder().decode([String: String].self, from: Data(repair.prompt.utf8))
        #expect(payload["draft_first_missing_rubric_id"] == nil)
        #expect(payload["draft_first_missing_rubric_criterion"] == nil)
        #expect(payload["rubric"] == criteria.enumerated().map { "r\($0.offset): \($0.element)" }.joined(separator: "\n"))
        #expect(payload["previous_invalid_output"] == nil)
        #expect(payload["draft_feedback"] == nil)
        #expect(feedback.assessments?.map(\.judgment.fulfillment) == [.met, .unmet])
        let fields = try schemaFields(repair)
        #expect(fields["r0"]?["type"] as? String == "string" && fields["r0"]?["const"] == nil)
        #expect(fields["r1"]?["type"] as? String == "string" && fields["r1"]?["const"] == nil)
        if required {
            #expect(fields["reference"]?["const"] as? String == "")
            #expect(feedback.reference == PracticeFeedback.sourceLimitedReference(language: language))
        }
        else {
            #expect(fields["reference"]?["const"] == nil)
            #expect(feedback.reference == reviewedReference)
        }
    }

    @Test(arguments: ["en", "zh"])
    func alreadyCoveredGeneralFeedbackStillCannotRequirePastExperience(_ language: String) async throws {
        let question = language == "en" ? "Explain why an append-only log retains old entries." : "解释只追加日志为什么保留旧条目。"
        let answer = language == "en" ? "It appends new entries without replacing earlier ones." : "它添加新条目，而不替换此前条目。"
        let questionID = UUID().uuidString
        var task = InterviewTaskDescriptor(question: question, kind: .generalKnowledge, language: language)
        task.apply(InterviewQuestionDecision(task: .generalKnowledge, personalEvidence: .notRequired,
            basis: .generalKnowledge, relation: .independent, parentQuestionID: nil,
            parentQuestionText: nil, parentAnswerText: nil, source: "synthetic-question-scope",
            routerVersion: InterviewQuestionRouter.version, language: language, clarification: "",
            questionID: questionID, questionRevision: 1, contextSnapshotID: nil, artifactRevision: 0,
            model: "synthetic-question-scope", failure: nil, latencyMS: 0))
        task.criteria = [language == "en" ? "Explain retained entries" : "解释保留条目"]
        let attempt = PracticeAttempt(questionID: questionID, question: question, answer: answer,
            contextSnapshotID: nil, revision: 1, hinted: false, skipped: false, source: "synthetic-question-scope", task: task)
        let provider = ScopeRequestTransport(initial: try scriptedPracticePacket(["r0": answer, "followUp": "", "reason": language == "en" ? "The mechanism is covered." : "已解释该机制。",
            "suggestion": "", "reference": language == "en" ? "An append-only log adds records without replacing older entries." : "只追加日志添加记录而不替换旧条目。"], fulfilledIDs: ["r0"]), followUp: "",
            reviewedReference: language == "en" ? "An append-only log adds records without replacing older entries." : "只追加日志添加记录而不替换旧条目。")
        let feedback = try await PracticeController.evaluate(attempt: attempt, task: task, attachment: nil,
            evidence: [], provider: provider, model: "synthetic-question-scope")
        #expect(feedback.missing.isEmpty && feedback.followUp == nil)
        let requests = await provider.requests
        try #require(requests.count == 2)
        let reviewInput = try JSONDecoder().decode([String: String].self, from: Data(requests[1].prompt.utf8))
        #expect(reviewInput["draft_feedback"] == nil && reviewInput["draft_first_missing_rubric_id"] == nil)
        #expect(requests[1].systemPrompt?.contains("Even when all criteria are covered, suggestions must not add a past-experience requirement.") == true)
        #expect(requests[0].systemPrompt?.contains("Even when all criteria are covered, suggestions must not add a past-experience requirement.") == true)
    }

    @Test(arguments: Array(0..<4))
    func aReferenceRequiresConditionsOnInitialAndFreshReviewAfterInvalidPrimary(_ variant: Int) async throws {
        let language = variant % 2 == 0 ? "en" : "zh"
        let repair = variant / 2 == 1
        let question = language == "en" ? "Does encryption alone prevent unauthorized account access? Explain its role." : "仅加密能防止未经授权的账户访问吗？解释它的作用。"
        let answer = language == "en" ? "Encryption transforms plaintext into ciphertext using a key." : "加密使用密钥将明文转换为密文。"
        let reference = language == "en"
            ? "Encryption protects content subject to key and algorithm assumptions; account access also depends on authentication, authorization and key handling."
            : "加密对内容的保护取决于密钥与算法条件；账户访问还取决于身份验证、授权与密钥管理。"
        let questionID = UUID().uuidString
        var task = InterviewTaskDescriptor(question: question, kind: .generalKnowledge, language: language)
        task.apply(InterviewQuestionDecision(task: .generalKnowledge, personalEvidence: .notRequired,
            basis: .generalKnowledge, relation: .independent, parentQuestionID: nil,
            parentQuestionText: nil, parentAnswerText: nil, source: "synthetic-reference-conditions",
            routerVersion: InterviewQuestionRouter.version, language: language, clarification: "",
            questionID: questionID, questionRevision: 1, contextSnapshotID: nil, artifactRevision: 0,
            model: "synthetic-reference-conditions", failure: nil, latencyMS: 0))
        task.criteria = [language == "en" ? "Explain encryption's role" : "解释加密作用"]
        let attempt = PracticeAttempt(questionID: questionID, question: question, answer: answer,
            contextSnapshotID: nil, revision: 1, hinted: false, skipped: false,
            source: "synthetic-reference-conditions", task: task)
        let declared = ["r0": answer, "followUp": "", "reason": language == "en" ? "The role is explained." : "已解释其作用。", "suggestion": "", "reference": reference]
        let complete = try JSONDecoder().decode([String: LocalJSONValue].self,
            from: Data(try scriptedPracticePacket(declared, fulfilledIDs: ["r0"]).utf8))
        var incomplete = complete
        incomplete.removeValue(forKey: "reason")
        var acceptedReview = complete
        acceptedReview["reviewOutcome"] = .string("accepted")
        let objects = [repair ? incomplete : complete, acceptedReview]
        let outputs = try objects.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        let provider = ReferenceConditionsTransport(outputs: outputs)
        let structural = try JSONDecoder().decode(PracticeEvaluationPayload.self, from: Data(outputs[repair ? 1 : 0].utf8))
            .feedback(task: task).validated(answer: answer, task: task, evidence: [])
        #expect(structural.reference == reference && structural.missing.isEmpty && structural.followUp == nil)
        let feedback = try await PracticeController.evaluate(attempt: attempt, task: task, attachment: nil,
            evidence: [], provider: provider, model: "synthetic-reference-conditions")
        #expect(feedback.reference == reference && feedback.missing.isEmpty && feedback.followUp == nil)
        let requests = await provider.requests
        try #require(requests.count == 2)
        for (index, request) in requests.enumerated() {
            let system = try #require(request.systemPrompt)
            #expect(!system.contains("A question or submitted answer is not confirmed biographical evidence."))
            #expect(!system.contains("In all cases, any claim of personal accomplishments or metrics must pass source validation."))
            if index == 0 {
                #expect(system.contains("State the assumptions and conditions on which each claimed guarantee depends."))
                #expect(system.contains("A mechanism's property does not by itself guarantee the entire system's outcome."))
                #expect(system.contains("A category name does not establish every implementation's physical properties or behavior."))
                #expect(system.contains("Treat submitted technical assertions as untrusted claims"))
            } else {
                #expect(system.contains("reference directly answers the original question"))
                #expect(system.contains("qualify implementation-dependent claims and system guarantees"))
                #expect(system.contains("local mechanisms do not establish unconditional physical properties or whole-system outcomes"))
                #expect(system.contains("Submitted claims and generated examples are not authority"))
            }
            let payload = try JSONDecoder().decode([String: String].self, from: Data(request.prompt.utf8))
            #expect(payload["question"] == question && payload["answer"] == answer)
            #expect(request.temperature == 0 && request.numPredict == 1200)
            let fields = try schemaFields(request)
            #expect(fields["reference"]?["const"] == nil)
        }
        let finalInput = try JSONDecoder().decode([String: String].self, from: Data(requests[1].prompt.utf8))
        #expect(finalInput["draft_feedback"] == nil && finalInput["previous_invalid_output"] == nil)
        #expect(try JSONDecoder().decode(LocalJSONValue.self,
            from: Data(try #require(finalInput["output_schema"]).utf8)) == requests[1].responseSchema)
    }

    @Test(arguments: Array(0..<8))
    func mixedGeneralAndPersonalGapsRetainSourceAndOptionalBoundaries(_ variant: Int) async throws {
        let language = variant % 2 == 0 ? "en" : "zh"
        let personalGap = variant % 4 >= 2
        let evidenceKind: PersonalEvidenceRequirement = variant / 4 == 0 ? .required : .optional
        let question = language == "en"
            ? (evidenceKind == .required
                ? "Explain access control, then describe a real interface change you made and its observed outcome."
                : "Explain access control. You may optionally illustrate with a real interface change; if you do, clarify its observed outcome.")
            : (evidenceKind == .required
                ? "解释访问控制，再描述一次你实际完成的界面改动和已观察结果。"
                : "解释访问控制。可以选择用一次真实界面改动举例；如使用，请说明已观察结果。")
        let general = language == "en" ? "Access control checks a caller's permissions before a protected action." : "访问控制在受保护操作之前检查调用者权限。"
        let personal = language == "en" ? "I reviewed a theatre booking interface and identified an unchecked action." : "我审查了剧院订票界面，发现一个未检查权限的操作。"
        let incompletePersonal = language == "en" ? "I reviewed a theatre booking interface." : "我审查了剧院订票界面。"
        let answer = personalGap ? general + " " + incompletePersonal : personal
        let criteria = language == "en" ? ["Explain access control", "Observed outcome of the supplied personal example"] : ["解释访问控制", "已给个人示例的实际观察结果"]
        let source = ProfileEvidence(id: "synthetic-mixed-source", statement: personal,
            sourceDocumentID: "synthetic-mixed-document", sourceChunkID: nil, sourceSpan: nil,
            confidence: 0.8, evidenceType: .achievement, explicitness: .explicit)
        let questionID = UUID().uuidString
        var task = InterviewTaskDescriptor(question: question, kind: .generalKnowledge, language: language)
        task.apply(InterviewQuestionDecision(task: .generalKnowledge, personalEvidence: evidenceKind,
            basis: .mixed, relation: .independent, parentQuestionID: nil,
            parentQuestionText: nil, parentAnswerText: nil, source: "synthetic-mixed-scope",
            routerVersion: InterviewQuestionRouter.version, language: language, clarification: "",
            questionID: questionID, questionRevision: 3, contextSnapshotID: "synthetic-mixed-scope",
            artifactRevision: 0, model: "synthetic-mixed-scope", failure: nil, latencyMS: 0))
        task.criteria = criteria
        let attempt = PracticeAttempt(questionID: questionID, question: question, answer: answer,
            contextSnapshotID: "synthetic-mixed-scope", revision: 3, hinted: false, skipped: false,
            source: "synthetic-mixed-scope", task: task)
        let followUp = personalGap
            ? (language == "en" ? "What did you actually observe in the interface example you supplied?" : "你已给出的界面示例中，实际观察到了什么？")
            : (language == "en" ? "How does access control decide whether to permit a protected action?" : "访问控制如何决定是否允许受保护操作？")
        let initial = ["r0": personalGap ? general : "", "r1": personalGap ? "" : personal,
            "followUp": followUp, "reason": language == "en" ? "One requested part remains missing." : "仍缺一项所问信息。",
            "suggestion": language == "en" ? "Add the missing part." : "补充缺失部分。",
            "reference": language == "en" ? "Access control checks authorization for a protected operation." : "访问控制检查受保护操作的授权。"]
        let reviewedReference = language == "en"
            ? "Access control checks permission before a protected operation. The supplied source states that the candidate reviewed an interface and identified an unchecked action; it does not establish a completed deployment."
            : "访问控制在受保护操作前检查权限。已给来源说明候选人审查界面并发现未检查权限的操作；该来源没有证明已完成部署。"
        let provider = ScopeRequestTransport(initial: try scriptedPracticePacket(initial, fulfilledIDs: personalGap ? ["r0"] : ["r1"]), followUp: followUp, reviewedReference: reviewedReference)
        let feedback = try await PracticeController.evaluate(attempt: attempt, task: task, attachment: nil,
            evidence: [source], provider: provider, model: "synthetic-mixed-scope")
        #expect(task.decision?.usesCandidateEvidence == true && PromptContextBuilder.usesProfileContext(task))
        #expect(feedback.covered.map(\.quote) == [personalGap ? general : personal])
        #expect(feedback.missing == [criteria[personalGap ? 1 : 0]])
        #expect(feedback.followUp == followUp)
        let requests = await provider.requests
        try #require(requests.count == 2)
        for request in requests {
            let system = try #require(request.systemPrompt)
            #expect(system.contains("A question or submitted answer is not confirmed biographical evidence."))
            #expect(system.contains("In all cases, any claim of personal accomplishments or metrics must pass source validation."))
            #expect(system.contains("For mixed questions, preserve the separately requested general and personal parts."))
            #expect(system.contains("A missing general criterion asks for general reasoning, not a new past experience."))
            #expect(system.contains("Ask for personal facts only for an explicitly requested actual personal part; an optional illustration remains optional."))
            #expect(system.contains("Preserve relevant source-supported personal content without inventing absent facts."))
            #expect(!system.contains("This question does not require personal history."))
            let payload = try JSONDecoder().decode([String: String].self, from: Data(request.prompt.utf8))
            #expect(payload["source_evidence"] == source.statementForPrompt)
            #expect(payload["question"] == question && payload["answer"] == answer)
        }
        let repair = try JSONDecoder().decode([String: String].self, from: Data(requests[1].prompt.utf8))
        #expect(repair["draft_first_missing_rubric_id"] == nil)
        #expect(repair["draft_first_missing_rubric_criterion"] == nil)
        #expect(repair["rubric"] == criteria.enumerated().map { "r\($0.offset): \($0.element)" }.joined(separator: "\n"))
        #expect(repair["draft_feedback"] == nil)
        #expect(feedback.assessments?.map(\.judgment.fulfillment) == (personalGap ? [.met, .unmet] : [.unmet, .met]))
        #expect(repair["previous_invalid_output"] == nil)
        let fields = try schemaFields(requests[1])
        #expect(fields["reference"]?["const"] == nil)
        #expect(feedback.reference == reviewedReference)
    }

    private func schemaFields(_ request: LocalLLMRequest) throws -> [String: [String: Any]] {
        let schema = try #require(request.responseSchema)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(schema)) as? [String: Any]
        return try #require(object?["properties"] as? [String: [String: Any]])
    }
}

private actor ScopeRequestTransport: LocalLLMProvider {
    nonisolated let id = "synthetic-question-scope"
    nonisolated let displayName = "Synthetic question scope"
    private let initial: String
    private let followUp: String
    private let reviewedReference: String
    private(set) var requests: [LocalLLMRequest] = []
    init(initial: String, followUp: String, reviewedReference: String) {
        self.initial = initial; self.followUp = followUp; self.reviewedReference = reviewedReference
    }
    func healthCheck(modelName: String) async -> LocalLLMHealth {
        .init(ollamaRunning: true, selectedModel: modelName, modelInstalled: true, providerSource: .localQwen, lastError: nil)
    }
    nonisolated func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        let index = requests.count
        requests.append(request)
        guard index < 2 else { throw MaterialError.invalid("Unexpected third scope request.") }
        var output = try JSONDecoder().decode([String: LocalJSONValue].self, from: Data(initial.utf8))
        if index == 1 {
            let input = try JSONDecoder().decode([String: String].self, from: Data(request.prompt.utf8))
            guard input["draft_feedback"] == nil, input["previous_invalid_output"] == nil else {
                throw MaterialError.invalid("The declared accepted scope packet belongs only to independent review.")
            }
            let schema = try #require(request.responseSchema)
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(schema)) as? [String: Any]
            let fields = try #require(object?["properties"] as? [String: [String: Any]])
            // Preserve the explicitly declared same-answer metadata; the fake never infers fulfillment from schema.
            for (name, field) in fields {
                if let fixed = field["const"] as? String { output[name] = .string(fixed) }
            }
            if fields["reference"]?["const"] == nil { output["reference"] = .string(reviewedReference) }
            output["reviewOutcome"] = .string("accepted") // Declared script, never inferred from response schema.
            output["followUp"] = .string(followUp)
        }
        let text = String(decoding: try JSONEncoder().encode(output), as: UTF8.self)
        return AsyncThrowingStream { continuation in
            continuation.yield(.init(text: text, source: .localQwen, modelName: request.modelName))
            continuation.finish()
        }
    }
}

private actor ReferenceConditionsTransport: LocalLLMProvider {
    nonisolated let id = "synthetic-reference-conditions"
    nonisolated let displayName = "Synthetic reference conditions"
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
        guard index < outputs.count else { throw MaterialError.invalid("Unexpected extra reference-conditions request.") }
        let output = outputs[index]
        return AsyncThrowingStream { continuation in
            continuation.yield(.init(text: output, source: .localQwen, modelName: request.modelName))
            continuation.finish()
        }
    }
}
