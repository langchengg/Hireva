import Foundation
import Testing
@testable import Hireva

@Suite(.serialized)
@MainActor
struct ReleaseValidationTests {
    @Test
    func realDeepSeekSequentialAnswerQualityPersistsFiveQuestions() async throws {
        guard TestSupport.realAppDatabaseTestsEnabled else {
            print("Skipping realDeepSeekSequentialAnswerQualityPersistsFiveQuestions: set REAL_APP_DB_TESTS=1 to allow real provider/keychain access.")
            return
        }

        let keychain = KeychainService()
        guard let apiKey = try keychain.loadAPIKey(account: KeychainConstants.deepSeekAccount),
              !apiKey.isEmpty else {
            print("Skipping realDeepSeekSequentialAnswerQualityPersistsFiveQuestions: DeepSeek API key is not configured in Keychain.")
            return
        }

        let traceURL = URL(fileURLWithPath: "/tmp/Hireva_release_answer_quality_trace.jsonl")
        try? FileManager.default.removeItem(at: traceURL)
        let appState = try makeRealReleaseValidationAppState(
            keychain: keychain,
            traceURL: traceURL,
            prefix: "ReleaseAnswerQuality"
        )
        let provider = try #require(appState.activeRealtimeProvider)
        let documents = try appState.documentRepository.documents()
        let chunkCounts = try contextChunkCounts(appState.documentRepository)
        print("Credential source: Keychain; non-empty credential available: \(!apiKey.isEmpty); selected provider: \(provider.name); model: \(provider.model); base URL: \(provider.baseURL)")
        print("Context metadata: documents=\(documents.count); cvDocuments=\(documents.filter { $0.type == .cv }.count); jobDescriptionDocuments=\(documents.filter { $0.type == .jobDescription }.count); additionalNotesDocuments=\(documents.filter { $0.type == .additionalNotes }.count); cvChunks=\(chunkCounts.cv); jobDescriptionChunks=\(chunkCounts.jd); additionalNotesChunks=\(chunkCounts.notes)")

        let session = try appState.sessionRepository.createSession(mode: .microphone, title: "Release answer quality validation")
        appState.currentSession = session
        appState.liveState = .listening
        appState.currentCaptureRuntimeState = .listening

        let cases = [
            ReleaseAnswerQualityCase(
                id: "architecture",
                question: "How did your robotics system connect YOLOv8 detection with localization, navigation, manipulation, and recovery behaviors?",
                requiredThemeGroups: [
                    ["yolov8", "yolo", "detection", "detector"],
                    ["localization", "localisation", "localize", "localise"],
                    ["navigation", "navigate"],
                    ["manipulation", "manipulator", "grasp", "pick"],
                    ["recovery", "recover", "fallback", "retry"]
                ],
                forbiddenThemeGroups: [
                    ["engineering team", "questions i would ask", "ask the team"],
                    ["droid", "mujoco", "franka", "diffusion"]
                ]
            ),
            ReleaseAnswerQualityCase(
                id: "real-world-execution",
                question: "What made real-world execution on the LeoRover harder than a clean simulation or demo environment?",
                requiredThemeGroups: [
                    ["real world", "real-world", "physical robot", "real robot"],
                    ["simulation", "demo"],
                    ["lighting", "calibration", "noise", "occlusion", "latency", "timing"],
                    ["recovery", "robust", "reliable", "failure"]
                ],
                forbiddenThemeGroups: [
                    ["engineering team", "questions i would ask"]
                ]
            ),
            ReleaseAnswerQualityCase(
                id: "droid-mujoco",
                question: "How did you convert real robot demonstrations from DROID into actions that your MuJoCo Franka simulation could use?",
                requiredThemeGroups: [
                    ["droid"],
                    ["mujoco"],
                    ["franka"],
                    ["action", "actions", "trajectory", "trajectories"],
                    ["mapping", "mapped", "convert", "converted", "coordinate", "timing"]
                ],
                forbiddenThemeGroups: [
                    ["engineering team", "questions i would ask"],
                    ["yolov8", "leorover recovery"]
                ]
            ),
            ReleaseAnswerQualityCase(
                id: "vla-vs-leorover",
                question: "Can you explain the difference between your VLA project and your LeoRover project?",
                requiredThemeGroups: [
                    ["vla"],
                    ["leorover", "leo rover"],
                    ["mujoco", "franka", "simulation"],
                    ["ros2", "yolov8", "navigation", "real robot", "real-world"],
                    ["difference", "whereas", "while", "versus", "compared"]
                ],
                forbiddenThemeGroups: [
                    ["engineering team", "questions i would ask"]
                ]
            ),
            ReleaseAnswerQualityCase(
                id: "team-fit-questions",
                question: "What would you ask the engineering team to understand whether this robotics role is a good fit?",
                requiredThemeGroups: [
                    ["success", "first three months", "first 3 months", "expectations"],
                    ["deployment", "real-world", "production", "field"],
                    ["team", "responsibilities", "ownership", "structured"],
                    ["data", "simulation", "infrastructure", "workflow"]
                ],
                forbiddenThemeGroups: [
                    ["my leover system", "my leorover system connected"],
                    ["droid", "mujoco", "franka"]
                ]
            )
        ]

        var observedQuestionIDs: [String] = []
        var observedGenerationIDs: [String] = []
        for (index, item) in cases.enumerated() {
            await appState.handleTranscriptSegment(systemAudioSegment(
                id: "release-quality-\(item.id)",
                sessionID: session.id,
                text: item.question,
                recognitionTaskID: "release-quality-task-\(index + 1)",
                sequence: index + 1
            ))

            try await waitUntil(timeout: 120.0, label: "\(item.id) answer complete") {
                appState.generationUIState.isTerminal &&
                    questionKey(appState.visibleAssistantRenderState.questionText) == questionKey(item.question) &&
                    appState.visibleAssistantRenderState.hasAnswerText &&
                    appState.visibleAssistantRenderState.keyPoints.isEmpty == false &&
                    appState.visibleAssistantRenderState.generationErrorText == nil
            }

            let questionID = try #require(appState.currentSuggestion?.detectedQuestionID)
            let generationID = try #require(appState.currentSuggestion?.generationID)
            observedQuestionIDs.append(questionID)
            observedGenerationIDs.append(generationID)
            let render = appState.visibleAssistantRenderState
            let card = try #require(appState.currentSuggestion)
            try assertAnswerQuality(
                item,
                render: render,
                card: card,
                expectedQuestionID: questionID,
                expectedGenerationID: generationID
            )

            for mode in FloatingAssistantDisplayMode.allCases {
                var modeSettings = appState.settings
                modeSettings.floatingAssistantDisplayMode = mode
                appState.saveSettings(modeSettings)
                let modeRender = appState.visibleAssistantRenderState
                #expect(questionKey(modeRender.questionText) == questionKey(item.question))
                #expect(modeRender.hasAnswerText)
                #expect(modeRender.keyPoints.isEmpty == false)
            }

            try await waitUntil(timeout: 10.0, label: "\(item.id) persistence") {
                (try? appState.suggestionRepository.suggestions(sessionID: session.id)
                    .filter { $0.detectedQuestionID == questionID }
                    .count == 1) == true
            }
            let rows = try appState.suggestionRepository.suggestions(sessionID: session.id)
            #expect(rows.count == index + 1)
            #expect(rows.filter { $0.detectedQuestionID == questionID }.count == 1)
            #expect(Set(rows.map(\.id)).count == rows.count)
        }

        let rows = try appState.suggestionRepository.suggestions(sessionID: session.id)
        #expect(rows.count == cases.count)
        #expect(Set(rows.compactMap(\.detectedQuestionID)).count == cases.count)
        #expect(Set(rows.compactMap(\.generationID)).isSuperset(of: Set(observedGenerationIDs)))
        #expect(rows.map { questionKey($0.questionText ?? "") } == cases.map { questionKey($0.question) })
        #expect(Set(observedQuestionIDs).count == cases.count)

        let trace = try String(contentsOf: traceURL, encoding: .utf8)
        for ((item, questionID), generationID) in zip(zip(cases, observedQuestionIDs), observedGenerationIDs) {
            try assertTraceContainsEventsInOrder(
                [
                    "question.accepted",
                    "answer.request.started",
                    "answer.ui.rendered",
                    "answer.stream.completed"
                ],
                trace: trace,
                questionID: questionID,
                generationID: generationID
            )
            #expect(trace.contains(questionKey(item.question)))
        }
    }

