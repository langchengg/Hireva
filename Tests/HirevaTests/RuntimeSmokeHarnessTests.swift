import Foundation
import Testing
@testable import Hireva

@MainActor
func makeHermeticContextBoundSession(
    appState: AppState,
    prefix: String,
    mode: InterviewMode = .microphone,
    title: String? = nil
) throws -> InterviewSession {
    let sourceID = "\(prefix)-synthetic-context"
    let candidateStatements = [
        "The synthetic candidate built a LeoRover ROS2 system connecting YOLOv8 perception, localization, navigation, manipulation, and recovery behavior.",
        "The synthetic candidate evaluated autoregressive, diffusion, and flow-matching policies with DROID trajectories in a MuJoCo Franka simulation.",
        "The synthetic candidate debugged real-world robot execution using logs, timestamp checks, calibration checks, lighting and occlusion tests, and recovery validation.",
        "The synthetic candidate uses Python, C++, and ROS2 and wants a robotics role focused on reliable deployed systems."
    ]
    let candidateEvidence = candidateStatements.enumerated().map { index, statement in
        ProfileEvidence(
            id: "\(prefix)-candidate-evidence-\(index)",
            statement: statement,
            sourceDocumentID: sourceID,
            sourceChunkID: "\(sourceID)-candidate-\(index)",
            sourceSpan: statement,
            confidence: 1,
            evidenceType: index == 3 ? .skill : .project,
            explicitness: .explicit
        )
    }
    let opportunityStatements = [
        "The synthetic robotics role requires perception, localization, navigation, manipulation, and systematic debugging of deployed robots.",
        "The engineering team evaluates clear technical communication, reliable delivery, and evidence-based failure analysis."
    ]
    let opportunityEvidence = opportunityStatements.enumerated().map { index, statement in
        ProfileEvidence(
            id: "\(prefix)-opportunity-evidence-\(index)",
            statement: statement,
            sourceDocumentID: sourceID,
            sourceChunkID: "\(sourceID)-opportunity-\(index)",
            sourceSpan: statement,
            confidence: 1,
            evidenceType: index == 0 ? .responsibility : .evaluationCriterion,
            explicitness: .explicit
        )
    }
    let profileID = "\(prefix)-candidate-profile"
    let opportunityID = "\(prefix)-opportunity"
    try appState.interviewContextRepository.saveCandidateProfile(CandidateProfile(
        id: profileID,
        displayName: "Synthetic Test Candidate",
        sourceDocumentIDs: [sourceID],
        education: [],
        experience: candidateEvidence,
        projects: [],
        skills: [],
        publications: [],
        achievements: [],
        declaredGaps: [],
        goals: [],
        generatedSummary: nil,
        version: 1,
        updatedAt: Date()
    ))
    try appState.interviewContextRepository.saveOpportunityContext(OpportunityContext(
        id: opportunityID,
        title: "Synthetic Robotics Engineer",
        organisation: "Synthetic Robotics Lab",
        opportunityType: .job,
        responsibilities: [opportunityEvidence[0]],
        requiredSkills: [],
        preferredSkills: [],
        researchTopics: [],
        evaluationCriteria: [opportunityEvidence[1]],
        sourceDocumentIDs: [sourceID],
        version: 1,
        updatedAt: Date()
    ))
    appState.refreshAll()
    appState.selectCandidateProfile(profileID)
    appState.selectOpportunityContext(opportunityID)
    appState.selectInterviewDomain(.roboticsResearch)

    let session = try appState.createContextBoundSession(mode: mode, title: title)
    guard let snapshotID = session.contextSnapshotID,
          let snapshot = try appState.interviewContextRepository.snapshot(id: snapshotID),
          snapshot.candidateProfileID == profileID,
          snapshot.opportunityContextID == opportunityID,
          snapshot.candidateEvidence.isEmpty == false,
          snapshot.opportunityEvidence.isEmpty == false else {
        throw NSError(
            domain: "HermeticInterviewContextFixture",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Failed to create a complete synthetic interview context snapshot."]
        )
    }
    return session
}

func hermeticRuntimeQuestion(from prompt: String) -> String {
    if let range = prompt.range(
        of: #"CURRENT QUESTION TO ANSWER:\s*\n"([^"]+)""#,
        options: [.regularExpression, .caseInsensitive]
    ) {
        return String(prompt[range])
            .replacingOccurrences(of: "CURRENT QUESTION TO ANSWER:", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))
    }
    return prompt
}

