import Combine
import Foundation
import Testing
@testable import Hireva

@Suite(.serialized)
@MainActor
struct FirstAnswerFallbackTests {
    @Test(.timeLimit(.minutes(1)))
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
            questionRoutingProvider: HermeticQuestionRoutingProvider(),
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

        try await runAutomaticFallback(appState, database: database, segment: segment) {
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
    }

    @Test(.timeLimit(.minutes(1)))
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
            questionRoutingProvider: HermeticQuestionRoutingProvider(),
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

        try await runAutomaticFallback(appState, database: database, segment: segment) {
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
    }

    @Test(.timeLimit(.minutes(1)))
    func firstAnswerFallbackAppearsWhenContextRetrievalIsSlow() async throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "FirstAnswerFallbackTests")
        let settingsRepository = SettingsRepository(database: database)
        try settingsRepository.ensureDefaultProviderConfigurations()
        let router = LLMRouter(settingsRepository: settingsRepository, clients: [.deepSeek: StreamingMockLLMClient()])
        let appState = AppState(
            database: database,
            questionRoutingProvider: HermeticQuestionRoutingProvider(),
            llmRouter: router,
            contextRetrievalService: SuspendedContextRetrievalService()
        )
        appState.answerProviderModeOverride = .deepSeekPrimary
        let delayProvider = MockDelayProvider()
        delayProvider.sleepDuration = 60_000_000_000
        delayProvider.setSleepDuration(1_000_000, forRequestedNanoseconds: 1_500_000_000)
        appState.delayProvider = delayProvider

        let session = try makeContextBoundSession(appState, suffix: "slow-retrieval")
        appState.currentSession = session
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

        let published = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let subscription = appState.liveInterview.suggestionUpdates.compactMap { $0 }
            .sink { _ in published.continuation.yield(()) }
        let generationTask = Task {
            try await appState.generateSuggestion(
                for: question,
                session: session,
                transcript: question.questionText,
                autoGenerated: true
            )
        }
        func cleanup() async {
            published.continuation.finish()
            subscription.cancel()
            generationTask.cancel()
            appState.cancelActiveGenerationForContextChange()
            _ = await generationTask.result
            #expect(await appState.shutdownResources())
            try? database.close()
        }

        do {
            // The requested watchdog deadline is still asserted below. This
            // wait observes the actual feature publication, rather than giving
            // unrelated MainActor test work a five-second scheduling deadline.
            try await withTaskCancellationHandler {
                var iterator = published.stream.makeAsyncIterator()
                guard await iterator.next() != nil else { throw CancellationError() }
            } onCancel: {
                published.continuation.finish()
                generationTask.cancel()
            }

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
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }


    enum FallbackPublicationReentry: String, CaseIterable, Sendable {
        case usedIntrinsic, latencyIntrinsic, shownAtIntrinsic, sourceIntrinsic
        case visibleCardPublication, suggestionTimestampIntrinsic
        case streamingIntrinsic, expansionIntrinsic
        case firstVisibleTelemetry, fallbackTelemetry, firstVisibleStateTimestamp
        case showingFallbackUI, infoLoadingPublication, infoFeedbackPublication
        case immediateVisibleCardPublication, immediateSuggestionTimestamp

        var usesImmediateEntry: Bool {
            self == .immediateVisibleCardPublication || self == .immediateSuggestionTimestamp
        }
    }

    /// Actual automatic transcript ingress, held RAG, and the real initial
    /// deadline callback. A synchronous observer installs another full identity.
    @Test(.timeLimit(.minutes(1)), arguments: FallbackPublicationReentry.allCases)
    func automaticFallbackPublicationCannotOverwriteReplacement(point: FallbackPublicationReentry) async throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "FallbackPublicationReentry")
        let settingsRepository = SettingsRepository(database: database)
        try settingsRepository.ensureDefaultProviderConfigurations()
        let client = StreamingMockLLMClient()
        client.chatResultContent = """
        {"should_trigger":true,"question_complete":true,"question_text":"Why do you want this role?",
         "intent":"company_fit","answer_strategy":"direct_answer","confidence":0.95,"reason":"Complete synthetic question."}
        """
        let app = AppState(database: database,
            questionRoutingProvider: HermeticQuestionRoutingProvider(),
            llmRouter: LLMRouter(settingsRepository: settingsRepository, clients: [.deepSeek: client]),
            permissionService: HermeticPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            contextRetrievalService: SuspendedContextRetrievalService(), dialogueDefaults: nil)
        let clock = ControlledGenerationWatchdogClock()
        let otherClock = ControlledGenerationWatchdogClock()
        let replacementClock = ControlledGenerationWatchdogClock()
        app.answerProviderModeOverride = .deepSeekPrimary
        app.delayProvider = clock
        app.generationWatchdogDelayProvider = otherClock
        var settings = app.settings
        settings.audioCaptureMode = .microphoneOnly
        app.saveSettings(settings)
        let session = try makeContextBoundSession(app, suffix: "reentry-" + point.rawValue)
        app.currentSession = session
        app.liveState = .listening
        app.currentCaptureRuntimeState = .listening
        let segment = TranscriptSegment(id: "fallback-reentry-" + point.rawValue,
            sessionID: session.id, source: .systemAudio, speaker: .interviewer,
            text: "Why do you want this role?", recognitionIsFinal: true)
        let owner = app.generationCoordinator
        var request: Task<Void, Never>?
        var deadline: Task<Void, Never>?
        var replacementDeadline: Task<Void, Never>?
        var observation: AnyCancellable?
        var reentered = false
        var committedAtPublication = true
        let suggestionTime = Date(timeIntervalSince1970: 101)
        let shownTime = Date(timeIntervalSince1970: 202)
        let visibleTime = Date(timeIntervalSince1970: 303)
        let visibleStateTime = Date(timeIntervalSince1970: 404)
        let fallbackTime = Date(timeIntervalSince1970: 505)
        let marker = "Synthetic replacement: " + point.rawValue
        let feedback = ActionFeedback(actionID: ActionID.generateAnswer,
            title: marker, message: "Replacement-owned feedback.", kind: .loading)
        func cleanup() async {
            observation?.cancel()
            clock.cancelAll(); otherClock.cancelAll(); replacementClock.cancelAll()
            request?.cancel(); deadline?.cancel(); replacementDeadline?.cancel()
            // Retain the cleanup root even when Testing cancels this case.
            let shutdown = Task { @MainActor in
                #expect(await app.shutdownResources())
                try? database.close()
            }
            await shutdown.value
            await request?.value; await deadline?.value; await replacementDeadline?.value
        }
        do {
            await app.handleTranscriptSegment(segment)
            try await withTaskCancellationHandler {
                try await clock.waitUntilPending(nanoseconds: 1_500_000_000)
            } onCancel: { clock.cancelAll(); otherClock.cancelAll(); replacementClock.cancelAll() }
            let requiredGenerationRequest: Task<Void, Never> = try #require(app.activeAITask)
            request = requiredGenerationRequest
            let requiredFallbackDeadline: Task<Void, Never> = try #require(owner.fallbackWatchdogTask)
            deadline = requiredFallbackDeadline
            let original = try #require(owner.activeGeneration?.identity)
            let replacement = GenerationIdentity(acceptedQuestionID: original.acceptedQuestionID,
                generationID: original.generationID, sessionID: original.sessionID,
                questionText: original.questionText, normalizedQuestionText: original.normalizedQuestionText,
                questionIntent: original.questionIntent, promptPrimaryQuestion: original.promptPrimaryQuestion,
                ingressIdentity: original.ingressIdentity,
                contextSnapshotID: "synthetic-fallback-replacement-" + point.rawValue)
            @MainActor func replacePresentation() {
                guard !reentered else { return }
                reentered = true
                owner.activate(identity: replacement, persistenceTicket: 2,
                    triggerPath: .regenerate, startedAt: Date())
                if point.usesImmediateEntry {
                    replacementDeadline = owner.launchDeadline(identity: replacement, role: .fallbackWatchdog,
                        nanoseconds: 1_500_000_000, delayProvider: replacementClock) { _, _ in
                        Issue.record("The replacement deadline must stay pending until controlled cleanup.")
                    }
                }
                app.generationUIState = .idle
                app.currentSuggestion = nil
                app.streamedSayFirst = marker
                app.currentSuggestionSetAt = suggestionTime
                app.softFallbackUsed = false
                app.softFallbackLatencyMS = 777
                app.softFallbackShownAt = shownTime
                app.finalVisibleSource = marker
                app.isStreamingSayFirst = true
                app.isExpandingSuggestionCard = false
                app.firstVisibleStateSetAt = visibleStateTime
                var telemetry = GenerationTelemetry.idle
                telemetry.generationID = replacement.generationID
                telemetry.questionID = replacement.acceptedQuestionID
                telemetry.firstVisibleAt = visibleTime
                telemetry.fallbackShownAt = fallbackTime
                app.currentGenerationTelemetry = telemetry
                app.lastAlignmentError = marker
                app.actionLoadingStates[ActionID.generateAnswer] = true
                app.activeActionFeedbacks = [feedback]
                app.actionFeedbackDismissTasks[ActionID.generateAnswer]?.cancel()
                app.actionFeedbackDismissTasks[ActionID.generateAnswer] = nil
            }
            switch point {
            case .usedIntrinsic:
                observation = app.softFallbackUsedUpdates.dropFirst().sink { value in
                    guard value, !reentered else { return }
                    committedAtPublication = app.softFallbackUsed == value
                    replacePresentation()
                }
            case .latencyIntrinsic:
                observation = app.softFallbackLatencyMSUpdates.dropFirst().sink { value in
                    guard let value, !reentered else { return }
                    committedAtPublication = app.softFallbackLatencyMS == value
                    replacePresentation()
                }
            case .shownAtIntrinsic:
                observation = app.softFallbackShownAtUpdates.dropFirst().sink { value in
                    guard let value, !reentered else { return }
                    committedAtPublication = app.softFallbackShownAt == value
                    replacePresentation()
                }
            case .sourceIntrinsic:
                observation = app.finalVisibleSourceUpdates.dropFirst().sink { value in
                    guard value == "local_first_answer_fallback", !reentered else { return }
                    committedAtPublication = app.finalVisibleSource == value
                    replacePresentation()
                }
            case .visibleCardPublication, .immediateVisibleCardPublication:
                observation = app.liveInterview.suggestionUpdates.dropFirst().sink { value in
                    guard value?.sayFirstSource == "local_first_answer_fallback", !reentered else { return }
                    committedAtPublication = app.currentSuggestion == value
                    replacePresentation()
                }
            case .suggestionTimestampIntrinsic, .immediateSuggestionTimestamp:
                observation = app.currentSuggestionSetAtUpdates.dropFirst().sink { value in
                    guard let value, !reentered else { return }
                    committedAtPublication = app.currentSuggestionSetAt == value
                    replacePresentation()
                }
            case .streamingIntrinsic:
                observation = app.liveInterview.isStreamingSayFirstUpdates.dropFirst().sink { value in
                    guard !value, !reentered else { return }
                    committedAtPublication = app.isStreamingSayFirst == value
                    replacePresentation()
                }
            case .expansionIntrinsic:
                observation = app.liveInterview.isExpandingSuggestionCardUpdates.dropFirst().sink { value in
                    guard value, !reentered else { return }
                    committedAtPublication = app.isExpandingSuggestionCard == value
                    replacePresentation()
                }
            case .firstVisibleTelemetry:
                observation = app.generationTelemetryUpdates.dropFirst().sink { value in
                    guard value.firstVisibleAt != nil, !reentered else { return }
                    committedAtPublication = app.currentGenerationTelemetry.firstVisibleAt == value.firstVisibleAt
                    replacePresentation()
                }
            case .fallbackTelemetry:
                observation = app.generationTelemetryUpdates.dropFirst().sink { value in
                    guard value.fallbackShownAt != nil, !reentered else { return }
                    committedAtPublication = app.currentGenerationTelemetry.fallbackShownAt == value.fallbackShownAt
                    replacePresentation()
                }
            case .firstVisibleStateTimestamp:
                observation = app.firstVisibleStateSetAtUpdates.dropFirst().sink { value in
                    guard let value, !reentered else { return }
                    committedAtPublication = app.firstVisibleStateSetAt == value
                    replacePresentation()
                }
            case .showingFallbackUI:
                observation = app.liveInterview.generationStateUpdates.dropFirst().sink { value in
                    guard case .showingFallback = value, !reentered else { return }
                    committedAtPublication = app.generationUIState == value
                    replacePresentation()
                }
            case .infoLoadingPublication:
                observation = app.actionLoadingStatesUpdates.dropFirst().sink { value in
                    guard case .showingFallback = app.generationUIState,
                          value[ActionID.generateAnswer] == false, !reentered else { return }
                    replacePresentation()
                }
            case .infoFeedbackPublication:
                observation = app.activeActionFeedbacksUpdates.dropFirst().sink { value in
                    guard value.contains(where: { $0.title == "First answer visible" }), !reentered else { return }
                    replacePresentation()
                }
            }
            if point.usesImmediateEntry {
                #expect(!app.showImmediateFallbackForActiveGenerationIfNeeded(reason: "synthetic ignored system audio"),
                    "A replaced immediate fallback must report that its publication was not admitted.")
            } else {
                clock.advance(by: 1_500_000_000)
                await deadline?.value
            }
            observation?.cancel(); observation = nil
            #expect(reentered, "Exercise the actual selected callback boundary.")
            #expect(committedAtPublication, "The in-progress setter must commit before observer reentry.")
            #expect(owner.isCurrent(replacement) && owner.canPublish(replacement))
            if point.usesImmediateEntry {
                let retained = try #require(replacementDeadline)
                #expect(owner.fallbackWatchdogTask == retained,
                    "The old entry must not clear a new context's same-generation deadline.")
                #expect(!retained.isCancelled)
            }
            #expect(app.generationUIState == .idle && app.currentSuggestion == nil)
            #expect(app.streamedSayFirst == marker)
            #expect(app.currentSuggestionSetAt == suggestionTime)
            #expect(!app.softFallbackUsed && app.softFallbackLatencyMS == 777)
            #expect(app.softFallbackShownAt == shownTime && app.finalVisibleSource == marker)
            #expect(app.isStreamingSayFirst && !app.isExpandingSuggestionCard)
            #expect(app.firstVisibleStateSetAt == visibleStateTime)
            #expect(app.currentGenerationTelemetry.firstVisibleAt == visibleTime)
            #expect(app.currentGenerationTelemetry.fallbackShownAt == fallbackTime)
            #expect(app.lastAlignmentError == marker)
            #expect(app.activeActionFeedbacks == [feedback] && app.isActionLoading(ActionID.generateAnswer))
            #expect(app.actionFeedbackDismissTasks[ActionID.generateAnswer] == nil)
            await cleanup()
            #expect(owner.pendingCleanupTaskCount == 0 && clock.pendingCount == 0 &&
                otherClock.pendingCount == 0 && replacementClock.pendingCount == 0)
        } catch {
            await cleanup()
            throw error
        }
    }

    private func runAutomaticFallback(_ app: AppState, database: AppDatabase,
        segment: TranscriptSegment, assertions: () throws -> Void) async throws {
        let published = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let subscription = app.liveInterview.suggestionUpdates.compactMap { $0 }
            .filter { $0.sayFirstSource == "local_first_answer_fallback" }
            .sink { _ in published.continuation.yield(()) }
        func cleanup() async {
            subscription.cancel()
            published.continuation.finish()
            // Retain and join this cleanup even when the test task is cancelled.
            let shutdown = Task { @MainActor in
                app.cancelActiveGenerationForContextChange()
                #expect(await app.shutdownResources())
                try? database.close()
            }
            await shutdown.value
        }
        do {
            await app.handleTranscriptSegment(segment)
            _ = try await TestEventWaitTrace(label: "automatic-first-answer-fallback")
                .nextEvent(in: published.stream, event: "actual-feature-published-fallback")
            #expect((app.delayProvider as? MockDelayProvider)?.delayCalledWithNanoseconds
                .contains(1_500_000_000) == true)
            try assertions()
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
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