    @Test
    func realDeepSeekSystemAudioStreamingLatestQuestionOwnsUI() async throws {
        guard TestSupport.realAppDatabaseTestsEnabled else {
            print("Skipping realDeepSeekSystemAudioStreamingLatestQuestionOwnsUI: set REAL_APP_DB_TESTS=1 to allow real provider/keychain access.")
            return
        }

        let keychain = KeychainService()
        guard let apiKey = try keychain.loadAPIKey(account: KeychainConstants.deepSeekAccount),
              !apiKey.isEmpty else {
            print("Skipping realDeepSeekSystemAudioStreamingLatestQuestionOwnsUI: DeepSeek API key is not configured in Keychain.")
            return
        }

        let traceURL = URL(fileURLWithPath: "/tmp/Hireva_release_real_streaming_trace.jsonl")
        try? FileManager.default.removeItem(at: traceURL)
        let appState = try makeRealReleaseValidationAppState(
            keychain: keychain,
            traceURL: traceURL,
            prefix: "ReleaseRealStreaming"
        )
        let provider = try #require(appState.activeRealtimeProvider)
        let documents = try appState.documentRepository.documents()
        let chunkCounts = try contextChunkCounts(appState.documentRepository)
        print("Credential source: Keychain; non-empty credential available: \(!apiKey.isEmpty); selected provider: \(provider.name); model: \(provider.model); base URL: \(provider.baseURL)")
        print("Context metadata: documents=\(documents.count); cvDocuments=\(documents.filter { $0.type == .cv }.count); jobDescriptionDocuments=\(documents.filter { $0.type == .jobDescription }.count); additionalNotesDocuments=\(documents.filter { $0.type == .additionalNotes }.count); cvChunks=\(chunkCounts.cv); jobDescriptionChunks=\(chunkCounts.jd); additionalNotesChunks=\(chunkCounts.notes)")

        let session = try appState.sessionRepository.createSession(mode: .microphone, title: "Release real streaming validation")
        appState.currentSession = session
        appState.liveState = .listening
        appState.currentCaptureRuntimeState = .listening

        let firstQuestion = "If your YOLOv8 detector confidently picks the wrong object on the robot, how would you debug it?"
        let secondQuestion = "What would you ask the engineering team to understand whether this robotics role is a good fit?"

        await appState.handleTranscriptSegment(systemAudioSegment(
            id: "release-real-stream-q1",
            sessionID: session.id,
            text: firstQuestion,
            recognitionTaskID: "release-real-stream-task-1",
            sequence: 1
        ))

        try await waitUntil(timeout: 30.0, label: "first real request started") {
            appState.activeGenerationID != nil &&
                appState.activeQuestionID != nil &&
                appState.lastDetectedQuestion != nil &&
                appState.recentTranscriptRuntimeEvents.contains {
                    $0.name == "answer.request.started" &&
                        $0.generationID == appState.activeGenerationID &&
                        $0.questionID == appState.activeQuestionID
                }
        }
        let firstGenerationID = try #require(appState.activeGenerationID)

        await appState.handleTranscriptSegment(systemAudioSegment(
            id: "release-real-stream-q2",
            sessionID: session.id,
            text: secondQuestion,
            recognitionTaskID: "release-real-stream-task-2",
            sequence: 2
        ))

        try await waitUntil(timeout: 30.0, label: "second question active") {
            questionKey(appState.lastDetectedQuestion?.questionText ?? "") == questionKey(secondQuestion) &&
                appState.activeQuestionID == appState.lastDetectedQuestion?.id &&
                appState.activeGenerationID != nil &&
                appState.activeGenerationID != firstGenerationID &&
                appState.cancelledGenerationCount >= 1
        }
        let secondQuestionID = try #require(appState.activeQuestionID)
        let secondGenerationID = try #require(appState.activeGenerationID)

        try await waitUntil(timeout: 60.0, label: "second real first token visible") {
            let trace = (try? String(contentsOf: traceURL, encoding: .utf8)) ?? ""
            return trace.contains("\"event_type\":\"answer.first_token\"") &&
                trace.contains("\"question_id\":\"\(secondQuestionID)\"") &&
                trace.contains("\"generation_id\":\"\(secondGenerationID)\"") &&
                questionKey(appState.visibleAssistantRenderState.questionText) == questionKey(secondQuestion) &&
                appState.visibleAssistantRenderState.hasAnswerText
        }

        let traceAtFirstVisible = try String(contentsOf: traceURL, encoding: .utf8)
        #expect(traceAtFirstVisible.range(of: "\"event_type\":\"answer.first_token\"") != nil)
        #expect(traceAtFirstVisible.range(of: "\"event_type\":\"answer.ui.rendered\"") != nil)

        try await waitUntil(timeout: 90.0, label: "second real answer complete") {
            let render = appState.visibleAssistantRenderState
            return appState.currentSuggestion?.detectedQuestionID == secondQuestionID &&
                appState.currentSuggestion?.generationID == secondGenerationID &&
                questionKey(render.questionText) == questionKey(secondQuestion) &&
                render.keyPoints.isEmpty == false &&
                render.generationErrorText == nil &&
                appState.generationUIState.isTerminal
        }

        let finalRender = appState.visibleAssistantRenderState
        #expect(questionKey(finalRender.questionText) == questionKey(secondQuestion))
        #expect(finalRender.answerText.localizedCaseInsensitiveContains("requires an API key") == false)
        #expect(finalRender.answerText.localizedCaseInsensitiveContains("request timed out") == false)
        #expect(finalRender.generationErrorText == nil)
        #expect(appState.currentSuggestion?.detectedQuestionID == secondQuestionID)
        #expect(appState.currentSuggestion?.generationID == secondGenerationID)
        #expect(QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: finalRender.questionText,
            answerText: finalRender.answerText,
            sayFirst: appState.currentSuggestion?.sayFirst ?? finalRender.answerText,
            stageBCompleted: true
        ).verdict != .mismatched)

        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(questionKey(appState.visibleAssistantRenderState.questionText) == questionKey(secondQuestion))
        #expect(appState.currentSuggestion?.generationID == secondGenerationID)
        for mode in FloatingAssistantDisplayMode.allCases {
            var modeSettings = appState.settings
            modeSettings.floatingAssistantDisplayMode = mode
            appState.saveSettings(modeSettings)
            let render = appState.visibleAssistantRenderState
            #expect(questionKey(render.questionText) == questionKey(secondQuestion))
            #expect(render.hasAnswerText)
            #expect(render.keyPoints.isEmpty == false)
        }
        let rows = try appState.suggestionRepository.suggestions(sessionID: session.id)
        let rowIDs = rows.compactMap(\.detectedQuestionID)
        #expect(rowIDs.filter { $0 == secondQuestionID }.count == 1)
        #expect(Set(rows.map(\.id)).count == rows.count)

        let trace = try String(contentsOf: traceURL, encoding: .utf8)
        try assertTraceContainsEventsInOrder(
            [
                "question.accepted",
                "answer.request.started",
                "answer.first_token",
                "answer.ui.rendered",
                "answer.stream.completed"
            ],
            trace: trace,
            questionID: secondQuestionID,
            generationID: secondGenerationID
        )
        #expect(trace.contains("\"generation_id\":\"\(firstGenerationID)\""))
        #expect(trace.contains("\"event_type\":\"cancelledGenerationPersistenceRejected\""))
    }

    @Test
    func temporaryDatabasePersistsSnapshotsReloadsAndUpsertsCompletedAnswer() async throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "ReleasePersistence")
        let settingsRepository = try configuredSettingsRepository(database)
        let client = ReleaseValidationMockLLMClient()
        client.stageAStreamDelayByNeedle["engineering team"] = 5_000_000_000
        let router = LLMRouter(settingsRepository: settingsRepository, clients: [.deepSeek: client])
        let appState = AppState(
            database: database,
            llmRouter: router,
            contextRetrievalService: ReleaseValidationEmptyContextRetrievalService()
        )
        appState.detectionDebounceSeconds = 0.01
        appState.generationFullCardWatchdogNanoseconds = 60_000_000_000
        var settings = appState.settings
        settings.audioCaptureMode = .systemAudioOnly
        settings.allowQuestionDetectionFromMicrophoneOnly = false
        settings.automaticQuestionDetectionEnabled = true
        appState.saveSettings(settings)

        let session = try appState.sessionRepository.createSession(mode: .microphone, title: "Release persistence validation")
        appState.currentSession = session
        appState.liveState = .listening
        appState.currentCaptureRuntimeState = .listening

        let questionA = "What would you ask the engineering team to understand whether this role is a good fit?"
        let questionB = "If you had one more month to improve your LeoRover system, what would you improve first?"

        await appState.handleTranscriptSegment(systemAudioSegment(
            id: "release-db-q1",
            sessionID: session.id,
            text: questionA,
            recognitionTaskID: "release-db-task-1",
            sequence: 1
        ))
        try await waitUntil(timeout: 8.0, label: "question A active") {
            appState.activeQuestionID != nil &&
                appState.currentSuggestion?.questionText == questionA
        }

        await appState.handleTranscriptSegment(systemAudioSegment(
            id: "release-db-q2",
            sessionID: session.id,
            text: questionB,
            recognitionTaskID: "release-db-task-2",
            sequence: 2
        ))

        try await waitUntil(timeout: 120.0, label: "A and B persisted") {
            let rows = (try? appState.suggestionRepository.suggestions(sessionID: session.id)) ?? []
            return rows.count == 2 &&
                rows.map(\.questionText) == [questionA, questionB] &&
                appState.currentSuggestion?.questionText == questionB &&
                appState.generationUIState.isTerminal
        }

        let initialRows = try appState.suggestionRepository.suggestions(sessionID: session.id)
        #expect(initialRows.count == 2)
        #expect(initialRows.map(\.questionText) == [questionA, questionB])
        #expect(Set(initialRows.compactMap(\.detectedQuestionID)).count == 2)
        #expect(initialRows[0].stageBStatus == "queued_next_question")
        let localSnapshotSources: Set<String> = [
            "rag_template_soft_fallback",
            "local_first_answer_fallback",
            "local_superseded_question_snapshot",
            "local_semantic_stage_b_fallback",
            "local_incomplete_stream_fallback",
            "semantic_intent_fallback"
        ]
        #expect(localSnapshotSources.contains(initialRows[0].finalVisibleSource ?? ""))
        #expect(initialRows[0].finalVisibleSource != "deepseek_stream")
        #expect(initialRows[0].stageBCompleted == false)
        #expect(initialRows[0].sayFirst.isEmpty == false)
        #expect(initialRows[1].finalVisibleSource == "deepseek_stream")
        #expect(appState.currentSuggestion?.questionText == questionB)

        let reloadedAppState = AppState(
            database: database,
            llmRouter: router,
            contextRetrievalService: ReleaseValidationEmptyContextRetrievalService()
        )
        reloadedAppState.currentSession = session
        reloadedAppState.refreshLiveSuggestionHistory(sessionID: session.id, latestQuestion: questionB)
        #expect(reloadedAppState.liveSuggestionHistory.map(\.questionText) == [questionA, questionB])

        await appState.handleTranscriptSegment(systemAudioSegment(
            id: "release-db-cumulative-replay",
            sessionID: session.id,
            text: [questionA, questionB].joined(separator: " "),
            recognitionTaskID: "release-db-task-2",
            sequence: 3
        ))
        try await Task.sleep(nanoseconds: 250_000_000)
        #expect((try appState.suggestionRepository.suggestions(sessionID: session.id)).count == 2)

        var completedA = initialRows[0]
        completedA.stageBStatus = "completed"
        completedA.stageBCompleted = true
        completedA.finalVisibleSource = "deepseek_stream"
        completedA.sayFirstSource = "deepseek_stream"
        completedA.sayFirst = "I would ask the engineering team how they define success for deployed robotics work."
        completedA.keyPoints = ["Deployment ownership", "Debugging expectations"]
        completedA.caution = "None"
        try appState.suggestionRepository.saveSuggestionCard(completedA)

        let updatedRows = try appState.suggestionRepository.suggestions(sessionID: session.id)
        #expect(updatedRows.count == 2)
        #expect(updatedRows[0].id == initialRows[0].id)
        #expect(updatedRows[0].stageBStatus == "completed")
        #expect(updatedRows[0].finalVisibleSource == "deepseek_stream")
        #expect(updatedRows[0].keyPoints == ["Deployment ownership", "Debugging expectations"])
    }

    private func configuredSettingsRepository(_ database: AppDatabase) throws -> SettingsRepository {
        let settingsRepository = SettingsRepository(database: database)
        try settingsRepository.ensureDefaultProviderConfigurations()
        if let deepSeek = try settingsRepository.providerConfigurations().first(where: { $0.kind == .deepSeek }) {
            var updated = deepSeek
            updated.isDefaultForRealtime = true
            updated.model = "deepseek-chat"
            try settingsRepository.saveProviderConfiguration(updated)
            try settingsRepository.setActiveRealtimeProvider(id: updated.id)
        }
        return settingsRepository
    }

    private func makeRealReleaseValidationAppState(
        keychain: KeychainService,
        traceURL: URL,
        prefix: String
    ) throws -> AppState {
        let database = try productionDatabaseSnapshotOrEmptyTemporary(prefix: prefix)
        let appState = AppState(database: database, keychainService: keychain)
        appState.runtimeTranscriptTraceLogURL = traceURL
        appState.detectionDebounceSeconds = 0.01
        appState.generationFullCardWatchdogNanoseconds = 60_000_000_000
        appState.stageATimeoutSeconds = 30.0
        appState.lateDeepSeekReplacementWindowSeconds = 60.0
        try appState.settingsRepository.ensureDefaultProviderConfigurations()
        let provider = try appState.settingsRepository.activeRealtimeProvider()
            ?? appState.settingsRepository.providerConfigurations().first(where: { $0.kind == .deepSeek })
        guard let provider, provider.kind == .deepSeek else {
            throw NSError(
                domain: "ReleaseValidationTests",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Active realtime provider is not DeepSeek."]
            )
        }
        try appState.settingsRepository.setActiveRealtimeProvider(id: provider.id)
        appState.activeRealtimeProvider = provider
        var settings = appState.settings
        settings.audioCaptureMode = .systemAudioOnly
        settings.allowQuestionDetectionFromMicrophoneOnly = false
        settings.automaticQuestionDetectionEnabled = true
        appState.saveSettings(settings)
        return appState
    }

    private func productionDatabaseSnapshotOrEmptyTemporary(prefix: String) throws -> AppDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("hireva_snapshot.sqlite")
        let source = AppPaths.databaseURL
        if FileManager.default.fileExists(atPath: source.path) {
            try FileManager.default.copyItem(at: source, to: destination)
            for suffix in ["-wal", "-shm"] {
                let sidecar = URL(fileURLWithPath: source.path + suffix)
                if FileManager.default.fileExists(atPath: sidecar.path) {
                    try? FileManager.default.copyItem(
                        at: sidecar,
                        to: URL(fileURLWithPath: destination.path + suffix)
                    )
                }
            }
            return try AppDatabase(path: destination)
        }
        return try AppDatabase(path: destination)
    }

    private func contextChunkCounts(_ repository: DocumentRepository) throws -> (cv: Int, jd: Int, notes: Int) {
        (
            try repository.chunks(type: .cv).count,
            try repository.chunks(type: .jobDescription).count,
            try repository.chunks(type: .additionalNotes).count
        )
    }

    private func questionKey(_ text: String) -> String {
        SemanticDuplicateKeyBuilder.key(for: text)
    }

    private func assertAnswerQuality(
        _ item: ReleaseAnswerQualityCase,
        render: VisibleAssistantRenderState,
        card: SuggestionCard,
        expectedQuestionID: String,
        expectedGenerationID: String
    ) throws {
        #expect(card.detectedQuestionID == expectedQuestionID)
        #expect(card.generationID == expectedGenerationID)
        #expect(questionKey(render.questionText) == questionKey(item.question))
        #expect(questionKey(card.questionText ?? "") == questionKey(item.question))
        #expect(["completed", "semantic_fallback"].contains(card.stageBStatus ?? ""))
        #expect([
            "deepseek_stream",
            "deepseek_section_stream",
            "rag_template_soft_fallback",
            "semantic_intent_fallback",
            "local_semantic_stage_b_fallback"
        ].contains(card.finalVisibleSource ?? ""))
        #expect(card.keyPoints.isEmpty == false)
        #expect(render.generationErrorText == nil)
        #expect(render.answerText.localizedCaseInsensitiveContains("requires an API key") == false)
        #expect(render.answerText.localizedCaseInsensitiveContains("request timed out") == false)

        let visibleAnswer = ([card.sayFirst] + card.keyPoints + [render.answerText])
            .joined(separator: " ")
            .lowercased()
        let missingGroups = item.requiredThemeGroups.filter { group in
            !group.contains { visibleAnswer.contains($0.lowercased()) }
        }
        let forbiddenMatches = item.forbiddenThemeGroups.flatMap { group in
            group.filter { visibleAnswer.contains($0.lowercased()) }
        }
        #expect(missingGroups.isEmpty, "Missing required answer themes for \(item.id): \(missingGroups)")
        #expect(forbiddenMatches.isEmpty, "Forbidden cross-question themes for \(item.id): \(forbiddenMatches)")

        let alignment = QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: item.question,
            answerText: render.answerText,
            sayFirst: card.sayFirst,
            stageBCompleted: true
        )
        #expect(alignment.verdict != .mismatched, "Alignment mismatch for \(item.id): \(alignment.reason)")
    }

    private func systemAudioSegment(
        id: String,
        sessionID: String,
        text: String,
        recognitionTaskID: String,
        sequence: Int
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            sessionID: sessionID,
            source: .systemAudio,
            speaker: .interviewer,
            text: text,
            createdAt: Date(),
            confidence: 1.0,
            asrFinalizationReason: "final_accepted",
            recognitionTaskID: recognitionTaskID,
            recognitionEventSequence: sequence,
            sourceTextStartUTF16: 0,
            sourceTextEndUTF16: text.utf16.count,
            recognitionIsFinal: true
        )
    }

    private func waitUntil(
        timeout: TimeInterval,
        label: String,
        predicate: @escaping @MainActor () -> Bool
    ) async throws {
        let start = Date()
        while !predicate() {
            if Date().timeIntervalSince(start) > timeout {
                throw NSError(
                    domain: "ReleaseValidationTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for \(label)."]
                )
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func assertTraceContainsEventsInOrder(
        _ events: [String],
        trace: String,
        questionID: String,
        generationID: String
    ) throws {
        var searchStart = trace.startIndex
        for event in events {
            let eventNeedle = "\"event_type\":\"\(event)\""
            var matchingEventRange: Range<String.Index>?
            var matchingLine = ""
            var scanStart = searchStart
            while let eventRange = trace.range(of: eventNeedle, range: scanStart..<trace.endIndex) {
                let lineStart = trace[..<eventRange.lowerBound].lastIndex(of: "\n").map { trace.index(after: $0) } ?? trace.startIndex
                let lineEnd = trace[eventRange.upperBound...].firstIndex(of: "\n") ?? trace.endIndex
                let line = String(trace[lineStart..<lineEnd])
                let generationMatches = event == "question.accepted" || line.contains("\"generation_id\":\"\(generationID)\"")
                if line.contains("\"question_id\":\"\(questionID)\""), generationMatches {
                    matchingEventRange = eventRange
                    matchingLine = line
                    break
                }
                scanStart = eventRange.upperBound
            }
            guard let eventRange = matchingEventRange else {
                throw NSError(
                    domain: "ReleaseValidationTests",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Missing trace event in order: \(event)."]
                )
            }
            #expect(matchingLine.isEmpty == false)
            searchStart = eventRange.upperBound
        }
    }
}

private final class ReleaseValidationAPIKeyStore: APIKeyStore {
    let key: String

    init(key: String) {
        self.key = key
    }

    func loadAPIKey(account: String) throws -> String? { key }
    func saveAPIKey(_ apiKey: String, account: String) throws {}
    func deleteAPIKey(account: String) throws {}
}

private struct ReleaseValidationEmptyContextRetrievalService: ContextRetrievalService {
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

private final class ReleaseValidationMockLLMClient: LLMClientProtocol, @unchecked Sendable {
    let providerKind: LLMProviderKind = .deepSeek
    var stageAStreamDelayByNeedle = [String: UInt64]()

    func testConnection(configuration: LLMProviderConfiguration) async throws -> LLMConnectionTestResult {
        LLMConnectionTestResult(success: true, message: "OK", latencyMS: 0, models: [])
    }

    func chatCompletion(
        configuration: LLMProviderConfiguration,
        messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions
    ) async throws -> LLMChatResult {
        let prompt = messages.map(\.content).joined(separator: "\n")
        let content = Self.jsonCard(for: prompt)
        return LLMChatResult(
            content: content,
            modelName: "release-validation-mock",
            providerKind: .deepSeek,
            providerName: "DeepSeek",
            baseURL: "",
            latencyMS: 5,
            isLocal: false,
            rawResponse: content
        )
    }

    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] {
        []
    }

    func chatCompletionStream(
        configuration: LLMProviderConfiguration,
        messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions
    ) -> AsyncThrowingStream<String, Error> {
        let prompt = messages.map(\.content).joined(separator: "\n")
        let delay = stageAStreamDelayByNeedle.first { prompt.localizedCaseInsensitiveContains($0.key) }?.value ?? 0
        let text: String
        if prompt.contains("Return plain text sections only") || prompt.contains("Stream the section response now.") {
            text = """
            SAY_FIRST: \(Self.sayFirst(for: prompt))
            KEY_POINTS:
            - Bind the answer to the current accepted question.
            - Keep older accepted questions in history only.
            FOLLOW_UP:
            - I can expand with a concrete example.
            """
        } else {
            text = Self.sayFirst(for: prompt)
        }
        return AsyncThrowingStream { continuation in
            Task {
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay)
                }
                continuation.yield(text)
                continuation.finish()
            }
        }
    }

    private static func jsonCard(for prompt: String) -> String {
        """
        {"strategy":"Release validation","say_first":\(jsonString(sayFirst(for: prompt))),"key_points":["Current question ownership is preserved.","Persistence uses one row per accepted question."],"follow_up_ready":["I can give an example."],"confidence":0.9,"caution":"None","evidence_used":[],"risk_level":"low"}
        """
    }

    private static func sayFirst(for prompt: String) -> String {
        if prompt.localizedCaseInsensitiveContains("engineering team") ||
            prompt.localizedCaseInsensitiveContains("good fit") {
            return "I would ask the engineering team how they define success, ownership, debugging expectations, deployment cadence, and collaboration for robotics work."
        }
        if prompt.localizedCaseInsensitiveContains("one more month") ||
            prompt.localizedCaseInsensitiveContains("improve your LeoRover") {
            return "If I had one more month to improve LeoRover, I would strengthen evaluation, test difficult lighting and occlusion cases, improve perception robustness, and add safer recovery behavior."
        }
        return "I would keep the answer focused on the current interviewer question."
    }

    private static func jsonString(_ value: String) -> String {
        let data = try? JSONEncoder().encode(value)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }
}

private struct ReleaseAnswerQualityCase {
    let id: String
    let question: String
    let requiredThemeGroups: [[String]]
    let forbiddenThemeGroups: [[String]]
}