func hermeticRuntimeAnswer(for prompt: String) -> String {
    let question = hermeticRuntimeQuestion(from: prompt)
    let lower = question.lowercased()
    if lower.contains("do you have any questions") || lower.contains("engineering team") || lower.contains("good fit") {
        return "How does the engineering team define success for reliable deployed robotics? How is debugging ownership shared? What would strong performance in the first three months look like?"
    }
    if lower.contains("why do you want") || lower.contains("join our team") || lower.contains("prepares you for this role") {
        return "I want the role because it matches my experience building reliable deployed robotics systems and my goal to deepen that work with the team."
    }
    if lower.contains("another month") || lower.contains("one more month") || lower.contains("change first") || lower.contains("improve first") || lower.contains("do differently") {
        return "My first priority for LeoRover would be to improve real-world reliability by adding failure-case tests, instrumenting perception and localization handoffs, evaluating recovery behavior, and validating the result on the robot."
    }
    if lower.contains("diffusion") || lower.contains("autoregressive") || lower.contains("flow-matching") {
        return "Compared with autoregressive decoding, the diffusion policy was more reliable in MuJoCo because it represented continuous action distributions smoothly and tolerated trajectory uncertainty better."
    }
    if lower.contains("difference") && lower.contains("vla") && lower.contains("leorover") {
        return "The VLA project evaluated DROID trajectories and diffusion decoders in a MuJoCo Franka simulation, whereas the LeoRover project connected YOLOv8 perception, ROS2 navigation, manipulation, and recovery on a real robot."
    }
    if lower.contains("sim real") || lower.contains("sim-to-real") || (lower.contains("hardware") && lower.contains("muji")) {
        return "I would compare simulation and real hardware logs, then isolate calibration, timing, action scaling, contact dynamics, and observation differences before validating the policy again."
    }
    if lower.contains("droid") || lower.contains("franka") {
        return "The transformation converted DROID demonstrations into synchronized trajectories, mapped actions into MuJoCo Franka control conventions, and validated timestamps and coordinate frames."
    }
    if lower.contains("yolo") || lower.contains("confident but wrong") {
        return "I would reproduce the YOLOv8 confidence failure, inspect the original frame and logs, isolate the bounding-box, class, calibration, lighting, and occlusion conditions, then test and validate the fix before retraining."
    }
    if lower.contains("noisy") || lower.contains("localisation") || lower.contains("localization") || lower.contains("hardest technical challenge") || lower.contains("fragile") {
        return "The main challenge was making noisy perception, localization, navigation, and manipulation work reliably together. I diagnosed it by inspecting logs and traces; validation guards, tests, and recovery behavior reduced risk."
    }
    if lower.contains("walk me through") || lower.contains("leorover") || lower.contains("robotics project") {
        return "I built a LeoRover object-retrieval pipeline that connected YOLOv8 perception to localization, navigation, manipulation, and recovery behavior. The result was repeatable end-to-end retrieval, and I learned to validate timestamps and frames at every handoff."
    }
    if lower.contains("comfortable") || lower.contains("python") || lower.contains("c plus plus") || lower.contains("ros two") {
        return "I am comfortable with Python, C++, and ROS2 because I have used them to build and debug perception, navigation, and manipulation pipelines."
    }
    if lower.contains("yourself") || lower.contains("background") {
        return "I built a LeoRover ROS2 system connecting YOLOv8 perception, localization, navigation, manipulation, and recovery behavior, and that robotics work is the core of my technical background."
    }
    return "I would answer the interviewer directly with a specific, evidence-grounded robotics example."
}

func hermeticRuntimeSectionTokens(for prompt: String) -> [String] {
    let answer = hermeticRuntimeAnswer(for: prompt)
    return [
        "STRATEGY:\nDirect answer\n",
        "SAY_FIRST:\n\(answer)\n",
        "KEY_POINTS:\n",
        "- \(answer.prefix(90))\n",
        "- Keep the response grounded in the synthetic candidate evidence\n",
        "FOLLOW_UP_READY:\n",
        "- I can go deeper into implementation details.\n",
        "CAUTION:\nNone\n"
    ]
}

func hermeticJSONString(_ value: String) -> String {
    let data = try? JSONEncoder().encode(value)
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
}

@Suite(.serialized)
@MainActor
struct RuntimeSmokeHarnessTests {
    @Test
    func badFragmentsSuiteRejectsWithoutGenerationOrPersistence() async throws {
        guard Self.shouldRun("bad-fragments") else { return }
        let harness = try makeHarness(suite: "bad-fragments")
        let fragments = [
            "what did you learn from comp",
            "tell me about a time you had",
            "what questions would you ask us about the",
            "how would you diagnose a seem"
        ]

        for (index, fragment) in fragments.enumerated() {
            await harness.feed(text: fragment, id: "bad-fragment-\(index)")
        }
        try await harness.waitBriefly()

        let rows = try harness.rows()
        let trace = try harness.traceText()
        harness.printSummary(rows: rows, trace: trace)

        #expect(rows.isEmpty)
        #expect(!trace.contains("\"event_type\":\"generationStarted\""))
        #expect(trace.contains("\"event_type\":\"questionRejected\""))
    }

