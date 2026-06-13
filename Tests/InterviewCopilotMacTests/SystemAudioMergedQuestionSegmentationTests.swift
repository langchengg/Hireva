import Foundation
import Testing
@testable import InterviewCopilotMac

@Suite(.serialized)
@MainActor
struct SystemAudioMergedQuestionSegmentationTests {
    private static let runtimeMergedTranscript = "Hi La IL ask these questions in a mixed order so please treat each one independently first why do you want to join our team now let us switch to your technical project experience why might a diffusion based policy be more stable for robotic manipulation than an auto regressive policy now let us switch to your technical project experience why might a diffusion based policy be more stable for robotic manipulation than an auto regressive policy when you moved from a clean demo to real robot execution which part of the pipeline was most fragile"

    private static let expectedQuestions = [
        "why do you want to join our team",
        "why might a diffusion policy be more stable for robotic manipulation than an autoregressive policy",
        "When you moved from a clean demo to real robot execution, which part of the pipeline was most fragile?"
    ]
    private static let fourQuestionRuntimeTranscript = [
        "Why might a diffusion based policy be more stable for robotic manipulation than an auto rig progressive policy",
        "Why might a diffusion based policy be more stable for robotic manipulation than an auto regressive policy",
        "could you explain your LeoRover project",
        "could you explain your LeoRover project from end to end when you",
        "when you moved from a clean demo to real robot execution which part of the pipeline was most fragile",
        "why do you want to join our team"
    ].joined(separator: " ")
    private static let expectedFourQuestions = [
        "Why might a diffusion policy be more stable for robotic manipulation than an autoregressive policy",
        "could you explain your LeoRover project from end to end",
        "When you moved from a clean demo to real robot execution, which part of the pipeline was most fragile?",
        "why do you want to join our team"
    ]

    @Test
    func mergedRuntimeTranscriptSplitsIntoThreeCleanQuestions() {
        let questions = SystemAudioQuestionExtractor.extract(from: Self.runtimeMergedTranscript)

        #expect(questions.map(\.text) == Self.expectedQuestions)
        #expect(Set(questions.map(\.text)).count == 3)
        #expect(questions.last?.intent == .technical)
    }

    @Test
    func latestRuntimeDatabaseReplaySplitsMergedTranscriptWhenAvailable() throws {
        let text = Self.latestRuntimeMergedTranscript() ?? Self.runtimeMergedTranscript

        let questions = SystemAudioQuestionExtractor.extract(from: text)
        let extractedTexts = questions.map(\.text)

        #expect(Self.containsExpectedQuestions(extractedTexts))
        #expect(extractedTexts.joined(separator: " ").localizedCaseInsensitiveContains("why do you want to join our team why do you want") == false)
    }

