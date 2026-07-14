import Foundation
import Testing
@testable import Hireva

@Suite(.serialized)
@MainActor
struct SystemAudioMergedQuestionSegmentationTests {
    // Full `swift test` runs other MainActor-heavy runtime suites concurrently.
    // This is not a latency assertion; the card/content assertions below remain strict.
    private static let runtimeWaitTimeout: TimeInterval = 30.0
    private static let runtimeMergedTranscript = "Hi La IL ask these questions in a mixed order so please treat each one independently first why do you want to join our team now let us switch to your technical project experience why might a diffusion based policy be more stable for robotic manipulation than an auto regressive policy now let us switch to your technical project experience why might a diffusion based policy be more stable for robotic manipulation than an auto regressive policy when you moved from a clean demo to real robot execution which part of the pipeline was most fragile"

    private static let expectedQuestions = [
        "Why do you want to join our team",
        "Why might a diffusion based policy be more stable for robotic manipulation than an auto regressive policy",
        "When you moved from a clean demo to real robot execution which part of the pipeline was most fragile"
    ]
    private static let fourQuestionRuntimeTranscript = [
        "Why might a diffusion based policy be more stable for robotic manipulation than an auto regressive policy",
        "Why might a diffusion based policy be more stable for robotic manipulation than an autoregressive policy",
        "could you explain your Atlas migration project",
        "could you explain your Atlas migration project from end to end when you",
        "when you moved from a clean test to production execution which part of the pipeline was most fragile",
        "why do you want to join our team"
    ].joined(separator: " ")
    private static let expectedFourQuestions = [
        "Why might a diffusion based policy be more stable for robotic manipulation than an auto regressive policy",
        "Could you explain your Atlas migration project from end-to-end",
        "When you moved from a clean test to production execution which part of the pipeline was most fragile",
        "Why do you want to join our team"
    ]
    private static let separateExpectedFourQuestions = [
        "Why might a diffusion based policy be more stable for robotic manipulation than an auto regressive policy",
        "Could you explain your LeoRover project from end-to-end",
        "When you moved from a clean demo to real robot execution which part of the pipeline was most fragile",
        "Why do you want to join our team"
    ]

    @Test
    func mergedRuntimeTranscriptSplitsIntoThreeCleanQuestions() {
        let questions = SystemAudioQuestionExtractor.extract(from: Self.runtimeMergedTranscript)

        let texts = questions.map(\.text)
        #expect(texts.count == 3)
        #expect(Set(texts.map(SemanticDuplicateKeyBuilder.key)).count == 3)
        #expect(texts[0].localizedCaseInsensitiveContains("join our team"))
        #expect(texts[1].localizedCaseInsensitiveContains("diffusion"))
        #expect(texts[1].localizedCaseInsensitiveContains("regressive"))
        #expect(texts[2].localizedCaseInsensitiveContains("real robot execution"))
        #expect(texts[2].localizedCaseInsensitiveContains("pipeline"))
        #expect(texts.allSatisfy { !$0.localizedCaseInsensitiveContains("now let us switch") })
        #expect(questions.last?.intent == .technical)
        #expect(questions.last?.answerStrategy == .technicalExplanation)
        #expect(questions.last.map { AnswerRelevancePolicy.intent(for: $0.text) } == .technicalChallenge)
    }

    @Test
    func alsoIfBoundarySplitsDecoderComparisonAndDetectorDebugging() {
        let transcript = "What did you learn from comparing autoregressive diffusion and flow matching decoders in your Muja Cove project? Also, if your detector gives a confident but wrong prediction, how would you debug it?"

        let questions = SystemAudioQuestionExtractor.extract(from: transcript)

        #expect(questions.count == 2)
        #expect(questions[0].text.localizedCaseInsensitiveContains("autoregressive"))
        #expect(questions[0].text.localizedCaseInsensitiveContains("diffusion"))
        #expect(questions[0].text.localizedCaseInsensitiveContains("flow matching"))
        #expect(questions[1].text.localizedCaseInsensitiveContains("detector"))
        #expect(questions[1].text.localizedCaseInsensitiveContains("confident but wrong"))
        #expect(questions[1].text.localizedCaseInsensitiveContains("debug"))
        #expect(Set(questions.map(\.text)).count == 2)
        #expect(questions.allSatisfy { !$0.text.localizedCaseInsensitiveContains("also") })
    }

