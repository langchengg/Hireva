import Combine
import Foundation
import Testing
@testable import Hireva

@MainActor
struct LiveInterviewOwnershipTests {
    @Test(.timeLimit(.minutes(1)))
    func productionViewConstructorsObserveTheSameContentAndManualOwners() async throws {
        try await withApp { app, _ in
            // These are the constructors used by the actual application hosts,
            // not look-alike state copied into a test-only view model.
            let home = HomeView(appState: app)
            let floating = FloatingAssistantView(appState: app)
            let live = LiveInterviewView(appState: app)
            let manual = ManualCaptureWorkspaceView(appState: app)
            let diagnostics = DiagnosticsView(appState: app)
            let providers = ProviderDiagnosticsView(appState: app)
            #expect(home.live === app.liveInterview)
            #expect(floating.live === app.liveInterview)
            #expect(live.live === app.liveInterview)
            #expect(manual.live === app.liveInterview)
            #expect(diagnostics.live === app.liveInterview)
            #expect(providers.live === app.liveInterview)
            #expect(home.manualWorkspace.live === app.liveInterview)
            #expect(live.manualWorkspace.live === app.liveInterview)
            #expect(home.manual === app.manualCaptureController)
            #expect(floating.manual === app.manualCaptureController)
            #expect(manual.manual === app.manualCaptureController)
            #expect(live.manualWorkspace.manual === app.manualCaptureController)
            #expect(home.settingsState === app.settingsState)
            var phases: [GenerationUIState] = []
            let phaseSubscription = home.live.generationStateUpdates.dropFirst().sink { phases.append($0) }
            defer { phaseSubscription.cancel() }
            let firstPhase = GenerationUIState.preparing(questionID: nil,
                generationID: "synthetic-phase-forward", triggerPath: .manualGenerate)
            app.generationUIState = firstPhase
            home.$live.isStreamingSayFirst.wrappedValue = true
            home.$live.isExpandingSuggestionCard.wrappedValue = true
            #expect(app.isStreamingSayFirst)
            #expect(app.isExpandingSuggestionCard)
            floating.$live.generationUIState.wrappedValue = .idle
            #expect(phases == [firstPhase, .idle])
            #expect(app.generationUIState == .idle)
            #expect(floating.settingsState === app.settingsState)
            #expect(live.permissions === app.systemAudioPermissions)

            var homeValues: [String] = []
            var floatingValues: [String] = []
            var liveValues: [String] = []
            let subscriptions = [
                home.live.streamedSayFirstUpdates.dropFirst().sink { homeValues.append($0) },
                floating.live.streamedSayFirstUpdates.dropFirst().sink { floatingValues.append($0) },
                live.live.streamedSayFirstUpdates.dropFirst().sink { liveValues.append($0) }
            ]
            defer { subscriptions.forEach { $0.cancel() } }
            app.streamedSayFirst = "Synthetic first answer."
            app.liveInterview.streamedSayFirst = "Synthetic complete answer."
            home.$live.streamedSayFirst.wrappedValue = "Synthetic bound answer."
            let expected = ["Synthetic first answer.", "Synthetic complete answer.", "Synthetic bound answer."]
            #expect(homeValues == expected)
            #expect(floatingValues == expected)
            #expect(liveValues == expected)
            #expect(app.streamedSayFirst == "Synthetic bound answer.")
            home.$manual.transcript.wrappedValue = "Synthetic bound manual transcript."
            #expect(app.manualCaptureTranscript == "Synthetic bound manual transcript.")
            #expect(floating.manual.transcript == "Synthetic bound manual transcript.")
            // This proves owner identity and publisher delivery. It does not
            // claim a rendered window or a measured visible-answer latency.
        }
    }

