import Foundation
import Testing
@testable import Hireva

@Suite(.serialized)
@MainActor
struct LongInterviewQuestionDetectionTests {
    @Test
    func longInterviewDetectsOnlyAnswerWorthyInterviewerQuestions() async throws {
        let (appState, session, _) = try makeAppState()
        let dialogue: [(AudioSourceType, SpeakerRole, String, String?)] = [
            (.systemAudio, .interviewer, "Hi Lang, thanks for joining today. We’ll start with a few questions about your background.", nil),
            (.systemAudio, .interviewer, "First, could you tell me a little bit about yourself and what brought you into robotics?", "Could you tell me a little bit about yourself and what brought you into robotics?"),
            (.microphone, .candidate, "Sure, I’m currently studying MSc Robotics at the University of Manchester.", nil),
            (.systemAudio, .interviewer, "Great, thanks. I saw your LeoRover project on your CV.", nil),
            (.systemAudio, .interviewer, "Could you walk me through that project, especially your role in the perception and navigation pipeline?", "Could you walk me through that project, especially your role in the perception and navigation pipeline?"),
            (.microphone, .candidate, "Yes, the project was about an autonomous object retrieval robot.", nil),
            (.systemAudio, .interviewer, "Okay, interesting. And what was the hardest technical challenge you faced?", "What was the hardest technical challenge you faced?"),
            (.microphone, .candidate, "The hardest part was integrating perception with navigation.", nil),
            (.systemAudio, .interviewer, "Right. You mentioned ROS2 and YOLOv8. How did you handle noisy detections or localization errors?", "How did you handle noisy detections or localization errors?"),
            (.microphone, .candidate, "We used filtering and recovery behavior.", nil),
            (.systemAudio, .interviewer, "Makes sense. Let’s move to your VLA project.", nil),
            (.systemAudio, .interviewer, "Why did the diffusion decoder perform better than the autoregressive and flow-matching decoders in your MuJoCo evaluation?", "Why did the diffusion decoder perform better than the autoregressive and flow-matching decoders in your MuJoCo evaluation?"),
            (.microphone, .candidate, "The diffusion policy was more robust.", nil),
            (.systemAudio, .interviewer, "Okay. Suppose you had another month to improve the system, what would you change first?", "Suppose you had another month to improve the system, what would you change first?"),
            (.microphone, .candidate, "I would improve the evaluation and add more robust perception.", nil),
            (.systemAudio, .interviewer, "Thanks. Now thinking about this role, why do you want to join our team?", "Why do you want to join our team?"),
            (.microphone, .candidate, "I’m interested because.", nil),
            (.systemAudio, .interviewer, "Great. That covers my questions. Do you have any questions for us?", "Do you have any questions for us?")
        ]

        var detected: [DetectedQuestion] = []
        var detectedIDs = Set<String>()
        var generationQuestionIDs = [String]()

        for (index, item) in dialogue.enumerated() {
            let segment = segment(
                id: "long-\(index)",
                sessionID: session.id,
                source: item.0,
                speaker: item.1,
                text: item.2
            )
            let previousDetectedCount = appState.detectedQuestionsInSessionCount
            await appState.handleTranscriptSegment(segment)

            if let expectedQuestion = item.3 {
                try await waitUntil(timeout: 8.0) {
                    appState.lastDetectedQuestion?.transcriptSegmentID == segment.id &&
                    appState.detectedQuestionsInSessionCount == previousDetectedCount + 1 &&
                    appState.activeQuestionID == appState.lastDetectedQuestion?.id
                }
                let question = try #require(appState.lastDetectedQuestion)
                detected.append(question)
                detectedIDs.insert(question.id)
                generationQuestionIDs.append(try #require(appState.activeQuestionID))

                #expect(question.questionText == expectedQuestion)
                #expect(question.shouldTrigger)
                #expect(question.questionComplete)
                #expect(question.confidence >= 0.75)
                #expect(appState.activeTriggerPath == .autoDetect)
                #expect(appState.lastDetectedQuestionSource == AudioSourceType.systemAudio.rawValue)
                #expect(appState.lastDetectedQuestionSpeaker == SpeakerRole.interviewer.rawValue)
                #expect(appState.currentGenerationTelemetry.source == AudioSourceType.systemAudio.rawValue)
                #expect(appState.currentGenerationTelemetry.speaker == SpeakerRole.interviewer.rawValue)
                #expect(appState.lastQuestionConfidence >= 0.75)
            } else if item.0 == .systemAudio {
                try await waitUntil(timeout: 8.0) {
                    appState.lastDetectionSubmittedSegmentText == segment.text
                }
                #expect(appState.detectedQuestionsInSessionCount == previousDetectedCount)
            } else {
                try await Task.sleep(nanoseconds: 80_000_000)
                #expect(appState.detectedQuestionsInSessionCount == previousDetectedCount)
            }
        }

        #expect(detected.map(\.questionText) == dialogue.compactMap(\.3))
        #expect(detected.count == 8)
        #expect(detectedIDs.count == 8)
        #expect(generationQuestionIDs.count == 8)
        #expect(Set(generationQuestionIDs).count == 8)
        #expect(appState.ignoredSmallTalkCount >= 3)
    }

    @Test
    func asrPartialFinalUpdatesTriggerOnlyOnce() async throws {
        let (appState, session, _) = try makeAppState()
        let segmentID = "partial-final-question"
        let partials = [
            "Could you walk me",
            "Could you walk me through your robotics",
            "Could you walk me through your robotics project"
        ]

        for partial in partials {
            await appState.handleTranscriptSegment(segment(id: segmentID, sessionID: session.id, source: .systemAudio, speaker: .interviewer, text: partial))
            try await Task.sleep(nanoseconds: 10_000_000)
            #expect(appState.detectedQuestionsInSessionCount == 0)
            #expect(appState.currentSpinnerVisible == false)
        }

        await appState.handleTranscriptSegment(segment(
            id: segmentID,
            sessionID: session.id,
            source: .systemAudio,
            speaker: .interviewer,
            text: "Could you walk me through your robotics project, especially your role in the perception and navigation pipeline?"
        ))

        try await waitUntil(timeout: 8.0) {
            appState.detectedQuestionsInSessionCount == 1 &&
            appState.lastDetectedQuestion?.transcriptSegmentID == segmentID
        }
        try await waitUntil(timeout: 8.0) {
            appState.visibleAnswerExists && !appState.currentSpinnerVisible
        }

        let question = try #require(appState.lastDetectedQuestion)
        #expect(question.questionText == "Could you walk me through your robotics project, especially your role in the perception and navigation pipeline?")
        #expect(appState.activeQuestionID == question.id)
        #expect(!appState.currentSpinnerVisible)
        #expect(appState.duplicateSuppressionCount == 0)
    }

    @Test
    func rotatedCumulativeCallbacksDoNotRestartConsumedQuestions() async throws {
        let (appState, session, _) = try makeAppState()
        let traceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rotated-cumulative-\(UUID().uuidString).jsonl")
        appState.runtimeTranscriptTraceLogURL = traceURL
        let leo = "Could you explain your LeoRover project from end to end?"
        let droid = "How did you convert real robot demonstrations from DROID into actions that your MuJoCo Franka simulation could use?"

        await appState.handleTranscriptSegment(segment(
            id: "apple-callback-1",
            sessionID: session.id,
            source: .systemAudio,
            speaker: .interviewer,
            text: leo,
            recognitionTaskID: "rotated-apple-task",
            recognitionEventSequence: 1
        ))
        try await waitUntil(timeout: 8.0) {
            appState.currentSuggestion?.questionText == SystemAudioQuestionExtractor.extract(from: leo).last?.text
        }

        appState.recentQuestionTimestamps = appState.recentQuestionTimestamps
            .mapValues { _ in Date().addingTimeInterval(-120) }
        await appState.handleTranscriptSegment(segment(
            id: "apple-callback-2",
            sessionID: session.id,
            source: .systemAudio,
            speaker: .interviewer,
            text: "\(leo) \(droid)",
            recognitionTaskID: "rotated-apple-task-restart",
            recognitionEventSequence: 1
        ))
        let expectedDROID = try #require(SystemAudioQuestionExtractor.extract(from: droid).last?.text)
        try await waitUntil(timeout: 8.0) {
            appState.currentSuggestion?.questionText == expectedDROID &&
                appState.pendingAcceptedQuestions.isEmpty
        }
        #expect(appState.detectedQuestionsInSessionCount == 2)
        #expect(appState.currentSuggestion?.questionText == expectedDROID)
        #expect(appState.activeQuestionID == appState.currentSuggestion?.detectedQuestionID)

        appState.transcriptReconciler.reset()
        appState.recentQuestionTimestamps = appState.recentQuestionTimestamps
            .mapValues { _ in Date().addingTimeInterval(-120) }
        await appState.handleTranscriptSegment(segment(
            id: "apple-callback-3",
            sessionID: session.id,
            source: .systemAudio,
            speaker: .interviewer,
            text: "\(leo) \(droid)",
            recognitionTaskID: "rotated-apple-task-second-replay",
            recognitionEventSequence: 1
        ))
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(appState.detectedQuestionsInSessionCount == 2)
        #expect(appState.currentSuggestion?.questionText == expectedDROID)
        let trace = try String(contentsOf: traceURL, encoding: .utf8)
        #expect(trace.contains("\"event_type\":\"cumulativeReplayRejected\""))
        #expect(trace.contains("\"old_recognition_task_id\":\"rotated-apple-task"))
        #expect(trace.contains("\"new_recognition_task_id\":\"rotated-apple-task-second-replay\""))
    }

    @Test
    func distinctNewUtteranceCanIntentionallyRepeatAQuestion() async throws {
        let (appState, session, _) = try makeAppState()
        let question = "What was the hardest technical challenge in making the real robot work reliably?"

        await appState.handleTranscriptSegment(segment(
            id: "explicit-repeat-utterance-1",
            sessionID: session.id,
            source: .systemAudio,
            speaker: .interviewer,
            text: question
        ))
        try await waitUntil(timeout: 8.0) { appState.detectedQuestionsInSessionCount == 1 }
        appState.recentQuestionTimestamps = appState.recentQuestionTimestamps
            .mapValues { _ in Date().addingTimeInterval(-120) }

        await appState.handleTranscriptSegment(segment(
            id: "explicit-repeat-utterance-2",
            sessionID: session.id,
            source: .systemAudio,
            speaker: .interviewer,
            text: question
        ))
        try await waitUntil(timeout: 8.0) { appState.detectedQuestionsInSessionCount == 2 }

        #expect(appState.lastDetectedQuestion?.questionText == question)
        let repeatedID = try #require(appState.lastDetectedQuestion?.id)
        #expect(appState.intentionalRepeatQuestionIDs.contains(repeatedID))
    }

    @Test
    func longInterviewerMonologueDetectsOnlyFinalQuestion() async throws {
        let (appState, session, _) = try makeAppState()
        let text = "Before I ask the next question, let me explain a little bit about what this role involves. We work with deployed robotics systems, perception, edge AI, and reliability in real environments. The team is small, so we care about people who can debug across software and hardware. With that context, can you explain how your previous robotics experience prepares you for this role?"
        await appState.handleTranscriptSegment(segment(id: "monologue", sessionID: session.id, source: .systemAudio, speaker: .interviewer, text: text))

        try await waitUntil(timeout: 8.0) {
            appState.lastDetectedQuestion?.transcriptSegmentID == "monologue"
        }

        #expect(appState.detectedQuestionsInSessionCount == 1)
        #expect(appState.lastDetectedQuestion?.questionText == "Can you explain how your previous robotics experience prepares you for this role?")
    }

    @Test
    func consecutiveFollowUpQuestionsSupersedeSafely() async throws {
        let (appState, session, _) = try makeAppState()
        let questions = [
            "What was the hardest technical challenge in your LeoRover project?",
            "How did you solve the noisy perception and navigation timing issue in your LeoRover project?",
            "If the same issue happened again in the LeoRover timing and localisation pipeline, what would you do differently?"
        ]

        var activeQuestionIDs: [String] = []
        for (index, text) in questions.enumerated() {
            let id = "follow-up-\(index)"
            await appState.handleTranscriptSegment(segment(id: id, sessionID: session.id, source: .systemAudio, speaker: .interviewer, text: text))
            try await waitUntil(timeout: 8.0) {
                appState.lastDetectedQuestion?.transcriptSegmentID == id &&
                appState.detectedQuestionsInSessionCount == index + 1 &&
                appState.activeQuestionID == appState.lastDetectedQuestion?.id
            }
            activeQuestionIDs.append(try #require(appState.activeQuestionID))
        }

        #expect(appState.detectedQuestionsInSessionCount == 3)
        #expect(Set(activeQuestionIDs).count == 3)
        #expect(appState.lastDetectedQuestion?.questionText == "If the same issue happened again in the LeoRover timing and localisation pipeline, what would you do differently?")
        #expect(appState.currentGenerationTelemetry.questionID == activeQuestionIDs.last)
        try await waitUntil(timeout: 8.0) {
            appState.visibleAnswerExists && !appState.currentSpinnerVisible
        }
        #expect(appState.cancelledGenerationCount == questions.count - 1)
        #expect(!appState.currentSpinnerVisible)
    }

    @Test
    func candidateQuestionLikeSpeechNeverAutoTriggers() async throws {
        let (appState, session, _) = try makeAppState()
        await appState.handleTranscriptSegment(segment(
            id: "candidate-rhetorical-question",
            sessionID: session.id,
            source: .microphone,
            speaker: .candidate,
            text: "I would answer that by explaining my ROS2 pipeline. Maybe the question is, how did I handle localization errors? I handled them by using recovery behavior."
        ))

        try await Task.sleep(nanoseconds: 120_000_000)
        #expect(appState.detectedQuestionsInSessionCount == 0)
        #expect(appState.lastDetectedQuestion == nil)
        #expect(appState.activeQuestionID == nil)
        #expect(appState.ignoredCandidateQuestionCount == 1)
    }

    private func makeAppState() throws -> (AppState, InterviewSession, LongInterviewLLMClient) {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "LongInterviewQuestionDetectionTests")
        let settingsRepository = SettingsRepository(database: database)
        try settingsRepository.ensureDefaultProviderConfigurations()
        if let deepSeek = try settingsRepository.providerConfigurations().first(where: { $0.kind == .deepSeek }) {
            try settingsRepository.setActiveRealtimeProvider(id: deepSeek.id)
        }
        let client = LongInterviewLLMClient()
        let router = LLMRouter(settingsRepository: settingsRepository, clients: [.deepSeek: client])
        let appState = AppState(
            database: database,
            llmRouter: router,
            contextRetrievalService: LongInterviewEmptyContextRetrievalService()
        )
        appState.detectionDebounceSeconds = 0.02
        appState.delayProvider = MockDelayProvider()
        appState.generationFullCardWatchdogNanoseconds = 1_000_000_000

        var settings = appState.settings
        settings.audioCaptureMode = .microphoneOnly
        settings.automaticQuestionDetectionEnabled = true
        settings.allowQuestionDetectionFromMicrophoneOnly = false
        appState.saveSettings(settings)

        let session = try appState.sessionRepository.createSession(mode: .microphone)
        appState.currentSession = session
        appState.liveState = .listening
        appState.currentCaptureRuntimeState = .listening
        return (appState, session, client)
    }

    private func segment(
        id: String,
        sessionID: String,
        source: AudioSourceType,
        speaker: SpeakerRole,
        text: String,
        recognitionTaskID: String? = nil,
        recognitionEventSequence: Int? = nil
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            sessionID: sessionID,
            source: source,
            speaker: speaker,
            text: text,
            createdAt: Date(),
            recognitionTaskID: recognitionTaskID,
            recognitionEventSequence: recognitionEventSequence,
            sourceTextStartUTF16: recognitionTaskID == nil ? nil : 0,
            sourceTextEndUTF16: recognitionTaskID == nil ? nil : (text as NSString).length,
            recognitionIsFinal: recognitionTaskID == nil ? nil : true
        )
    }