    @Test
    func rapidTwoQuestionSuiteRejectsLateFirstQuestionCallbacksAndPersistsSeparateRows() async throws {
        guard Self.shouldRun("rapid-two") else { return }
        let harness = try makeHarness(suite: "rapid-two")
        harness.appState.delayProvider = RuntimeSmokeDeferredFallbackDelayProvider()
        harness.appState.generationFullCardWatchdogNanoseconds = 30_000_000_000
        harness.appState.stageATimeoutSeconds = 30
        harness.client.blockStreams(containing: "engineering team")
        defer { harness.client.releaseBlockedStreams(containing: "engineering team") }

        let firstQuestion = "What would you ask the engineering team to understand whether this role is a good fit?"
        let secondQuestion = "If you had one more month to improve your LeoRover system, what would you improve first?"
        await harness.feed(text: firstQuestion, id: "rapid-two-q1", secondsFromStart: 0)
        try await harness.waitForBlockedStreams(containing: "engineering team", startedAtLeast: 2)
        #expect(harness.appState.currentSuggestion == nil)

        await harness.feed(text: secondQuestion, id: "rapid-two-q2", secondsFromStart: 1)
        try await harness.waitForCurrentQuestion(secondQuestion)
        harness.client.releaseBlockedStreams(containing: "engineering team")
        try await harness.waitForBlockedStreams(containing: "engineering team", finishedAtLeast: 2)

        try await harness.waitForRows(2)
        try await harness.waitForTraceEventCount("persistenceSucceeded", atLeast: 2)
        let rows = try harness.rows()
        let trace = try harness.traceText()
        harness.printSummary(rows: rows, trace: trace)

        #expect(rows.count == 2)
        #expect(rows[0].questionIntent == .interviewerQuestions)
        #expect(rows[1].questionIntent == .improvementPlan)
        #expect(rows.allSatisfy { $0.questionText == $0.promptPrimaryQuestion })
        #expect(harness.appState.liveSuggestionHistory.count == 2)
        #expect(harness.appState.currentSuggestion?.questionText == rows[1].questionText)
        #expect(harness.appState.currentSuggestion?.questionText == secondQuestion)
        #expect(trace.contains("\"event_type\":\"answer.request.started\""))
        #expect(trace.components(separatedBy: "\"event_type\":\"persistenceSucceeded\"").count - 1 >= 2)
        #expect(
            trace.contains("\"event_type\":\"staleGenerationResultRejected\"") ||
                trace.contains("\"event_type\":\"cancelledGenerationPersistenceRejected\"")
        )
    }

    @Test
    func rapidThreeQuestionSuiteKeepsLatestCardAfterTwoLateProviderCompletions() async throws {
        guard Self.shouldRun("rapid-three") else { return }
        let harness = try makeHarness(suite: "rapid-three")
        harness.client.blockStreams(containing: "engineering team")
        harness.client.blockStreams(containing: "one more month")
        defer {
            harness.client.releaseBlockedStreams(containing: "engineering team")
            harness.client.releaseBlockedStreams(containing: "one more month")
        }

        let firstQuestion = "What would you ask the engineering team to understand whether this role is a good fit?"
        let secondQuestion = "If you had one more month to improve your LeoRover system, what would you improve first?"
        let thirdQuestion = "Can you explain the difference between your VLA project and your LeoRover project?"
        await harness.feed(text: firstQuestion, id: "rapid-three-q1", secondsFromStart: 0)
        try await harness.waitForBlockedStreams(containing: "engineering team", startedAtLeast: 2)
        await harness.feed(text: secondQuestion, id: "rapid-three-q2", secondsFromStart: 1)
        try await harness.waitForBlockedStreams(containing: "one more month", startedAtLeast: 2)
        await harness.feed(text: thirdQuestion, id: "rapid-three-q3", secondsFromStart: 2)
        try await harness.waitForCurrentQuestion(thirdQuestion)

        harness.client.releaseBlockedStreams(containing: "engineering team")
        harness.client.releaseBlockedStreams(containing: "one more month")
        try await harness.waitForBlockedStreams(containing: "engineering team", finishedAtLeast: 2)
        try await harness.waitForBlockedStreams(containing: "one more month", finishedAtLeast: 2)

        try await harness.waitForRows(3)
        try await harness.waitForTraceEventCount("persistenceSucceeded", atLeast: 3)
        let rows = try harness.rows()
        let trace = try harness.traceText()
        harness.printSummary(rows: rows, trace: trace)

        #expect(rows.count == 3)
        #expect(rows.map(\.questionIntent) == [.interviewerQuestions, .improvementPlan, .projectComparison])
        let interviewer = try #require(rows.first { $0.questionIntent == .interviewerQuestions })
        let improvement = try #require(rows.first { $0.questionIntent == .improvementPlan })
        let comparison = try #require(rows.first { $0.questionIntent == .projectComparison })
        let comparisonText = ([comparison.sayFirst] + comparison.keyPoints).joined(separator: " ")
        #expect(interviewer.sayFirst.filter { $0 == "?" }.count >= 2)
        #expect(QuestionAnswerAlignmentEvaluator.isAnswerComplete(improvement.sayFirst))
        #expect(improvement.sayFirst.localizedCaseInsensitiveContains("LeoRover"))
        #expect(comparisonText.localizedCaseInsensitiveContains("MuJoCo") || comparisonText.localizedCaseInsensitiveContains("Franka"))
        #expect(comparisonText.localizedCaseInsensitiveContains("DROID") || comparisonText.localizedCaseInsensitiveContains("decoder"))
        #expect(comparisonText.localizedCaseInsensitiveContains("ROS2") || comparisonText.localizedCaseInsensitiveContains("YOLOv8"))
        #expect(comparisonText.localizedCaseInsensitiveContains("navigation") || comparisonText.localizedCaseInsensitiveContains("manipulation") || comparisonText.localizedCaseInsensitiveContains("recovery"))
        #expect(harness.appState.liveSuggestionHistory.map(\.id) == rows.map(\.id))
        #expect(harness.appState.currentSuggestion?.questionIntent == .projectComparison)
        #expect(harness.appState.currentSuggestion?.questionText == thirdQuestion)
        #expect(rows.allSatisfy { $0.questionText == $0.promptPrimaryQuestion })
        #expect(trace.components(separatedBy: "\"event_type\":\"persistenceSucceeded\"").count - 1 >= 3)
        #expect(
            trace.contains("\"event_type\":\"staleGenerationResultRejected\"") ||
                trace.contains("\"event_type\":\"cancelledGenerationPersistenceRejected\"")
        )
    }

    @Test
    func conditionalASRSuiteKeepsFullConditionalQuestion() async throws {
        guard Self.shouldRun("conditional-asr") else { return }
        let harness = try makeHarness(suite: "conditional-asr")

        await harness.feed(
            text: "If your yo love eight detector gives a confident but wrong prediction on the layover, how would you debug it?",
            id: "conditional-asr-yolo"
        )

        try await harness.waitForRows(1)
        let rows = try harness.rows()
        let trace = try harness.traceText()
        harness.printSummary(rows: rows, trace: trace)

        let row = try #require(rows.first)
        #expect(row.questionText == "If your yo love eight detector gives a confident but wrong prediction on the layover, how would you debug it?")
        #expect(row.questionIntent == .perceptionDebugging)
        #expect(row.sayFirst.localizedCaseInsensitiveContains("YOLOv8"))
        #expect(row.sayFirst.localizedCaseInsensitiveContains("confidence"))
        #expect((row.questionText ?? "").hasPrefix("If your yo love eight"))
    }

    @Test
    func noisyCanonicalizationSuiteNormalizesCommonASRVariants() async throws {
        guard Self.shouldRun("noisy-canonicalization") else { return }
        let harness = try makeHarness(suite: "noisy-canonicalization")

        await harness.feed(text: "How would you diagnose a sim to real gap if your policy works in simulation but fails on hardware?", id: "noisy-sim-real")
        try await harness.waitForRows(1)
        await harness.feed(text: "What did you learn from comparing auto aggressive diffusion and flow matching decoders in your villa project?", id: "noisy-vla")

        try await harness.waitForRows(2)
        let rows = try harness.rows()
        let trace = try harness.traceText()
        harness.printSummary(rows: rows, trace: trace)

        #expect(rows.contains { ($0.questionText ?? "").contains("sim-to-real") && ($0.questionText ?? "").contains("simulation") })
        #expect(rows.contains { ($0.questionText ?? "").contains("auto aggressive") && ($0.questionText ?? "").contains("flow matching") && ($0.questionText ?? "").contains("villa project") })
    }

    @Test
    func incompleteStreamSuiteRejectsPartialProviderAnswerAndUsesFallback() async throws {
        guard Self.shouldRun("incomplete-stream") else { return }
        let harness = try makeHarness(suite: "incomplete-stream")
        defer { harness.appState.cancelStageBTask() }
        harness.client.incompleteStageAForNeedle = "engineering team"
        let delayProvider = MockDelayProvider()
        delayProvider.sleepDuration = 2_000_000_000
        harness.appState.delayProvider = delayProvider
        harness.appState.generationFullCardWatchdogNanoseconds = 60_000_000_000

        await harness.feed(text: "What would you ask the engineering team to understand whether this role is a good fit?", id: "incomplete-stream-q1")

        try await harness.waitForRows(1)
        try await harness.waitForTraceEvent("partialAnswerRejectedIncomplete")
        let rows = try harness.rows()
        let trace = try harness.traceText()
        harness.printSummary(rows: rows, trace: trace)

        let row = try #require(rows.first)
        #expect(row.alignmentVerdict == .aligned)
        #expect(!row.sayFirst.localizedCaseInsensitiveContains("how they"))
        #expect(row.finalVisibleSource?.localizedCaseInsensitiveContains("fallback") == true)
        #expect(trace.contains("\"event_type\":\"partialAnswerRejectedIncomplete\""))
    }

    @Test
    func completedStageBCancelsFullCardWatchdog() async throws {
        guard Self.shouldRun("stage-b-watchdog") else { return }
        let harness = try makeHarness(suite: "stage-b-watchdog")
        harness.appState.generationFullCardWatchdogNanoseconds = 5_000_000_000

        await harness.feed(
            text: "Can you explain the difference between your VLA project and your LeoRover project?",
            id: "stage-b-watchdog-q1"
        )

        try await harness.waitForRows(1)
        try await harness.waitForPipelineIdle(timeout: 12.0)
        try await Task.sleep(nanoseconds: 5_500_000_000)
        let trace = try harness.traceText()
        let row = try #require(try harness.rows().first)

        #expect(harness.appState.generationUIState.displayName == "Answer ready")
        #expect(harness.appState.visibleAssistantRenderState.generationErrorText == nil)
        #expect(row.stageBStatus == "completed" || row.stageBStatus == "semantic_fallback")
        #expect(!trace.contains("\"event_type\":\"generationTimedOut\""))
    }

    @Test
    func longInterviewSuiteKeepsSevenCumulativeQuestionsDistinctAndCurrent() async throws {
        guard Self.shouldRun("long-interview") else { return }
        let harness = try makeHarness(suite: "long-interview")
        let questions = [
            "Could you briefly introduce yourself and your robotics background?",
            "Could you explain your LeoRover project from end to end?",
            "What was the hardest technical challenge in making the real robot work reliably?",
            "In your VLA project, why did the diffusion decoder outperform the autoregressive and flow-matching versions?",
            "How did you convert real robot demonstrations from DROID into actions that your MuJoCo Franka simulation could use?",
            "If your YOLOv8 detector confidently picks the wrong object on the LeoRover, how would you debug that before retraining the model?",
            "Can you explain the difference between your VLA project and your LeoRover project?"
        ]
        var cumulativeTranscript: [String] = []

        for (index, question) in questions.enumerated() {
            if index == 4 {
                harness.appState.recentQuestionTimestamps = harness.appState.recentQuestionTimestamps
                    .mapValues { _ in Date().addingTimeInterval(-120) }
            }
            cumulativeTranscript.append(question)
            let cumulativeText = cumulativeTranscript.joined(separator: " ")
            let expectedQuestion = SystemAudioQuestionExtractor.extract(from: cumulativeText).last?.text ?? question
            await harness.feed(
                text: cumulativeText,
                id: "long-interview-cumulative-segment",
                secondsFromStart: TimeInterval(index * 25)
            )
            try await harness.waitForCurrentQuestion(expectedQuestion)
            try await harness.waitForRows(index + 1)
            #expect(harness.appState.currentSuggestion?.questionText == expectedQuestion)
            #expect(harness.appState.visibleQuestionText(for: harness.appState.currentSuggestion) == expectedQuestion)
        }

        try await harness.waitForPipelineIdle()
        try await harness.waitForTraceEventCount("persistenceSucceeded", atLeast: 7)
        let rows = try harness.rows()
        let trace = try harness.traceText()
        harness.printSummary(rows: rows, trace: trace)
        let normalizedQuestions = rows.compactMap(\.questionText).map(SemanticDuplicateKeyBuilder.key(for:))
        let persistenceSucceededCount = trace.components(
            separatedBy: "\"event_type\":\"persistenceSucceeded\""
        ).count - 1
        let orderedAll = questions.flatMap {
            SystemAudioQuestionExtractor.extract(from: $0).map { SemanticDuplicateKeyBuilder.key(for: $0.text) }
        }

        #expect(rows.count == 7)
        #expect(Set(normalizedQuestions).count == rows.count)
        #expect(Set(rows.compactMap(\.detectedQuestionID)).count == rows.count)
        #expect(Set(rows.compactMap(\.generationID)).count == rows.count)
        #expect(Set(rows.compactMap(\.questionIntent)).count >= 5)
        #expect(rows.allSatisfy { $0.questionText == $0.promptPrimaryQuestion })
        #expect(harness.appState.liveSuggestionHistory.count == rows.count)
        let finalExpectedQuestion = SystemAudioQuestionExtractor.extract(
            from: questions.joined(separator: " ")
        ).last?.text
        #expect(harness.appState.currentSuggestion?.questionText == finalExpectedQuestion)
        #expect(persistenceSucceededCount == rows.count)
        #expect(normalizedQuestions == orderedAll)
        #expect(!trace.contains("\"event_type\":\"duplicatePersistenceRejected\""))
    }

    @Test
    func appleSpeechCumulativeReplaySuiteRejectsOldCallbacksAndKeepsNewestCard() async throws {
        guard Self.shouldRun("apple-speech-cross-task-replay") else { return }
        let harness = try makeHarness(suite: "apple-speech-cross-task-replay")
        harness.client.stageAStreamDelayByNeedle["LeoRover project"] = 5_000_000_000
        let slowDelay = MockDelayProvider()
        slowDelay.sleepDuration = 5_000_000_000
        harness.appState.delayProvider = slowDelay
        harness.appState.generationFullCardWatchdogNanoseconds = 5_000_000_000
        let q1 = "Could you explain your LeoRover project from end to end?"
        let q2 = "How did you convert real robot demonstrations from DROID into actions that your MuJoCo Franka simulation could use?"
        let q3 = "If your YOLOv8 detector confidently picks the wrong object on the LeoRover, how would you debug that before retraining the model?"

        await harness.feed(text: q1, id: "apple-replay-callback-1", secondsFromStart: 0, recognitionTaskID: "apple-task-1", eventSequence: 1)
        try await harness.waitForTraceEvent("generationStarted")
        harness.appState.recentQuestionTimestamps = harness.appState.recentQuestionTimestamps
            .mapValues { _ in Date().addingTimeInterval(-120) }
        let fastDelay = MockDelayProvider()
        fastDelay.sleepDuration = 5_000_000
        harness.appState.delayProvider = fastDelay
        harness.appState.generationFullCardWatchdogNanoseconds = 400_000_000
        await harness.feed(text: "\(q1) \(q2)", id: "apple-replay-callback-2", secondsFromStart: 65, recognitionTaskID: "apple-task-1", eventSequence: 2)
        let expectedQ2 = SystemAudioQuestionExtractor.extract(from: q2).last?.text ?? q2
        try await harness.waitForCurrentQuestion(expectedQ2)
        await harness.feed(text: "\(q1) \(q2) \(q3)", id: "apple-replay-callback-3", secondsFromStart: 90, recognitionTaskID: "apple-task-2", eventSequence: 1)

        let expectedQ3 = SystemAudioQuestionExtractor.extract(from: q3).last?.text ?? q3
        try await harness.waitForCurrentQuestion(expectedQ3)
        try await harness.waitForRows(3)
        try await harness.waitForPipelineIdle()
        let rows = try harness.rows()
        let trace = try harness.traceText()
        harness.printSummary(rows: rows, trace: trace)
        let normalized = rows.compactMap(\.questionText).map(SemanticDuplicateKeyBuilder.key(for:))

        #expect(Set(normalized).count == rows.count)
        #expect(rows.filter { SemanticDuplicateKeyBuilder.areDuplicates($0.questionText ?? "", q1) }.count == 1)
        #expect(rows.contains { ($0.questionText ?? "").localizedCaseInsensitiveContains("DROID") })
        #expect(rows.contains { ($0.questionText ?? "").localizedCaseInsensitiveContains("YOLOv8") })
        #expect(rows.allSatisfy { $0.stageBStatus != "cancelled" })
        #expect(harness.appState.currentSuggestion?.questionText == expectedQ3)
        #expect(trace.contains("\"event_type\":\"cancelledGenerationPersistenceRejected\""))
    }

    @Test
    func realLongInterviewOrderingSuiteNeverRegressesToOldCumulativeQuestion() async throws {
        guard Self.shouldRun("seven-question-real-order") else { return }
        let harness = try makeHarness(suite: "seven-question-real-order")
        let questions = [
            "Could you briefly introduce yourself and your robotics background?",
            "Could you explain your LeoRover project from end to end?",
            "What was the hardest technical challenge in making the real robot work reliably?",
            "In your VLA project, why did the diffusion decoder outperform the autoregressive and flow-matching versions?",
            "How did you convert real robot demonstrations from DROID into actions that your MuJoCo Franka simulation could use?",
            "If your YOLOv8 detector confidently picks the wrong object on the LeoRover, how would you debug that before retraining the model?",
            "Can you explain the difference between your VLA project and your LeoRover project?"
        ]
        var cumulative: [String] = []

        for (index, question) in questions.enumerated() {
            if index == 4 {
                harness.appState.recentQuestionTimestamps = harness.appState.recentQuestionTimestamps
                    .mapValues { _ in Date().addingTimeInterval(-120) }
            }
            cumulative.append(question)
            await harness.feed(
                text: cumulative.joined(separator: " "),
                id: "real-apple-callback-\(index)",
                secondsFromStart: TimeInterval(index * 25),
                recognitionTaskID: index >= 4 ? "real-apple-task-restart" : "real-apple-task",
                eventSequence: index + 1
            )
            try await harness.waitForPipelineIdle()
            let expected = SystemAudioQuestionExtractor.extract(from: question).last?.text
            #expect(harness.appState.currentSuggestion?.questionText == expected)
            #expect(harness.appState.visibleQuestionText(for: harness.appState.currentSuggestion) == expected)
        }

        try await harness.waitForRows(7)
        try await harness.waitForTraceEventCount("persistenceSucceeded", atLeast: 7)
        let rows = try harness.rows()
        let trace = try harness.traceText()
        harness.printSummary(rows: rows, trace: trace)
        let normalized = rows.compactMap(\.questionText).map(SemanticDuplicateKeyBuilder.key(for:))
        let orderedAll = questions.flatMap {
            SystemAudioQuestionExtractor.extract(from: $0).map { SemanticDuplicateKeyBuilder.key(for: $0.text) }
        }

        #expect(rows.count == 7)
        #expect(Set(normalized).count == rows.count)
        #expect(normalized == orderedAll)
        #expect(rows.contains { ($0.questionText ?? "").localizedCaseInsensitiveContains("DROID") })
        #expect(rows.contains { ($0.questionText ?? "").localizedCaseInsensitiveContains("YOLOv8") })
        #expect(rows.allSatisfy { $0.questionText == $0.promptPrimaryQuestion })
        #expect(rows.allSatisfy { $0.stageBStatus != "cancelled" })
        #expect(!trace.contains("\"event_type\":\"duplicatePersistenceRejected\""))
    }

    private static func shouldRun(_ suite: String) -> Bool {
        let selected = ProcessInfo.processInfo.environment["RUNTIME_SMOKE_SUITE"] ?? "all"
        return selected == "all" || selected == suite
    }

    private func makeHarness(suite: String) throws -> RuntimeSmokeHarness {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "RuntimeSmokeHarness-\(suite)")
        let settingsRepository = SettingsRepository(database: database)
        try settingsRepository.ensureDefaultProviderConfigurations()
        if let deepSeek = try settingsRepository.providerConfigurations().first(where: { $0.kind == .deepSeek }) {
            try settingsRepository.setActiveRealtimeProvider(id: deepSeek.id)
        }
        let client = RuntimeSmokeLLMClient()
        let router = LLMRouter(settingsRepository: settingsRepository, clients: [.deepSeek: client])
        let appState = AppState(
            database: database,
            llmRouter: router,
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            contextRetrievalService: RuntimeSmokeContextRetrievalService(),
            dialogueDefaults: nil
        )
        appState.answerProviderModeOverride = .deepSeekPrimary
        let traceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-smoke-\(suite)-\(UUID().uuidString).jsonl")
        appState.runtimeTranscriptTraceLogURL = traceURL
        appState.detectionDebounceSeconds = 0.01
        appState.delayProvider = RealDelayProvider()
        appState.generationFullCardWatchdogNanoseconds = 2_000_000_000

        var settings = appState.settings
        settings.audioCaptureMode = .systemAudioOnly
        settings.automaticQuestionDetectionEnabled = true
        settings.allowQuestionDetectionFromMicrophoneOnly = false
        settings.saveTranscriptsLocally = true
        appState.saveSettings(settings)

        let session = try makeHermeticContextBoundSession(appState: appState, prefix: "runtime-smoke-\(suite)")
        appState.currentSession = session
        appState.liveState = .listening
        appState.currentCaptureRuntimeState = .listening
        return RuntimeSmokeHarness(appState: appState, session: session, client: client, traceURL: traceURL)
    }
}

