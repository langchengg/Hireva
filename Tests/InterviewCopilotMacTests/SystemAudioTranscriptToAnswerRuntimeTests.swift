import Foundation
import GRDB
import Testing
@testable import InterviewCopilotMac

@Suite(.serialized)
@MainActor
struct SystemAudioTranscriptToAnswerRuntimeTests {
    @Test
    func oneLongSystemAudioTranscriptExtractsAllQuestionsAndGeneratesLatestAnswer() async throws {
        let (appState, database, session, client) = try makeAppState()
        let transcript = Self.realRuntimeLongTranscriptFixture

        await appState.handleTranscriptSegment(systemAudioSegment(
            id: "real-runtime-long-transcript",
            sessionID: session.id,
            speaker: .interviewer,
            text: transcript
        ))

        try await waitUntil(timeout: 10.0) {
            appState.detectedQuestionsInSessionCount == 9 &&
            appState.lastTranscriptQuestionGenerationTrace.extractedQuestionCount == 9 &&
            appState.currentSuggestion != nil &&
            appState.lastTranscriptQuestionGenerationTrace.visibleSuggestionCreated
        }

        let detectedQuestions = try detectedQuestionTexts(database: database)
        #expect(detectedQuestions.count == 9)
        #expect(detectedQuestions[0].localizedCaseInsensitiveContains("could you tell me a little bit about yourself"))
        #expect(detectedQuestions[1].localizedCaseInsensitiveContains("could you walk me through your"))
        #expect(detectedQuestions[2].localizedCaseInsensitiveContains("what was the hardest technical challenge"))
        #expect(detectedQuestions[3].localizedCaseInsensitiveContains("how did you handle noisy detections"))
        #expect(detectedQuestions[4].localizedCaseInsensitiveContains("why did the diffusion decoder perform better"))
        #expect(detectedQuestions[5].localizedCaseInsensitiveContains("what would you change first"))
        #expect(detectedQuestions[6].localizedCaseInsensitiveContains("why do you want to join our team"))
        #expect(detectedQuestions[7].localizedCaseInsensitiveContains("how comfortable are you with python"))
        #expect(detectedQuestions[8].localizedCaseInsensitiveContains("do you have any questions for us"))

        let currentQuestion = try #require(appState.currentSuggestion?.questionText)
        #expect(currentQuestion.localizedCaseInsensitiveContains("do you have any questions for us"))
        #expect(appState.pendingAcceptedQuestions.isEmpty)
        #expect(appState.lastTranscriptQuestionGenerationTrace.generationTriggered)
        #expect(appState.lastTranscriptQuestionGenerationTrace.currentSuggestionExists)
        #expect(client.answerCallCount <= 2)
    }

    @Test
    func sourceSystemAudioSpeakerUnknownStillExtractsLongTranscriptQuestions() async throws {
        let (appState, database, session, _) = try makeAppState()

        await appState.handleTranscriptSegment(systemAudioSegment(
            id: "real-runtime-long-transcript-unknown",
            sessionID: session.id,
            speaker: .unknown,
            text: Self.realRuntimeLongTranscriptFixture
        ))

        try await waitUntil(timeout: 10.0) {
            appState.detectedQuestionsInSessionCount == 9 &&
            appState.lastTranscriptQuestionGenerationTrace.extractedQuestionCount == 9 &&
            appState.currentSuggestion != nil
        }

        #expect(try detectedQuestionTexts(database: database).count == 9)
        #expect(appState.lastDetectedQuestionSpeaker == SpeakerRole.unknown.rawValue)
        #expect(appState.currentSuggestion?.questionText?.localizedCaseInsensitiveContains("do you have any questions for us") == true)
        #expect(appState.pendingAcceptedQuestions.isEmpty)
        #expect(appState.lastTranscriptQuestionGenerationTrace.generationTriggered)
    }

    @Test
    func latestRealDatabaseTranscriptFixtureExtractsQuestionsIfAvailable() async throws {
        let (appState, _, session, _) = try makeAppState()
        let transcript = Self.latestRealDatabaseSystemAudioTranscript() ?? Self.realRuntimeLongTranscriptFixture

        await appState.handleTranscriptSegment(systemAudioSegment(
            id: "real-db-replay-transcript",
            sessionID: session.id,
            speaker: .interviewer,
            text: transcript
        ))

        try await waitUntil(timeout: 10.0) {
            appState.lastTranscriptQuestionGenerationTrace.extractedQuestionCount >= 1 &&
            appState.detectedQuestionsInSessionCount >= 1 &&
            appState.lastTranscriptQuestionGenerationTrace.generationTriggered &&
            appState.lastTranscriptQuestionGenerationTrace.visibleSuggestionCreated &&
            appState.currentSuggestion != nil
        }

        #expect(appState.currentSuggestion != nil)
        #expect(!appState.currentSpinnerVisible)
    }

