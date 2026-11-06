import Foundation
import Testing
@testable import Hireva

@Suite
struct PromptContextBuilderTests {
    @Test
    func currentQuestionAppearsBeforeContextAndBackground() {
        let question = makeQuestion("Why did the diffusion model perform better than the autoregressive model?")

        let snapshot = PromptContextBuilder.generationRequestSnapshot(
            question: question,
            generationID: "generation-1",
            triggerPath: .autoDetect,
            source: .systemAudio,
            speaker: .interviewer,
            acceptedAt: Date(timeIntervalSince1970: 1_717_171_717),
            context: mixedContext(),
            transcriptContext: "Interviewer: Could you walk me through your LeoRover project?",
            cvSummary: "Candidate has robotics, LeoRover, and VLA policy experience.",
            jdSummary: "Robotics team focused on reliable deployed systems.",
            stage: .firstAnswer
        )

        #expect(snapshot.detectedQuestionID == question.id)
        #expect(snapshot.questionText == question.questionText)
        #expect(snapshot.promptPrimaryQuestion == question.questionText)
        #expect(snapshot.promptSnapshot.prompt.hasPrefix("""
        CURRENT QUESTION TO ANSWER:
        "\(question.questionText)"
        """))

        let prompt = snapshot.promptSnapshot.prompt
        let questionRange = prompt.range(of: "CURRENT QUESTION TO ANSWER:")
        let candidateRange = prompt.range(of: "Candidate summary:")
        let roleRange = prompt.range(of: "Target role summary:")
        let evidenceRange = prompt.range(of: "Selected local evidence:")
        let backgroundRange = prompt.range(of: "BACKGROUND FROM EARLIER INTERVIEW:")

        #expect(questionRange != nil)
        #expect(candidateRange != nil)
        #expect(roleRange != nil)
        #expect(evidenceRange != nil)
        #expect(backgroundRange != nil)
        if let questionRange, let candidateRange, let roleRange, let evidenceRange, let backgroundRange {
            #expect(questionRange.lowerBound < candidateRange.lowerBound)
            #expect(candidateRange.lowerBound < roleRange.lowerBound)
            #expect(roleRange.lowerBound < evidenceRange.lowerBound)
            #expect(evidenceRange.lowerBound < backgroundRange.lowerBound)
        }
    }

    @Test
    func previousTranscriptIsBackgroundAndCannotOverrideCurrentQuestion() {
        let question = makeQuestion("Why did the diffusion model perform better than the autoregressive model?")

        let snapshot = PromptContextBuilder.promptSnapshot(
            question: question,
            context: mixedContext(),
            transcriptContext: "Interviewer: Which part of the LeoRover pipeline was most fragile when moving from a clean demo to real robot execution?",
            cvSummary: "Candidate has robotics project experience.",
            jdSummary: "Robotics role.",
            stage: .firstAnswer
        )

        #expect(snapshot.prompt.localizedCaseInsensitiveContains("Previous transcript is background only and must not change the question."))
        #expect(snapshot.previousQuestionText?.localizedCaseInsensitiveContains("LeoRover pipeline") == true)
        #expect(snapshot.previousQuestionIncluded == false)
        #expect(snapshot.promptContainsPreviousQuestion == false)
        #expect(snapshot.contextBleedRisk == .low)
        #expect(snapshot.prompt.localizedCaseInsensitiveContains("Which part of the LeoRover pipeline was most fragile") == false)
        #expect(snapshot.prompt.localizedCaseInsensitiveContains(question.questionText))
    }

    @Test
    func diffusionAutoregressiveQuestionGetsModelComparisonGuidance() {
        let question = makeQuestion("Why did the diffusion model perform better than the autoregressive model?")

        let snapshot = PromptContextBuilder.promptSnapshot(
            question: question,
            context: mixedContext(),
            transcriptContext: "Interviewer: Could you walk me through LeoRover?",
            cvSummary: "Candidate has robotics experience.",
            jdSummary: "Robotics role.",
            stage: .fullAnswer
        )

        #expect(snapshot.questionIntent == .modelComparison)
        #expect(snapshot.prompt.localizedCaseInsensitiveContains("alternatives -> evaluation criteria -> evidence -> trade-off"))
        #expect(snapshot.prompt.localizedCaseInsensitiveContains(question.questionText))
        #expect(snapshot.ragChunkIDs.contains("diffusion"))
        #expect(snapshot.ragChunkIDs.contains("fragility") == false)
        #expect(snapshot.prompt.localizedCaseInsensitiveContains("pipeline was most fragile") == false)
    }

    @Test
    func whyRoleQuestionKeepsFullPrimaryQuestionAndRoleGuidance() {
        let question = makeQuestion("Why do you want to join our team?")

        let snapshot = PromptContextBuilder.generationRequestSnapshot(
            question: question,
            generationID: "generation-why-role",
            triggerPath: .autoDetect,
            source: .systemAudio,
            speaker: .interviewer,
            acceptedAt: Date(timeIntervalSince1970: 1_717_171_718),
            context: mixedContext(),
            transcriptContext: "Interviewer: Tell me about yourself.",
            cvSummary: "Candidate works on robotics perception and manipulation.",
            jdSummary: "Team builds deployed robotics systems.",
            stage: .firstAnswer
        )

        #expect(snapshot.questionText == "Why do you want to join our team?")
        #expect(snapshot.promptPrimaryQuestion == "Why do you want to join our team?")
        #expect(snapshot.questionIntent == .whyRole)
        #expect(snapshot.promptSnapshot.prompt.localizedCaseInsensitiveContains("target need -> supported candidate evidence -> motivation"))
        #expect(snapshot.promptSnapshot.ragChunkIDs.contains("jd-role"))
        #expect(snapshot.promptSnapshot.prompt.localizedCaseInsensitiveContains("Why do you want"))
    }

    @Test
    func candidateQuestionsIntentAsksInterviewerInsteadOfSelfIntroduction() {
        let question = makeQuestion("Do you have any questions for us?")

        let snapshot = PromptContextBuilder.promptSnapshot(
            question: question,
            context: mixedContext(),
            transcriptContext: "",
            cvSummary: "Candidate has MSc Robotics and a computer science background.",
            jdSummary: "Team evaluates robotics deployment success.",
            stage: .firstAnswer
        )

        #expect(snapshot.questionIntent == .candidateQuestions)
        #expect(snapshot.prompt.localizedCaseInsensitiveContains("concise questions about success, constraints, team, and evaluation"))
        #expect(snapshot.ragContextSnapshot.cvChunks.count == 3)
        #expect(snapshot.ragContextSnapshot.jobDescriptionChunks.map(\.id) == ["jd-role"])
        #expect(snapshot.prompt.localizedCaseInsensitiveContains("MSc Robotics") == true)
        #expect(snapshot.prompt.localizedCaseInsensitiveContains("generic self-introduction") == true)
    }

    @Test
    func promptRedactsRawAPIKeys() {
        let question = makeQuestion("Why do you want to join our team?")
        let rawKey = "sk-abcdefghijklmnopqrstuvwxyz1234567890"
        let context = RetrievedContext(
            cvChunks: [
                chunk("secret-cv", "DeepSeek API key: \(rawKey) should never appear in prompts.", .cv)
            ],
            jobDescriptionChunks: [
                chunk("secret-jd", "api key = \(rawKey) belongs in settings, not prompt context.", .jobDescription)
            ],
            additionalNotesChunks: []
        )

        let snapshot = PromptContextBuilder.promptSnapshot(
            question: question,
            context: context,
            transcriptContext: "Interviewer: background contained \(rawKey)",
            cvSummary: "Candidate summary mentions \(rawKey)",
            jdSummary: "Role summary mentions \(rawKey)",
            stage: .firstAnswer
        )

        #expect(snapshot.prompt.contains(rawKey) == false)
        #expect(snapshot.prompt.localizedCaseInsensitiveContains("[REDACTED_API_KEY]"))
    }

    @Test(arguments: [
        "How would you design a notification service to handle duplicate deliveries and retry failures?",
        "Design a booking system with a 300 ms response budget.",
        "How would you build a notification service?",
        "How should retries work for notifications?",
        "Explain an algorithm for finding duplicate array values.",
        "编写 SQL 统计每位客户的订单数量。"
    ])
    func generalPracticalTasksExcludeUnrelatedProfileConstraints(text: String) {
        let context = RetrievedContext(
            cvChunks: [chunk("cv-canary", "PROFILE_CANARY latency x <= 5 ms", .cv)],
            jobDescriptionChunks: [chunk("jd-canary", "ROLE_CANARY requires five years", .jobDescription)],
            additionalNotesChunks: [chunk("notes-canary", "NOTES_CANARY", .additionalNotes)]
        )
        for stage in [AnswerPromptStage.firstAnswer, .fullAnswer, .sectionStream, .jsonCard] {
            let snapshot = PromptContextBuilder.promptSnapshot(
                question: makeQuestion(text), context: context, transcriptContext: "",
                cvSummary: "SUMMARY_CANARY x <= 5", jdSummary: "ROLE_SUMMARY_CANARY", stage: stage
            )
            #expect(!snapshot.prompt.contains("CANARY"))
            #expect(snapshot.ragChunkIDs.isEmpty)
            #expect(snapshot.ragContextSnapshot.promptText.isEmpty)
            #expect(snapshot.prompt.contains(text))
            #expect(snapshot.prompt.contains("explain concepts and reasoning for explanations; propose solutions for design or problem-solving tasks"))
            #expect(!snapshot.prompt.contains("For general tasks, explain a proposed solution"))
        }
    }

    @Test
    func personalArchitectureQuestionRetainsCandidateEvidence() {
        let snapshot = PromptContextBuilder.promptSnapshot(
            question: makeQuestion("Explain the architecture of your project and your contribution."),
            context: mixedContext(), transcriptContext: "", cvSummary: "PERSONAL_EVIDENCE_CANARY",
            jdSummary: "", stage: .firstAnswer
        )
        #expect(snapshot.taskDescriptor?.requiresPersonalEvidence == true)
        #expect(snapshot.prompt.contains("PERSONAL_EVIDENCE_CANARY"))
        #expect(!snapshot.ragChunkIDs.isEmpty)
    }

    @Test
    func independentDesignQuestionsDoNotInheritEarlierConstraints() {
        let snapshot = PromptContextBuilder.promptSnapshot(
            question: makeQuestion("Design a booking service with durable storage."),
            context: mixedContext(),
            transcriptContext: "Interviewer: Design a notification service with OLD_CONSTRAINT_CANARY and a five-second retry limit?",
            cvSummary: "", jdSummary: "", stage: .firstAnswer
        )
        #expect(!snapshot.previousQuestionIncluded)
        #expect(!snapshot.prompt.contains("OLD_CONSTRAINT_CANARY"))
    }

    @Test(arguments: [
        "Explain a reversible transition and its limits.",
        "How can a project select a finite retry policy?",
        "说明哈希函数与编码的区别。"
    ])
    func explicitGeneralKnowledgeWithoutRoutingDoesNotAdmitProfileContext(text: String) throws {
        let task = InterviewTaskDescriptor(question: text, kind: .generalKnowledge)
        try #require(task.decision == nil && !task.requiresPersonalEvidence)
        #expect(!PromptContextBuilder.usesProfileContext(task))
        var question = makeQuestion(text)
        question.taskDescriptor = task
        let context = RetrievedContext(
            cvChunks: [chunk("general-cv", "PROFILE_CONTEXT_CANARY unrelated personal work", .cv)],
            jobDescriptionChunks: [chunk("general-jd", "ROLE_CONTEXT_CANARY unrelated job conditions", .jobDescription)],
            additionalNotesChunks: [chunk("general-notes", "NOTES_CONTEXT_CANARY", .additionalNotes)]
        )
        for stage in [AnswerPromptStage.firstAnswer, .fullAnswer, .sectionStream, .jsonCard] {
            let snapshot = PromptContextBuilder.promptSnapshot(question: question, context: context,
                transcriptContext: "", cvSummary: "SUMMARY_CONTEXT_CANARY", jdSummary: "ROLE_SUMMARY_CONTEXT_CANARY",
                stage: stage)
            #expect(snapshot.taskDescriptor == task)
            #expect(snapshot.promptPrimaryQuestion == text && snapshot.prompt.contains(text))
            #expect(!snapshot.prompt.contains("CONTEXT_CANARY"))
            #expect(snapshot.ragChunkIDs.isEmpty && snapshot.ragContextSnapshot.promptText.isEmpty)
        }
    }

    @Test
    func explicitGeneralKindDoesNotOverrideLegacyPersonalRequirement() throws {
        let task = InterviewTaskDescriptor(question: "Explain how you built your tool.", kind: .generalKnowledge)
        try #require(task.decision == nil && task.requiresPersonalEvidence)
        #expect(PromptContextBuilder.usesProfileContext(task))
    }

    @Test(arguments: [InterviewTaskKind.generalKnowledge, .unknown])
    func technicalAccuracyPolicyReachesEveryAnswerStageWithoutAddingProfileEvidence(kind: InterviewTaskKind) {
        var task = InterviewTaskDescriptor(question: "Explain an all-or-nothing guarantee and its boundary.", kind: kind)
        if kind == .unknown {
            task.apply(.init(task: .unknown, personalEvidence: .uncertain, basis: .unknown, relation: .independent,
                parentQuestionID: nil, parentQuestionText: nil, parentAnswerText: nil, source: "safeFallback",
                routerVersion: InterviewQuestionRouter.version, language: "en", clarification: "", questionID: "policy-fallback",
                questionRevision: 0, contextSnapshotID: nil, artifactRevision: 0, model: "synthetic-no-model", failure: "timeout", latencyMS: 8050))
        }
        var question = makeQuestion(task.question)
        question.taskDescriptor = task
        for stage in [AnswerPromptStage.firstAnswer, .fullAnswer, .sectionStream, .jsonCard] {
            let snapshot = PromptContextBuilder.promptSnapshot(question: question, context: RetrievedContext(cvChunks: [], jobDescriptionChunks: []),
                transcriptContext: "", cvSummary: "PRIVATE_PROFILE_CANARY", jdSummary: "PRIVATE_ROLE_CANARY", stage: stage)
            #expect(snapshot.prompt.contains("A local mechanism's property does not establish the whole operation's outcome"))
            #expect(snapshot.taskDescriptor == task)
            #expect(!snapshot.prompt.contains("PRIVATE_PROFILE_CANARY") && !snapshot.prompt.contains("PRIVATE_ROLE_CANARY"))
        }
        #expect(!InterviewTaskDescriptor(question: "What working hours do you prefer?", kind: .arrangements)
            .answerPromptPolicy.contains("Technical accuracy:"))
        #expect(!task.promptPolicy.contains("Technical accuracy:"), "Practice assessment retains its independently tested policy.")
    }

    @Test
    func unknownKindRetainsTheRecognizedLegacyInterviewerQuestionIntent() throws {
        let task = InterviewTaskDescriptor(question: "Do you have any questions for us?", kind: .unknown)
        try #require(task.decision == nil && !task.requiresPersonalEvidence)
        #expect(QuestionIntentPromptPolicy.intent(for: task.question) == .candidateQuestions)
        #expect(PromptContextBuilder.usesProfileContext(task))
    }

    @Test(arguments: PersonalEvidenceRequirement.allCases)
    func routedEvidenceAuthorityStillPrecedesTheSelectedGeneralKind(requirement: PersonalEvidenceRequirement) {
        var task = InterviewTaskDescriptor(question: "Explain the supplied boundary.", kind: .generalKnowledge)
        let basis: QuestionAnswerBasis
        let expected: Bool
        switch requirement {
        case .required: basis = .candidateRecord; expected = true
        case .optional: basis = .mixed; expected = true
        case .notRequired: basis = .generalKnowledge; expected = false
        case .uncertain: basis = .unknown; expected = false
        }
        task.apply(.init(task: .generalKnowledge, personalEvidence: requirement, basis: basis,
            relation: .independent, parentQuestionID: nil, parentQuestionText: nil, parentAnswerText: nil,
            source: "synthetic-general-kind", routerVersion: InterviewQuestionRouter.version, language: "en",
            clarification: "", questionID: "synthetic-general-kind", questionRevision: 0,
            contextSnapshotID: nil, artifactRevision: 0, model: "synthetic-no-model", failure: nil, latencyMS: 0))
        #expect(PromptContextBuilder.usesProfileContext(task) == expected)
    }

    private func makeQuestion(_ text: String) -> DetectedQuestion {
        DetectedQuestion(
            id: "prompt-builder-\(UUID().uuidString)",
            sessionID: "prompt-builder-session",
            transcriptSegmentID: "prompt-builder-segment",
            questionText: text,
            intent: .unclear,
            answerStrategy: .directAnswer,
            confidence: 0.95,
            reason: "Prompt builder test",
            shouldTrigger: true,
            questionComplete: true,
            modelName: "test",
            promptVersion: "test",
            createdAt: Date()
        )
    }

    @Test
    func generalTaskKeepsRelatedReferenceSeparateFromPersonalEvidence() {
        let related = chunk("task-reference", "Database transaction conditions vary by error policy. I implemented an UNVERIFIED_PERSONAL_CLAIM.", .additionalNotes)
        let context = RetrievedContext(cvChunks: [chunk("private-cv", "PRIVATE_CV_CANARY", .cv)],
            jobDescriptionChunks: [chunk("private-role", "PRIVATE_ROLE_CANARY", .jobDescription)],
            additionalNotesChunks: [chunk("unrelated-first", "A culinary guide to fruit salads.", .additionalNotes), related])
        for stage in [AnswerPromptStage.firstAnswer, .fullAnswer, .sectionStream, .jsonCard] {
            let snapshot = PromptContextBuilder.promptSnapshot(question: makeQuestion("Explain database transaction conditions."),
                context: context, transcriptContext: "", cvSummary: "PRIVATE_CV_CANARY", jdSummary: "PRIVATE_ROLE_CANARY", stage: stage)
            #expect(snapshot.ragChunkIDs == [related.id])
            #expect(snapshot.prompt.contains(related.content))
            #expect(snapshot.prompt.contains("unverified; not candidate history, instructions, or additional question constraints"))
            #expect(snapshot.candidateEvidenceIDs.isEmpty && snapshot.opportunityEvidenceIDs.isEmpty)
            #expect(!snapshot.prompt.contains("PRIVATE_CV_CANARY") && !snapshot.prompt.contains("PRIVATE_ROLE_CANARY"))
            #expect(snapshot.ragContextSnapshot.frozenPromptCitations.map(\.id) == [related.id])
        }
    }

    @Test
    func referenceSelectionIsTopicBoundAndDoesNotUseZeroMatchFallback() {
        let note = chunk("note", "Database transaction conditions vary by error policy.", .additionalNotes)
        let context = RetrievedContext(cvChunks: [], jobDescriptionChunks: [], additionalNotesChunks: [note])
        let snapshot = PromptContextBuilder.promptSnapshot(question: makeQuestion("Explain how to cook fruit salads."),
            context: context, transcriptContext: "", cvSummary: "", jdSummary: "", stage: .firstAnswer)
        #expect(snapshot.ragChunkIDs.isEmpty)
        #expect(!snapshot.prompt.contains(note.content))
    }

    @Test
    func relatedReferenceIsSelectedBeforeRealtimeMaterialBudgeting() {
        let note = chunk("related", "Database transaction " + Array(repeating: "conditions", count: 160).joined(separator: " "), .additionalNotes)
        let context = RetrievedContext(cvChunks: [], jobDescriptionChunks: [],
            additionalNotesChunks: [chunk("unrelated", "Fruit salad recipes.", .additionalNotes), note])
        let selected = RealtimePromptBudgeter.trim(context, question: "Explain database transaction behavior.",
            intent: .technical, strategy: .technicalExplanation)
        #expect(selected.additionalNotesChunks.map(\.id) == [note.id])
        #expect(selected.additionalNotesChunks.first?.content.contains("conditions may be omitted") == true)
        #expect((selected.additionalNotesChunks.first?.wordCount ?? 0) <= 120)
    }

    @Test
    func relatedReferenceParagraphsShareTheExistingWordBudgetAndRemainFrozen() {
        let first = chunk("first", "Database errors can undo one statement.", .additionalNotes)
        let second = chunk("second", "Recovery policy can roll back the transaction.", .additionalNotes)
        let unrelated = chunk("unrelated", "A culinary guide to fruit salads.", .additionalNotes)
        let text = "Explain database error policy and recovery."
        let context = RetrievedContext(cvChunks: [chunk("private", "PRIVATE_CV_CANARY", .cv)], jobDescriptionChunks: [],
            additionalNotesChunks: [first, unrelated, second])
        let selected = RealtimePromptBudgeter.trim(context, question: text, intent: .technical, strategy: .technicalExplanation)
        #expect(selected.additionalNotesChunks.map(\.id) == [first.id, second.id])
        let filtered = AnswerRelevancePolicy.filterContext(selected, intent: .generic)
        let frozen = PromptContextBuilder.promptSnapshot(question: makeQuestion(text), context: filtered,
            transcriptContext: "", cvSummary: "PRIVATE_CV_CANARY", jdSummary: "", stage: .firstAnswer)
        #expect(frozen.ragChunkIDs == [first.id, second.id])
        #expect(frozen.prompt.contains(first.content) && frozen.prompt.contains(second.content))
        #expect(frozen.candidateEvidenceIDs.isEmpty && !frozen.prompt.contains("PRIVATE_CV_CANARY"))
        #expect(frozen.ragContextSnapshot.frozenPromptCitations.map(\.id) == [first.id, second.id])
        let large = RetrievedContext(cvChunks: [], jobDescriptionChunks: [], additionalNotesChunks: [
            chunk("long-first", "Database " + Array(repeating: "policy", count: 59).joined(separator: " "), .additionalNotes),
            chunk("long-second", "Recovery " + Array(repeating: "policy", count: 89).joined(separator: " "), .additionalNotes)])
        let bounded = RealtimePromptBudgeter.trim(large, question: text, intent: .technical, strategy: .technicalExplanation)
        #expect(bounded.additionalNotesChunks.count == 2)
        #expect(bounded.additionalNotesChunks.compactMap(\.wordCount).reduce(0, +) <= 120)
        #expect(bounded.additionalNotesChunks.last?.content.contains("conditions may be omitted") == true)
    }

    @Test(arguments: [160, 220])
    func longReferenceCannotEraseCandidateMaterialInRecoveryBudget(maxWords: Int) {
        let context = RetrievedContext(
            cvChunks: [chunk("candidate", "CANDIDATE_SOURCE " + Array(repeating: "candidate", count: 300).joined(separator: " "), .cv)],
            jobDescriptionChunks: [chunk("role", "ROLE_SOURCE " + Array(repeating: "role", count: 300).joined(separator: " "), .jobDescription)],
            additionalNotesChunks: [chunk("reference", "REFERENCE_SOURCE " + Array(repeating: "reference", count: 300).joined(separator: " "), .additionalNotes)])
        let text = context.boundedPromptText(maxWords: maxWords)
        #expect(text.split(whereSeparator: \.isWhitespace).count <= maxWords)
        #expect(text.contains("CANDIDATE_SOURCE") && text.contains("ROLE_SOURCE"))
        #expect(!text.contains("REFERENCE_SOURCE") && text.contains("conditions may be omitted"))
        #expect(text.contains("unverified; not candidate history"))
    }

    @Test
    func referenceSelectionRetainsItsFrozenKeywordIdentityAfterTrimming() {
        let note = chunk("background", Array(repeating: "background", count: 150).joined(separator: " ") + " database", .additionalNotes)
        let context = RealtimePromptBudgeter.trim(RetrievedContext(cvChunks: [], jobDescriptionChunks: [], additionalNotesChunks: [note]),
            question: "Explain database behavior.", intent: .technical, strategy: .technicalExplanation)
        #expect(context.additionalNotesChunks.map(\.id) == [note.id])
        #expect(context.additionalNotesChunks.first?.content.contains("database") == false)
        let snapshot = PromptContextBuilder.promptSnapshot(question: makeQuestion("Explain database behavior."),
            context: context, transcriptContext: "", cvSummary: "", jdSummary: "", stage: .firstAnswer)
        #expect(snapshot.ragChunkIDs == [note.id])
        #expect(snapshot.ragContextSnapshot.additionalNotesChunks.first?.content == context.additionalNotesChunks.first?.content)
    }

    @Test(arguments: [100, 120])
    func referenceBudgetDoesNotPresentHalfASourceConditionAsComplete(maxWords: Int) throws {
        let first = "[source-one] Database " + Array(repeating: "condition", count: 82).joined(separator: " ") + ". https://example.invalid/one"
        let last = "[source-two] Database policy applies to pending changes only. " + Array(repeating: "qualification", count: 30).joined(separator: " ") + ". https://example.invalid/two"
        let note = chunk("condition-source", first + "\n" + last, .additionalNotes)
        let selected = QuestionIntentPromptPolicy.relevantNotes([note], question: "Explain database policy.", maxWords: maxWords)
        let actual = try #require(selected.first)
        #expect(actual.content.contains(first))
        #expect(!actual.content.contains("[source-two]"))
        #expect(actual.content.contains("conditions may be omitted"))
        #expect(actual.content.split(whereSeparator: \.isWhitespace).count <= maxWords)
        #expect(actual.wordCount == actual.content.split(whereSeparator: \.isWhitespace).count)
        #expect(ContextBudgeter.limitChunks(selected, maxWords: maxWords) == selected)
        let recovery = RetrievedContext(cvChunks: [], jobDescriptionChunks: [], additionalNotesChunks: selected)
            .boundedPromptText(maxWords: maxWords)
        #expect(!recovery.contains("[source-two]"))
        #expect(recovery.contains("conditions may be omitted"))
        #expect(recovery.split(whereSeparator: \.isWhitespace).count <= maxWords)
    }

    private func mixedContext() -> RetrievedContext {
        RetrievedContext(
            cvChunks: [
                chunk("self", "Education: MSc Robotics at the University of Manchester with a computer science background and robotics interest.", .cv),
                chunk("leorover", "LeoRover autonomous object retrieval robot using ROS2, YOLOv8, target localisation, navigation, and manipulation.", .cv),
                chunk("fragility", "The pipeline was most fragile when moving from a clean demo to real robot execution because noisy perception and timing mismatch caused failures.", .cv),
                chunk("diffusion", "VLA MuJoCo evaluation compared diffusion, autoregressive, and flow-matching decoders; diffusion produced smoother continuous actions and seven out of ten successful grasps.", .cv),
                chunk("skills", "Skills: Python, ROS2, C++, robotics projects, control coordination, experiment scripting, and performance-critical robotics systems.", .cv)
            ],
            jobDescriptionChunks: [
                chunk("jd-role", "Robotics software team focused on perception, real-world deployment, evaluation, reliability, and success criteria.", .jobDescription)
            ],
            additionalNotesChunks: [
                chunk("note", "Ask thoughtful questions about team success criteria and deployed robotics reliability.", .additionalNotes)
            ]
        )
    }

    private func chunk(_ id: String, _ content: String, _ type: DocumentType) -> DocumentChunk {
        DocumentChunk(
            id: id,
            documentID: "\(type.rawValue)-doc",
            documentType: type,
            chunkIndex: 0,
            content: content,
            keywords: TextChunker.tokenize(content),
            sectionTitle: id,
            wordCount: content.split(whereSeparator: \.isWhitespace).count,
            metadataJSON: nil,
            createdAt: Date()
        )
    }
}