    @Test
    func unpunctuatedCoordinatedQuestionPersistsOneDetectionWithoutLocalSnapshot() async throws {
        let (appState, _, session, _) = try makeAppState()
        let question = "How did you validate the forecasting model and how did you guard against leakage?"

        await appState.handleTranscriptSegment(systemAudioSegment(
            id: "unpunctuated-coordinated-question",
            sessionID: session.id,
            text: question
        ))

        try await waitUntil(
            timeout: Self.runtimeWaitTimeout,
            label: "single coordinated question detection"
        ) {
            appState.detectedQuestionsInSessionCount == 1 &&
            ((try? appState.suggestionRepository.questions(sessionID: session.id).count) ?? 0) == 1
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        let detected = try appState.suggestionRepository.questions(sessionID: session.id)
        let cards = try appState.suggestionRepository.suggestions(sessionID: session.id)
        #expect(detected.map(\.questionText) == [question])
        #expect(cards.allSatisfy { $0.finalVisibleSource != "local_merged_question_snapshot" })
    }

    @Test
    func syntheticRuntimeReplaySplitsMergedTranscriptDeterministically() throws {
        let text = Self.latestRuntimeMergedTranscript()

        let questions = SystemAudioQuestionExtractor.extract(from: text)
        let extractedTexts = questions.map(\.text)

        #expect(Self.containsExpectedQuestions(extractedTexts))
        #expect(extractedTexts.joined(separator: " ").localizedCaseInsensitiveContains("why do you want to join our team why do you want") == false)
    }

    @Test
    func mergedTranscriptPersistsAllDetectedQuestionsAndGeneratesLatestAnswer() async throws {
        let (appState, database, session, client) = try makeAppState()

        await appState.handleTranscriptSegment(systemAudioSegment(
            id: "merged-runtime-segment",
            sessionID: session.id,
            text: Self.runtimeMergedTranscript
        ))

        try await waitUntil(
            timeout: Self.runtimeWaitTimeout,
            label: "local extraction of all merged transcript questions",
            stateSnapshot: { stateSnapshot(appState: appState, session: session, client: client) }
        ) {
            appState.detectedQuestionsInSessionCount == 3 &&
            appState.lastTranscriptQuestionGenerationTrace.extractedQuestionCount == 3
        }

        try await waitUntil(
            timeout: Self.runtimeWaitTimeout,
            label: "latest answer for split questions",
            stateSnapshot: { stateSnapshot(appState: appState, session: session, client: client) }
        ) {
            appState.currentSuggestion.map {
                SemanticDuplicateKeyBuilder.areDuplicates($0.questionText ?? "", Self.expectedQuestions.last ?? "")
            } == true &&
            (try? appState.suggestionRepository.suggestions(sessionID: session.id).last).map {
                SemanticDuplicateKeyBuilder.areDuplicates($0.questionText ?? "", Self.expectedQuestions.last ?? "")
            } == true &&
            appState.visibleAnswerExists &&
            !appState.currentSpinnerVisible
        }

        let detected = try appState.suggestionRepository.questions(sessionID: session.id)
        #expect(detected.map { SemanticDuplicateKeyBuilder.key(for: $0.questionText) } == Self.expectedQuestions.map(SemanticDuplicateKeyBuilder.key))
        #expect(SemanticDuplicateKeyBuilder.areDuplicates(appState.lastDetectedQuestionText, Self.expectedQuestions.last ?? ""))
        #expect(SemanticDuplicateKeyBuilder.areDuplicates(appState.currentSuggestion?.questionText ?? "", Self.expectedQuestions.last ?? ""))
        #expect(SemanticDuplicateKeyBuilder.areDuplicates(appState.currentSuggestion?.promptPrimaryQuestion ?? "", Self.expectedQuestions.last ?? ""))
        #expect(appState.currentSuggestion?.sayFirst.localizedCaseInsensitiveContains("perception") == true)
        #expect(appState.currentSuggestion?.sayFirst.localizedCaseInsensitiveContains("localisation") == true)
        #expect(appState.currentSuggestion?.sayFirst.localizedCaseInsensitiveContains("timing") == true)
        #expect(appState.currentSuggestion?.sayFirst.localizedCaseInsensitiveContains("join our team") == false)
        #expect(client.detectionCallCount == 0)

        let persistedDetected = try await database.dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT question_text
                FROM detected_questions
                WHERE session_id = ?
                ORDER BY created_at ASC
                """,
                arguments: [session.id]
            )
        }
        #expect(persistedDetected.map(SemanticDuplicateKeyBuilder.key) == Self.expectedQuestions.map(SemanticDuplicateKeyBuilder.key))
        #expect(persistedDetected.allSatisfy { !$0.localizedCaseInsensitiveContains("why do you want to join our team now let us switch") })
        let persistedSuggestions = try appState.suggestionRepository.suggestions(sessionID: session.id)
        #expect(persistedSuggestions.isEmpty == false)
        #expect(persistedSuggestions.allSatisfy { card in
            detected.contains { SemanticDuplicateKeyBuilder.areDuplicates($0.questionText, card.questionText ?? "") }
        })
        #expect(SemanticDuplicateKeyBuilder.areDuplicates(persistedSuggestions.last?.questionText ?? "", Self.expectedQuestions.last ?? ""))
    }

    @Test
    func fourQuestionRuntimeTranscriptDedupesASRVariantsAndBoundaryContamination() async throws {
        let (appState, database, session, client) = try makeAppState()
        let pureQuestions = SystemAudioQuestionExtractor.extract(from: Self.fourQuestionRuntimeTranscript).map(\.text)
        #expect(
            pureQuestions.map(SemanticDuplicateKeyBuilder.key) ==
                Self.expectedFourQuestions.map(SemanticDuplicateKeyBuilder.key)
        )
        guard pureQuestions.count == Self.expectedFourQuestions.count else { return }

        await appState.handleTranscriptSegment(systemAudioSegment(
            id: "four-question-runtime-segment",
            sessionID: session.id,
            text: Self.fourQuestionRuntimeTranscript
        ))

        try await waitUntil(
            timeout: Self.runtimeWaitTimeout,
            label: "four split detected questions",
            stateSnapshot: { stateSnapshot(appState: appState, session: session, client: client) }
        ) {
            appState.detectedQuestionsInSessionCount == 4 &&
            appState.lastTranscriptQuestionGenerationTrace.extractedQuestionCount == 4
        }

        let detected = try appState.suggestionRepository.questions(sessionID: session.id)
        #expect(detected.map { SemanticDuplicateKeyBuilder.key(for: $0.questionText) } == Self.expectedFourQuestions.map(SemanticDuplicateKeyBuilder.key))
        #expect(detected.map(\.questionText).allSatisfy { !$0.localizedCaseInsensitiveContains("from end to end when you") })
        #expect(detected.map(\.questionText).filter { $0.localizedCaseInsensitiveContains("diffusion") }.count == 1)
        #expect(detected.map(\.questionText).filter { $0.localizedCaseInsensitiveContains("Atlas migration") }.count == 1)

        try await waitUntil(
            timeout: Self.runtimeWaitTimeout,
            label: "latest answer for four split questions",
            stateSnapshot: { stateSnapshot(appState: appState, session: session, client: client) }
        ) {
            appState.currentSuggestion.map {
                SemanticDuplicateKeyBuilder.areDuplicates($0.questionText ?? "", Self.expectedFourQuestions.last ?? "")
            } == true &&
            (try? appState.suggestionRepository.suggestions(sessionID: session.id).last).map {
                SemanticDuplicateKeyBuilder.areDuplicates($0.questionText ?? "", Self.expectedFourQuestions.last ?? "")
            } == true &&
            appState.visibleAnswerExists &&
            !appState.currentSpinnerVisible
        }

        let persisted = try await database.dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT question_text
                FROM detected_questions
                WHERE session_id = ?
                ORDER BY created_at ASC
                """,
                arguments: [session.id]
            )
        }
        #expect(persisted.map(SemanticDuplicateKeyBuilder.key) == Self.expectedFourQuestions.map(SemanticDuplicateKeyBuilder.key))
        #expect(persisted.count == Self.expectedFourQuestions.count)
        #expect(persisted.allSatisfy { !$0.localizedCaseInsensitiveContains("from end to end when you") })
    }

    @Test
    func separateFourQuestionRuntimeSequencePersistsExactlyFourAlignedCards() async throws {
        let (appState, _, session, client) = try makeAppState()
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
            try await waitUntil(
                timeout: Self.runtimeWaitTimeout,
                label: "separate question \(index + 1) answer",
                stateSnapshot: { stateSnapshot(appState: appState, session: session, client: client) }
            ) {
                appState.currentSuggestion.map {
                    SemanticDuplicateKeyBuilder.areDuplicates(
                        $0.questionText ?? "",
                        Self.separateExpectedFourQuestions[index]
                    )
                } == true &&
                appState.visibleAnswerExists &&
                !appState.currentSpinnerVisible &&
                appState.generationUIState.isTerminal
            }
            try await waitUntil(
                timeout: 5.0,
                label: "separate question \(index + 1) persistence"
            ) {
                (try? appState.suggestionRepository.suggestions(sessionID: session.id).count) == index + 1
            }
            let persistedCount = try appState.suggestionRepository.suggestions(sessionID: session.id).count
            #expect(persistedCount == index + 1)
        }

        let cards = try appState.suggestionRepository.suggestions(sessionID: session.id)
        #expect(cards.count == 4)
        #expect(cards.map { SemanticDuplicateKeyBuilder.key(for: $0.questionText ?? "") } == Self.separateExpectedFourQuestions.map(SemanticDuplicateKeyBuilder.key))
        #expect(cards.map { SemanticDuplicateKeyBuilder.key(for: $0.promptPrimaryQuestion ?? "") } == Self.separateExpectedFourQuestions.map(SemanticDuplicateKeyBuilder.key))
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

        try await waitUntil(timeout: Self.runtimeWaitTimeout) {
            appState.detectedQuestionsInSessionCount == 2 &&
            appState.currentSuggestion.map {
                SemanticDuplicateKeyBuilder.areDuplicates(
                    $0.questionText ?? "",
                    "Why might a diffusion policy be more stable for robotic manipulation than an autoregressive policy"
                )
            } == true &&
            (try? appState.suggestionRepository.suggestions(sessionID: session.id).last).map {
                SemanticDuplicateKeyBuilder.areDuplicates(
                    $0.questionText ?? "",
                    "Why might a diffusion based policy be more stable for robotic manipulation than an autoregressive policy"
                )
            } == true &&
            appState.visibleAnswerExists &&
            !appState.currentSpinnerVisible
        }

        let detected = try appState.suggestionRepository.questions(sessionID: session.id)
        #expect(detected.map { SemanticDuplicateKeyBuilder.key(for: $0.questionText) } == [
            "Why do you want to join our team",
            "Why might a diffusion based policy be more stable for robotic manipulation than an autoregressive policy"
        ].map(SemanticDuplicateKeyBuilder.key))
        let persisted = try appState.suggestionRepository.suggestions(sessionID: session.id)
        #expect(persisted.isEmpty == false)
        #expect(persisted.allSatisfy { SemanticDuplicateKeyBuilder.areDuplicates($0.questionText ?? "", detected.last?.questionText ?? "") })
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

        try await waitUntil(timeout: Self.runtimeWaitTimeout) {
            appState.detectedQuestionsInSessionCount == 1 &&
            appState.currentSuggestion?.questionText == expectedCleanQuestion &&
            appState.visibleAnswerExists &&
            !appState.currentSpinnerVisible
        }

        let detected = try appState.suggestionRepository.questions(sessionID: session.id)
        #expect(detected.map(\.questionText) == [expectedCleanQuestion])
        #expect(appState.currentSuggestion?.promptPrimaryQuestion == expectedCleanQuestion)
        #expect(appState.currentSuggestion?.questionText?.localizedCaseInsensitiveContains("now let us switch") == false)
        #expect(client.detectionCallCount == 0)
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
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            contextRetrievalService: MergedQuestionEmptyContextRetrievalService(),
            dialogueDefaults: nil
        )
        appState.answerProviderModeOverride = .deepSeekPrimary
        appState.detectionDebounceSeconds = 0.01
        appState.delayProvider = RealDelayProvider()
        appState.generationFullCardWatchdogNanoseconds = 1_000_000_000

        var settings = appState.settings
        settings.audioCaptureMode = .systemAudioOnly
        settings.automaticQuestionDetectionEnabled = true
        settings.allowQuestionDetectionFromMicrophoneOnly = false
        settings.saveTranscriptsLocally = true
        appState.saveSettings(settings)

        let session = try makeHermeticContextBoundSession(appState: appState, prefix: "merged-question")
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

    nonisolated private func waitUntil(
        timeout: TimeInterval,
        label: String = "merged question segmentation state",
        stateSnapshot: (@MainActor () -> String)? = nil,
        predicate: @escaping @MainActor () -> Bool
    ) async throws {
        let pollIntervalNanoseconds: UInt64 = 25_000_000
        let maxAttempts = max(1, Int(timeout / 0.025))
        var attempts = 0
        while !(await predicate()) {
            attempts += 1
            if attempts > maxAttempts {
                let snapshot = await stateSnapshot?() ?? ""
                let suffix = snapshot.isEmpty ? "" : " State: \(snapshot)"
                throw NSError(
                    domain: "SystemAudioMergedQuestionSegmentationTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for \(label).\(suffix)"]
                )
            }
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
    }

    private func stateSnapshot(
        appState: AppState,
        session: InterviewSession,
        client: MergedQuestionLLMClient
    ) -> String {
        let questionRows = (try? appState.suggestionRepository.questions(sessionID: session.id).count) ?? -1
        let detectedQuestions = (try? appState.suggestionRepository.questions(sessionID: session.id).map(\.questionText)) ?? []
        let suggestions = (try? appState.suggestionRepository.suggestions(sessionID: session.id)) ?? []
        let suggestionRows = suggestions.count
        return [
            "detectedCount=\(appState.detectedQuestionsInSessionCount)",
            "repoQuestions=\(questionRows)",
            "detectedQuestions=\(detectedQuestions.joined(separator: " || "))",
            "repoSuggestions=\(suggestionRows)",
            "suggestionQuestions=\(suggestions.compactMap(\.questionText).joined(separator: " || "))",
            "lastQuestion=\(appState.lastDetectedQuestion?.questionText ?? "nil")",
            "currentQuestion=\(appState.currentSuggestion?.questionText ?? "nil")",
            "currentDetectedID=\(appState.currentSuggestion?.detectedQuestionID ?? "nil")",
            "lastDetectedID=\(appState.lastDetectedQuestion?.id ?? "nil")",
            "visibleAnswerExists=\(appState.visibleAnswerExists)",
            "spinner=\(appState.currentSpinnerVisible)",
            "generationState=\(appState.generationUIState.displayName)",
            "activeGenerationID=\(appState.currentGenerationID ?? "nil")",
            "activeQuestionID=\(appState.activeQuestionID ?? "nil")",
            "pending=\(appState.pendingAcceptedQuestions.map { $0.question.questionText }.joined(separator: " || "))",
            "activeTaskNil=\(appState.activeAITask == nil)",
            "answerCalls=\(client.answerCallCount)",
            "streamCalls=\(client.streamCallCount)",
            "detectionCalls=\(client.detectionCallCount)"
        ].joined(separator: " | ")
    }

    private static func latestRuntimeMergedTranscript() -> String { runtimeMergedTranscript }

    private static func containsExpectedQuestions(_ questions: [String]) -> Bool {
        questions.count == 3 &&
            questions[0].localizedCaseInsensitiveContains("join our team") &&
            questions[1].localizedCaseInsensitiveContains("diffusion") &&
            questions[1].localizedCaseInsensitiveContains("regressive") &&
            questions[2].localizedCaseInsensitiveContains("real robot execution") &&
            questions[2].localizedCaseInsensitiveContains("pipeline")
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
    private var streamCalls = 0

    var detectionCallCount: Int {
        lock.withLock { detectionCalls }
    }

    var answerCallCount: Int {
        lock.withLock { answerCalls }
    }

    var streamCallCount: Int {
        lock.withLock { streamCalls }
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
        lock.withLock { streamCalls += 1 }
        let prompt = messages.map(\.content).joined(separator: "\n")
        let question = currentQuestion(from: prompt)
        let tokens = prompt.contains("Return plain text sections only")
            ? sectionAnswer(for: question)
            : sayFirst(for: question).split(separator: " ").map { String($0) + " " }

        return AsyncThrowingStream { continuation in
            for token in tokens {
                continuation.yield(token)
            }
            continuation.finish()
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
            return "I would say the diffusion policy was more robust than the autoregressive policy because it modelled continuous action distributions more smoothly and recovered better from small trajectory errors."
        }
        if lower.contains("leorover") || lower.contains("leo rover") || lower.contains("project") {
            return "My LeoRover project was an autonomous object retrieval robot where I built the ROS2 perception pipeline around YOLOv8, connected localisation to navigation, and coordinated manipulation. I validated the complete handoff on the real robot so it could pick up the target object reliably."
        }
        if lower.contains("fragile") || lower.contains("real robot execution") || lower.contains("pipeline") {
            return "The most fragile challenge was the integration around noisy perception, localisation stability, and timing between navigation and manipulation. I debugged it with logs and timestamp traces, then tested and validated each handoff during real robot execution."
        }
        if lower.contains("join our team") {
            return "I want to join this team because the role aligns with my experience building reliable deployed robotics systems, and I am motivated to contribute to its engineering responsibilities."
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