    @Test
    func mergedTranscriptCreatesRowsForAllQuestionsButGeneratesForLatestOnly() async throws {
        let (appState, database, session, client) = try makeAppState()

        await appState.handleTranscriptSegment(systemAudioSegment(
            id: "merged-runtime-segment",
            sessionID: session.id,
            text: Self.runtimeMergedTranscript
        ))

        try await waitUntil(timeout: 8.0) {
            appState.detectedQuestionsInSessionCount == 3 &&
            appState.lastDetectedQuestion?.questionText == Self.expectedQuestions.last &&
            appState.currentSuggestion?.detectedQuestionID == appState.lastDetectedQuestion?.id &&
            appState.visibleAnswerExists &&
            !appState.currentSpinnerVisible
        }

        let detected = try appState.suggestionRepository.questions(sessionID: session.id)
        #expect(detected.map(\.questionText) == Self.expectedQuestions)
        #expect(appState.lastDetectedQuestionText == Self.expectedQuestions.last)
        #expect(appState.currentSuggestion?.questionText == Self.expectedQuestions.last)
        #expect(appState.currentSuggestion?.promptPrimaryQuestion == Self.expectedQuestions.last)
        #expect(appState.currentSuggestion?.sayFirst.localizedCaseInsensitiveContains("perception") == true)
        #expect(appState.currentSuggestion?.sayFirst.localizedCaseInsensitiveContains("localisation") == true)
        #expect(appState.currentSuggestion?.sayFirst.localizedCaseInsensitiveContains("timing") == true)
        #expect(appState.currentSuggestion?.sayFirst.localizedCaseInsensitiveContains("join our team") == false)
        #expect(client.detectionCallCount == 0)
        #expect(client.answerCallCount <= 2)

        try await waitUntil(timeout: 8.0) {
            (try? appState.suggestionRepository.suggestions(sessionID: session.id).count) == 1
        }
        let persisted = try await database.dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT question_text
                FROM suggestion_cards
                WHERE session_id = ?
                ORDER BY created_at ASC
                """,
                arguments: [session.id]
            )
        }
        #expect(persisted.count == 1)
        #expect(persisted.last == Self.expectedQuestions.last)
        #expect(persisted.joined(separator: " ").localizedCaseInsensitiveContains("why do you want to join our team now let us switch") == false)
    }

    @Test
    func fourQuestionRuntimeTranscriptDedupesASRVariantsAndBoundaryContamination() async throws {
        let (appState, database, session, _) = try makeAppState()

        await appState.handleTranscriptSegment(systemAudioSegment(
            id: "four-question-runtime-segment",
            sessionID: session.id,
            text: Self.fourQuestionRuntimeTranscript
        ))

        try await waitUntil(timeout: 8.0) {
            appState.detectedQuestionsInSessionCount == 4 &&
            appState.lastDetectedQuestion?.questionText == Self.expectedFourQuestions.last &&
            appState.currentSuggestion?.questionText == Self.expectedFourQuestions.last &&
            appState.visibleAnswerExists &&
            !appState.currentSpinnerVisible
        }

        let detected = try appState.suggestionRepository.questions(sessionID: session.id)
        #expect(detected.map(\.questionText) == Self.expectedFourQuestions)
        #expect(detected.map(\.questionText).allSatisfy { !$0.localizedCaseInsensitiveContains("from end to end when you") })
        #expect(detected.map(\.questionText).filter { $0.localizedCaseInsensitiveContains("diffusion") }.count == 1)
        #expect(detected.map(\.questionText).filter { $0.localizedCaseInsensitiveContains("LeoRover") }.count == 1)

        try await waitUntil(timeout: 8.0) {
            (try? appState.suggestionRepository.suggestions(sessionID: session.id).count) == 1
        }
        let persisted = try await database.dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT question_text
                FROM suggestion_cards
                WHERE session_id = ?
                ORDER BY created_at ASC
                """,
                arguments: [session.id]
            )
        }
        #expect(persisted == [Self.expectedFourQuestions.last])
    }

    @Test
    func separateFourQuestionRuntimeSequencePersistsExactlyFourAlignedCards() async throws {
        let (appState, _, session, _) = try makeAppState()
        let segments = [
            "Why might a diffusion based policy be more stable for robotic manipulation than an auto regressive policy",
            "could you explain your LeoRover project from end to end",
            "when you moved from a clean demo to real robot execution which part of the pipeline was most fragile",
            "why do you want to join our team"
        ]

        for (index, text) in segments.enumerated() {
            await appState.handleTranscriptSegment(systemAudioSegment(
                id: "separate-four-question-\(index)",
                sessionID: session.id,
                text: text
            ))
            try await waitUntil(timeout: 8.0) {
                (try? appState.suggestionRepository.suggestions(sessionID: session.id).count) == index + 1
            }
        }

        let cards = try appState.suggestionRepository.suggestions(sessionID: session.id)
        #expect(cards.count == 4)
        #expect(cards.map { $0.questionText ?? "" } == Self.expectedFourQuestions)
        #expect(cards.map { $0.promptPrimaryQuestion ?? "" } == Self.expectedFourQuestions)
        #expect(cards.map { $0.questionIntent?.rawValue ?? "" } == ["model_comparison", "project_walkthrough", "technical_challenge", "why_role"])
        #expect(cards.allSatisfy { $0.alignmentVerdict == .aligned })
        #expect(cards.map { $0.questionText ?? "" }.filter { $0.localizedCaseInsensitiveContains("fragile") }.count == 1)
        #expect(cards.map { $0.questionText ?? "" }.joined(separator: " ").localizedCaseInsensitiveContains("when you moved from a clean demo to real robot execution which part of the pipeline was most fragile when you moved") == false)
    }

    @Test
    func diffusionQuestionSplitDoesNotDisplayWhyRoleAnswer() async throws {
        let (appState, _, session, _) = try makeAppState()
        let transcript = "Why do you want to join our team now let us switch to your technical project experience why might a diffusion based policy be more stable for robotic manipulation than an autoregressive policy"

        await appState.handleTranscriptSegment(systemAudioSegment(
            id: "role-then-diffusion",
            sessionID: session.id,
            text: transcript
        ))

        try await waitUntil(timeout: 8.0) {
            appState.detectedQuestionsInSessionCount == 2 &&
            appState.currentSuggestion?.questionText == "why might a diffusion policy be more stable for robotic manipulation than an autoregressive policy" &&
            appState.visibleAnswerExists &&
            !appState.currentSpinnerVisible
        }

        let answer = try #require(appState.currentSuggestion?.sayFirst)
        #expect(answer.localizedCaseInsensitiveContains("diffusion"))
        #expect(answer.localizedCaseInsensitiveContains("autoregressive"))
        #expect(answer.localizedCaseInsensitiveContains("continuous action"))
        #expect(answer.localizedCaseInsensitiveContains("join our team") == false)
    }

    @Test
    func providerMergedQuestionIsCleanedBeforePersistenceWhenLLMDetectionPathRuns() async throws {
        let (appState, _, session, client) = try makeAppState()
        let transcript = "Why do you want to join our team now let us switch to your technical project experience"
        let expectedCleanQuestion = "Why do you want to join our team"

        await appState.handleTranscriptSegment(systemAudioSegment(
            id: "provider-merged-single-question",
            sessionID: session.id,
            text: transcript
        ))

        try await waitUntil(timeout: 8.0) {
            appState.detectedQuestionsInSessionCount == 1 &&
            appState.currentSuggestion?.questionText == expectedCleanQuestion &&
            appState.visibleAnswerExists &&
            !appState.currentSpinnerVisible
        }

        let detected = try appState.suggestionRepository.questions(sessionID: session.id)
        #expect(detected.map(\.questionText) == [expectedCleanQuestion])
        #expect(appState.currentSuggestion?.promptPrimaryQuestion == expectedCleanQuestion)
        #expect(appState.currentSuggestion?.questionText?.localizedCaseInsensitiveContains("now let us switch") == false)
        #expect(client.detectionCallCount == 1)
    }

    private func makeAppState() throws -> (AppState, AppDatabase, InterviewSession, MergedQuestionLLMClient) {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "SystemAudioMergedQuestionSegmentation")
        let settingsRepository = SettingsRepository(database: database)
        try settingsRepository.ensureDefaultProviderConfigurations()
        if let deepSeek = try settingsRepository.providerConfigurations().first(where: { $0.kind == .deepSeek }) {
            try settingsRepository.setActiveRealtimeProvider(id: deepSeek.id)
        }

        let client = MergedQuestionLLMClient()
        let router = LLMRouter(settingsRepository: settingsRepository, clients: [.deepSeek: client])
        let appState = AppState(
            database: database,
            llmRouter: router,
            contextRetrievalService: MergedQuestionEmptyContextRetrievalService()
        )
        appState.detectionDebounceSeconds = 0.01
        appState.delayProvider = MockDelayProvider()
        appState.generationFullCardWatchdogNanoseconds = 1_000_000_000

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
        return (appState, database, session, client)
    }

    private func systemAudioSegment(id: String, sessionID: String, text: String) -> TranscriptSegment {
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

    private func waitUntil(timeout: TimeInterval, predicate: @escaping @MainActor () -> Bool) async throws {
        let start = Date()
        while !predicate() {
            if Date().timeIntervalSince(start) > timeout {
                throw NSError(
                    domain: "SystemAudioMergedQuestionSegmentationTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for merged question segmentation state."]
                )
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    private static func latestRuntimeMergedTranscript() -> String? {
        let dbPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/InterviewCopilotMac/interview_copilot.sqlite")
            .path
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }
        guard let database = try? AppDatabase(path: URL(fileURLWithPath: dbPath)) else { return nil }
        return try? database.dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: """
                SELECT text
                FROM transcript_segments
                WHERE source = 'systemAudio'
                  AND lower(text) LIKE '%why might a diffusion%'
                  AND lower(text) LIKE '%which part of the pipeline%'
                ORDER BY created_at DESC
                LIMIT 1
                """
            )
        }
    }

    private static func containsExpectedQuestions(_ questions: [String]) -> Bool {
        let normalizedQuestions = questions.map(normalizedQuestion)
        let normalizedExpected = expectedQuestions.map(normalizedQuestion)
        return normalizedExpected.allSatisfy { normalizedQuestions.contains($0) }
    }

    private static func normalizedQuestion(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

private final class MergedQuestionLLMClient: LLMClientProtocol, @unchecked Sendable {
    let providerKind: LLMProviderKind = .deepSeek
    private let lock = NSLock()
    private var detectionCalls = 0
    private var answerCalls = 0

    var detectionCallCount: Int {
        lock.withLock { detectionCalls }
    }

    var answerCallCount: Int {
        lock.withLock { answerCalls }
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
            lock.withLock { detectionCalls += 1 }
            let latest = prompt
                .components(separatedBy: "Recent transcript:")
                .last?
                .components(separatedBy: "Decide whether")
                .first?
                .replacingOccurrences(of: "Interviewer:", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return detectionResult(question: latest)
        }

        lock.withLock { answerCalls += 1 }
        let question = currentQuestion(from: prompt)
        let content = """
        {
          "strategy": "Current question answer",
          "say_first": "\(Self.jsonEscaped(sayFirst(for: question)))",
          "key_points": ["\(Self.jsonEscaped(keyPoint(for: question)))", "Bind the answer to the latest split question"],
          "follow_up_ready": ["I can go deeper into implementation details."],
          "confidence": 0.88,
          "caution": "None",
          "evidence_used": [],
          "risk_level": "low"
        }
        """
        return LLMChatResult(content: content, modelName: "merged-question-mock", providerKind: .deepSeek, providerName: "DeepSeek", baseURL: "", latencyMS: 10, isLocal: false, rawResponse: content)
    }

    func chatCompletionStream(
        configuration: LLMProviderConfiguration,
        messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions
    ) -> AsyncThrowingStream<String, Error> {
        let prompt = messages.map(\.content).joined(separator: "\n")
        let question = currentQuestion(from: messages.last?.content ?? prompt)
        let tokens = prompt.contains("Return plain text sections only")
            ? sectionAnswer(for: question)
            : sayFirst(for: question).split(separator: " ").map { String($0) + " " }

        return AsyncThrowingStream { continuation in
            Task {
                for token in tokens {
                    if Task.isCancelled { break }
                    continuation.yield(token)
                }
                continuation.finish()
            }
        }
    }

    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] {
        []
    }

    private func detectionResult(question: String) -> LLMChatResult {
        let lower = question.lowercased()
        let intent: String
        let strategy: String
        if lower.contains("join our team") || lower.contains("why do you want") {
            intent = "company_fit"
            strategy = "direct_answer"
        } else if lower.contains("leorover") || lower.contains("leo rover") || lower.contains("project") {
            intent = "project_deep_dive"
            strategy = "project_walkthrough"
        } else {
            intent = "technical"
            strategy = "technical_explanation"
        }
        let content = """
        {
          "should_trigger": true,
          "question_complete": true,
          "question_text": \(Self.jsonString(question)),
          "intent": "\(intent)",
          "answer_strategy": "\(strategy)",
          "confidence": 0.95,
          "reason": "Complete interviewer question."
        }
        """
        return LLMChatResult(content: content, modelName: "merged-question-detector", providerKind: .deepSeek, providerName: "DeepSeek", baseURL: "", latencyMS: 5, isLocal: false, rawResponse: content)
    }

    private func currentQuestion(from prompt: String) -> String {
        if let range = prompt.range(of: #"CURRENT QUESTION TO ANSWER:\s*\n"([^"]+)""#, options: [.regularExpression, .caseInsensitive]) {
            return String(prompt[range])
                .replacingOccurrences(of: "CURRENT QUESTION TO ANSWER:", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: "\"", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return prompt
    }

    private func sayFirst(for question: String) -> String {
        let lower = question.lowercased()
        if lower.contains("diffusion") || lower.contains("autoregressive") || lower.contains("auto regressive") {
            return "The diffusion policy was more robust than the autoregressive policy because it modelled continuous action distributions more smoothly and recovered better from small trajectory errors."
        }
        if lower.contains("leorover") || lower.contains("leo rover") || lower.contains("project") {
            return "My LeoRover project was an autonomous object retrieval robot where I built the ROS2 perception pipeline around YOLOv8, connected localisation to navigation, and coordinated the manipulation step so the real robot could pick up the target object."
        }
        if lower.contains("fragile") || lower.contains("real robot execution") || lower.contains("pipeline") {
            return "The most fragile part was the integration around noisy perception, localisation stability, and timing between navigation and manipulation during real robot execution."
        }
        if lower.contains("join our team") {
            return "I’m drawn to Dexory because my work in embodied AI and ROS2 robotics aligns perfectly with your mission to deploy intelligent robots in real logistics environments, and I want to help build practical, scalable robotics systems with the team."
        }
        return "I would answer the latest interviewer question directly with a specific robotics example."
    }

    private func keyPoint(for question: String) -> String {
        String(sayFirst(for: question).prefix(90))
    }

    private func sectionAnswer(for question: String) -> [String] {
        [
            "STRATEGY:\nDirect answer\n",
            "SAY_FIRST:\n\(sayFirst(for: question))\n",
            "KEY_POINTS:\n",
            "- \(keyPoint(for: question))\n",
            "- Bind the answer to the latest split question\n",
            "FOLLOW_UP_READY:\n",
            "- I can go deeper into implementation details.\n",
            "CAUTION:\nNone\n"
        ]
    }

    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let encoded = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return encoded
    }

    private static func jsonEscaped(_ value: String) -> String {
        let encoded = jsonString(value)
        return String(encoded.dropFirst().dropLast())
    }
}

private final class MergedQuestionEmptyContextRetrievalService: ContextRetrievalService, @unchecked Sendable {
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
