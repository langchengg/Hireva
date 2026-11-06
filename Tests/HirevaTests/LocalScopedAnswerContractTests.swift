import Foundation
import Testing
@testable import Hireva

@MainActor
struct LocalScopedAnswerContractTests {
    @Test(arguments: [
        #"{"scoped_claim":"A condition applies.","say_first":"数据库事务保留条件。"}"#,
        #" { "say_first":"A statement can fail without ending the transaction.", "scoped_claim":"The default ABORT policy rolls back the failing statement." } "#,
        #"{"scoped_claim":"A \"quoted\" condition applies.","say_first":"It depends on the transaction’s error policy."}"#,
        #"{"scoped_claim":"A character class matches one character.","say_first":"Use [ab] to match either character, and \\ to escape it."}"#
    ])
    func strictProjectionPreservesPublicSpokenText(_ raw: String) throws {
        let values = try JSONDecoder().decode([String: String].self, from: Data(raw.utf8))
        let parsed = LocalQwenAnswerParser.parse(raw, responseSchema: LocalQwenAnswerParser.scopedResponseSchema)
        #expect(parsed.failureCategory == nil)
        #expect(parsed.sayFirst == (try #require(values["say_first"])).trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(parsed.scopedClaim == values["scoped_claim"])
        #expect(parsed.sectionParserResult == "scoped_json_answer")
    }

    @Test(arguments: [
        #"{"scoped_claim":"A","scoped_claim":"B"}"#,
        #"{"scoped_claim":"A","scoped_claim":"B","say_first":"C"}"#,
        #"{"scoped_claim":"A","\u0073coped_claim":"B"}"#,
        #"{"scoped_claim":"A","say_first":null}"#,
        #"{"scoped_claim":"A","say_first":{"text":"B"}}"#,
        #"{"scoped_claim":"","say_first":"B"}"#,
        #"{"scoped_claim":"A","say_first":" "}"#,
        #"{"scoped_claim":"A"}"#,
        #"{"scoped_claim":"A","say_first":"B","extra":"C"}"#,
        #"{"scoped_claim":"A","say_first":"B""#,
        #"Preface {"scoped_claim":"A","say_first":"B"}"#,
        "```json\n{\"scoped_claim\":\"A\",\"say_first\":\"B\"}\n```",
        "An ordinary answer is still not a schema response."
    ])
    func malformedScopedOutputNeverFallsBackToFlattenedText(_ raw: String) {
        let parsed = LocalQwenAnswerParser.parse(raw, responseSchema: LocalQwenAnswerParser.scopedResponseSchema)
        #expect(parsed.sayFirst.isEmpty)
        #expect(parsed.failureCategory != nil)
        #expect(parsed.scopedClaim == nil)
    }