    @Test
    func dialogueOwnerCommitsFinalTransitionsAndAcceptsSelectedModeAsAValue() {
        let owner = LiveInterviewFeature()
        owner.interviewSessionModeSelectionDidChange(from: .auto, to: .presentation)
        let segment = TranscriptSegment(id: "synthetic-dialogue-question", sessionID: "synthetic-session",
            source: .systemAudio, speaker: .interviewer,
            text: "How did your current project prepare you for this PhD?")
        let decision = InterviewDialogueTriggerPolicy.decideDialogueTrigger(
            segment: segment, sessionMode: .presentation,
            currentState: owner.dialogueRuntimeState(selectedSessionMode: .presentation),
            answerPanelQuestions: true, suppressPresentation: true, suppressCandidateQuestions: true)
        #expect(decision.nextResolvedSessionPhase == .panelQuestions)

        owner.applyDialogueDecision(decision, source: .systemAudio, allowModeTransition: false)
        #expect(owner.resolvedInterviewSessionPhase == .presentation)
        #expect(owner.detectedDialogueSpeakerRole == .interviewer)
        #expect(owner.detectedDialogueTurnType == .substantiveQuestion)
        #expect(owner.lastDialogueSourceChannel == AudioSourceType.systemAudio.rawValue)
        #expect(owner.lastModeTransition == "auto -> presentation")
        #expect(owner.lastModeTransitionReason == "user selected presentation")

        owner.applyDialogueDecision(decision, source: .systemAudio)
        #expect(owner.resolvedInterviewSessionPhase == .panelQuestions)
        #expect(owner.lastModeTransition == "presentation -> panel_questions")
        #expect(owner.lastModeTransitionReason == decision.modeTransitionReason)
        owner.lastModeTransitionReason = "Synthetic retained transition reason"
        owner.applyDialogueDecision(decision, source: .systemAudio)
        #expect(owner.lastModeTransitionReason == "Synthetic retained transition reason")

        // Reselecting the same configured mode resets a resolved phase that
        // moved on automatically. A true no-op preserves the transition audit.
        owner.interviewSessionModeSelectionDidChange(from: .presentation, to: .presentation)
        #expect(owner.resolvedInterviewSessionPhase == .presentation)
        #expect(owner.lastModeTransition == "panel_questions -> presentation")
        owner.lastModeTransitionReason = "Synthetic no-op marker"
        owner.interviewSessionModeSelectionDidChange(from: .presentation, to: .presentation)
        #expect(owner.lastModeTransitionReason == "Synthetic no-op marker")
        #expect(owner.dialogueRuntimeState(selectedSessionMode: .candidateQuestions).selectedSessionMode == .candidateQuestions)
        #expect(owner.resolvedInterviewSessionPhase == .presentation)
    }

