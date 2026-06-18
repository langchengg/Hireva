import Foundation
import Testing
@testable import InterviewCopilotMac

@Suite(.serialized)
@MainActor
struct SystemAudioMixedDialogueTests {
    @Test
    func fullDialogueAllSystemAudioIgnoresCandidateStyleAnswers() async throws {
        let (appState, session, client, _) = try makeAppState()
        try await settleStartup(appState)
        let dialogue: [(String, String?)] = [
            ("Hi Lang, thanks for joining today. We’ll keep this quite conversational.", nil),
            ("First, could you tell me a little bit about yourself and what brought you into robotics?", "Could you tell me a little bit about yourself and what brought you into robotics?"),
            ("Sure. I’m currently studying MSc Robotics at the University of Manchester. My background is in computer science, and I became interested in robotics because it combines software, perception, control, and real-world systems.", nil),
            ("Great, thanks. I saw your LeoRover project on your CV. Could you walk me through that project, especially your role in the perception and navigation pipeline?", "Could you walk me through that project, especially your role in the perception and navigation pipeline?"),
            ("Yes. The LeoRover project was an autonomous object retrieval robot. The goal was to search for a target object, localise it, navigate toward it, and pick it up using a manipulator.", nil),
            ("Okay, interesting. What was the hardest technical challenge you faced in that project?", "What was the hardest technical challenge you faced in that project?"),
            ("The hardest challenge was making different modules work reliably together on the real robot. Perception results were noisy, robot localisation was not always stable, and timing between detection, navigation, and manipulation could create failures.", nil),
            ("Right. You mentioned ROS2 and YOLOv8. How did you handle noisy detections or localisation errors?", "How did you handle noisy detections or localisation errors?"),
            ("I handled this by adding filtering and recovery behaviour. Instead of trusting a single detection, the system used repeated observations and only acted when the target was stable enough.", nil),
            ("Good. Now thinking about this role, why do you want to join our team?", "Why do you want to join our team?"),
            ("I’m interested in this role because it connects closely with the kind of robotics work I want to do.", nil)
        ]

        var detectedQuestions: [String] = []
        for (index, item) in dialogue.enumerated() {
            let beforeDetected = appState.detectedQuestionsInSessionCount
            let beforeDetectorCalls = client.detectionCallCount
            let segment = systemSegment(id: "mixed-\(index)", sessionID: session.id, text: item.0)
            let started = Date()
            await appState.handleTranscriptSegment(segment)
            let ingestionMs = Int(Date().timeIntervalSince(started) * 1000)
            #expect(ingestionMs < 250)

            if let expectedQuestion = item.1 {
                try await waitUntil(timeout: 15.0) {
                    appState.detectedQuestionsInSessionCount == beforeDetected + 1 &&
                    appState.lastDetectedQuestion?.transcriptSegmentID == segment.id
                }
                detectedQuestions.append(try #require(appState.lastDetectedQuestion?.questionText))
                #expect(appState.lastDetectedQuestion?.questionText == expectedQuestion)
                #expect(client.detectionCallCount == beforeDetectorCalls)
            } else {
                try await waitUntil(timeout: 2.2) {
                    !appState.shouldShowBlockingAnswerSpinner
                }
                #expect(appState.detectedQuestionsInSessionCount == beforeDetected)
                #expect(client.detectionCallCount == beforeDetectorCalls)
                #expect(!appState.shouldShowBlockingAnswerSpinner)
            }
        }

        #expect(detectedQuestions == dialogue.compactMap(\.1))
        #expect(appState.ignoredSystemAudioAnswerLikeCount >= 4)
        #expect(!appState.shouldShowBlockingAnswerSpinner)
    }

    @Test
    func longCandidateAnswerFromSystemAudioDoesNotRunDetectionOrRAG() async throws {
        let (appState, session, client, retrievalService) = try makeAppState()
        try await settleStartup(appState)
        let longAnswer = "Sure. I’m currently studying MSc Robotics at the University of Manchester. My background is in computer science, and I became interested in robotics because it combines software, perception, control, and real-world systems. Recently, most of my work has focused on robot perception, manipulation, and AI-based decision making."

        let started = Date()
        await appState.handleTranscriptSegment(systemSegment(id: "long-answer", sessionID: session.id, text: longAnswer))
        let ingestionMs = Int(Date().timeIntervalSince(started) * 1000)
        try await Task.sleep(nanoseconds: 650_000_000)

        #expect(ingestionMs < 250)
        #expect(appState.detectedQuestionsInSessionCount == 0)
        #expect(client.detectionCallCount == 0)
        #expect(retrievalService.retrieveCount == 0)
        #expect(appState.lastIgnoredSystemAudioReason.localizedCaseInsensitiveContains("candidate"))
        #expect(appState.ignoredSystemAudioAnswerLikeCount == 1)
        #expect(!appState.shouldShowBlockingAnswerSpinner)
    }

    @Test
    func asrPartialStormForCandidateAnswerDoesNotExplodeRowsOrTriggerGeneration() async throws {
        let (appState, session, client, retrievalService) = try makeAppState()
        try await settleStartup(appState)
        let prefixes = [
            "Sure.",
            "Sure. I’m currently studying",
            "Sure. I’m currently studying MSc Robotics",
            "Sure. I’m currently studying MSc Robotics at the University of Manchester",
            "Sure. I’m currently studying MSc Robotics at the University of Manchester. My background is in computer science",
            "Sure. I’m currently studying MSc Robotics at the University of Manchester. My background is in computer science, and I became interested in robotics because it combines software, perception, control, and real-world systems."
        ]

        for index in 0..<20 {
            await appState.handleTranscriptSegment(systemSegment(
                id: "candidate-partial-storm",
                sessionID: session.id,
                text: prefixes[min(index, prefixes.count - 1)]
            ))
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 650_000_000)

        #expect(appState.transcriptSegments.count == 1)
        #expect(appState.detectedQuestionsInSessionCount == 0)
        #expect(client.detectionCallCount == 0)
        #expect(retrievalService.retrieveCount == 0)
        #expect(appState.ignoredSystemAudioAnswerLikeCount >= 1)
        #expect(!appState.shouldShowBlockingAnswerSpinner)
    }

    @Test
    func questionAfterLongSystemAudioAnswerStillStartsGeneration() async throws {
        let (appState, session, client, _) = try makeAppState()
        try await settleStartup(appState)
        let longAnswer = "The hardest challenge was making different modules work reliably together on the real robot. Perception results were noisy, robot localisation was not always stable, and timing between detection, navigation, and manipulation could create failures."

        await appState.handleTranscriptSegment(systemSegment(id: "ignored-answer", sessionID: session.id, text: longAnswer))
        try await Task.sleep(nanoseconds: 160_000_000)
        #expect(appState.detectedQuestionsInSessionCount == 0)
        #expect(client.detectionCallCount == 0)

        await appState.handleTranscriptSegment(systemSegment(
            id: "question-after-answer",
            sessionID: session.id,
            text: "Great. What was the hardest technical challenge you faced in that project?"
        ))

        try await waitUntil(timeout: 15.0) {
            appState.detectedQuestionsInSessionCount == 1 &&
            appState.lastDetectedQuestion?.transcriptSegmentID == "question-after-answer" &&
            appState.visibleAnswerExists
        }

        #expect(appState.lastDetectedQuestion?.questionText == "What was the hardest technical challenge you faced in that project?")
        #expect(appState.activeQuestionID == appState.lastDetectedQuestion?.id)
        #expect(!appState.shouldShowBlockingAnswerSpinner)
    }

    @Test
    func rapidMixedSystemAudioDialogueLeavesLatestQuestionActive() async throws {
        let (appState, session, _, _) = try makeAppState()
        try await settleStartup(appState)
        let dialogue: [(String, Bool)] = [
            ("Hi Lang, thanks for joining today.", false),
            ("First, could you tell me a little bit about yourself and what brought you into robotics?", true),
            ("Sure. I’m currently studying MSc Robotics at the University of Manchester and recently focused on perception and manipulation.", false),
            ("Great. Could you walk me through that project, especially your role in the perception and navigation pipeline?", true),
            ("Yes. The LeoRover project was an autonomous object retrieval robot and my role focused on ROS2 perception and navigation coordination.", false)
        ]

        for (index, item) in dialogue.enumerated() {
            await appState.handleTranscriptSegment(systemSegment(id: "rapid-\(index)", sessionID: session.id, text: item.0))
            if item.1 {
                try await waitUntil(timeout: 15.0) {
                    appState.lastDetectedQuestion?.transcriptSegmentID == "rapid-\(index)"
                }
            } else {
                try await Task.sleep(nanoseconds: 80_000_000)
            }
        }

        try await waitUntil(timeout: 15.0) {
            appState.visibleAnswerExists && !appState.shouldShowBlockingAnswerSpinner
        }

        #expect(appState.detectedQuestionsInSessionCount == 2)
        #expect(appState.lastDetectedQuestion?.questionText == "Could you walk me through that project, especially your role in the perception and navigation pipeline?")
        #expect(appState.currentGenerationTelemetry.questionID == appState.activeQuestionID)
        #expect(!appState.shouldShowBlockingAnswerSpinner)
    }

    private func makeAppState() throws -> (AppState, InterviewSession, SystemAudioMixedDialogueLLMClient, CountingContextRetrievalService) {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "SystemAudioMixedDialogueTests")
        let settingsRepository = SettingsRepository(database: database)
        try settingsRepository.ensureDefaultProviderConfigurations()
        if let deepSeek = try settingsRepository.providerConfigurations().first(where: { $0.kind == .deepSeek }) {
            try settingsRepository.setActiveRealtimeProvider(id: deepSeek.id)
        }

        let client = SystemAudioMixedDialogueLLMClient()
        let router = LLMRouter(settingsRepository: settingsRepository, clients: [.deepSeek: client])
        let retrievalService = CountingContextRetrievalService()
        let appState = AppState(database: database, llmRouter: router, contextRetrievalService: retrievalService)
        appState.detectionDebounceSeconds = 0.02
        appState.delayProvider = MockDelayProvider()
        appState.generationFullCardWatchdogNanoseconds = 1_000_000_000
        appState.startMainThreadHeartbeat()

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
        return (appState, session, client, retrievalService)
    }