    private func waitUntil(timeout: TimeInterval, predicate: @escaping @MainActor () -> Bool) async throws {
        let start = Date()
        let effectiveTimeout = max(timeout, 90.0)
        while !predicate() {
            if Date().timeIntervalSince(start) > effectiveTimeout {
                throw NSError(
                    domain: "LongInterviewQuestionDetectionTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for long interview question detection state."]
                )
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }
}

private final class LongInterviewLLMClient: LLMClientProtocol, @unchecked Sendable {
    let providerKind: LLMProviderKind = .deepSeek

    private let answerWorthyQuestions: [(needle: String, question: String, intent: String, strategy: String)] = [
        ("could you tell me a little bit about yourself", "Could you tell me a little bit about yourself and what brought you into robotics?", "behavioral", "star_story"),
        ("could you walk me through that project", "Could you walk me through that project, especially your role in the perception and navigation pipeline?", "project_deep_dive", "project_walkthrough"),
        ("what was the hardest technical challenge you faced", "What was the hardest technical challenge you faced?", "behavioral", "star_story"),
        ("how did you handle noisy detections", "How did you handle noisy detections or localization errors?", "technical", "technical_explanation"),
        ("why did the diffusion decoder perform better", "Why did the diffusion decoder perform better than the autoregressive and flow-matching decoders in your MuJoCo evaluation?", "technical", "technical_explanation"),
        ("suppose you had another month to improve the system", "Suppose you had another month to improve the system, what would you change first?", "technical", "direct_answer"),
        ("why do you want to join our team", "Why do you want to join our team?", "company_fit", "direct_answer"),
        ("do you have any questions for us", "Do you have any questions for us?", "company_fit", "direct_answer"),
        ("can you explain how your previous robotics experience prepares you for this role", "Can you explain how your previous robotics experience prepares you for this role?", "company_fit", "direct_answer"),
        ("what was the hardest technical challenge in your leorover project", "What was the hardest technical challenge in your LeoRover project?", "behavioral", "star_story"),
        ("how did you solve the noisy perception and navigation timing issue in your leorover project", "How did you solve the noisy perception and navigation timing issue in your LeoRover project?", "technical", "technical_explanation"),
        ("if the same issue happened again in the leorover timing and localisation pipeline", "If the same issue happened again in the LeoRover timing and localisation pipeline, what would you do differently?", "behavioral", "star_story"),
        ("and how did you solve it", "And how did you solve it?", "technical", "technical_explanation"),
        ("if the same issue happened again", "If the same issue happened again, what would you do differently?", "behavioral", "star_story"),
        ("could you walk me through your robotics project, especially your role", "Could you walk me through your robotics project, especially your role in the perception and navigation pipeline?", "project_deep_dive", "project_walkthrough")
    ]

