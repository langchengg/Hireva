import Foundation
import Testing
@testable import InterviewCopilotMac

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
    func rapidTwoQuestionSuitePersistsTwoSeparateRows() async throws {
        guard Self.shouldRun("rapid-two") else { return }
        let harness = try makeHarness(suite: "rapid-two")
        harness.client.stageAStreamDelayByNeedle["engineering team"] = 250_000_000

        await harness.feed(text: "What would you ask the engineering team to understand whether this role is a good fit?", id: "rapid-two-q1", secondsFromStart: 0)
        await harness.feed(text: "If you had one more month to improve your LeoRover system, what would you improve first?", id: "rapid-two-q2", secondsFromStart: 3)

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
        #expect(trace.contains("\"event_type\":\"answer.request.started\""))
        #expect(trace.components(separatedBy: "\"event_type\":\"persistenceSucceeded\"").count - 1 >= 2)
    }

    @Test
    func rapidThreeQuestionSuitePersistsHistoryAndLatestCurrentCard() async throws {
        guard Self.shouldRun("rapid-three") else { return }
        let harness = try makeHarness(suite: "rapid-three")
        harness.client.stageAStreamDelayByNeedle["engineering team"] = 250_000_000

        await harness.feed(text: "What would you ask the engineering team to understand whether this role is a good fit?", id: "rapid-three-q1", secondsFromStart: 0)
        await harness.feed(text: "If you had one more month to improve your LeoRover system, what would you improve first?", id: "rapid-three-q2", secondsFromStart: 3)
        await harness.feed(text: "Can you explain the difference between your VLA project and your LeoRover project?", id: "rapid-three-q3", secondsFromStart: 6)

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
        #expect(rows.allSatisfy { $0.questionText == $0.promptPrimaryQuestion })
        #expect(trace.components(separatedBy: "\"event_type\":\"persistenceSucceeded\"").count - 1 >= 3)
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
        #expect(row.questionText == "If your YOLOv8 detector gives a confident but wrong prediction on the LeoRover, how would you debug it?")
        #expect(row.questionIntent == .perceptionDebugging)
        #expect(row.sayFirst.localizedCaseInsensitiveContains("YOLOv8"))
        #expect(row.sayFirst.localizedCaseInsensitiveContains("confidence"))
        #expect(!(row.questionText ?? "").localizedCaseInsensitiveContains("would you debug it") || (row.questionText ?? "").hasPrefix("If your YOLOv8"))
    }

    @Test
    func noisyCanonicalizationSuiteNormalizesCommonASRVariants() async throws {
        guard Self.shouldRun("noisy-canonicalization") else { return }
        let harness = try makeHarness(suite: "noisy-canonicalization")

        await harness.feed(text: "How would you diagnose a sim real gap if your policy works in Muji but fails on hardware?", id: "noisy-sim-real")
        await harness.feed(text: "What did you learn from comparing auto aggressive diffusion and flow matching decoders in your villa project?", id: "noisy-vla")

        try await harness.waitForRows(2)
        let rows = try harness.rows()
        let trace = try harness.traceText()
        harness.printSummary(rows: rows, trace: trace)

        #expect(rows.contains { ($0.questionText ?? "").contains("sim-to-real") && ($0.questionText ?? "").contains("MuJoCo") })
        #expect(rows.contains { ($0.questionText ?? "").contains("autoregressive") && ($0.questionText ?? "").contains("flow-matching") && ($0.questionText ?? "").contains("VLA project") })
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
            if index > 0 {
                try await harness.waitForRowsAtLeast(index)
            }
            #expect(harness.appState.currentSuggestion?.questionText == expectedQuestion)
            #expect(harness.appState.visibleQuestionText(for: harness.appState.currentSuggestion) == expectedQuestion)
        }

        try await harness.waitForPipelineIdle()
        try await harness.waitForTraceEventCount("persistenceSucceeded", atLeast: 6)
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
        let orderedWithoutGreeting = Array(orderedAll.dropFirst())

        #expect(rows.count == 6 || rows.count == 7)
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
        if normalizedQuestions == orderedWithoutGreeting {
            #expect(trace.contains("\"event_type\":\"persistenceRejected\""))
            #expect(trace.contains(questions[0]))
        } else {
            #expect(normalizedQuestions == orderedAll)
        }
        #expect(!trace.contains("\"event_type\":\"duplicatePersistenceRejected\""))
    }

    @Test
    func appleSpeechCumulativeReplaySuiteRejectsOldCallbacksAndKeepsNewestCard() async throws {
        guard Self.shouldRun("apple-speech-cross-task-replay") else { return }
        let harness = try makeHarness(suite: "apple-speech-cross-task-replay")
        harness.client.stageAStreamDelayByNeedle["LeoRover project from end to end"] = 5_000_000_000
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
        try await harness.waitForRows(2)
        try await harness.waitForPipelineIdle()
        let rows = try harness.rows()
        let trace = try harness.traceText()
        harness.printSummary(rows: rows, trace: trace)
        let normalized = rows.compactMap(\.questionText).map(SemanticDuplicateKeyBuilder.key(for:))

        #expect(Set(normalized).count == rows.count)
        #expect(rows.filter { SemanticDuplicateKeyBuilder.areDuplicates($0.questionText ?? "", q1) }.isEmpty)
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

        try await harness.waitForRowsAtLeast(6)
        try await harness.waitForTraceEventCount("persistenceSucceeded", atLeast: 6)
        let rows = try harness.rows()
        let trace = try harness.traceText()
        harness.printSummary(rows: rows, trace: trace)
        let normalized = rows.compactMap(\.questionText).map(SemanticDuplicateKeyBuilder.key(for:))
        let expectedNormalized = Set(questions.flatMap {
            SystemAudioQuestionExtractor.extract(from: $0).map { SemanticDuplicateKeyBuilder.key(for: $0.text) }
        })
        let orderedAll = questions.flatMap {
            SystemAudioQuestionExtractor.extract(from: $0).map { SemanticDuplicateKeyBuilder.key(for: $0.text) }
        }
        let orderedWithoutGreeting = Array(orderedAll.dropFirst())

        #expect(rows.count >= 6)
        #expect(rows.count <= 7)
        #expect(Set(normalized).count == rows.count)
        #expect(Set(normalized).isSubset(of: expectedNormalized))
        if normalized == orderedWithoutGreeting {
            #expect(trace.contains("\"event_type\":\"persistenceRejected\""))
            #expect(trace.contains(questions[0]))
        } else {
            #expect(normalized == orderedAll)
        }
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
            contextRetrievalService: RuntimeSmokeContextRetrievalService()
        )
        let traceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-smoke-\(suite)-\(UUID().uuidString).jsonl")
        appState.runtimeTranscriptTraceLogURL = traceURL
        appState.detectionDebounceSeconds = 0.01
        let delayProvider = MockDelayProvider()
        delayProvider.sleepDuration = 5_000_000
        appState.delayProvider = delayProvider
        appState.generationFullCardWatchdogNanoseconds = 400_000_000

        var settings = appState.settings
        settings.audioCaptureMode = .systemAudioOnly
        settings.automaticQuestionDetectionEnabled = true
        settings.allowQuestionDetectionFromMicrophoneOnly = false
        settings.saveTranscriptsLocally = true
        appState.saveSettings(settings)

        let session = try appState.sessionRepository.createSession(mode: .microphone)
        appState.currentSession = session
        appState.liveState = .listening
        appState.currentCaptureRuntimeState = .listening
        return RuntimeSmokeHarness(appState: appState, session: session, client: client, traceURL: traceURL)
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

    func waitForRows(_ expected: Int, timeout: TimeInterval = 60.0) async throws {
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
                    "lastAlignmentError=\(appState.lastAlignmentError)"
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

    func waitForRowsAtLeast(_ expected: Int, timeout: TimeInterval = 60.0) async throws {
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

    func waitForCurrentQuestion(_ expected: String, timeout: TimeInterval = 60.0) async throws {
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

    func waitForTraceEvent(_ eventType: String, timeout: TimeInterval = 60.0) async throws {
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
        timeout: TimeInterval = 60.0
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

    func waitForPipelineIdle(timeout: TimeInterval = 60.0) async throws {
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
    var stageAStreamDelayByNeedle = [String: UInt64]()
    var incompleteStageAForNeedle: String?

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
        let isStageA = prompt.contains("Generate the single opening answer now:")
        let text: String
        if let incompleteStageAForNeedle,
           prompt.localizedCaseInsensitiveContains(incompleteStageAForNeedle) {
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
        let delay = stageAStreamDelayByNeedle.first { prompt.localizedCaseInsensitiveContains($0.key) }?.value ?? 0
        let shouldYieldSynchronously = incompleteStageAForNeedle != nil && prompt.localizedCaseInsensitiveContains(incompleteStageAForNeedle ?? "")
        return AsyncThrowingStream { continuation in
            if shouldYieldSynchronously {
                continuation.yield(text)
                continuation.finish()
                return
            }
            Task {
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay)
                }
                continuation.yield(text)
                continuation.finish()
            }
        }
    }

    private static func sectionCard(for prompt: String) -> String {
        """
        SAY_FIRST: \(sayFirst(for: prompt))
        KEY_POINTS:
        - Keep the question bound to the current interviewer prompt.
        - Give a concrete first-person answer.
        - Mention project-specific evidence when relevant.
        FOLLOW_UP:
        - I can expand with a short example if helpful.
        """
    }

    private static func jsonCard(for prompt: String) -> String {
        """
        {"strategy":"Runtime smoke","say_first":\(jsonString(sayFirst(for: prompt))),"key_points":["Concrete current-question answer.","No merged context."],"follow_up_ready":["I can expand if helpful."],"confidence":0.9,"caution":"None","evidence_used":[],"risk_level":"low"}
        """
    }

    private static func sayFirst(for prompt: String) -> String {
        if prompt.localizedCaseInsensitiveContains("YOLOv8") || prompt.localizedCaseInsensitiveContains("confident but wrong") {
            return "I would debug the confident but wrong YOLOv8 prediction on LeoRover by checking the original frame, bounding box, class label, confidence score, calibration, lighting, occlusion, and temporal consistency before deciding whether retraining is needed."
        }
        if prompt.localizedCaseInsensitiveContains("what would you ask the engineering team") ||
            prompt.localizedCaseInsensitiveContains("what questions would you ask us") ||
            prompt.localizedCaseInsensitiveContains("good fit") {
            return "I'd ask what success looks like for real-world deployment given the team's ownership structure."
        }
        if prompt.localizedCaseInsensitiveContains("one more month") ||
            prompt.localizedCaseInsensitiveContains("improve your LeoRover") {
            return "If I had one more month to improve LeoRover, I would strengthen evaluation, perception robustness, and spatial c"
        }
        if prompt.localizedCaseInsensitiveContains("difference between your VLA project") ||
            (prompt.localizedCaseInsensitiveContains("VLA project") && prompt.localizedCaseInsensitiveContains("LeoRover project")) {
            return "The VLA project focused on simulation, while LeoRover was a real robot integration project."
        }
        if prompt.localizedCaseInsensitiveContains("sim-to-real") ||
            prompt.localizedCaseInsensitiveContains("MuJoCo") && prompt.localizedCaseInsensitiveContains("hardware") {
            return "I would diagnose the sim-to-real gap by comparing MuJoCo and hardware observations, action scaling, timing, calibration, contact dynamics, and failure videos before changing the policy."
        }
        return "In my MuJoCo VLA evaluation, diffusion was stronger because it denoised a continuous action trajectory, while autoregressive prediction accumulated step-by-step errors and produced less robust manipulation behavior."
    }

    private static func jsonString(_ value: String) -> String {
        let data = try? JSONEncoder().encode(value)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }
}