private struct RuntimeSmokeDeferredFallbackDelayProvider: DelayProvider {
    func sleep(nanoseconds: UInt64) async throws {
        let effectiveDelay = nanoseconds == 1_500_000_000
            ? 30_000_000_000
            : nanoseconds
        try await Task.sleep(nanoseconds: effectiveDelay)
    }
}

@MainActor
private struct RuntimeSmokeHarness {
    let appState: AppState
    let session: InterviewSession
    let client: RuntimeSmokeLLMClient
    let traceURL: URL
    private let startedAt = Date()

    func feed(
        text: String,
        id: String,
        secondsFromStart: TimeInterval = 0,
        recognitionTaskID: String? = nil,
        eventSequence: Int? = nil
    ) async {
        let segment = TranscriptSegment(
            id: id,
            sessionID: session.id,
            source: .systemAudio,
            speaker: .interviewer,
            text: text,
            createdAt: startedAt.addingTimeInterval(secondsFromStart),
            confidence: 1.0,
            asrFinalizationReason: "final_accepted",
            recognitionTaskID: recognitionTaskID,
            recognitionEventSequence: eventSequence,
            sourceTextStartUTF16: 0,
            sourceTextEndUTF16: (text as NSString).length,
            recognitionIsFinal: true
        )
        await appState.handleTranscriptSegment(segment)
    }

