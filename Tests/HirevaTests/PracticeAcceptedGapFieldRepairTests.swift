import Foundation
import Combine
import Testing
@testable import Hireva

/// Real evaluator/admission and controller revision boundaries; finite packets
/// prove the request contract, not a real model's semantic correctness.
@Suite
@MainActor
struct PracticeAcceptedGapFieldRepairTests {
    @Test
    func gapQuestionRepairReceivesAdmittedPersonalSupport() async throws {
        let fixture = try makeFixture(personal: true)
        let answer = "I built a prototype and tested transaction rollback by injecting failures."
        var attempt = fixture.attempt
        attempt.answer = answer
        var final = try JSONDecoder().decode([String: LocalJSONValue].self, from: Data(fixture.finalWire.utf8))
        final["r0"] = .string(answer)
        guard case .object(var assessments)? = final["assessments"],
              case .object(var action)? = assessments["r0"] else {
            Issue.record("The controlled final map needs its action assessment."); return
        }
        action["accuracy"] = .string("supported")
        action["accuracyBasis"] = .string("The candidate stated this action.")
        assessments["r0"] = .object(action)
        final["assessments"] = .object(assessments)
        let provider = GapFieldPackets(outputs: [fixture.primaryWire,
            String(decoding: try JSONEncoder().encode(final), as: UTF8.self), fixture.questionWire])
        let feedback = try await PracticeController.evaluate(attempt: attempt, task: fixture.task,
            attachment: nil, evidence: [], provider: provider, model: "synthetic-gap-field")
        let requests = await provider.recorded()
        try #require(requests.count == 3)
        let input = try JSONDecoder().decode([String: String].self, from: Data(requests[2].prompt.utf8))
        let accepted = try JSONDecoder().decode(GapFieldAcceptedMap.self,
            from: Data(try #require(input["accepted_final_feedback"]).utf8))
        #expect(accepted.quotes["r0"] == answer && accepted.assessments["r0"]?.fulfillment == .met)
        #expect(accepted.assessments["r0"]?.accuracy == .unverified)
        #expect(feedback.assessments?.first?.judgment.accuracy == .unverified)
        #expect(feedback.missing == [fixture.task.criteria[1]] && feedback.followUp == fixture.question["followUp"])
    }

    @Test(arguments: Array(0..<8))
    func acceptedFinalGapGetsOneQuestionOnlyRepair(_ variant: Int) async throws {
        let language = variant % 2 == 0 ? "en" : "zh"
        let personal = variant / 4 == 1
        let malformedPrimary = variant % 4 >= 2
        let fixture = try makeFixture(language: language, personal: personal)
        let provider = GapFieldPackets(outputs: [malformedPrimary ? "not JSON" : fixture.primaryWire,
            fixture.finalWire, fixture.questionWire])
        let feedback = try await evaluate(fixture, provider)
        #expect(feedback.covered.map(\.quote) == [fixture.quote])
        #expect(feedback.missing == [fixture.task.criteria[1]])
        #expect(feedback.followUp == fixture.question["followUp"])
        #expect(feedback.reason == fixture.final["reason"])
        #expect(feedback.suggestions == [fixture.final["suggestion"]!])
        #expect(feedback.reference == (personal
            ? PracticeFeedback.sourceLimitedReference(language: language) : fixture.final["reference"]))
        let requests = await provider.recorded()
        try #require(requests.count == 3)
        let input = try JSONDecoder().decode([String: String].self, from: Data(requests[2].prompt.utf8))
        #expect(input["first_missing_rubric_id"] == "r1")
        #expect(input["first_missing_rubric_criterion"] == fixture.task.criteria[1])
        #expect(input["repair_reason"] == "accepted_final_gap_question_missing")
        #expect(input["repair_attempt"] == "1" && input["repair_limit"] == "1")
        #expect(input["question"] == fixture.attempt.question && input["answer"] == fixture.attempt.answer)
        let frozen = try JSONDecoder().decode(GapFieldAcceptedMap.self,
            from: Data(try #require(input["accepted_final_feedback"]).utf8))
        let rubricIDs = Set(fixture.task.criteria.indices.map { "r\($0)" })
        #expect(frozen.quotes == fixture.final.filter { rubricIDs.contains($0.key) })
        #expect(Set(frozen.assessments.keys) == rubricIDs)
        #expect(frozen.assessments["r0"]?.fulfillment == .met && frozen.assessments["r1"]?.fulfillment == .unmet)
        #expect(Set(frozen.quotes.keys) == rubricIDs)
        let acceptedFields = try JSONDecoder().decode([String: LocalJSONValue].self,
            from: Data(try #require(input["accepted_final_feedback"]).utf8))
        #expect(Set(acceptedFields.keys) == ["quotes", "assessments"])
        #expect(input["rubric"] == "r1: \(fixture.task.criteria[1])")
        #expect(input["rubric"]?.contains(fixture.task.criteria[0]) == false)
        #expect(input["source_evidence"] == "" && input["attachment"] == "")
        #expect(input["application_reference_notice"] == nil)
        let grounded = try JSONDecoder().decode(LocalJSONValue.self,
            from: Data(try #require(input["output_schema"]).utf8))
        #expect(grounded == requests[2].responseSchema)
        guard case .object(let contract) = grounded,
              case .object(let properties)? = contract["properties"],
              case .object(let questionField)? = properties["followUp"],
              case .string(let description)? = questionField["description"] else {
            Issue.record("Gap repair omitted the selected criterion's semantic contract."); return
        }
        #expect(Set(properties.keys) == ["followUp"])
        #expect(questionField["type"] == .string("string") && questionField["minLength"] == .number(1))
        #expect(contract["required"] == .array([.string("followUp")]) && contract["additionalProperties"] == .boolean(false))
        #expect(description.contains("r1: \(fixture.task.criteria[1])"))
        #expect(!description.contains("r0:") && !description.contains(fixture.task.criteria[0]))
        #expect(description.contains("Do not presuppose a difference or fact"))
        #expect(description.contains("This selected criterion is the request target"))
        #expect(description.contains("essential explanatory concepts remain allowed"))
        #expect(requests[2].responseSchemaPropertyOrder == ["followUp"])
        #expect(requests[2].numPredict == 256 && requests[2].temperature == 0)
        #expect(!requests[2].thinkingEnabled && requests[2].prompt.utf8.count <= 24000)
        #expect(requests[2].systemPrompt?.contains("Keep future activities as future") == true)
    }

    @Test(arguments: ["en", "zh"])
    func sourceLimitedEmptyWireReferencePreservesOneQuestionRepair(language: String) async throws {
        let fixture = try makeFixture(language: language, personal: true)
        let canonical = PracticeFeedback.sourceLimitedReference(language: language)
        var primary = fixture.primary
        var final = fixture.final
        primary["reference"] = ""
        final["reference"] = ""
        let provider = GapFieldPackets(outputs: [
            try scriptedPracticePacket(primary, fulfilledIDs: []),
            try scriptedPracticePacket(final, fulfilledIDs: ["r0"]), fixture.questionWire
        ])
        var feedback: PracticeFeedback?
        var failure: String?
        do { feedback = try await evaluate(fixture, provider) }
        catch { failure = error.localizedDescription }

        let requests = await provider.recorded()
        #expect(requests.count == 3, "Only the existing accepted-gap question repair may follow the two evaluation requests.")
        for (index, request) in requests.enumerated() {
            let input = try JSONDecoder().decode([String: String].self, from: Data(request.prompt.utf8))
            #expect(input["question"] == fixture.attempt.question && input["answer"] == fixture.attempt.answer)
            #expect(input["source_evidence"] == "" && input["attachment"] == "")
            #expect(input["application_reference_notice"] == nil)
            #expect(!request.prompt.contains(canonical) && !(request.systemPrompt ?? "").contains(canonical))
            let schema = try #require(request.responseSchema)
            let embedded = try JSONDecoder().decode(LocalJSONValue.self,
                from: Data(try #require(input["output_schema"]).utf8))
            #expect(embedded == schema)
            #expect(!String(decoding: try JSONEncoder().encode(schema), as: UTF8.self).contains(canonical))
            if index < 2 {
                guard case .object(let object) = schema, case .object(let fields)? = object["properties"] else {
                    Issue.record("Evaluation request omitted its field contract."); continue
                }
                #expect(fields["reference"] == .object(["type": .string("string"), "const": .string("")]))
                #expect(request.numPredict == 1200 && request.temperature == 0 && !request.thinkingEnabled)
            } else {
                #expect(request.responseSchemaPropertyOrder == ["followUp"] && request.numPredict == 256)
                #expect(input["first_missing_rubric_id"] == "r1")
                #expect(input["rubric"] == "r1: \(fixture.task.criteria[1])")
                let accepted = try JSONDecoder().decode(GapFieldAcceptedMap.self,
                    from: Data(try #require(input["accepted_final_feedback"]).utf8))
                #expect(accepted.quotes == ["r0": fixture.quote, "r1": ""])
                #expect(accepted.assessments["r0"]?.fulfillment == .met && accepted.assessments["r1"]?.fulfillment == .unmet)
            }
        }
        #expect(failure == nil, "Fixed empty wire reference must permit the owned gap repair: \(failure ?? "")")
        let admitted = try #require(feedback)
        #expect(admitted.reference == canonical && admitted.referenceOrigin == .applicationSourceNotice)
        #expect(admitted.covered.map(\.quote) == [fixture.quote] && admitted.missing == [fixture.task.criteria[1]])
        #expect(admitted.followUp == fixture.question["followUp"])
        #expect(admitted.reason == fixture.final["reason"] && admitted.suggestions == [fixture.final["suggestion"]!])
    }

    @Test
    func soleGapProjectionOmitsLaterCriterionButRetainsFullAcceptedMap() async throws {
        let original = try makeFixture()
        var task = original.task
        task.criteria.append("Explain overload recovery")
        task.question += " Explain overload recovery separately."
        var attempt = original.attempt
        attempt.question = task.question
        attempt.task = task
        var primary = original.primary
        primary["r2"] = ""
        var final = original.final
        final["r2"] = ""
        let provider = GapFieldPackets(outputs: [try scriptedPracticePacket(primary, fulfilledIDs: []),
            try scriptedPracticePacket(final, fulfilledIDs: ["r0"]), original.questionWire])
        let feedback = try await PracticeController.evaluate(attempt: attempt, task: task,
            attachment: nil, evidence: [], provider: provider, model: "synthetic-gap-field")
        let requests = await provider.recorded()
        try #require(requests.count == 3)
        let input = try JSONDecoder().decode([String: String].self, from: Data(requests[2].prompt.utf8))
        #expect(input["first_missing_rubric_id"] == "r1")
        #expect(input["first_missing_rubric_criterion"] == task.criteria[1])
        #expect(input["rubric"] == "r1: \(task.criteria[1])")
        #expect(input["rubric"]?.contains(task.criteria[0]) == false)
        #expect(input["rubric"]?.contains(task.criteria[2]) == false)
        #expect(input["question"] == attempt.question && input["answer"] == attempt.answer)
        let map = try JSONDecoder().decode(GapFieldAcceptedMap.self,
            from: Data(try #require(input["accepted_final_feedback"]).utf8))
        #expect(map.quotes == ["r0": original.quote, "r1": "", "r2": ""])
        #expect(Set(map.assessments.keys) == ["r0", "r1", "r2"])
        #expect(map.assessments["r0"]?.fulfillment == .met)
        #expect(map.assessments["r1"]?.fulfillment == .unmet && map.assessments["r2"]?.fulfillment == .unmet)
        #expect(feedback.covered.map(\.quote) == [original.quote])
        #expect(feedback.missing == Array(task.criteria[1...]))
        #expect(feedback.followUp == original.question["followUp"])
        #expect(feedback.reference == final["reference"])
        #expect(feedback.reason == final["reason"] && feedback.suggestions == [final["suggestion"]!])
    }

    @Test
    func englishRepairedQuestionCannotBypassFrozenChineseLanguage() async throws {
        let fixture = try makeFixture(language: "zh")
        let provider = GapFieldPackets(outputs: [fixture.primaryWire, fixture.finalWire,
            "{\"followUp\":\"How is new work handled at capacity?\"}"])
        do { _ = try await evaluate(fixture, provider); Issue.record("English repaired question was admitted for Chinese feedback.") }
        catch { #expect(error.localizedDescription.contains("frozen Chinese feedback language")) }
        #expect(await provider.recorded().count == 3)
        #expect(fixture.attempt.feedback == nil)
    }

    @Test(arguments: GapFieldFinalDefect.allCases, [false, true])
    func rejectedOrInvalidFinalMapHasNoThirdRequest(defect: GapFieldFinalDefect, malformedPrimary: Bool) async throws {
        let fixture = try makeFixture(personal: defect == .changedSourceNotice)
        var final = try JSONDecoder().decode([String: LocalJSONValue].self, from: Data(fixture.finalWire.utf8))
        let expected: String
        switch defect {
        case .rejected: final["reviewOutcome"] = .string("rejected"); expected = "Semantic review rejected"
        case .unverified: final.removeValue(forKey: "reviewOutcome"); expected = "did not verify"
        case .inventedQuote: final["r0"] = .string("A quote from a later revision."); expected = "quote/rubric validation"
        case .blankQuote: final["r0"] = .string(" "); expected = "Criterion assessment conflicts"
        case .inventedID: final["r92"] = .string(""); expected = "omitted or invented rubric IDs"
        case .emptyReference: final["reference"] = .string(" \n "); expected = "empty reference answer"
        case .changedSourceNotice: final["reference"] = .string("A changed source notice."); expected = "source-limited reference"
        case .missingAssessment: final.removeValue(forKey: "assessments"); expected = "assessments"
        case .assessmentQuoteConflict:
            guard case .object(var assessments)? = final["assessments"],
                  case .object(var criterion)? = assessments["r0"] else {
                Issue.record("The controlled final map needs its declared assessment."); return
            }
            criterion["presence"] = .string("absent")
            assessments["r0"] = .object(criterion)
            final["assessments"] = .object(assessments)
            expected = "Criterion assessment conflicts"
        }
        let provider = GapFieldPackets(outputs: [malformedPrimary ? "not JSON" : fixture.primaryWire,
            String(decoding: try JSONEncoder().encode(final), as: UTF8.self), fixture.questionWire])
        do { _ = try await evaluate(fixture, provider); Issue.record("Invalid final feedback entered question repair.") }
        catch { #expect(error.localizedDescription.contains(expected)) }
        #expect(await provider.recorded().count == 2)
    }

    @Test(arguments: GapFieldRepairDefect.allCases)
    func ignoredQuestionSchemaFailsWithoutFourthRequest(defect: GapFieldRepairDefect) async throws {
        let fixture = try makeFixture()
        var question = fixture.question
        switch defect {
        case .empty: question["followUp"] = ""
        case .whitespace: question["followUp"] = " \n\t"
        case .extraField: question["r1"] = "An invented repaired quote."
        case .omittedField: question.removeValue(forKey: "followUp")
        case .providerError, .nonString: break
        }
        let provider = GapFieldPackets(outputs: [fixture.primaryWire, fixture.finalWire,
            String(decoding: try JSONEncoder().encode(question), as: UTF8.self)],
            failThird: defect == .providerError, rawThird: defect == .nonString ? "{\"followUp\":7}" : nil)
        do { _ = try await evaluate(fixture, provider); Issue.record("Invalid field-only repair was accepted.") }
        catch { #expect(error.localizedDescription.contains("One bounded follow-up repair failed")) }
        #expect(await provider.recorded().count == 3)
        #expect(fixture.attempt.feedback == nil)
    }

    @Test
    func completeMapAndAlreadyValidQuestionKeepTwoRequests() async throws {
        let fixture = try makeFixture()
        for complete in [false, true] {
            var final = fixture.final
            if complete { final["r1"] = fixture.quote; final["followUp"] = "" }
            else { final["followUp"] = fixture.question["followUp"] }
            var attempt = fixture.attempt
            if complete {
                let boundary = "At capacity, new work is rejected."
                attempt.answer += " " + boundary
                final["r1"] = boundary
            }
            let completeProvider = GapFieldPackets(outputs: [fixture.primaryWire,
                try scriptedPracticePacket(final, fulfilledIDs: complete ? ["r0", "r1"] : ["r0"]), fixture.questionWire])
            let feedback = try await PracticeController.evaluate(attempt: attempt, task: fixture.task,
                attachment: nil, evidence: [], provider: completeProvider, model: "synthetic-gap-field")
            #expect(feedback.missing.isEmpty == complete)
            #expect(await completeProvider.recorded().count == 2)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationWhileRepairIsHeldCannotAcceptTheLateQuestion() async throws {
        let fixture = try makeFixture()
        let provider = GapFieldPackets(outputs: [fixture.primaryWire, fixture.finalWire, fixture.questionWire], holdThird: true)
        let task = Task { try await evaluate(fixture, provider) }
        do {
            _ = try await TestEventWaitTrace(label: "GapRepair.cancel").nextEvent(in: provider.repairEntered.stream, event: "repair.entered")
            task.cancel()
            await provider.releaseRepair()
            do { _ = try await task.value; Issue.record("Cancelled repair was admitted.") }
            catch { #expect(error is CancellationError) }
            #expect(await provider.recorded().count == 3)
            #expect(fixture.attempt.feedback == nil)
        } catch {
            task.cancel(); await provider.releaseRepair(); _ = try? await task.value
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func changedAttemptCannotReceiveAnOldHeldQuestionRepair() async throws {
        let fixture = try makeFixture()
        let database = try AppDatabase(inMemory: true)
        let provider = GapFieldPackets(outputs: [fixture.primaryWire, fixture.finalWire, fixture.questionWire], holdThird: true)
        let controller = PracticeController(dependencies: .init(repository: PracticeRepository(database: database),
            sessions: SessionRepository(database: database), questions: SuggestionRepository(database: database),
            contexts: InterviewContextRepository(database: database), persistenceConsent: PersistenceConsent(),
            context: { .init(historyEnabled: false, selection: .init(candidateProfileID: nil, opportunityContextID: nil, domainProfileID: .general), temporarySnapshotID: nil) },
            evaluationConfiguration: { (provider, "synthetic-gap-field") }, selectedASRProvider: { .localParakeet },
            isLiveCaptureActive: { false }, prepareForPractice: {}, requestAudioPermissions: { _ in
                throw MaterialError.invalid("This keyboard-only fixture must not request audio permission.")
            }, makeAudioProvider: { _ in throw MaterialError.invalid("This fixture must not create ASR.") },
            historyDidChange: { _ in }, delayProvider: RealDelayProvider()))
        controller.run = PracticeRun(sessionID: "synthetic-gap-session", snapshotID: nil, task: fixture.task,
            questionID: fixture.attempt.questionID, mainQuestionID: fixture.attempt.questionID,
            phase: .answering, draft: fixture.attempt.answer, revision: fixture.attempt.revision)
        let terminal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let subscription = controller.runUpdates.sink { incoming in
            if incoming?.phase == .paused { terminal.continuation.yield(()); terminal.continuation.finish() }
        }
        do {
            controller.submit()
            _ = try await TestEventWaitTrace(label: "GapRepair.revision").nextEvent(in: provider.repairEntered.stream, event: "repair.entered")
            controller.run?.attempts[0].revision += 1
            controller.run?.attempts[0].answer = "A newer answer has different content."
            await provider.releaseRepair()
            _ = try await TestEventWaitTrace(label: "GapRepair.revision").nextEvent(in: terminal.stream, event: "old_evaluation.discarded")
            #expect(controller.run?.attempts[0].feedback == nil)
            #expect(controller.run?.attempts[0].answer == "A newer answer has different content.")
            #expect(controller.error == nil)
            await controller.shutdown(); try database.close()
            subscription.cancel(); terminal.continuation.finish()
        } catch {
            await provider.releaseRepair(); await controller.shutdown(); try? database.close()
            subscription.cancel(); terminal.continuation.finish(); throw error
        }
    }

    private func makeFixture(language: String = "en", personal: Bool = false) throws -> GapFieldFixture {
        let chinese = language == "zh"
        let question = personal ? (chinese ? "说明一次行动及已知结果。" : "Describe an action and its known outcome.")
            : (chinese ? "说明队列准入及容量边界。" : "Explain queue admission and its capacity boundary.")
        let quote = personal ? (chinese ? "我记录了不同方案。" : "I recorded the alternatives.")
            : (chinese ? "队列接收获准的工作。" : "The queue receives admitted work.")
        let kind: InterviewTaskKind = personal ? .behavioral : .generalKnowledge
        var task = InterviewTaskDescriptor(question: question, kind: kind, language: language)
        task.apply(.init(task: kind, personalEvidence: personal ? .required : .notRequired,
            basis: personal ? .candidateRecord : .generalKnowledge, relation: .independent,
            parentQuestionID: nil, parentQuestionText: nil, parentAnswerText: nil,
            source: "synthetic-gap-field", routerVersion: InterviewQuestionRouter.version,
            language: language, clarification: "", questionID: "synthetic-gap-field", questionRevision: 3,
            contextSnapshotID: nil, artifactRevision: 0, model: "synthetic-gap-field", failure: nil, latencyMS: 0))
        task.criteria = personal ? ["Stated action", "Known outcome"] : ["Explain admission", "State capacity boundary"]
        let reference = personal ? "" : (chinese ? "说明准入与有界队列的容量策略。" : "State admission and the bounded queue's capacity policy.")
        let primary = ["r0": "", "r1": "", "followUp": "Untrusted provisional question.",
            "reason": "Draft prose.", "suggestion": "Draft suggestion.", "reference": reference]
        let final = ["r0": quote, "r1": "", "followUp": "", "reason": chinese ? "第二项仍缺失。" : "The second criterion is missing.",
            "suggestion": chinese ? "只补充第二项。" : "Add only the second criterion.", "reference": reference, "reviewOutcome": "accepted"]
        let followUp = personal ? (chinese ? "目前已知或观察到什么结果，如无结果也可以说明吗？" : "What outcome is known or observed so far, if any?")
            : (chinese ? "容量已满时如何处理新的工作？" : "How is new work handled at capacity?")
        return .init(attempt: .init(questionID: "synthetic-gap-field", question: question, answer: quote,
            contextSnapshotID: nil, revision: 3, hinted: false, skipped: false, source: "synthetic-packets", task: task),
            task: task, quote: quote, primary: primary, final: final, question: ["followUp": followUp],
            primaryWire: try scriptedPracticePacket(primary, fulfilledIDs: []),
            finalWire: try scriptedPracticePacket(final, fulfilledIDs: ["r0"]),
            questionWire: String(decoding: try JSONEncoder().encode(["followUp": followUp]), as: UTF8.self))
    }
    private func evaluate(_ fixture: GapFieldFixture, _ provider: GapFieldPackets) async throws -> PracticeFeedback {
        try await PracticeController.evaluate(attempt: fixture.attempt, task: fixture.task,
            attachment: nil, evidence: [], provider: provider, model: "synthetic-gap-field")
    }
}
enum GapFieldFinalDefect: CaseIterable, Sendable { case rejected, unverified, inventedQuote, blankQuote, inventedID, emptyReference, changedSourceNotice, missingAssessment, assessmentQuoteConflict }
enum GapFieldRepairDefect: CaseIterable, Sendable { case empty, whitespace, extraField, omittedField, providerError, nonString }
private struct GapFieldFixture {
    let attempt: PracticeAttempt
    let task: InterviewTaskDescriptor
    let quote: String
    let primary: [String: String]
    let final: [String: String]
    let question: [String: String]
    let primaryWire: String
    let finalWire: String
    let questionWire: String
}
private struct GapFieldAcceptedMap: Decodable {
    let quotes: [String: String]
    let assessments: [String: PracticeFeedback.RubricAssessment]
}
private actor GapFieldPackets: LocalLLMProvider {
    nonisolated let id = "synthetic-gap-field"
    nonisolated let displayName = "Finite accepted-gap field packets"
    nonisolated let repairEntered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    private let outputs: [String]
    private let failThird: Bool
    private let holdThird: Bool
    private let rawThird: String?
    private var requests: [LocalLLMRequest] = []
    private var held: (request: LocalLLMRequest, continuation: AsyncThrowingStream<LLMToken, Error>.Continuation)?
    init(outputs: [String], failThird: Bool = false, holdThird: Bool = false, rawThird: String? = nil) {
        self.outputs = outputs; self.failThird = failThird; self.holdThird = holdThird; self.rawThird = rawThird
    }
    func healthCheck(modelName: String) async -> LocalLLMHealth {
        .init(ollamaRunning: true, selectedModel: modelName, modelInstalled: true, providerSource: .localQwen, lastError: nil)
    }
    nonisolated func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> { AsyncThrowingStream { $0.finish() } }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        let index = requests.count; requests.append(request)
        guard index < outputs.count && index < 3 else { throw MaterialError.invalid("Unexpected fourth field-repair request.") }
        if index == 2 && failThird { throw MaterialError.invalid("Synthetic repair network failure.") }
        if index == 2 && holdThird {
            let pair = AsyncThrowingStream<LLMToken, Error>.makeStream()
            held = (request, pair.continuation)
            repairEntered.continuation.yield(()); repairEntered.continuation.finish()
            return pair.stream
        }
        let text: String
        if index == 2, let rawThird { text = rawThird }
        else { text = outputs[index] }
        return AsyncThrowingStream { c in c.yield(.init(text: text, source: .localQwen, modelName: request.modelName)); c.finish() }
    }
    func releaseRepair() {
        repairEntered.continuation.finish()
        guard let held else { return }
        self.held = nil
        held.continuation.yield(.init(text: outputs[2], source: .localQwen, modelName: held.request.modelName))
        held.continuation.finish()
    }
    func recorded() -> [LocalLLMRequest] { requests }
}
