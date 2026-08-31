import Foundation
import Testing
@testable import Hireva

@Suite(.serialized, .sharedRuntimeResources)
@MainActor
struct ReleaseValidationTests {
    @Test
    func syntheticProviderSequentialPipelinePersistsFiveAnswers() async throws {
        try await withDeterministicReleaseValidationAppState(
            prefix: "ReleaseAnswerPipeline"
        ) { appState, client in
        let traceURL = appState.runtimeTranscriptTraceLogURL
        let provider = try #require(appState.activeRealtimeProvider)
        #expect(provider.kind == .deepSeek)
        #expect(provider.name == "DeepSeek")
        #expect(provider.model == "deepseek-v4-flash")

        let session = try makeSyntheticReleaseContextBoundSession(
            appState: appState,
            prefix: "release-answer-pipeline",
            title: "Synthetic release answer pipeline"
        )
        appState.currentSession = session
        appState.liveState = .listening
        appState.currentCaptureRuntimeState = .listening

        let cases = [
            ReleaseAnswerQualityCase(
                id: "architecture",
                question: "How did the synthetic event service connect ingestion, validation, processing, persistence, and recovery?",
                requiredThemeGroups: [
                    ["ingestion", "ingest"],
                    ["validation", "validate"],
                    ["processing", "process"],
                    ["persistence", "persist", "database"],
                    ["recovery", "recover", "fallback", "retry"]
                ],
                forbiddenThemeGroups: [
                    ["engineering team", "questions i would ask", "ask the team"]
                ]
            ),
            ReleaseAnswerQualityCase(
                id: "production-execution",
                question: "What made production execution of the synthetic event service harder than the isolated test environment?",
                requiredThemeGroups: [
                    ["production"],
                    ["test", "isolated"],
                    ["latency", "noisy", "configuration", "timing"],
                    ["rollback", "recovery", "reliable", "failure"]
                ],
                forbiddenThemeGroups: [
                    ["engineering team", "questions i would ask"]
                ]
            ),
            ReleaseAnswerQualityCase(
                id: "event-normalization",
                question: "How did the synthetic service convert incoming events into normalized actions the worker could execute?",
                requiredThemeGroups: [
                    ["incoming", "ingestion"],
                    ["event", "events"],
                    ["normalized", "normalization"],
                    ["action", "actions"],
                    ["worker"],
                    ["mapping", "mapped", "convert", "validation"]
                ],
                forbiddenThemeGroups: [
                    ["engineering team", "questions i would ask"]
                ]
            ),
            ReleaseAnswerQualityCase(
                id: "service-vs-deployment-tool",
                question: "Can you explain the difference between the synthetic event service and the synthetic deployment tool?",
                requiredThemeGroups: [
                    ["event service"],
                    ["deployment tool"],
                    ["ingestion", "processing", "persistence"],
                    ["release", "rollback", "configuration"],
                    ["difference", "whereas", "while", "versus", "compared"]
                ],
                forbiddenThemeGroups: [
                    ["engineering team", "questions i would ask"]
                ]
            ),
            ReleaseAnswerQualityCase(
                id: "team-fit-questions",
                question: "What would you ask the engineering team to understand whether this synthetic reliability role is a good fit?",
                requiredThemeGroups: [
                    ["success", "first three months", "first 3 months", "expectations"],
                    ["deployment", "production", "operations"],
                    ["team", "responsibilities", "ownership", "structured"],
                    ["data", "infrastructure", "workflow"]
                ],
                forbiddenThemeGroups: [
                    ["event service connected", "my synthetic event service"]
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
        try assertMockProviderInvocations(
            client.invocations,
            expectedQuestions: cases.map(\.question)
        )
        for row in rows {
            assertRemoteMockOwnership(row)
        }

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
    }

    @Test
    func syntheticProviderQueuedLatestQuestionOwnsStreamingUI() async throws {
        try await withDeterministicReleaseValidationAppState(
            prefix: "ReleaseLatestQuestion"
        ) { appState, client in
        let traceURL = appState.runtimeTranscriptTraceLogURL
        let provider = try #require(appState.activeRealtimeProvider)
        #expect(provider.kind == .deepSeek)
        #expect(provider.name == "DeepSeek")
        #expect(provider.model == "deepseek-v4-flash")

        let session = try makeSyntheticReleaseContextBoundSession(
            appState: appState,
            prefix: "release-latest-question",
            title: "Synthetic latest-question validation"
        )
        appState.currentSession = session
        appState.liveState = .listening
        appState.currentCaptureRuntimeState = .listening

        let firstQuestion = "If the synthetic service accepts an invalid event, how would you debug it?"
        let secondQuestion = "What would you ask the engineering team to understand whether this synthetic reliability role is a good fit?"
        client.blockNextStageB(containing: "invalid event")
        defer { client.releaseBlockedStageB() }

        await appState.handleTranscriptSegment(systemAudioSegment(
            id: "release-real-stream-q1",
            sessionID: session.id,
            text: firstQuestion,
            recognitionTaskID: "release-real-stream-task-1",
            sequence: 1
        ))

        try await waitUntil(timeout: 30.0, label: "first provider answer visible before queueing") {
            appState.activeGenerationID != nil &&
                appState.activeQuestionID != nil &&
                appState.lastDetectedQuestion != nil &&
                client.blockedStageBStarted &&
                client.invocationCount(kind: .firstAnswerStream, question: firstQuestion) == 1 &&
                client.invocationCount(kind: .fullCardStream, question: firstQuestion) == 1 &&
                appState.currentSuggestion?.detectedQuestionID == appState.activeQuestionID &&
                appState.currentSuggestion?.stageBCompleted == false &&
                appState.currentSuggestion?.finalVisibleSource == AnswerSource.deepseekStream.rawValue &&
                appState.visibleAssistantRenderState.hasAnswerText &&
                appState.recentTranscriptRuntimeEvents.contains {
                    $0.name == "answer.request.started" &&
                        $0.generationID == appState.activeGenerationID &&
                        $0.questionID == appState.activeQuestionID
                }
        }
        let firstQuestionID = try #require(appState.activeQuestionID)
        let firstGenerationID = try #require(appState.activeGenerationID)

        await appState.handleTranscriptSegment(systemAudioSegment(
            id: "release-real-stream-q2",
            sessionID: session.id,
            text: secondQuestion,
            recognitionTaskID: "release-real-stream-task-2",
            sequence: 2
        ))

        try await waitUntil(timeout: 5.0, label: "second question queued behind active generation") {
            guard questionKey(appState.lastDetectedQuestion?.questionText ?? "") == questionKey(secondQuestion),
                  let secondQuestionID = appState.lastDetectedQuestion?.id else {
                return false
            }
            let firstRow = try? appState.suggestionRepository.suggestions(sessionID: session.id)
                .first(where: { $0.detectedQuestionID == firstQuestionID })
            let trace = (try? String(contentsOf: traceURL, encoding: .utf8)) ?? ""
            let queuedEventPersisted = trace.split(separator: "\n").contains {
                $0.contains("\"event_type\":\"questionQueued\"") &&
                    $0.contains("\"question_id\":\"\(secondQuestionID)\"")
            }
            return appState.cancelledGenerationCount == 0 &&
                firstRow?.stageBStatus == "queued_next_question" &&
                firstRow?.stageBCompleted == false &&
                queuedEventPersisted
        }
        let secondQuestionID = try #require(appState.lastDetectedQuestion?.id)

        try await waitUntil(timeout: 30.0, label: "queued second question starts generation") {
            client.invocationCount(kind: .firstAnswerStream, question: secondQuestion) == 1 &&
                appState.recentTranscriptRuntimeEvents.contains {
                    $0.name == "answer.request.started" &&
                        $0.questionID == secondQuestionID &&
                        $0.generationID != nil &&
                        $0.generationID != firstGenerationID
                }
        }
        let secondGenerationID = try #require(
            appState.recentTranscriptRuntimeEvents.last(where: {
                $0.name == "answer.request.started" && $0.questionID == secondQuestionID
            })?.generationID
        )

        try await waitUntil(timeout: 60.0, label: "second synthetic answer visible and traced") {
            let trace = (try? String(contentsOf: traceURL, encoding: .utf8)) ?? ""
            let matchingLines = trace.split(separator: "\n").filter {
                $0.contains("\"question_id\":\"\(secondQuestionID)\"") &&
                    $0.contains("\"generation_id\":\"\(secondGenerationID)\"")
            }
            return matchingLines.contains { $0.contains("\"event_type\":\"answer.first_token\"") } &&
                matchingLines.contains { $0.contains("\"event_type\":\"answer.ui.rendered\"") } &&
                questionKey(appState.visibleAssistantRenderState.questionText) == questionKey(secondQuestion) &&
                appState.visibleAssistantRenderState.hasAnswerText
        }

        let traceAtFirstVisible = try String(contentsOf: traceURL, encoding: .utf8)
        #expect(traceAtFirstVisible.range(of: "\"event_type\":\"answer.first_token\"") != nil)
        #expect(traceAtFirstVisible.range(of: "\"event_type\":\"answer.ui.rendered\"") != nil)

        try await waitUntil(timeout: 90.0, label: "second synthetic answer complete") {
            let render = appState.visibleAssistantRenderState
            return appState.currentSuggestion?.detectedQuestionID == secondQuestionID &&
                appState.currentSuggestion?.generationID == secondGenerationID &&
                questionKey(render.questionText) == questionKey(secondQuestion) &&
                render.keyPoints.isEmpty == false &&
                render.generationErrorText == nil &&
                appState.currentSuggestion?.stageBCompleted == true &&
                appState.currentSuggestion?.stageBStatus == "completed" &&
                client.invocationCount(kind: .fullCardStream, question: secondQuestion) == 1 &&
                appState.generationUIState.isTerminal
        }

        let finalRender = appState.visibleAssistantRenderState
        let finalCard = try #require(appState.currentSuggestion)
        #expect(questionKey(finalRender.questionText) == questionKey(secondQuestion))
        #expect(finalRender.answerText.localizedCaseInsensitiveContains("requires an API key") == false)
        #expect(finalRender.answerText.localizedCaseInsensitiveContains("request timed out") == false)
        #expect(finalRender.generationErrorText == nil)
        #expect(finalCard.detectedQuestionID == secondQuestionID)
        #expect(finalCard.generationID == secondGenerationID)
        #expect(finalCard.stageBCompleted == true)
        #expect(finalCard.stageBStatus == "completed")
        assertRemoteMockOwnership(finalCard)
        #expect(QuestionAnswerAlignmentEvaluator.evaluate(
            questionText: finalRender.questionText,
            answerText: finalRender.answerText,
            sayFirst: finalCard.sayFirst,
            stageBCompleted: true
        ).verdict == .aligned)

        try await waitUntil(timeout: 10.0, label: "both queued answers persisted by mock provider") {
            let rows = (try? appState.suggestionRepository.suggestions(sessionID: session.id)) ?? []
            return rows.count == 2 &&
                rows.first(where: { $0.detectedQuestionID == firstQuestionID })?.stageBStatus == "queued_next_question" &&
                rows.first(where: { $0.detectedQuestionID == secondQuestionID })?.stageBStatus == "completed" &&
                client.invocations.count >= 4
        }
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
        #expect(rows.count == 2)
        let rowIDs = rows.compactMap(\.detectedQuestionID)
        #expect(rowIDs.filter { $0 == secondQuestionID }.count == 1)
        #expect(Set(rows.map(\.id)).count == rows.count)
        let firstRow = try #require(rows.first(where: { $0.detectedQuestionID == firstQuestionID }))
        #expect(firstRow.stageBStatus == "queued_next_question")
        #expect(firstRow.stageBCompleted == false)
        assertRemoteMockOwnership(firstRow)
        let secondRow = try #require(rows.first(where: { $0.detectedQuestionID == secondQuestionID }))
        #expect(secondRow.stageBStatus == "completed")
        #expect(secondRow.stageBCompleted == true)
        assertRemoteMockOwnership(secondRow)
        #expect(appState.cancelledGenerationCount == 0)
        try assertMockProviderInvocations(
            client.invocations,
            expectedQuestions: [firstQuestion, secondQuestion]
        )

        let trace = try String(contentsOf: traceURL, encoding: .utf8)
        try assertTraceContainsEventsInOrder(
            [
                "question.accepted",
                "questionQueued",
                "questionDequeued",
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
        #expect(trace.contains("\"event_type\":\"cancelledGenerationPersistenceRejected\"") == false)
        #expect(trace.contains("\"cancelled\":true") == false)
        #expect(trace.localizedCaseInsensitiveContains("superseded") == false)
        }
    }

    @Test
    func temporaryDatabasePersistsSnapshotsReloadsAndUpsertsCompletedAnswer() async throws {
        try await withReleasePersistenceFixture { database, appState, router, client in
        client.blockNextStageB(containing: "engineering team")
        defer { client.releaseBlockedStageB() }

        let session = try makeHermeticContextBoundSession(
            appState: appState,
            prefix: "release-persistence",
            title: "Release persistence validation"
        )
        appState.currentSession = session
        appState.liveState = .listening
        appState.currentCaptureRuntimeState = .listening

        let questionA = "What would you ask the engineering team to understand whether this role is a good fit?"
        let questionB = "If you had one more month to improve the synthetic event service, what would you improve first?"

        await appState.handleTranscriptSegment(systemAudioSegment(
            id: "release-db-q1",
            sessionID: session.id,
            text: questionA,
            recognitionTaskID: "release-db-task-1",
            sequence: 1
        ))
        try await waitUntil(timeout: 30.0, label: "question A active") {
            appState.activeQuestionID != nil &&
                appState.currentSuggestion?.questionText == questionA &&
                client.blockedStageBStarted
        }

        await appState.handleTranscriptSegment(systemAudioSegment(
            id: "release-db-q2",
            sessionID: session.id,
            text: questionB,
            recognitionTaskID: "release-db-task-2",
            sequence: 2
        ))
        client.releaseBlockedStageB()

        try await waitUntil(timeout: 15.0, label: "A and B persisted") {
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
        #expect(initialRows[0].finalVisibleSource == "deepseek_stream")
        #expect(initialRows[0].isLocal == false)
        #expect(initialRows[0].stageBCompleted == false)
        #expect(initialRows[0].sayFirst.isEmpty == false)
        #expect(initialRows[1].finalVisibleSource == "deepseek_stream")
        #expect(appState.currentSuggestion?.questionText == questionB)

        let reloadedAppState = AppState(
            database: database,
            llmRouter: router,
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            contextRetrievalService: ReleaseValidationEmptyContextRetrievalService(),
            dialogueDefaults: nil
        )
        reloadedAppState.answerProviderModeOverride = .deepSeekPrimary
        reloadedAppState.currentSession = session
        reloadedAppState.refreshLiveSuggestionHistory(sessionID: session.id, latestQuestion: questionB)
        #expect(reloadedAppState.liveSuggestionHistory.map(\.questionText) == [questionA, questionB])
        await reloadedAppState.shutdownForTesting()

        await appState.handleTranscriptSegment(systemAudioSegment(
            id: "release-db-cumulative-replay",
            sessionID: session.id,
            text: [questionA, questionB].joined(separator: " "),
            recognitionTaskID: "release-db-task-2",
            sequence: 3
        ))
        try await waitUntil(timeout: 5.0, label: "cumulative replay rejected without another row") {
            let rowCount = try? appState.suggestionRepository.suggestions(sessionID: session.id).count
            return rowCount == 2 && appState.recentTranscriptRuntimeEvents.contains {
                $0.name == "cumulativeReplayRejected"
            }
        }
        #expect((try appState.suggestionRepository.suggestions(sessionID: session.id)).count == 2)

        var completedA = initialRows[0]
        completedA.stageBStatus = "completed"
        completedA.stageBCompleted = true
        completedA.finalVisibleSource = "deepseek_stream"
        completedA.sayFirstSource = "deepseek_stream"
        completedA.sayFirst = "I would ask the engineering team how they define success for deployed service work."
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
    }

    private func configuredSettingsRepository(_ database: AppDatabase) throws -> SettingsRepository {
        let settingsRepository = SettingsRepository(database: database)
        try settingsRepository.ensureDefaultProviderConfigurations()
        if let deepSeek = try settingsRepository.providerConfigurations().first(where: { $0.kind == .deepSeek }) {
            var updated = deepSeek
            updated.isDefaultForRealtime = true
            try settingsRepository.saveProviderConfiguration(updated)
            try settingsRepository.setActiveRealtimeProvider(id: updated.id)
        }
        return settingsRepository
    }

    private func withDeterministicReleaseValidationAppState(
        prefix: String,
        operation: (AppState, ReleaseValidationMockLLMClient) async throws -> Void
    ) async throws {
        let (appState, client) = try makeDeterministicReleaseValidationAppState(prefix: prefix)
        let database = appState.database
        let directory = try temporaryDatabaseDirectory(database, expectedPrefix: prefix)

        do {
            try await operation(appState, client)
        } catch {
            await appState.shutdownForTesting()
            try? database.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }

        await appState.shutdownForTesting()
        try database.close()
        try FileManager.default.removeItem(at: directory)
    }

    private func withReleasePersistenceFixture(
        operation: (AppDatabase, AppState, LLMRouter, ReleaseValidationMockLLMClient) async throws -> Void
    ) async throws {
        let prefix = "ReleasePersistence"
        let database = try TestSupport.makeTemporaryDatabase(prefix: prefix)
        let directory = try temporaryDatabaseDirectory(database, expectedPrefix: prefix)
        let settingsRepository = try configuredSettingsRepository(database)
        let client = ReleaseValidationMockLLMClient()
        let router = LLMRouter(settingsRepository: settingsRepository, clients: [.deepSeek: client])
        let appState = AppState(
            database: database,
            llmRouter: router,
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            contextRetrievalService: ReleaseValidationEmptyContextRetrievalService(),
            dialogueDefaults: nil
        )
        appState.answerProviderModeOverride = .deepSeekPrimary
        appState.detectionDebounceSeconds = 0.01
        appState.generationFullCardWatchdogNanoseconds = 60_000_000_000
        let delayProvider = MockDelayProvider()
        delayProvider.sleepDuration = 60_000_000_000
        appState.delayProvider = delayProvider
        var settings = appState.settings
        settings.audioCaptureMode = .systemAudioOnly
        settings.allowQuestionDetectionFromMicrophoneOnly = false
        settings.automaticQuestionDetectionEnabled = true
        settings.saveTranscriptsLocally = true
        settings.diagnosticTraceMode = .fullText
        appState.saveSettings(settings)

        do {
            try await operation(database, appState, router, client)
        } catch {
            await appState.shutdownForTesting()
            try? database.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }

        await appState.shutdownForTesting()
        try database.close()
        try FileManager.default.removeItem(at: directory)
    }

    private func temporaryDatabaseDirectory(
        _ database: AppDatabase,
        expectedPrefix: String
    ) throws -> URL {
        let databaseURL = try #require(database.databaseURL)
        let directory = databaseURL.deletingLastPathComponent().standardizedFileURL
        let expectedParent = FileManager.default.temporaryDirectory.standardizedFileURL
        guard directory.deletingLastPathComponent() == expectedParent,
              directory.lastPathComponent.hasPrefix("\(expectedPrefix)-") else {
            throw NSError(
                domain: "ReleaseValidationTests",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Refusing to remove a non-fixture database directory."]
            )
        }
        return directory
    }

    private func makeDeterministicReleaseValidationAppState(
        prefix: String
    ) throws -> (appState: AppState, client: ReleaseValidationMockLLMClient) {
        let database = try TestSupport.makeTemporaryDatabase(prefix: prefix)
        let settingsRepository = try configuredSettingsRepository(database)
        let client = ReleaseValidationMockLLMClient()
        let router = LLMRouter(
            settingsRepository: settingsRepository,
            clients: [.deepSeek: client]
        )
        let appState = AppState(
            database: database,
            llmRouter: router,
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            contextRetrievalService: ReleaseValidationEmptyContextRetrievalService(),
            dialogueDefaults: nil
        )
        appState.answerProviderModeOverride = .deepSeekPrimary
        appState.detectionDebounceSeconds = 0.01
        appState.generationFullCardWatchdogNanoseconds = 60_000_000_000
        appState.stageATimeoutSeconds = 60.0
        appState.lateDeepSeekReplacementWindowSeconds = 60.0
        let delayProvider = MockDelayProvider()
        delayProvider.sleepDuration = 60_000_000_000
        appState.delayProvider = delayProvider
        let provider = try settingsRepository.activeRealtimeProvider()
            ?? settingsRepository.providerConfigurations().first(where: { $0.kind == .deepSeek })
        guard let provider, provider.kind == .deepSeek else {
            throw NSError(
                domain: "ReleaseValidationTests",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Active realtime provider is not DeepSeek."]
            )
        }
        try settingsRepository.setActiveRealtimeProvider(id: provider.id)
        appState.activeRealtimeProvider = provider
        var settings = appState.settings
        settings.audioCaptureMode = .systemAudioOnly
        settings.allowQuestionDetectionFromMicrophoneOnly = false
        settings.automaticQuestionDetectionEnabled = true
        settings.saveTranscriptsLocally = true
        settings.diagnosticTraceMode = .fullText
        appState.saveSettings(settings)
        return (appState, client)
    }

    private func makeSyntheticReleaseContextBoundSession(
        appState: AppState,
        prefix: String,
        title: String
    ) throws -> InterviewSession {
        let documentID = "\(prefix)-synthetic-document"
        let profile = TestSupport.makeCandidateProfile(
            id: "\(prefix)-candidate",
            documentID: documentID,
            statements: [
                "The synthetic candidate built an event service with ingestion, validation, processing, persistence, and recovery stages.",
                "The synthetic candidate normalized incoming events into worker actions through explicit mapping and schema validation.",
                "The synthetic candidate diagnosed production failures using logs, metrics, latency measurements, configuration checks, rollback, and recovery drills.",
                "The synthetic candidate also built a deployment tool for configuration validation, controlled releases, and rollback."
            ]
        )
        let opportunity = TestSupport.makeOpportunityContext(
            id: "\(prefix)-opportunity",
            documentID: documentID,
            statements: [
                "The synthetic reliability role requires evidence-based debugging, reliable production delivery, and clear operational ownership.",
                "The team uses structured workflows for deployment, data quality, infrastructure, and incident recovery."
            ]
        )
        try appState.interviewContextRepository.saveCandidateProfile(profile)
        try appState.interviewContextRepository.saveOpportunityContext(opportunity)
        appState.refreshAll()
        appState.selectCandidateProfile(profile.id)
        appState.selectOpportunityContext(opportunity.id)
        appState.selectInterviewDomain(.general)

        let session = try appState.createContextBoundSession(mode: .microphone, title: title)
        guard let snapshotID = session.contextSnapshotID,
              let snapshot = try appState.interviewContextRepository.snapshot(id: snapshotID),
              snapshot.candidateProfileID == profile.id,
              snapshot.opportunityContextID == opportunity.id,
              snapshot.candidateEvidence.isEmpty == false,
              snapshot.opportunityEvidence.isEmpty == false else {
            throw NSError(
                domain: "ReleaseValidationTests",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Synthetic release context snapshot is incomplete."]
            )
        }
        return session
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
        #expect(card.stageBStatus == "completed")
        #expect(card.stageBCompleted == true)
        assertRemoteMockOwnership(card)
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
        #expect(alignment.verdict == .aligned, "Alignment mismatch for \(item.id): \(alignment.reason)")
    }

    private func assertRemoteMockOwnership(_ card: SuggestionCard) {
        #expect(card.providerKind == .deepSeek)
        #expect(card.providerName == "DeepSeek")
        #expect(card.modelName == "deepseek-v4-flash")
        #expect(card.providerBaseURL == "https://api.deepseek.com")
        #expect(card.isLocal == false)
        #expect(card.sayFirstSource == AnswerSource.deepseekStream.rawValue)
        #expect(card.finalVisibleSource == AnswerSource.deepseekStream.rawValue)
        #expect(card.softFallbackUsed == false)
        #expect(card.fallbackReason == nil)
    }

    private func assertMockProviderInvocations(
        _ invocations: [ReleaseValidationMockInvocation],
        expectedQuestions: [String]
    ) throws {
        #expect(invocations.filter { $0.kind == .completion }.isEmpty)
        #expect(invocations.filter { $0.kind == .firstAnswerStream }.count == expectedQuestions.count)
        #expect(invocations.filter { $0.kind == .fullCardStream }.count == expectedQuestions.count)
        #expect(invocations.count == expectedQuestions.count * 2)

        for question in expectedQuestions {
            let firstAnswerInvocations = invocations.filter {
                $0.kind == .firstAnswerStream && questionKey($0.question) == questionKey(question)
            }
            let fullCardInvocations = invocations.filter {
                $0.kind == .fullCardStream && questionKey($0.question) == questionKey(question)
            }
            #expect(firstAnswerInvocations.count == 1)
            #expect(fullCardInvocations.count == 1)

            for invocation in firstAnswerInvocations + fullCardInvocations {
                #expect(invocation.prompt.contains("CURRENT QUESTION TO ANSWER:"))
                #expect(invocation.prompt.contains(question))
                #expect(invocation.providerKind == .deepSeek)
                #expect(invocation.providerName == "DeepSeek")
                #expect(invocation.model == "deepseek-v4-flash")
            }
        }
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
                let generationMatches = ["question.accepted", "questionQueued", "questionDequeued"].contains(event) ||
                    line.contains("\"generation_id\":\"\(generationID)\"")
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

private enum ReleaseValidationMockInvocationKind: Sendable {
    case completion
    case firstAnswerStream
    case fullCardStream
}

private struct ReleaseValidationMockInvocation: Sendable {
    let kind: ReleaseValidationMockInvocationKind
    let prompt: String
    let question: String
    let providerKind: LLMProviderKind
    let providerName: String
    let model: String
}

private final class ReleaseValidationMockLLMClient: LLMClientProtocol, @unchecked Sendable {
    let providerKind: LLMProviderKind = .deepSeek
    private let blockedStageBGate = ReleaseValidationOneShotAsyncGate()
    private let blockedStageBLock = NSLock()
    private var blockedStageBNeedle: String?
    private var blockedStageBStartedStorage = false
    private let invocationLock = NSLock()
    private var invocationsStorage: [ReleaseValidationMockInvocation] = []

    var blockedStageBStarted: Bool {
        blockedStageBLock.withLock { blockedStageBStartedStorage }
    }

    var invocations: [ReleaseValidationMockInvocation] {
        invocationLock.withLock { invocationsStorage }
    }

    func invocationCount(kind: ReleaseValidationMockInvocationKind, question: String) -> Int {
        invocationLock.withLock {
            invocationsStorage.filter {
                $0.kind == kind && $0.question.caseInsensitiveCompare(question) == .orderedSame
            }.count
        }
    }

    func blockNextStageB(containing needle: String) {
        blockedStageBLock.withLock {
            blockedStageBNeedle = needle
            blockedStageBStartedStorage = false
        }
    }

    func releaseBlockedStageB() {
        blockedStageBGate.open()
    }

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
        recordInvocation(kind: .completion, prompt: prompt, configuration: configuration)
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
        let isStageB = prompt.contains("Return plain text sections only") || prompt.contains("Stream the section response now.")
        recordInvocation(
            kind: isStageB ? .fullCardStream : .firstAnswerStream,
            prompt: prompt,
            configuration: configuration
        )
        let shouldBlockStageB = isStageB && blockedStageBLock.withLock {
            guard let needle = blockedStageBNeedle,
                  prompt.localizedCaseInsensitiveContains(needle) else {
                return false
            }
            blockedStageBNeedle = nil
            blockedStageBStartedStorage = true
            return true
        }
        let text: String
        if isStageB {
            let keyPoints = Self.keyPoints(for: prompt)
            text = """
            SAY_FIRST: \(Self.sayFirst(for: prompt))
            KEY_POINTS:
            - \(keyPoints[0])
            - \(keyPoints[1])
            FOLLOW_UP:
            - I can expand with a concrete example.
            """
        } else {
            text = Self.sayFirst(for: prompt)
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                if shouldBlockStageB {
                    await blockedStageBGate.wait()
                }
                guard !Task.isCancelled else {
                    continuation.finish()
                    return
                }
                continuation.yield(text)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func recordInvocation(
        kind: ReleaseValidationMockInvocationKind,
        prompt: String,
        configuration: LLMProviderConfiguration
    ) {
        let invocation = ReleaseValidationMockInvocation(
            kind: kind,
            prompt: prompt,
            question: Self.currentQuestion(from: prompt),
            providerKind: configuration.kind,
            providerName: configuration.name,
            model: configuration.model
        )
        invocationLock.withLock {
            invocationsStorage.append(invocation)
        }
    }

    private static func jsonCard(for prompt: String) -> String {
        """
        {"strategy":"Release validation","say_first":\(jsonString(sayFirst(for: prompt))),"key_points":["Current question ownership is preserved.","Persistence uses one row per accepted question."],"follow_up_ready":["I can give an example."],"confidence":0.9,"caution":"None","evidence_used":[],"risk_level":"low"}
        """
    }

    private static func sayFirst(for prompt: String) -> String {
        let question = currentQuestion(from: prompt)
        if question.localizedCaseInsensitiveContains("invalid event") ||
            question.localizedCaseInsensitiveContains("debug it") {
            return "I would reproduce the invalid event, inspect ingestion and validation logs, trace its mapping into worker actions, isolate the faulty schema check, and verify the repair with repeatable tests."
        }
        if question.localizedCaseInsensitiveContains("engineering team") ||
            question.localizedCaseInsensitiveContains("good fit") {
            return "How does the engineering team define success in the first three months? Which production deployment constraints shape the workflow? Who owns operational responsibilities? What data and infrastructure boundaries should I understand?"
        }
        if question.localizedCaseInsensitiveContains("one more month") {
            return "With one more month, I would improve the synthetic event service by strengthening production evaluation, exercising noisy-input and latency failures, validating configuration rollback, and adding repeatable recovery drills."
        }
        if question.localizedCaseInsensitiveContains("difference between") &&
            question.localizedCaseInsensitiveContains("deployment tool") {
            return "I would explain that the event service owns ingestion, validation, processing, and persistence, whereas the deployment tool owns configuration checks, controlled releases, and rollback."
        }
        if question.localizedCaseInsensitiveContains("incoming events") ||
            question.localizedCaseInsensitiveContains("normalized actions") {
            return "I converted each incoming event into normalized worker actions through explicit field mapping, then validated the schema and tested deterministic conversion rules."
        }
        if question.localizedCaseInsensitiveContains("production execution") ||
            question.localizedCaseInsensitiveContains("isolated test environment") {
            return "I found production harder than the isolated test environment because noisy inputs, latency, timing, and configuration drift created failures that required reliable rollback and recovery."
        }
        if question.localizedCaseInsensitiveContains("connect ingestion") ||
            question.localizedCaseInsensitiveContains("event service") {
            return "I connected ingestion to validation, processing, and database persistence, with retry and recovery paths around every handoff."
        }
        return "I would keep the answer focused on the current interviewer question."
    }

    private static func keyPoints(for prompt: String) -> [String] {
        let question = currentQuestion(from: prompt)
        if question.localizedCaseInsensitiveContains("invalid event") ||
            question.localizedCaseInsensitiveContains("debug it") {
            return [
                "Reproduce the invalid event and inspect ingestion and validation logs.",
                "Trace the schema mapping into worker actions and verify the repair with tests."
            ]
        }
        if question.localizedCaseInsensitiveContains("engineering team") ||
            question.localizedCaseInsensitiveContains("good fit") {
            return [
                "Clarify first-three-month success, production deployment, and operational expectations.",
                "Map team responsibilities, ownership, data, infrastructure, and workflow boundaries."
            ]
        }
        if question.localizedCaseInsensitiveContains("incoming events") ||
            question.localizedCaseInsensitiveContains("normalized actions") {
            return [
                "Map each incoming event into explicit normalized worker actions.",
                "The schema and conversion rules were validated and tested before worker execution."
            ]
        }
        if question.localizedCaseInsensitiveContains("difference between") &&
            question.localizedCaseInsensitiveContains("deployment tool") {
            return [
                "The event service owns ingestion, processing, and persistence.",
                "The deployment tool owns configuration, controlled releases, and rollback."
            ]
        }
        if question.localizedCaseInsensitiveContains("production execution") ||
            question.localizedCaseInsensitiveContains("isolated test environment") {
            return [
                "Production adds noisy inputs, latency, timing, and configuration drift.",
                "Reliable rollback and recovery contain failures absent from isolated tests."
            ]
        }
        return [
            "Connect ingestion, validation, processing, and database persistence.",
            "Use retry and recovery paths around every service handoff."
        ]
    }

    private static func currentQuestion(from prompt: String) -> String {
        guard let range = prompt.range(
            of: #"CURRENT QUESTION TO ANSWER:\s*\n"([^"]+)""#,
            options: [.regularExpression, .caseInsensitive]
        ) else {
            return prompt
        }
        return String(prompt[range])
            .replacingOccurrences(of: "CURRENT QUESTION TO ANSWER:", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \n\"") )
    }

    private static func jsonString(_ value: String) -> String {
        let data = try? JSONEncoder().encode(value)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }
}

private final class ReleaseValidationOneShotAsyncGate: @unchecked Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        let pair = AsyncStream<Void>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func wait() async {
        for await _ in stream {
            return
        }
    }

    func open() {
        continuation.yield(())
        continuation.finish()
    }
}

private struct ReleaseAnswerQualityCase {
    let id: String
    let question: String
    let requiredThemeGroups: [[String]]
    let forbiddenThemeGroups: [[String]]
}