    func waitBriefly() async throws {
        try await Task.sleep(nanoseconds: 150_000_000)
    }

    func waitForRows(_ expected: Int, timeout: TimeInterval = 12.0) async throws {
        let start = Date()
        while true {
            if (try? rows().count) == expected {
                return
            }
            if Date().timeIntervalSince(start) > timeout {
                let current = appState.currentSuggestion
                let diagnostic = [
                    "Timed out waiting for \(expected) persisted row(s).",
                    "currentQuestion=\(current?.questionText ?? "nil")",
                    "sayFirst=\(current?.sayFirst ?? "nil")",
                    "stageBStatus=\(current?.stageBStatus ?? "nil")",
                    "stageBCompleted=\(String(describing: current?.stageBCompleted))",
                    "finalVisibleSource=\(current?.finalVisibleSource ?? "nil")",
                    "alignmentVerdict=\(current?.alignmentVerdict?.rawValue ?? "nil")",
                    "lastAlignmentError=\(appState.lastAlignmentError)",
                    "fakeLastResponse=\(client.lastStreamResponse)"
                ].joined(separator: " | ")
                throw NSError(
                    domain: "RuntimeSmokeHarnessTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: diagnostic]
                )
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    func waitForRowsAtLeast(_ expected: Int, timeout: TimeInterval = 12.0) async throws {
        let start = Date()
        while true {
            if (try? rows().count) ?? 0 >= expected {
                return
            }
            if Date().timeIntervalSince(start) > timeout {
                throw NSError(
                    domain: "RuntimeSmokeHarnessTests",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for at least \(expected) persisted row(s)."]
                )
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    func waitForCurrentQuestion(_ expected: String, timeout: TimeInterval = 12.0) async throws {
        let start = Date()
        while true {
            if appState.currentSuggestion?.questionText == expected && appState.visibleAnswerExists {
                return
            }
            if Date().timeIntervalSince(start) > timeout {
                throw NSError(
                    domain: "RuntimeSmokeHarnessTests",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for current card: \(expected)"]
                )
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    func waitForTraceEvent(_ eventType: String, timeout: TimeInterval = 12.0) async throws {
        let expected = "\"event_type\":\"\(eventType)\""
        let start = Date()
        while true {
            if (try? traceText().contains(expected)) == true {
                return
            }
            if Date().timeIntervalSince(start) > timeout {
                throw NSError(
                    domain: "RuntimeSmokeHarnessTests",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for trace event \(eventType)."]
                )
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    func waitForTraceEventCount(
        _ eventType: String,
        atLeast expectedCount: Int,
        timeout: TimeInterval = 12.0
    ) async throws {
        let needle = "\"event_type\":\"\(eventType)\""
        let start = Date()
        while true {
            let count = ((try? traceText()) ?? "").components(separatedBy: needle).count - 1
            if count >= expectedCount {
                return
            }
            if Date().timeIntervalSince(start) > timeout {
                throw NSError(
                    domain: "RuntimeSmokeHarnessTests",
                    code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for \(expectedCount) \(eventType) events."]
                )
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    func waitForPipelineIdle(timeout: TimeInterval = 12.0) async throws {
        let start = Date()
        while true {
            let idle = appState.pendingAcceptedQuestions.isEmpty &&
                !appState.autoSuggestionLaunchPending &&
                !appState.suggestionGenerationStarted &&
                !appState.isStreamingSayFirst &&
                !appState.providerStreamActive &&
                !appState.stageBTaskActive &&
                !appState.fallbackWatchdogActive
            if idle {
                return
            }
            if Date().timeIntervalSince(start) > timeout {
                throw NSError(
                    domain: "RuntimeSmokeHarnessTests",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for long-interview pipeline idle state."]
                )
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    func waitForBlockedStreams(
        containing needle: String,
        startedAtLeast expectedStarted: Int = 0,
        finishedAtLeast expectedFinished: Int = 0,
        timeout: TimeInterval = 12.0
    ) async throws {
        let start = Date()
        while true {
            let started = client.blockedStreamStartedCount(containing: needle)
            let finished = client.blockedStreamFinishedCount(containing: needle)
            if started >= expectedStarted && finished >= expectedFinished {
                return
            }
            if Date().timeIntervalSince(start) > timeout {
                throw NSError(
                    domain: "RuntimeSmokeHarnessTests",
                    code: 7,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Timed out waiting for blocked streams containing \(needle): started=\(started)/\(expectedStarted), finished=\(finished)/\(expectedFinished)."
                    ]
                )
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    func rows() throws -> [SuggestionCard] {
        try appState.suggestionRepository.suggestions(sessionID: session.id)
    }

    func traceText() throws -> String {
        guard FileManager.default.fileExists(atPath: traceURL.path) else { return "" }
        return try String(contentsOf: traceURL, encoding: .utf8)
    }

    func printSummary(rows: [SuggestionCard], trace: String) {
        let events = trace.split(separator: "\n")
        let accepted = events.filter { $0.contains("\"event_type\":\"questionAccepted\"") }.count
        let rejected = events.filter { $0.contains("\"event_type\":\"questionRejected\"") }.count
        let generations = events.filter { $0.contains("\"event_type\":\"generationStarted\"") }.count
        print("""

        Runtime smoke summary
        transcript_events=\(events.count)
        accepted_questions=\(accepted)
        rejected_questions=\(rejected)
        generations_started=\(generations)
        db_rows=\(rows.count)
        trace_path=\(traceURL.path)
        DB rows:
        created_at | question_intent | question_text | prompt_primary_question | alignment_verdict | stage_b_status | final_visible_source
        """)
        let formatter = ISO8601DateFormatter()
        for row in rows {
            print([
                formatter.string(from: row.createdAt),
                row.questionIntent?.rawValue ?? "",
                row.questionText ?? "",
                row.promptPrimaryQuestion ?? "",
                row.alignmentVerdict?.rawValue ?? "",
                row.stageBStatus ?? "",
                row.finalVisibleSource ?? ""
            ].joined(separator: " | "))
        }
    }
}

private struct RuntimeSmokeContextRetrievalService: ContextRetrievalService {
    func retrieveContextWithTrace(
        question: String,
        intent: QuestionIntent,
        maxCVWords: Int,
        maxJDWords: Int,
        strategy: AnswerStrategy?
    ) async throws -> (context: RetrievedContext, trace: RetrievalTrace) {
        let context = RetrievedContext(cvChunks: [], jobDescriptionChunks: [])
        let trace = RetrievalTrace(
            id: UUID(),
            query: question,
            intent: intent.rawValue,
            createdAt: Date(),
            rankedCVChunks: [],
            rankedJDChunks: [],
            includedCVChunks: [],
            includedJDChunks: [],
            excludedCVChunks: [],
            excludedJDChunks: [],
            cvWordsUsed: 0,
            jdWordsUsed: 0,
            cvWordBudget: maxCVWords,
            jdWordBudget: maxJDWords,
            retrievalLatencyMS: 1,
            emptyQueryFallbackUsed: false,
            zeroScoreFallbackUsed: false
        )
        return (context, trace)
    }
}

private final class RuntimeSmokeLLMClient: LLMClientProtocol, @unchecked Sendable {
    let providerKind: LLMProviderKind = .deepSeek
    private let lock = NSLock()
    private var streamCalls = 0
    private var latestStreamResponse = ""
    private var streamBlocks = [RuntimeSmokeStreamBlock]()
    var stageAStreamDelayByNeedle = [String: UInt64]()
    var incompleteStageAForNeedle: String?

    var lastStreamResponse: String {
        lock.withLock { latestStreamResponse }
    }

    func blockStreams(containing needle: String) {
        lock.withLock {
            streamBlocks.append(RuntimeSmokeStreamBlock(needle: needle))
        }
    }

    func releaseBlockedStreams(containing needle: String) {
        matchingBlock(forNeedle: needle)?.release()
    }

    func blockedStreamStartedCount(containing needle: String) -> Int {
        matchingBlock(forNeedle: needle)?.startedCount ?? 0
    }

    func blockedStreamFinishedCount(containing needle: String) -> Int {
        matchingBlock(forNeedle: needle)?.finishedCount ?? 0
    }

    func testConnection(configuration: LLMProviderConfiguration) async throws -> LLMConnectionTestResult {
        LLMConnectionTestResult(success: true, message: "OK", latencyMS: 0, models: [])
    }

    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] {
        []
    }

    func chatCompletion(
        configuration: LLMProviderConfiguration,
        messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions
    ) async throws -> LLMChatResult {
        let prompt = messages.map(\.content).joined(separator: "\n")
        return LLMChatResult(
            content: Self.jsonCard(for: prompt),
            modelName: "runtime-smoke",
            providerKind: .deepSeek,
            providerName: "DeepSeek",
            baseURL: "",
            latencyMS: 5,
            isLocal: false,
            rawResponse: Self.jsonCard(for: prompt)
        )
    }

    func chatCompletionStream(
        configuration: LLMProviderConfiguration,
        messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions
    ) -> AsyncThrowingStream<String, Error> {
        lock.withLock { streamCalls += 1 }
        let prompt = messages.map(\.content).joined(separator: "\n")
        let currentQuestion = hermeticRuntimeQuestion(from: prompt)
        let isStageA = prompt.contains("Generate the single opening answer now:")
        let text: String
        if let incompleteStageAForNeedle,
           currentQuestion.localizedCaseInsensitiveContains(incompleteStageAForNeedle) {
            if isStageA {
                text = "I would ask the engineering team how they"
            } else {
                text = """
                SAY_FIRST: I would ask the engineering team how they
                KEY_POINTS:
                - Incomplete provider output
                FOLLOW_UP:
                - 
                """
            }
        } else if prompt.contains("Return plain text sections only") || prompt.contains("Stream the section response now.") {
            text = Self.sectionCard(for: prompt)
        } else {
            text = Self.sayFirst(for: prompt)
        }
        lock.withLock { latestStreamResponse = text }
        let delay = stageAStreamDelayByNeedle.first {
            currentQuestion.localizedCaseInsensitiveContains($0.key)
        }?.value ?? 0
        let shouldYieldSynchronously = incompleteStageAForNeedle != nil &&
            currentQuestion.localizedCaseInsensitiveContains(incompleteStageAForNeedle ?? "")
        let streamBlock = matchingBlock(forQuestion: currentQuestion)
        return AsyncThrowingStream { continuation in
            if shouldYieldSynchronously {
                continuation.yield(text)
                continuation.finish()
                return
            }
            Task {
                if let streamBlock {
                    streamBlock.markStarted()
                    await streamBlock.wait()
                }
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay)
                }
                continuation.yield(text)
                continuation.finish()
                streamBlock?.markFinished()
            }
        }
    }

    private func matchingBlock(forQuestion question: String) -> RuntimeSmokeStreamBlock? {
        lock.withLock {
            streamBlocks.first { question.localizedCaseInsensitiveContains($0.needle) }
        }
    }

    private func matchingBlock(forNeedle needle: String) -> RuntimeSmokeStreamBlock? {
        lock.withLock {
            streamBlocks.first { $0.needle.caseInsensitiveCompare(needle) == .orderedSame }
        }
    }

    private static func sectionCard(for prompt: String) -> String {
        hermeticRuntimeSectionTokens(for: prompt).joined()
    }

    private static func jsonCard(for prompt: String) -> String {
        """
        {"strategy":"Runtime smoke","say_first":\(jsonString(sayFirst(for: prompt))),"key_points":["Concrete current-question answer.","No merged context."],"follow_up_ready":["I can expand if helpful."],"confidence":0.9,"caution":"None","evidence_used":[],"risk_level":"low"}
        """
    }

    private static func sayFirst(for prompt: String) -> String {
        hermeticRuntimeAnswer(for: prompt)
    }

    private static func jsonString(_ value: String) -> String {
        let data = try? JSONEncoder().encode(value)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }
}

private final class RuntimeSmokeStreamBlock: @unchecked Sendable {
    let needle: String
    private let lock = NSLock()
    private let gate = RuntimeSmokeBroadcastGate()
    private var started = 0
    private var finished = 0

    init(needle: String) {
        self.needle = needle
    }

    var startedCount: Int { lock.withLock { started } }
    var finishedCount: Int { lock.withLock { finished } }

    func markStarted() {
        lock.withLock { started += 1 }
    }

    func wait() async {
        await gate.wait()
    }

    func release() {
        gate.release()
    }

    func markFinished() {
        lock.withLock { finished += 1 }
    }
}

private final class RuntimeSmokeBroadcastGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters = [CheckedContinuation<Void, Never>]()

    func wait() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                if isOpen {
                    return true
                }
                waiters.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func release() {
        let continuations = lock.withLock {
            guard isOpen == false else { return [CheckedContinuation<Void, Never>]() }
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        continuations.forEach { $0.resume() }
    }
}
