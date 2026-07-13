import Foundation
import Testing
@testable import Hireva

@Suite(.serialized)
@MainActor
struct FirstAnswerFallbackTests {
    @Test
    func automaticQuestionDetectionCorrectsProviderWaitForCompleteProjectQuestion() async throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "FirstAnswerFallbackTests")
        let settingsRepository = SettingsRepository(database: database)
        try settingsRepository.ensureDefaultProviderConfigurations()
        let mockClient = StreamingMockLLMClient()
        mockClient.chatResultContent = """
        {
          "should_trigger": false,
          "question_complete": false,
          "question_text": "Could you walk me through your LeoRover project",
          "intent": "project_deep_dive",
          "answer_strategy": "wait",
          "confidence": 0.6,
          "reason": "The question appears incomplete; the interviewer likely intends to ask for more details about the project."
        }
        """
        let router = LLMRouter(settingsRepository: settingsRepository, clients: [.deepSeek: mockClient])
        let appState = AppState(
            database: database,
            llmRouter: router,
            contextRetrievalService: SlowContextRetrievalService(delayNanoseconds: 5_000_000_000)
        )
        let delayProvider = MockDelayProvider()
        appState.delayProvider = delayProvider
        var settings = appState.settings
        settings.audioCaptureMode = .microphoneOnly
        appState.saveSettings(settings)

        let session = try appState.sessionRepository.createSession(mode: .microphone)
        appState.currentSession = session
        appState.liveState = .listening
        appState.currentCaptureRuntimeState = .listening

        let segment = TranscriptSegment(
            id: "short-project-question-segment",
            sessionID: session.id,
            source: .systemAudio,
            speaker: .interviewer,
            text: "Could you walk me through your LeoRover project"
        )

        await appState.handleTranscriptSegment(segment)
        try await waitForSuggestion(appState, timeout: 20.0)

        let question = try #require(appState.lastDetectedQuestion)
        let card = try #require(appState.currentSuggestion)
        #expect(question.shouldTrigger)
        #expect(question.questionComplete)
        #expect(question.questionText == "Could you walk me through your LeoRover project")
        #expect(question.answerStrategy == .projectWalkthrough)
        #expect(card.sayFirstSource == "local_first_answer_fallback")
        #expect(appState.homeLiveAnswerPreviewText == card.sayFirst)
        #expect(appState.homeLiveAnswerPreviewText != "Generating first answer...")
        #expect(!appState.isStreamingSayFirst)
        #expect(appState.isExpandingSuggestionCard)
    }

    @Test
    func automaticQuestionDetectionShowsFirstAnswerFallback() async throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "FirstAnswerFallbackTests")
        let settingsRepository = SettingsRepository(database: database)
        try settingsRepository.ensureDefaultProviderConfigurations()
        let mockClient = StreamingMockLLMClient()
        mockClient.chatResultContent = """
        {
          "should_trigger": true,
          "question_complete": true,
          "question_text": "Why do you want this role?",
          "intent": "company_fit",
          "answer_strategy": "direct_answer",
          "confidence": 0.95,
          "reason": "Complete interviewer question."
        }
        """
        let router = LLMRouter(settingsRepository: settingsRepository, clients: [.deepSeek: mockClient])
        let appState = AppState(
            database: database,
            llmRouter: router,
            contextRetrievalService: SlowContextRetrievalService(delayNanoseconds: 5_000_000_000)
        )
        let delayProvider = MockDelayProvider()
        appState.delayProvider = delayProvider
        var settings = appState.settings
        settings.audioCaptureMode = .microphoneOnly
        appState.saveSettings(settings)

        let session = try appState.sessionRepository.createSession(mode: .microphone)
        appState.currentSession = session
        appState.liveState = .listening
        appState.currentCaptureRuntimeState = .listening

        let segment = TranscriptSegment(
            id: "auto-question-segment",
            sessionID: session.id,
            source: .systemAudio,
            speaker: .interviewer,
            text: "Why do you want this role?"
        )

        await appState.handleTranscriptSegment(segment)
        try await waitForSuggestion(appState, timeout: 20.0)

        let card = try #require(appState.currentSuggestion)
        #expect(appState.lastDetectedQuestion?.questionText == "Why do you want this role?")
        #expect(card.sayFirstSource == "local_first_answer_fallback")
        #expect(card.sayFirst.contains("I’m interested in this role"))
        #expect(!appState.isStreamingSayFirst)
        #expect(appState.isExpandingSuggestionCard)
    }

    @Test
    func firstAnswerFallbackAppearsWhenContextRetrievalIsSlow() async throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "FirstAnswerFallbackTests")
        let settingsRepository = SettingsRepository(database: database)
        try settingsRepository.ensureDefaultProviderConfigurations()
        let router = LLMRouter(settingsRepository: settingsRepository, clients: [.deepSeek: StreamingMockLLMClient()])
        let appState = AppState(
            database: database,
            llmRouter: router,
            contextRetrievalService: SlowContextRetrievalService(delayNanoseconds: 5_000_000_000)
        )
        let delayProvider = MockDelayProvider()
        appState.delayProvider = delayProvider

        let session = InterviewSession(
            id: "session-1",
            title: "Test Session",
            company: nil,
            role: nil,
            startedAt: Date(),
            mode: .microphone,
            createdAt: Date()
        )
        let question = DetectedQuestion(
            id: "question-1",
            sessionID: session.id,
            transcriptSegmentID: "segment-1",
            questionText: "Why do you want this role?",
            intent: .companyFit,
            answerStrategy: .directAnswer,
            confidence: 0.95,
            reason: "Test",
            shouldTrigger: true,
            questionComplete: true,
            modelName: "test",
            promptVersion: "test",
            createdAt: Date()
        )

        let generationTask = Task {
            try await appState.generateSuggestion(
                for: question,
                session: session,
                transcript: question.questionText,
                autoGenerated: true
            )
        }
        defer { generationTask.cancel() }

        try await waitForSuggestion(appState, timeout: 20.0)

        let card = try #require(appState.currentSuggestion)
        #expect(card.sayFirst.contains("I’m interested in this role"))
        #expect(card.sayFirstSource == "local_first_answer_fallback")
        #expect(card.providerName == "Local First Answer Fallback")
        #expect(card.keyPoints.count == 3)
        #expect(card.firstKeyPointVisibleMS != nil)
        #expect(appState.softFallbackUsed)
        #expect(delayProvider.delayCalledWithNanoseconds.contains(1_500_000_000))
        #expect(!appState.isStreamingSayFirst)
        #expect(appState.isExpandingSuggestionCard)
    }

    private func waitForSuggestion(_ appState: AppState, timeout: TimeInterval) async throws {
        let start = Date()
        while appState.currentSuggestion == nil {
            if Date().timeIntervalSince(start) > timeout {
                throw NSError(
                    domain: "FirstAnswerFallbackTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for first answer fallback."]
                )
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private final class SlowContextRetrievalService: ContextRetrievalService {
    let delayNanoseconds: UInt64

    init(delayNanoseconds: UInt64) {
        self.delayNanoseconds = delayNanoseconds
    }

    func retrieveContextWithTrace(
        question: String,
        intent: QuestionIntent,
        maxCVWords: Int,
        maxJDWords: Int,
        strategy: AnswerStrategy?
    ) async throws -> (context: RetrievedContext, trace: RetrievalTrace) {
        try await Task.sleep(nanoseconds: delayNanoseconds)
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
            retrievalLatencyMS: Double(delayNanoseconds) / 1_000_000.0,
            emptyQueryFallbackUsed: false,
            zeroScoreFallbackUsed: false
        )
        return (context, trace)
    }
}