    func testConnection(configuration: LLMProviderConfiguration) async throws -> LLMConnectionTestResult {
        LLMConnectionTestResult(success: true, message: "Mock OK", latencyMS: 0, models: [])
    }

    func chatCompletion(
        configuration: LLMProviderConfiguration,
        messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions
    ) async throws -> LLMChatResult {
        let prompt = messages.map(\.content).joined(separator: "\n")
        if prompt.contains("Decide whether the interviewer has asked") {
            return detectionResult(for: prompt)
        }
        let content = """
        {
          "strategy": "Direct interview answer",
          "say_first": "I would answer this directly with a concise example from my robotics experience.",
          "key_points": ["Robotics context", "Technical decision", "Result and learning"],
          "follow_up_ready": ["I can go deeper into the implementation."],
          "confidence": 0.86,
          "caution": "None",
          "evidence_used": [],
          "risk_level": "low"
        }
        """
        return LLMChatResult(content: content, modelName: "long-interview-mock", providerKind: .deepSeek, providerName: "DeepSeek", baseURL: "", latencyMS: 10, isLocal: false, rawResponse: content)
    }

    func chatCompletionStream(
        configuration: LLMProviderConfiguration,
        messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions
    ) -> AsyncThrowingStream<String, Error> {
        let prompt = messages.map(\.content).joined(separator: "\n")
        return AsyncThrowingStream { continuation in
            Task {
                if prompt.contains("Return plain text sections only") {
                    continuation.finish()
                    return
                }
                for token in ["I ", "would ", "answer ", "with ", "a ", "specific ", "robotics ", "example."] {
                    continuation.yield(token)
                }
                continuation.finish()
            }
        }
    }

    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] {
        []
    }