    private static let realRuntimeLongTranscriptFixture = "Hi thanks for joining today first could you tell me a little bit about yourself and what brought you into robotics great thanks could you walk me through your Leah Rover project what was the hardest technical challenge you faced how did you handle noisy detections or localization error errors why did the diffusion decoder perform better in your Mouko evaluation what would you change first if you had another month why do you want to join our team how comfortable are you with python C and Rose two do you have any questions for us"

    private func makeAppState() throws -> (AppState, AppDatabase, InterviewSession, RuntimeTranscriptLLMClient) {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "SystemAudioTranscriptToAnswerRuntimeTests")
        let settingsRepository = SettingsRepository(database: database)
        try settingsRepository.ensureDefaultProviderConfigurations()
        if let deepSeek = try settingsRepository.providerConfigurations().first(where: { $0.kind == .deepSeek }) {
            try settingsRepository.setActiveRealtimeProvider(id: deepSeek.id)
        }

        let client = RuntimeTranscriptLLMClient()
        let router = LLMRouter(settingsRepository: settingsRepository, clients: [.deepSeek: client])
        let appState = AppState(
            database: database,
            llmRouter: router,
            contextRetrievalService: RuntimeTranscriptEmptyContextRetrievalService()
        )
        appState.detectionDebounceSeconds = 0.02
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

    private func systemAudioSegment(
        id: String,
        sessionID: String,
        speaker: SpeakerRole,
        text: String
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            sessionID: sessionID,
            source: .systemAudio,
            speaker: speaker,
            text: text,
            createdAt: Date(),
            confidence: 1.0
        )
    }

    private func detectedQuestionTexts(database: AppDatabase) throws -> [String] {
        try database.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT question_text FROM detected_questions ORDER BY created_at ASC")
        }
    }

    private func waitUntil(timeout: TimeInterval, predicate: @escaping @MainActor () -> Bool) async throws {
        let start = Date()
        let effectiveTimeout = max(timeout, 90.0)
        while !predicate() {
            if Date().timeIntervalSince(start) > effectiveTimeout {
                throw NSError(
                    domain: "SystemAudioTranscriptToAnswerRuntimeTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for long transcript-to-answer state."]
                )
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    private static func latestRealDatabaseSystemAudioTranscript() -> String? {
        let dbURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/InterviewCopilotMac/interview_copilot.sqlite")
        guard FileManager.default.fileExists(atPath: dbURL.path),
              let queue = try? DatabaseQueue(path: dbURL.path) else {
            return nil
        }
        return try? queue.read { db in
            try String.fetchOne(
                db,
                sql: """
                SELECT text
                FROM transcript_segments
                WHERE source = 'systemAudio'
                  AND length(text) >= 120
                ORDER BY created_at DESC
                LIMIT 1
                """
            )
        }
    }
}

private final class RuntimeTranscriptLLMClient: LLMClientProtocol, @unchecked Sendable {
    let providerKind: LLMProviderKind = .deepSeek
    private let lock = NSLock()
    private var answerCalls = 0

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
        lock.withLock { answerCalls += 1 }
        let content = """
        {
          "strategy": "Direct interview answer",
          "say_first": "I would answer the latest question directly and keep it concise.",
          "key_points": ["Use a first-person answer", "Connect it to robotics experience", "Keep the response speakable"],
          "follow_up_ready": ["I can add more detail if needed."],
          "confidence": 0.86,
          "caution": "None",
          "evidence_used": [],
          "risk_level": "low"
        }
        """
        return LLMChatResult(content: content, modelName: "runtime-transcript-mock", providerKind: .deepSeek, providerName: "DeepSeek", baseURL: "", latencyMS: 10, isLocal: false, rawResponse: content)
    }

    func chatCompletionStream(
        configuration: LLMProviderConfiguration,
        messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream<String, Error> { continuation in
            Task {
                let prompt = messages.map(\.content).joined(separator: "\n")
                if prompt.contains("Return plain text sections only") {
                    continuation.finish()
                    return
                }
                for token in ["I ", "would ", "answer ", "the ", "latest ", "question."] {
                    continuation.yield(token)
                }
                continuation.finish()
            }
        }
    }

    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] {
        []
    }
}

private final class RuntimeTranscriptEmptyContextRetrievalService: ContextRetrievalService {
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