    @Test
    func legacyDialogueBridgePreservesTurnAndPhaseDistinctionsOnTheOwner() {
        let cases: [(InterviewPhase, DialogueSessionPhase, DialogueTurnType)] = [
            (.unknown, .panelQuestions, .unknown),
            (.logistics, .panelQuestions, .logistics),
            (.candidatePresentation, .presentation, .candidatePresentation),
            (.interviewerQuestions, .panelQuestions, .unknown),
            (.candidateAnswer, .panelQuestions, .candidateAnswer),
            (.candidateQuestionsToPanel, .candidateQuestions, .candidateQuestionToPanel),
            (.closing, .closing, .closing)
        ]
        for (legacyPhase, expectedPhase, expectedTurn) in cases {
            let owner = LiveInterviewFeature()
            owner.resolvedInterviewSessionPhase = .panelQuestions
            owner.lastDialogueSourceChannel = "Synthetic source"
            owner.lastModeTransition = "Synthetic prior transition"
            owner.lastModeTransitionReason = "Synthetic prior reason"
            owner.interviewPhase = legacyPhase
            #expect(owner.interviewPhase == legacyPhase)
            #expect(owner.resolvedInterviewSessionPhase == expectedPhase)
            #expect(owner.detectedDialogueTurnType == expectedTurn)
            #expect(owner.detectedDialogueSpeakerRole == .ambiguous)
            #expect(owner.lastDialogueSourceChannel == "Synthetic source")
            #expect(owner.lastModeTransition == "Synthetic prior transition")
            #expect(owner.lastModeTransitionReason == "Synthetic prior reason")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func dialogueCompatibilityAndViewBindingsObserveTheSameOwner() async throws {
        try await withApp { app, _ in
            let home = HomeView(appState: app)
            let floating = FloatingAssistantView(appState: app)
            let diagnostics = DiagnosticsView(appState: app)
            let owner = app.liveInterview
            #expect(home.live === owner && floating.live === owner && diagnostics.live === owner)
            var homePhases: [DialogueSessionPhase] = []
            var floatingPhases: [DialogueSessionPhase] = []
            var diagnosticTurns: [DialogueTurnType] = []
            var appPublications = 0
            let subscriptions = [
                home.live.$resolvedInterviewSessionPhase.dropFirst().sink { homePhases.append($0) },
                floating.live.$resolvedInterviewSessionPhase.dropFirst().sink { floatingPhases.append($0) },
                diagnostics.live.$detectedDialogueTurnType.dropFirst().sink { diagnosticTurns.append($0) },
                app.objectWillChange.sink { appPublications += 1 }
            ]
            defer { subscriptions.forEach { $0.cancel() } }

            app.resolvedInterviewSessionPhase = .presentation
            floating.$live.resolvedInterviewSessionPhase.wrappedValue = .panelQuestions
            app.interviewPhase = .candidateAnswer
            #expect(app.resolvedInterviewSessionPhase == .panelQuestions)
            #expect(app.detectedDialogueTurnType == .candidateAnswer)
            #expect(owner.interviewPhase == .candidateAnswer)
            owner.interviewPhase = .candidateQuestionsToPanel
            #expect(app.interviewPhase == .candidateQuestionsToPanel)
            #expect(app.resolvedInterviewSessionPhase == .candidateQuestions)
            #expect(app.detectedDialogueTurnType == .candidateQuestionToPanel)
            #expect(homePhases == [.presentation, .panelQuestions, .candidateQuestions])
            #expect(floatingPhases == homePhases)
            #expect(diagnosticTurns == [.candidateAnswer, .candidateQuestionToPanel])
            // Seven owner publications, each relayed once. This checks the
            // existing compatibility observation, not rendered GUI frames.
            #expect(appPublications == 7)
            #expect(app.dialogueRuntimeState == owner.dialogueRuntimeState(selectedSessionMode: app.interviewSessionMode))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func compatibilityWritesAndOwnerWritesUseOneAuthorityAndExplicitRelay() async throws {
        try await withApp { app, _ in
            let owner = app.liveInterview
            let session = try app.sessionRepository.createSession(mode: .mock)
            let question = makeQuestion(sessionID: session.id, id: "forward-question", text: "Explain atomicity.")
            let card = makeCard(sessionID: session.id, id: "forward-card", questionID: question.id)
            let segment = TranscriptSegment(id: "forward-segment", sessionID: session.id,
                source: .systemAudio, speaker: .unknown, text: "Synthetic transcript.")
            app.currentSession = session
            app.transcriptSegments = [segment]
            app.currentSuggestion = card
            app.liveSuggestionHistory = [card]
            app.lastDetectedQuestion = question
            app.possibleQuestion = question
            app.lastTranscriptSnippet = "snippet"
            app.rawTranscriptText = "raw"
            app.partialTranscriptText = "partial"
            app.finalTranscriptText = "final"
            app.displayTranscriptText = "display"
            app.lastAcceptedQuestionText = "accepted"
            app.currentSuggestionRetrievedChunks = [makeChunk()]
            app.streamedSayFirst = "stream"
            app.liveState = .listening
            #expect(owner.currentSession == session)
            #expect(owner.transcriptSegments == [segment])
            #expect(owner.currentSuggestion == card)
            #expect(owner.liveSuggestionHistory == [card])
            #expect(owner.lastDetectedQuestion == question)
            #expect(owner.possibleQuestion == question)
            #expect(owner.lastTranscriptSnippet == "snippet")
            #expect(owner.rawTranscriptText == "raw")
            #expect(owner.partialTranscriptText == "partial")
            #expect(owner.finalTranscriptText == "final")
            #expect(owner.displayTranscriptText == "display")
            #expect(owner.lastAcceptedQuestionText == "accepted")
            #expect(owner.currentSuggestionRetrievedChunks.map(\.id) == ["synthetic-live-chunk"])
            #expect(owner.streamedSayFirst == "stream")
            #expect(owner.liveState == .listening)
            #expect(app.diagnosticsState.developer.liveState == .listening)

            var appPublications = 0
            var ownerPublications = 0
            let appSubscription = app.objectWillChange.sink { appPublications += 1 }
            let ownerSubscription = owner.objectWillChange.sink { ownerPublications += 1 }
            defer { appSubscription.cancel(); ownerSubscription.cancel() }
            app.streamedSayFirst = "compatibility update"
            owner.streamedSayFirst = "direct owner update"
            #expect(appPublications == 2)
            #expect(ownerPublications == 2)
            #expect(app.streamedSayFirst == "direct owner update")
            owner.liveState = .transcribing
            #expect(app.liveState == .transcribing)
            #expect(app.diagnosticsState.developer.liveState == .transcribing)
            owner.currentSuggestion = nil
            owner.transcriptSegments.removeAll()
            #expect(app.currentSuggestion == nil)
            #expect(app.transcriptSegments.isEmpty)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func actualTranscriptCallbacksPublishFinalAndResetToTheDirectOwner() async throws {
        try await withApp { app, _ in
            let owner = app.liveInterview
            var publishedDisplay: [String] = []
            let subscription = owner.$displayTranscriptText.dropFirst().sink { publishedDisplay.append($0) }
            defer { subscription.cancel() }
            app.recordTranscriptRuntimeEvent(.asrPartial(sessionID: "synthetic-live-session",
                text: "Synthetic partial", recognitionTaskID: "synthetic-recognition", eventSequence: 1,
                sourceStartUTF16: 0, sourceEndUTF16: 17, isFinal: false, timestamp: Date()))
            #expect(owner.rawTranscriptText == "Synthetic partial")
            #expect(owner.partialTranscriptText == "Synthetic partial")
            app.recordTranscriptRuntimeEvent(.asrFinal(sessionID: "synthetic-live-session",
                text: "Synthetic final", recognitionTaskID: "synthetic-recognition", eventSequence: 2,
                sourceStartUTF16: 0, sourceEndUTF16: 15, isFinal: true, timestamp: Date()))
            #expect(owner.rawTranscriptText == "Synthetic final")
            #expect(owner.finalTranscriptText == "Synthetic final")
            #expect(owner.partialTranscriptText.isEmpty)
            app.lastAcceptedQuestionText = "Synthetic accepted question"
            app.resetRuntimeTranscriptState(clearEvents: true)
            #expect(publishedDisplay == ["Synthetic partial", "Synthetic final", ""])
            #expect(owner.rawTranscriptText.isEmpty)
            #expect(owner.finalTranscriptText.isEmpty)
            #expect(owner.lastAcceptedQuestionText.isEmpty)
            #expect(app.displayTranscriptText.isEmpty)
            #expect(app.partialUtteranceFinalizationTasks.isEmpty)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func realPublicationKeepsTheVisibleCardQuestionWhenDetectionMovesAhead() async throws {
        try await withApp { app, _ in
            let session = try app.sessionRepository.createSession(mode: .mock)
            app.currentSession = session
            let first = makeQuestion(sessionID: session.id, id: "visible-q1", text: "Explain database transactions and atomicity.")
            let second = makeQuestion(sessionID: session.id, id: "detected-q2", text: "Explain transaction isolation.")
            let generationID = "synthetic-live-generation"
            app.activateGeneration(question: first, generationID: generationID,
                triggerPath: .manualGenerate, requestStart: Date(), source: nil, speaker: nil)
            try #require(app.publishStreamingSections(.init(strategy: "Explanation",
                sayFirst: "A database transaction groups operations into an atomic unit that either commits or rolls back together.",
                keyPoints: ["Atomicity commits or rolls back the complete transaction."],
                followUpReady: [], caution: ""), cardID: "synthetic-visible-card", generationID: generationID,
                question: first, session: session, requestStart: Date(), stageBStreamStartedMS: nil))
            app.lastDetectedQuestion = second
            let home = HomeView(appState: app)
            let floating = FloatingAssistantView(appState: app)
            let ownerRender = app.liveInterview.renderState(activeIdentity: app.activeGenerationController?.identity,
                generationState: app.generationUIState, elapsedMS: app.activeGenerationElapsedMs ?? 0,
                isStreaming: app.isStreamingSayFirst, isExpanding: app.isExpandingSuggestionCard,
                providerStreamActive: app.providerStreamActive)
            #expect(app.visibleAssistantRenderState == ownerRender)
            #expect(home.renderState == ownerRender)
            #expect(floating.renderState == ownerRender)
            #expect(ownerRender.questionText == first.questionText)
            #expect(ownerRender.activeQuestionID == first.id)
            #expect(ownerRender.hasAnswerText)
            #expect(app.liveInterview.currentSuggestion?.detectedQuestionID == first.id)
            #expect(!app.liveInterview.shouldShowBlockingAnswerSpinner(generationState: app.generationUIState, elapsedMS: 0))
            #expect(app.liveInterview.shouldShowAnswerExpansionStatus(generationState: .expandingFullAnswer(
                questionID: first.id, generationID: generationID, triggerPath: .manualGenerate), isExpanding: false))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func productionHistoryCallerPreservesUpsertCapAndSeparateHistorySelection() async throws {
        try await withApp { app, _ in
            let session = try app.sessionRepository.createSession(mode: .mock)
            app.currentSession = session
            app.selectedSessionID = session.id
            for index in 0..<22 {
                var card = makeCard(sessionID: session.id, id: "history-\(index)", questionID: "history-q-\(index)")
                card.createdAt = Date(timeIntervalSince1970: Double(index))
                app.recordVisibleSuggestionInHistory(card)
            }
            #expect(app.liveInterview.liveSuggestionHistory.count == 20)
            #expect(app.liveInterview.liveSuggestionHistory.first?.id == "history-2")
            #expect(app.selectedSessionSuggestions == app.liveInterview.liveSuggestionHistory)
            var replacement = try #require(app.liveInterview.liveSuggestionHistory.last)
            replacement.sayFirst = "Synthetic updated historical answer."
            app.recordVisibleSuggestionInHistory(replacement)
            #expect(app.liveSuggestionHistory.count == 20)
            #expect(app.liveSuggestionHistory.last?.sayFirst == replacement.sayFirst)
            var rejected = replacement
            rejected.id = "partial-history"
            rejected.isPartial = true
            app.recordVisibleSuggestionInHistory(rejected)
            rejected.id = "foreign-history"
            rejected.isPartial = false
            rejected.sessionID = "different-session"
            app.recordVisibleSuggestionInHistory(rejected)
            rejected.id = "empty-history"
            rejected.sessionID = session.id
            rejected.sayFirst = "  "
            app.recordVisibleSuggestionInHistory(rejected)
            #expect(app.liveSuggestionHistory.count == 20)
            #expect(app.liveSuggestionHistory.allSatisfy { !$0.id.contains("-history") })
            #expect(app.selectedSessionSuggestions == app.liveSuggestionHistory)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func existingProductionViewsReadPhaseUpdatesFromTheirObservedOwner() async throws {
        try await withApp { app, _ in
            let home = HomeView(appState: app)
            let floating = FloatingAssistantView(appState: app)
            #expect(!home.renderState.isGenerating)
            #expect(!floating.renderState.isGenerating)
            app.generationUIState = .generatingFirstAnswer(questionID: nil,
                generationID: "synthetic-owner-phase", triggerPath: .manualGenerate)
            app.isStreamingSayFirst = true
            #expect(home.renderState.isGenerating)
            #expect(floating.renderState.isGenerating)
            #expect(home.renderState.generationStatus == "Generating first answer")
            #expect(floating.renderState.generationStatus == "Generating first answer")
            app.streamedSayFirst = "Synthetic usable first answer."
            app.isStreamingSayFirst = false
            app.isExpandingSuggestionCard = true
            app.generationUIState = .expandingFullAnswer(questionID: nil,
                generationID: "synthetic-owner-phase", triggerPath: .manualGenerate)
            #expect(home.renderState.isGenerating)
            #expect(floating.renderState.isGenerating)
            app.isExpandingSuggestionCard = false
            app.generationUIState = .answerReady(questionID: nil,
                generationID: "synthetic-owner-phase", triggerPath: .manualGenerate)
            #expect(!home.renderState.isGenerating)
            #expect(!floating.renderState.isGenerating)
            #expect(home.renderState.generationStatus == "Answer ready")
            #expect(floating.renderState.generationStatus == "Answer ready")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func compatibilityCapturePresentationPublishesToTheExistingLiveOwner() async throws {
        try await withApp { app, _ in
            let owner = app.liveInterview
            var publications = 0
            let subscription = owner.objectWillChange.sink { publications += 1 }
            defer { subscription.cancel() }
            // These public compatibility entries must forward to the same
            // feature observed by Home/Live/Floating, without copied storage.
            app.currentCaptureRuntimeState = .starting
            app.stopReason = .userRequested
            app.lastCaptureStartedAt = Date(timeIntervalSince1970: 100)
            app.lastCaptureStoppedAt = Date(timeIntervalSince1970: 200)
            app.recent20CaptureEvents = []
            #expect(publications == 5)
            #expect(app.currentCaptureRuntimeState == .starting)
            #expect(app.stopReason == .userRequested)
            #expect(app.lastCaptureStartedAt == Date(timeIntervalSince1970: 100))
            #expect(app.lastCaptureStoppedAt == Date(timeIntervalSince1970: 200))
        }
    }


    @Test(.timeLimit(.minutes(1)))
    func fallbackPresentationAndCompatibilityPublishersShareTheActualLiveOwner() async throws {
        try await withApp { app, _ in
            let live = app.liveInterview
            let home = HomeView(appState: app)
            #expect(home.live === live)
            let livePublishers: [AnyPublisher<Void, Never>] = [
                live.currentSuggestionSetAtUpdates.map { _ in () }.eraseToAnyPublisher(),
                live.softFallbackUsedUpdates.map { _ in () }.eraseToAnyPublisher(),
                live.softFallbackLatencyMSUpdates.map { _ in () }.eraseToAnyPublisher(),
                live.softFallbackShownAtUpdates.map { _ in () }.eraseToAnyPublisher(),
                live.finalVisibleSourceUpdates.map { _ in () }.eraseToAnyPublisher()
            ]
            let appPublishers: [AnyPublisher<Void, Never>] = [
                app.currentSuggestionSetAtUpdates.map { _ in () }.eraseToAnyPublisher(),
                app.softFallbackUsedUpdates.map { _ in () }.eraseToAnyPublisher(),
                app.softFallbackLatencyMSUpdates.map { _ in () }.eraseToAnyPublisher(),
                app.softFallbackShownAtUpdates.map { _ in () }.eraseToAnyPublisher(),
                app.finalVisibleSourceUpdates.map { _ in () }.eraseToAnyPublisher()
            ]
            var liveEvents = Array(repeating: 0, count: livePublishers.count)
            var appEvents = Array(repeating: 0, count: appPublishers.count)
            var forwardedNotifications = 0
            let relayed = app.objectWillChange.sink { forwardedNotifications += 1 }
            let subscriptions = livePublishers.enumerated().map { index, publisher in
                publisher.dropFirst().sink { liveEvents[index] += 1 }
            } + appPublishers.enumerated().map { index, publisher in
                publisher.dropFirst().sink { appEvents[index] += 1 }
            }
            defer { subscriptions.forEach { $0.cancel() }; relayed.cancel() }
            let first = Date(timeIntervalSince1970: 101)
            app.currentSuggestionSetAt = first
            app.softFallbackUsed = true
            app.softFallbackLatencyMS = 111
            app.softFallbackShownAt = first
            app.finalVisibleSource = "synthetic-app-write"
            #expect(live.currentSuggestionSetAt == first && live.softFallbackUsed)
            #expect(live.softFallbackLatencyMS == 111 && live.softFallbackShownAt == first)
            #expect(live.finalVisibleSource == "synthetic-app-write")
            #expect(liveEvents == [1, 1, 1, 1, 1] && appEvents == liveEvents)
            let second = Date(timeIntervalSince1970: 202)
            live.currentSuggestionSetAt = second
            live.softFallbackUsed = false
            live.softFallbackLatencyMS = 222
            live.softFallbackShownAt = second
            live.finalVisibleSource = "synthetic-live-write"
            #expect(app.currentSuggestionSetAt == second && !app.softFallbackUsed)
            #expect(app.softFallbackLatencyMS == 222 && app.softFallbackShownAt == second)
            #expect(app.finalVisibleSource == "synthetic-live-write")
            #expect(liveEvents == [2, 2, 2, 2, 2] && appEvents == liveEvents)
            #expect(forwardedNotifications == 10,
                "The existing feature-observation bridge forwards each sole-owner write once.")
            // Binding is an ObservedObject writable-key-path API, not the
            // removed property's Combine projection. Keep actual view binding.
            home.$live.softFallbackUsed.wrappedValue = true
            #expect(app.softFallbackUsed && live.softFallbackUsed)
            home.$live.isStreamingSayFirst.wrappedValue = true
            home.$live.isExpandingSuggestionCard.wrappedValue = true
            #expect(app.isStreamingSayFirst && app.isExpandingSuggestionCard)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func providerStreamPhasePublishersAndBindingShareOneCommittedLiveValue() async throws {
        try await withApp { app, _ in
            let live = app.liveInterview
            let home = HomeView(appState: app)
            var appValues: [Bool] = []
            var liveValues: [Bool] = []
            var committed = true
            var forwarded = 0
            let appUpdates = app.providerStreamActiveUpdates.dropFirst().sink { value in
                appValues.append(value)
                committed = committed && app.providerStreamActive == value && live.providerStreamActive == value
            }
            let liveUpdates = live.providerStreamActiveUpdates.dropFirst().sink { value in
                liveValues.append(value)
                committed = committed && app.providerStreamActive == value && live.providerStreamActive == value
            }
            let notifications = app.objectWillChange.sink { forwarded += 1 }
            defer { appUpdates.cancel(); liveUpdates.cancel(); notifications.cancel() }
            app.providerStreamActive = true
            #expect(live.providerStreamActive)
            live.providerStreamActive = false
            #expect(!app.providerStreamActive)
            home.$live.providerStreamActive.wrappedValue = true
            app.providerStreamActive = true
            #expect(committed && appValues == [true, false, true, true] && liveValues == appValues)
            #expect(forwarded == 4 && home.live === live)
            // This is the existing writable stream presentation phase, not a
            // count of current or retired producer handles.
            #expect(app.generationCoordinator.stageATask == nil && app.providerStreamActive)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func floatingQueueValuesFollowTheCommittedOwnerWithoutViewReconstruction() async throws {
        try await withApp { app, _ in
            let session = try app.sessionRepository.createSession(mode: .mock)
            app.currentSession = session
            let first = makeQuestion(sessionID: session.id, id: "synthetic-queue-first", text: "Explain atomicity.")
            let next = makeQuestion(sessionID: session.id, id: "synthetic-queue-next", text: "Explain isolation.")
            let queuedFirst = AppState.PendingAcceptedQuestion(question: first, session: session,
                transcript: first.questionText, canonicalQuestion: first.questionText, intent: AnswerRelevancePolicy.intent(for: first.questionText),
                promptPrimaryQuestion: first.questionText, duplicateKey: first.id,
                queuedAt: Date(timeIntervalSince1970: 1), consentTicket: nil)
            let queuedNext = AppState.PendingAcceptedQuestion(question: next, session: session,
                transcript: next.questionText, canonicalQuestion: next.questionText, intent: AnswerRelevancePolicy.intent(for: next.questionText),
                promptPrimaryQuestion: next.questionText, duplicateKey: next.id,
                queuedAt: Date(timeIntervalSince1970: 2), consentTicket: nil)
            let floating = FloatingAssistantView(appState: app)
            var observedHeads: [String?] = []
            let subscription = app.liveInterview.objectWillChange.sink { _ in
                observedHeads.append(app.pendingAcceptedQuestions.first?.question.id)
            }
            defer { subscription.cancel() }
            app.pendingAcceptedQuestions = [queuedFirst]
            #expect(floating.hasQueuedQuestions)
            #expect(floating.queuedQuestionID == first.id)
            app.pendingAcceptedQuestions = [queuedNext]
            #expect(floating.hasQueuedQuestions)
            #expect(floating.queuedQuestionID == next.id)
            app.pendingAcceptedQuestions = []
            #expect(!floating.hasQueuedQuestions && floating.queuedQuestionID == nil)
            let expected: [String?] = [first.id, next.id, nil]
            #expect(observedHeads == expected)
            // The real host may also reconstruct its child after App relays.
            // This proves owner derivation/notification, not rendered GUI frames.
        }
    }

    private func withApp(_ body: @MainActor (AppState, AppDatabase) async throws -> Void) async throws {
        let database = try AppDatabase(inMemory: true)
        let app = AppState(database: database, questionRoutingProvider: HermeticQuestionRoutingProvider(),
            permissionService: HermeticPermissionService(), keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            dialogueDefaults: nil)
        do {
            try await body(app, database)
            await app.shutdownForTesting()
            try database.close()
        } catch {
            await app.shutdownForTesting()
            try? database.close()
            throw error
        }
    }

    private func makeQuestion(sessionID: String, id: String, text: String) -> DetectedQuestion {
        DetectedQuestion(id: id, sessionID: sessionID, transcriptSegmentID: nil, questionText: text,
            intent: .technical, answerStrategy: .directAnswer, confidence: 1, reason: "Synthetic Live owner fixture",
            shouldTrigger: true, questionComplete: true, modelName: "fixture", promptVersion: "fixture", createdAt: Date())
    }

    private func makeCard(sessionID: String, id: String, questionID: String) -> SuggestionCard {
        SuggestionCard(id: id, sessionID: sessionID, questionID: questionID, strategy: "Synthetic",
            sayFirst: "Synthetic complete answer.", keyPoints: [], followUpReady: [], confidence: nil, caution: nil,
            evidenceUsed: [], riskLevel: nil, modelName: "fixture", promptVersion: "fixture", rawJSON: nil, createdAt: Date())
    }

    private func makeChunk() -> RetrievedChunk {
        .init(id: "synthetic-live-chunk", documentID: "synthetic-document", documentType: .cv, chunkIndex: 0,
            contentPreview: "Synthetic candidate evidence.", fullContent: "Synthetic candidate evidence.", keywords: [],
            score: 1, keywordOverlapCount: 0, contentOverlapCount: 0, rank: 1, isIncludedInPrompt: true,
            sectionTitle: nil, wordCount: 3)
    }
}