    private func detectionResult(for prompt: String) -> LLMChatResult {
        let latestInterviewerLine = latestInterviewerLine(from: prompt)
        let lower = latestInterviewerLine.lowercased()
        if let match = answerWorthyQuestions.first(where: { lower.contains($0.needle) }) {
            let content = """
            {
              "should_trigger": true,
              "question_complete": true,
              "question_text": \(jsonString(match.question)),
              "intent": "\(match.intent)",
              "answer_strategy": "\(match.strategy)",
              "confidence": 0.95,
              "reason": "Complete interviewer question."
            }
            """
            return LLMChatResult(content: content, modelName: "long-interview-detector", providerKind: .deepSeek, providerName: "DeepSeek", baseURL: "", latencyMS: 5, isLocal: false, rawResponse: content)
        }

        let content = """
        {
          "should_trigger": false,
          "question_complete": false,
          "question_text": "",
          "intent": "small_talk",
          "answer_strategy": "wait",
          "confidence": 0.15,
          "reason": "Small talk, explanation, or candidate speech should not trigger an answer."
        }
        """
        return LLMChatResult(content: content, modelName: "long-interview-detector", providerKind: .deepSeek, providerName: "DeepSeek", baseURL: "", latencyMS: 5, isLocal: false, rawResponse: content)
    }

    private func latestInterviewerLine(from prompt: String) -> String {
        let transcript = prompt
            .components(separatedBy: "Recent transcript:")
            .last?
            .components(separatedBy: "Decide whether")
            .first ?? prompt
        return transcript
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .reversed()
            .first { $0.lowercased().hasPrefix("interviewer:") }?
            .replacingOccurrences(of: "Interviewer:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func jsonString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let encoded = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return encoded
    }
}

private final class LongInterviewEmptyContextRetrievalService: ContextRetrievalService {
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
            retrievalLatencyMS: 0,
            emptyQueryFallbackUsed: false,
            zeroScoreFallbackUsed: false
        )
        return (context, trace)
    }
}