    private func systemSegment(id: String, sessionID: String, text: String) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            sessionID: sessionID,
            source: .systemAudio,
            speaker: .interviewer,
            text: text,
            createdAt: Date(),
            confidence: 1.0
        )
    }

    private func settleStartup(_ appState: AppState) async throws {
        try await Task.sleep(nanoseconds: 300_000_000)
        appState.stopReason = nil
        appState.liveState = .listening
        appState.currentCaptureRuntimeState = .listening
    }

    private func waitUntil(timeout: TimeInterval, predicate: @escaping @MainActor () -> Bool) async throws {
        let start = Date()
        while !predicate() {
            if Date().timeIntervalSince(start) > timeout {
                throw NSError(
                    domain: "SystemAudioMixedDialogueTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for mixed system-audio dialogue state."]
                )
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }
}

private final class SystemAudioMixedDialogueLLMClient: LLMClientProtocol, @unchecked Sendable {
    let providerKind: LLMProviderKind = .deepSeek
    private let lock = NSLock()
    private var detectionCalls = 0

    var detectionCallCount: Int {
        lock.withLock { detectionCalls }
    }

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
            lock.withLock {
                detectionCalls += 1
            }
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
        return LLMChatResult(content: content, modelName: "mixed-dialogue-mock", providerKind: .deepSeek, providerName: "DeepSeek", baseURL: "", latencyMS: 10, isLocal: false, rawResponse: content)
    }

    func chatCompletionStream(
        configuration: LLMProviderConfiguration,
        messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                if messages.map(\.content).joined(separator: "\n").contains("Return plain text sections only") {
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
        let latestLine = latestInterviewerLine(from: prompt)
        let lower = latestLine.lowercased()
        let question: String?
        if lower.contains("could you tell me a little bit about yourself") {
            question = "Could you tell me a little bit about yourself and what brought you into robotics?"
        } else if lower.contains("could you walk me through") {
            question = "Could you walk me through that project, especially your role in the perception and navigation pipeline?"
        } else if lower.contains("what was the hardest technical challenge") {
            question = "What was the hardest technical challenge you faced in that project?"
        } else if lower.contains("how did you handle noisy detections") {
            question = "How did you handle noisy detections or localisation errors?"
        } else if lower.contains("why do you want to join our team") {
            question = "Why do you want to join our team?"
        } else {
            question = nil
        }

        let content: String
        if let question {
            content = """
            {
              "should_trigger": true,
              "question_complete": true,
              "question_text": \(jsonString(question)),
              "intent": "technical",
              "answer_strategy": "direct_answer",
              "confidence": 0.95,
              "reason": "Complete interviewer question."
            }
            """
        } else {
            content = """
            {
              "should_trigger": false,
              "question_complete": false,
              "question_text": "",
              "intent": "small_talk",
              "answer_strategy": "wait",
              "confidence": 0.15,
              "reason": "Not an answer-worthy question."
            }
            """
        }
        return LLMChatResult(content: content, modelName: "mixed-dialogue-detector", providerKind: .deepSeek, providerName: "DeepSeek", baseURL: "", latencyMS: 5, isLocal: false, rawResponse: content)
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

private final class CountingContextRetrievalService: ContextRetrievalService, @unchecked Sendable {
    private let lock = NSLock()
    private var retrieves = 0

    var retrieveCount: Int {
        lock.withLock { retrieves }
    }

    func retrieveContextWithTrace(
        question: String,
        intent: QuestionIntent,
        maxCVWords: Int,
        maxJDWords: Int,
        strategy: AnswerStrategy?
    ) async throws -> (context: RetrievedContext, trace: RetrievalTrace) {
        lock.withLock {
            retrieves += 1
        }
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