    @Test func plainOutputKeepsItsExistingContract() {
        let answer = "A transaction commits its changes together."
        #expect(LocalQwenAnswerParser.parse(answer).sayFirst == answer)
        #expect(LocalQwenAnswerParser.parse(answer).scopedClaim == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func actualSelectedReferenceEntryUsesScopedContract() async throws {
        let fixture = try await LocalQwenOwnedEntryFixture()
        var question = fixture.question
        question.taskDescriptor = .init(question: question.questionText, kind: .generalKnowledge, language: "en")
        let context = RetrievedContext(cvChunks: [], jobDescriptionChunks: [], additionalNotesChunks: [
            .init(id: "synthetic-transaction-reference", documentID: "synthetic-topic-source", documentType: .additionalNotes,
                chunkIndex: 0, content: "Database transaction atomicity applies to committed changes; statement errors need not end a transaction.",
                keywords: ["transaction", "atomicity"], sectionTitle: "Transactions", wordCount: 16, metadataJSON: nil, createdAt: Date())
        ])
        let pending = Task {
            try await fixture.app.finishWithLocalQwenAnswer(question: question, session: fixture.session,
                transcript: question.questionText, context: context, retrievedChunks: [], cvSummary: "", jdSummary: "",
                generationID: fixture.generationID, cardID: UUID().uuidString, requestStart: Date(), triggerPath: .manualGenerate,
                source: .mock, speaker: .unknown, localProvider: fixture.provider, modelName: fixture.model, fallbackReason: nil)
        }
        do {
            #expect(try await fixture.provider.nextStart() == 1)
            let calls = await fixture.provider.gate.calls()
            let request = try #require(calls.first)
            #expect(request.responseSchema != nil)
            #expect(request.responseSchemaPropertyOrder == ["scoped_claim", "say_first"])
            #expect(request.prompt.contains("scoped_claim") && request.prompt.contains("say_first"))
            #expect(!request.prompt.contains("Output only one natural first-person spoken answer"))
            #expect(request.prompt.hasSuffix("\"\(question.questionText)\""))
            fixture.app.cancelActiveGenerationForContextChange()
            await fixture.provider.releaseAll()
            #expect(try await pending.value == false)
            try await fixture.close([pending])
        } catch {
            try? await fixture.close([pending])
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [
        "In your database learning prototype, which concurrency and indexing topic did you compare?",
        "Choose your project and explain its contribution, baseline, experiment and failure trade-offs."
    ])
    func actualProjectEntryKeepsQuestionScopeAcrossRecoveries(_ text: String) async throws {
        let fixture = try await LocalQwenOwnedEntryFixture()
        var question = fixture.question
        question.questionText = text
        var task = InterviewTaskDescriptor(question: text, kind: .project, language: "en")
        task.apply(.init(task: .project, personalEvidence: .required, basis: .candidateRecord,
            relation: .independent, parentQuestionID: nil, parentQuestionText: nil, parentAnswerText: nil,
            source: "synthetic-scope", routerVersion: InterviewQuestionRouter.version, language: "en",
            clarification: "", questionID: question.id, questionRevision: 0, contextSnapshotID: nil,
            artifactRevision: 0, model: fixture.model, failure: nil, latencyMS: 0))
        question.taskDescriptor = task
        fixture.app.activateGeneration(question: question, generationID: fixture.generationID,
            triggerPath: .manualGenerate, requestStart: Date(), source: .mock, speaker: .unknown,
            answerProviderMode: .localQwenPrimary)
        #expect(task.promptPolicy.contains("Rubric:"), "Practice keeps its supplied assessment contract.")
        let pending = Task {
            try await fixture.app.finishWithLocalQwenAnswer(question: question, session: fixture.session,
                transcript: text, context: .init(cvChunks: [], jobDescriptionChunks: []), retrievedChunks: [],
                cvSummary: "", jdSummary: "", generationID: fixture.generationID, cardID: UUID().uuidString,
                requestStart: Date(), triggerPath: .manualGenerate, source: .mock, speaker: .unknown,
                localProvider: fixture.provider, modelName: fixture.model, fallbackReason: nil)
        }
        do {
            for ordinal in 1...4 {
                #expect(try await fixture.provider.nextStart() == ordinal)
                let request = try #require(await fixture.provider.gate.calls().last)
                let combined = request.prompt + (request.systemPrompt ?? "")
                #expect(request.prompt.contains(text))
                #expect(!combined.contains("Rubric:") && !combined.contains(task.criteria.joined(separator: "; ")))
                #expect(!combined.contains(task.criteria.joined(separator: " -> ")))
                #expect(combined.contains("source-supported candidate facts"))
                await fixture.provider.gate.release(ordinal)
                #expect(try await fixture.provider.nextStream() == ordinal)
                fixture.provider.finish(ordinal: ordinal)
            }
            if case .success = await pending.result { Issue.record("Empty answers must remain rejected.") }
            #expect(fixture.app.currentSuggestion == nil)
            try await fixture.close([pending])
        } catch {
            try? await fixture.close([pending])
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [
        "I reduced transaction latency by 37% in my production system.",
        "Under default ABORT, only the failing statement is undone and the transaction remains active"
    ])
    func bothRecoveryRequestsRetainSchemaAndRejectInvalidClaimBeforePublication(_ invalidClaim: String) async throws {
        let trace = TestEventWaitTrace(label: "scoped_recovery_contract.\(invalidClaim.utf8.count)")
        trace.mark("body.entered")
        defer { trace.mark("body.return_or_throw") }
        let fixture = try await LocalQwenOwnedEntryFixture()
        trace.mark("fixture.ready")
        var question = fixture.question
        question.taskDescriptor = .init(question: question.questionText, kind: .generalKnowledge, language: "en")
        let reference = "Database transaction atomicity applies to committed changes; statement errors need not end a transaction."
        let context = RetrievedContext(cvChunks: [], jobDescriptionChunks: [], additionalNotesChunks: [
            .init(id: "synthetic-transaction-reference", documentID: "synthetic-topic-source", documentType: .additionalNotes,
                chunkIndex: 0, content: reference, keywords: ["transaction", "atomicity"], sectionTitle: "Transactions",
                wordCount: 16, metadataJSON: nil, createdAt: Date())
        ])
        let pending = Task {
            try await fixture.app.finishWithLocalQwenAnswer(question: question, session: fixture.session,
                transcript: question.questionText, context: context, retrievedChunks: [], cvSummary: "", jdSummary: "",
                generationID: fixture.generationID, cardID: UUID().uuidString, requestStart: Date(), triggerPath: .manualGenerate,
                source: .mock, speaker: .unknown, localProvider: fixture.provider, modelName: fixture.model, fallbackReason: nil)
        }
        do {
            let spoken = "A transaction commits its changes together. A statement error may leave the transaction active; symbols such as [x], {y}, and \\ remain literal notation."
            for ordinal in 1...4 {
                trace.mark("request.\(ordinal).start_wait.begin")
                #expect(try await fixture.provider.nextStart() == ordinal)
                trace.mark("request.\(ordinal).start_consumed")
                let request = try #require(await fixture.provider.gate.calls().last)
                #expect(request.responseSchema == LocalQwenAnswerParser.scopedResponseSchema)
                #expect(request.responseSchemaPropertyOrder == LocalQwenAnswerParser.scopedPropertyOrder)
                #expect(request.numPredict == (ordinal == 4 ? 220 : 180))
                #expect(request.prompt.contains(reference))
                #expect(request.modelName == fixture.model)
                #expect(!request.prompt.contains("output only the final spoken answer"))
                #expect(request.prompt.hasSuffix("\"\(question.questionText)\""))
                if ordinal > 1 { #expect(fixture.app.currentSuggestion == nil) }
                trace.mark("request.\(ordinal).startup_release.begin")
                await fixture.provider.gate.release(ordinal)
                trace.mark("request.\(ordinal).startup_release.return")
                #expect(try await fixture.provider.nextStream() == ordinal)
                trace.mark("request.\(ordinal).stream_consumed")
                let claim = ordinal == 4
                    ? "A statement error need not end a transaction; atomicity concerns committed changes."
                    : invalidClaim
                fixture.provider.emit(JSONParsing.jsonString(["scoped_claim": claim, "say_first": spoken]), ordinal: ordinal)
                fixture.provider.finish(ordinal: ordinal)
                trace.mark("request.\(ordinal).stream_finished")
            }
            trace.mark("pending.join.begin")
            #expect(try await pending.value)
            trace.mark("pending.join.return")
            let card = try #require(fixture.app.currentSuggestion)
            #expect(card.sayFirst == spoken)
            #expect(card.rawJSON == spoken)
            #expect(card.promptVersion == "ollama-qwen-scoped-v1")
            #expect(!card.sayFirst.contains("scoped_claim"))
            #expect(card.questionID == question.id && card.generationID == fixture.generationID)
            // This isolated repository round trip checks text storage, separately from the app's disabled consent.
            try fixture.app.suggestionRepository.saveSuggestionCard(card)
            #expect(try fixture.app.suggestionRepository.latestSuggestion(sessionID: fixture.session.id)?.sayFirst == spoken)
            trace.mark("retired.drain.begin")
            await fixture.app.generationCoordinator.drainRetiredTasks()
            trace.mark("retired.drain.return")
            #expect(fixture.app.generationCoordinator.pendingCleanupTaskCount == 0)
            trace.mark("fixture.close.begin")
            try await fixture.close([pending])
            trace.mark("fixture.close.return")
        } catch {
            trace.mark("error.cleanup.begin")
            try? await fixture.close([pending])
            trace.mark("error.cleanup.return")
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: Array(0..<7))
    func personalSchemaRequiresUsableFrozenEvidenceAcrossAllRecoveryRequests(_ variant: Int) async throws {
        let fixture = try await LocalQwenOwnedEntryFixture()
        let explicitness: EvidenceExplicitness = variant == 1 ? .userConfirmed : variant == 2 ? .inferred : variant == 3 ? .userRejected : .explicit
        let statement = variant == 4 ? " " : "I built a database prototype and tested rollback by deliberately injecting failures."
        let evidence = ProfileEvidence(id: "frozen-personal-source", statement: statement,
            sourceDocumentID: "synthetic-source", sourceChunkID: nil, sourceSpan: statement,
            confidence: 1, evidenceType: .project, explicitness: explicitness)
        var session = fixture.session
        let snapshot = variant == 5 ? nil : InterviewContextSnapshot(id: UUID().uuidString,
            sessionID: session.id, candidateProfileID: "synthetic-profile", candidateProfileVersion: 1,
            opportunityContextID: nil, opportunityContextVersion: nil, domainProfileID: "general",
            candidateEvidence: [evidence], opportunityEvidence: [], createdAt: Date())
        session.contextSnapshotID = snapshot?.id
        fixture.app.currentSession = session
        fixture.app.activeContextSnapshot = snapshot
        var question = fixture.question
        question.questionText = variant == 6 ? "Explain database transaction rollback." : "How did you test rollback in your database prototype?"
        var task = InterviewTaskDescriptor(question: question.questionText, kind: variant == 6 ? .generalKnowledge : .project, language: "en")
        task.apply(.init(task: task.kind, personalEvidence: variant == 6 ? .notRequired : .required,
            basis: variant == 6 ? .generalKnowledge : .candidateRecord, relation: .independent,
            parentQuestionID: nil, parentQuestionText: nil, parentAnswerText: nil, source: "synthetic-personal-schema",
            routerVersion: InterviewQuestionRouter.version, language: "en", clarification: "",
            questionID: question.id, questionRevision: 0, contextSnapshotID: snapshot?.id,
            artifactRevision: 0, model: fixture.model, failure: nil, latencyMS: 0))
        question.taskDescriptor = task
        fixture.app.activateGeneration(question: question, generationID: fixture.generationID,
            triggerPath: .manualGenerate, requestStart: Date(), source: .mock, speaker: .unknown,
            answerProviderMode: .localQwenPrimary)
        let legacy = RetrievedContext(cvChunks: [.init(id: evidence.id, documentID: "synthetic-source",
            documentType: .cv, chunkIndex: 0, content: statement, keywords: ["rollback"], sectionTitle: nil,
            wordCount: 15, metadataJSON: nil, createdAt: Date())], jobDescriptionChunks: [])
        let frozenSession = session
        let frozenQuestion = question
        let pending = Task {
            try await fixture.app.finishWithLocalQwenAnswer(question: frozenQuestion, session: frozenSession,
                transcript: frozenQuestion.questionText, context: legacy, retrievedChunks: [], cvSummary: statement,
                jdSummary: "", generationID: fixture.generationID, cardID: UUID().uuidString, requestStart: Date(),
                triggerPath: .manualGenerate, source: .mock, speaker: .unknown, localProvider: fixture.provider,
                modelName: fixture.model, fallbackReason: nil, interviewContextSnapshot: snapshot)
        }
        do {
            for ordinal in 1...4 {
                #expect(try await fixture.provider.nextStart() == ordinal)
                let request = try #require(await fixture.provider.gate.calls().last)
                let scoped = variant < 2
                #expect(request.responseSchema == (scoped ? LocalQwenAnswerParser.scopedResponseSchema : nil))
                #expect(request.responseSchemaPropertyOrder == (scoped ? LocalQwenAnswerParser.scopedPropertyOrder : nil))
                #expect(request.numPredict == (ordinal == 4 ? 220 : 180))
                if scoped { #expect(request.prompt.contains(statement)) }
                if variant == 6 { #expect(!request.prompt.contains(statement)) }
                #expect(fixture.app.currentSuggestion == nil)
                await fixture.provider.gate.release(ordinal)
                #expect(try await fixture.provider.nextStream() == ordinal)
                if scoped && ordinal < 4 {
                    let spoken = "I tested rollback in my database prototype by deliberately injecting failures."
                    #expect(LocalQwenAnswerValidationResult.validate(spoken, question: frozenQuestion,
                        interviewContextSnapshot: snapshot).accepted)
                    let claim = "I reduced production transaction latency by 37%."
                    #expect(!LocalQwenAnswerValidationResult.validate(claim, question: frozenQuestion,
                        interviewContextSnapshot: snapshot).accepted)
                    fixture.provider.emit(JSONParsing.jsonString(["scoped_claim": claim, "say_first": spoken]), ordinal: ordinal)
                }
                fixture.provider.finish(ordinal: ordinal)
            }
            if case .success = await pending.result { Issue.record("Empty formal answers cannot publish.") }
            #expect(fixture.app.currentSuggestion == nil)
            try await fixture.close([pending])
        } catch {
            try? await fixture.close([pending]); throw error
        }
    }
}
