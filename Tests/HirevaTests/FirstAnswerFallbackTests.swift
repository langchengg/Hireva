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
            contextRetrievalService: SuspendedContextRetrievalService()
        )
        appState.answerProviderModeOverride = .deepSeekPrimary
        let delayProvider = MockDelayProvider()
        delayProvider.sleepDuration = 60_000_000_000
        delayProvider.setSleepDuration(1_000_000, forRequestedNanoseconds: 1_500_000_000)
        appState.delayProvider = delayProvider
        var settings = appState.settings
        settings.audioCaptureMode = .microphoneOnly
        appState.saveSettings(settings)

        let session = try makeContextBoundSession(appState, suffix: "corrected-project")
        defer { appState.cancelActiveGenerationForContextChange() }
        appState.currentSession = session
        appState.liveState = .listening
        appState.currentCaptureRuntimeState = .listening

        let segment = TranscriptSegment(
            id: "short-project-question-segment",
            sessionID: session.id,
            source: .systemAudio,
            speaker: .interviewer,
            text: "Could you walk me through your LeoRover project",
            recognitionIsFinal: true
        )

        await appState.handleTranscriptSegment(segment)
        try await waitForSuggestion(appState, timeout: 5.0)

        let question = try #require(appState.lastDetectedQuestion)
        let card = try #require(appState.currentSuggestion)
        #expect(question.shouldTrigger)
        #expect(question.questionComplete)
        #expect(question.questionText == "Could you walk me through your LeoRover project")
        #expect(question.answerStrategy == .projectWalkthrough)
        #expect(card.sayFirstSource == "local_first_answer_fallback")
        #expect(card.contextIsolationStatus == "matched")
        #expect(!card.candidateEvidenceIDs.isEmpty)
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
            contextRetrievalService: SuspendedContextRetrievalService()
        )
        appState.answerProviderModeOverride = .deepSeekPrimary
        let delayProvider = MockDelayProvider()
        delayProvider.sleepDuration = 60_000_000_000
        delayProvider.setSleepDuration(1_000_000, forRequestedNanoseconds: 1_500_000_000)
        appState.delayProvider = delayProvider
        var settings = appState.settings
        settings.audioCaptureMode = .microphoneOnly
        appState.saveSettings(settings)

        let session = try makeContextBoundSession(appState, suffix: "automatic-fallback")
        defer { appState.cancelActiveGenerationForContextChange() }
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
        try await waitForSuggestion(appState, timeout: 5.0)

        let card = try #require(appState.currentSuggestion)
        #expect(appState.lastDetectedQuestion?.questionText == "Why do you want this role?")
        #expect(card.sayFirstSource == "local_first_answer_fallback")
        #expect(card.sayFirst.localizedCaseInsensitiveContains("role"))
        #expect(card.sayFirst.localizedCaseInsensitiveContains("robotics"))
        #expect(card.contextIsolationStatus == "matched")
        #expect(!card.candidateEvidenceIDs.isEmpty)
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
            contextRetrievalService: SuspendedContextRetrievalService()
        )
        appState.answerProviderModeOverride = .deepSeekPrimary
        let delayProvider = MockDelayProvider()
        delayProvider.sleepDuration = 60_000_000_000
        delayProvider.setSleepDuration(1_000_000, forRequestedNanoseconds: 1_500_000_000)
        appState.delayProvider = delayProvider

        let session = try makeContextBoundSession(appState, suffix: "slow-retrieval")
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
        defer {
            generationTask.cancel()
            appState.cancelActiveGenerationForContextChange()
        }

        try await waitForSuggestion(appState, timeout: 5.0)

        let card = try #require(appState.currentSuggestion)
        #expect(card.sayFirst.localizedCaseInsensitiveContains("role"))
        #expect(card.sayFirst.localizedCaseInsensitiveContains("robotics"))
        #expect(card.sayFirstSource == "local_first_answer_fallback")
        #expect(card.providerName == "Local First Answer Fallback")
        #expect(!card.keyPoints.isEmpty)
        #expect(card.contextIsolationStatus == "matched")
        #expect(!card.candidateEvidenceIDs.isEmpty)
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
                    userInfo: [
                        NSLocalizedDescriptionKey: """
                        Timed out waiting for first answer fallback. detection=\(appState.lastQuestionDetectionResult) \
                        skip=\(appState.lastDetectionSkipReason) question=\(appState.lastDetectedQuestion?.questionText ?? "nil") \
                        live=\(appState.liveState.displayName) provider=\(appState.selectedAnswerProviderMode.rawValue) \
                        generation=\(appState.generationUIState.displayName) alignment=\(appState.lastAlignmentError) \
                        fallbackWatchdog=\(appState.fallbackWatchdogActive) activeTasks=\(appState.activeTaskSummary)
                        """
                    ]
                )
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func makeContextBoundSession(_ appState: AppState, suffix: String) throws -> InterviewSession {
        let profileID = "first-answer-profile-\(suffix)"
        let evidence = [
            makeEvidence(
                id: "\(suffix)-project",
                statement: "My LeoRover project was an autonomous object retrieval robot using ROS2, YOLOv8 perception, navigation, target localisation, and manipulation on a real robot.",
                type: .project
            ),
            makeEvidence(
                id: "\(suffix)-role",
                statement: "I want this role because it connects my robotics, AI, perception, and real-world deployment experience with the team's product direction.",
                type: .goal
            ),
            makeEvidence(
                id: "\(suffix)-integration",
                statement: "I integrated robot perception, localisation, navigation, and manipulation through ROS2.",
                type: .experience
            ),
            makeEvidence(
                id: "\(suffix)-result",
                statement: "The LeoRover project result was a complete perception-to-action pipeline on a real robot, and I learned that localisation and timing made integration the main reliability challenge.",
                type: .project
            )
        ]
        let profile = CandidateProfile(
            id: profileID,
            displayName: "Synthetic First Answer Candidate",
            sourceDocumentIDs: ["first-answer-fixture"],
            education: [],
            experience: [evidence[2]],
            projects: [evidence[0], evidence[3]],
            skills: [],
            publications: [],
            achievements: [],
            declaredGaps: [],
            goals: [evidence[1]],
            generatedSummary: nil,
            version: 1,
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        try appState.interviewContextRepository.saveCandidateProfile(profile)
        appState.refreshAll()
        appState.selectCandidateProfile(profileID)
        appState.selectInterviewDomain(.roboticsResearch)
        return try appState.createContextBoundSession(mode: .microphone, title: "First Answer Fallback")
    }

    private func makeEvidence(id: String, statement: String, type: EvidenceType) -> ProfileEvidence {
        ProfileEvidence(
            id: id,
            statement: statement,
            sourceDocumentID: "first-answer-fixture",
            sourceChunkID: "chunk-\(id)",
            sourceSpan: statement,
            confidence: 1,
            evidenceType: type,
            explicitness: .explicit
        )
    }
}

private final class SuspendedContextRetrievalService: ContextRetrievalService {
    func retrieveContextWithTrace(
        question: String,
        intent: QuestionIntent,
        maxCVWords: Int,
        maxJDWords: Int,
        strategy: AnswerStrategy?
    ) async throws -> (context: RetrievedContext, trace: RetrievalTrace) {
        try await Task.sleep(nanoseconds: UInt64.max)
        throw CancellationError()
    }
}
