import Foundation
import Combine
import os
import Testing
@testable import Hireva

@MainActor
struct StageAAwaitEntryOwnershipTests {
    @Test(.timeLimit(.minutes(1)))
    func oldActualEntryWaiterCannotClearReplacementOfSameGenerationSlots() async throws {
        let fixture = try StageAAwaitEntryFixture()
        let replacementGate = StageAAwaitReleaseGate()
        let replacementTimerGate = StageAAwaitReleaseGate()
        var root: Task<Void, Never>?
        var replacement: Task<String, Error>?
        var timer: Task<Void, Never>?
        do {
            await fixture.submitAcceptedQuestion()
            let originalRoot = try #require(fixture.app.activeAITask)
            root = originalRoot
            try await fixture.waitForFirstAnswerAndBothDeadlines()
            let owner = fixture.app.generationCoordinator
            let identity = try #require(owner.activeGeneration?.identity)
            let originalChild = try #require(owner.stageATask)
            let next = Task<String, Error> {
                await replacementGate.wait()
                try Task.checkCancellation()
                return "Synthetic replacement only"
            }
            replacement = next
            let nextTimer = Task { await replacementTimerGate.wait() }
            timer = nextTimer
            // The exact real owner API permits replacing a slot without
            // inventing a new generation or copying application cleanup logic.
            #expect(owner.registerStageATask(next, generationID: identity.generationID))
            #expect(owner.registerTask(nextTimer, role: .stageATimeout, generationID: identity.generationID))
            #expect(originalChild.isCancelled)
            try await fixture.join(originalRoot)
            // Pre-migration AppState catch clears both current slots by only
            // generationID. This must fail there rather than hide behind sleep.
            #expect(!next.isCancelled)
            #expect(!nextTimer.isCancelled)
            #expect(owner.stageATask != nil)
            #expect(owner.activeGeneration?.stageATimeoutTask != nil)
            #expect(owner.isCurrent(identity))
            #expect(owner.canPublish(identity))
            #expect(!fixture.app.generationUIState.isTerminal)
            #expect(fixture.app.currentSuggestion == nil)
            #expect(fixture.client.firstAnswerCancelled)
            replacementGate.release(); replacementTimerGate.release()
            await fixture.close(roots: [originalRoot], children: [next], timers: [nextTimer])
            #expect(owner.pendingCleanupTaskCount == 0)
        } catch {
            replacementGate.release(); replacementTimerGate.release()
            root?.cancel(); replacement?.cancel(); timer?.cancel()
            await fixture.close(roots: root.map { [$0] } ?? [],
                children: replacement.map { [$0] } ?? [], timers: timer.map { [$0] } ?? [])
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: End.allCases)
    func realEntryKeepsCompletionTimeoutAndCancellationContracts(end: End) async throws {
        let fixture = try StageAAwaitEntryFixture()
        var pending: Task<Void, Never>?
        do {
            await fixture.submitAcceptedQuestion()
            let request = try #require(fixture.app.activeAITask)
            pending = request
            try await fixture.waitForFirstAnswerAndBothDeadlines()
            let stageA = try #require(fixture.app.generationCoordinator.stageATask)
            switch end {
            case .completed:
                fixture.client.completeFirstAnswer()
            case .deadline:
                let preview = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
                let observation = fixture.app.liveInterview.streamedSayFirstUpdates
                    .filter { $0 == StageAAwaitEntryClient.answer }
                    .sink { _ in preview.continuation.yield(()) }
                defer { observation.cancel(); preview.continuation.finish() }
                fixture.client.emitFirstAnswerPreview()
                _ = try await TestEventWaitTrace(label: "stage-a-await.legal-preview")
                    .nextEvent(in: preview.stream, event: "actual-live-owner-published-preview")
                #expect(fixture.app.streamedSayFirst == StageAAwaitEntryClient.answer)
                fixture.clock.advance(by: 6_000_000_000)
            case .cancelled:
                fixture.app.cancelActiveGenerationForContextChange()
            }
            try await fixture.join(request)
            #expect(fixture.app.generationCoordinator.stageATask == nil)
            #expect(fixture.app.generationCoordinator.activeGeneration?.stageATimeoutTask == nil)
            switch end {
            case .completed:
                #expect(fixture.app.currentSuggestion?.sayFirst == StageAAwaitEntryClient.answer)
                #expect(fixture.app.currentSuggestion?.sayFirstSource == "deepseek_stream")
                #expect(fixture.app.currentSuggestion?.detectedQuestionID == fixture.question.id)
            case .deadline:
                #expect(stageA.isCancelled)
                #expect(fixture.client.firstAnswerCancelled)
                #expect(fixture.app.currentSuggestion?.sayFirst == StageAAwaitEntryClient.answer,
                    "Keep the already qualified provider answer while expansion remains active.")
                #expect(fixture.app.currentSuggestion?.sayFirstSource == "deepseek_stream")
            case .cancelled:
                #expect(request.isCancelled)
                #expect(stageA.isCancelled)
                #expect(fixture.client.firstAnswerCancelled)
                #expect(fixture.app.currentGenerationID == nil)
                #expect(fixture.app.currentSuggestion == nil)
            }
            await fixture.close(roots: [request])
            #expect(fixture.app.generationCoordinator.pendingCleanupTaskCount == 0)
            #expect(fixture.clock.pendingCount == 0)
            #expect(fixture.observerClock.pendingCount == 0)
        } catch {
            pending?.cancel()
            await fixture.close(roots: pending.map { [$0] } ?? [])
            throw error
        }
    }

    enum StartedReentry: String, CaseIterable, Sendable {
        case stop, terminalWithoutCancellation, changedContext, sameValueGeneration, sameValueStageASlot
    }

    /// Actual retry -> App callback -> concrete service/router -> finite client.
    /// Observe onStarted publication, not a copied coordinator operation.
    @Test(.timeLimit(.minutes(1)), arguments: StartedReentry.allCases)
    func actualStartedPublicationCannotAdmitAnObsoleteFirstAnswer(reentry: StartedReentry) async throws {
        let fixture = try StageAAwaitEntryFixture()
        let owner = fixture.app.generationCoordinator
        var root: Task<Void, Never>?
        var replacement: Task<String, Error>?
        var originalChild: Task<String, Error>?
        var cancelledAtPublication: Bool?
        var reentered = false
        var observation: AnyCancellable?
        do {
            observation = fixture.app.$lastProviderOperation.sink { operation in
                guard !reentered, operation == "Stage A first-answer stream started",
                      let identity = owner.activeGeneration?.identity else { return }
                reentered = true
                originalChild = owner.stageATask
                switch reentry {
                case .stop:
                    fixture.app.cancelActiveGenerationForStop()
                case .terminalWithoutCancellation:
                    owner.markTerminal(generationID: identity.generationID)
                case .changedContext:
                    let next = GenerationIdentity(acceptedQuestionID: identity.acceptedQuestionID,
                        generationID: identity.generationID, sessionID: identity.sessionID,
                        questionText: identity.questionText, normalizedQuestionText: identity.normalizedQuestionText,
                        questionIntent: identity.questionIntent, promptPrimaryQuestion: identity.promptPrimaryQuestion,
                        ingressIdentity: identity.ingressIdentity, contextSnapshotID: "synthetic-started-replacement-context")
                    owner.activate(identity: next, persistenceTicket: 2,
                        triggerPath: .regenerate, startedAt: Date())
                case .sameValueGeneration:
                    owner.activate(identity: identity, persistenceTicket: 2,
                        triggerPath: .regenerate, startedAt: Date())
                case .sameValueStageASlot:
                    let next = Task<String, Error> { "Finite replacement child" }
                    replacement = next
                    #expect(owner.registerStageATask(next, generationID: identity.generationID))
                }
                cancelledAtPublication = originalChild?.isCancelled
            }
            await fixture.submitAcceptedQuestion()
            let request = try #require(fixture.app.activeAITask)
            root = request
            try await fixture.join(request)
            _ = await originalChild?.result
            observation?.cancel(); observation = nil
            #expect(reentered && originalChild != nil,
                "Reentry must occur inside the actual App onStarted callback with its registered child.")
            #expect(cancelledAtPublication == (reentry != .terminalWithoutCancellation),
                "The terminal case tests publication authority independently of cooperative cancellation.")
            #expect(fixture.client.firstAnswerCallCount == 0,
                "After onStarted revokes this child, the real service/router must not call the stream client.")
            if let replacement {
                #expect(owner.stageATask == replacement && !replacement.isCancelled,
                    "An old actual root must not clear the newer same-value Stage A slot.")
            }
            await fixture.close(roots: [request], children: replacement.map { [$0] } ?? [])
            #expect(owner.pendingCleanupTaskCount == 0)
        } catch {
            observation?.cancel()
            await fixture.close(roots: root.map { [$0] } ?? [],
                children: replacement.map { [$0] } ?? [])
            throw error
        }
    }

    enum TokenReentry: String, CaseIterable, Sendable {
        case firstVisibleTelemetry, livePreview
    }

    /// Finite token through the actual App callback. Observe later writes only:
    /// a post-setter fence cannot undo the Published setter currently in willSet.
    @Test(.timeLimit(.minutes(1)), arguments: TokenReentry.allCases)
    func actualTokenPublicationCannotContinueWritingReplacementPresentation(point: TokenReentry) async throws {
        let fixture = try StageAAwaitEntryFixture()
        let app = fixture.app
        let owner = app.generationCoordinator
        var root: Task<Void, Never>?
        var observation: AnyCancellable?
        var reentered = false
        do {
            await fixture.submitAcceptedQuestion()
            let request = try #require(app.activeAITask)
            root = request
            try await fixture.waitForFirstAnswerAndBothDeadlines()
            let original = try #require(owner.activeGeneration?.identity)
            let originalChild = try #require(owner.stageATask)
            let replacement = GenerationIdentity(acceptedQuestionID: original.acceptedQuestionID,
                generationID: original.generationID, sessionID: original.sessionID,
                questionText: original.questionText, normalizedQuestionText: original.normalizedQuestionText,
                questionIntent: original.questionIntent, promptPrimaryQuestion: original.promptPrimaryQuestion,
                ingressIdentity: original.ingressIdentity, contextSnapshotID: "synthetic-token-replacement-context")
            let marker = "Synthetic replacement preview, separate from the old token."
            @MainActor func replacePresentation() {
                guard !reentered else { return }
                reentered = true
                owner.activate(identity: replacement, persistenceTicket: 2,
                    triggerPath: .regenerate, startedAt: Date())
                app.generationUIState = .idle
                app.streamedSayFirst = marker
                app.streamedSayFirstSetAt = nil
                app.streamFirstSentenceAt = nil
                app.streamFullResponseAt = nil
            }
            switch point {
            case .firstVisibleTelemetry:
                observation = app.generationTelemetryUpdates.sink { value in
                    guard value.generationID == original.generationID, value.firstVisibleAt != nil else { return }
                    replacePresentation()
                }
            case .livePreview:
                observation = app.liveInterview.streamedSayFirstUpdates.sink { value in
                    guard value == StageAAwaitEntryClient.answer else { return }
                    replacePresentation()
                }
            }
            fixture.client.emitFirstAnswerPreview()
            try await fixture.join(request)
            _ = await originalChild.result
            observation?.cancel(); observation = nil
            #expect(reentered && originalChild.isCancelled)
            #expect(owner.isCurrent(replacement))
            #expect(fixture.client.firstAnswerCallCount == 1,
                "This case consumes one finite actual service stream and starts no replacement provider.")
            if point == .firstVisibleTelemetry {
                #expect(app.generationUIState == .idle)
                #expect(app.streamedSayFirst == marker,
                    "After markFirstVisibleAnswer reentry, the older callback must not publish its remaining preview.")
            }
            #expect(app.streamedSayFirstSetAt == nil && app.streamFirstSentenceAt == nil,
                "After either real publication boundary, later old timestamps must not target the replacement.")
            #expect(app.streamFullResponseAt == nil)
            await fixture.close(roots: [request])
            #expect(owner.pendingCleanupTaskCount == 0)
        } catch {
            observation?.cancel()
            await fixture.close(roots: root.map { [$0] } ?? [])
            throw error
        }
    }

    enum PresentationReentry: String, CaseIterable, Sendable {
        case firstTokenTimestamp, firstTokenTelemetry, firstTokenLatency
        case firstVisibleTimestamp, firstVisibleStateTimestamp, firstVisibleTelemetry, firstVisibleLatency
        case streamingPhase, infoLoadingPublication, infoFeedbackPublication
        case previewIntrinsic, previewTimestamp, firstSentenceTimestamp
        case completedPreviewIntrinsic, completedPreviewTimestamp, completedFullResponseTimestamp

        var isCompletion: Bool {
            switch self {
            case .completedPreviewIntrinsic, .completedPreviewTimestamp, .completedFullResponseTimestamp: true
            default: false
            }
        }
    }

    /// One finite real service stream. Reenter at its actual synchronous App/Live
    /// publication; verify both the setter in progress and every later timing write.
    @Test(.timeLimit(.minutes(1)), arguments: PresentationReentry.allCases)
    func actualStageAPublicationPreservesCommittedReplacementPresentation(point: PresentationReentry) async throws {
        let fixture = try StageAAwaitEntryFixture()
        let app = fixture.app
        let owner = app.generationCoordinator
        var root: Task<Void, Never>?
        var originalChild: Task<String, Error>?
        var observation: AnyCancellable?
        var readiness: AnyCancellable?
        var reentered = false
        var committedAtPublication = true
        do {
            await fixture.submitAcceptedQuestion()
            let request = try #require(app.activeAITask)
            root = request
            try await fixture.waitForFirstAnswerAndBothDeadlines()
            let original = try #require(owner.activeGeneration?.identity)
            let child = try #require(owner.stageATask)
            originalChild = child
            let replacement = GenerationIdentity(acceptedQuestionID: original.acceptedQuestionID,
                generationID: original.generationID, sessionID: original.sessionID,
                questionText: original.questionText, normalizedQuestionText: original.normalizedQuestionText,
                questionIntent: original.questionIntent, promptPrimaryQuestion: original.promptPrimaryQuestion,
                ingressIdentity: original.ingressIdentity,
                contextSnapshotID: "synthetic-committed-presentation-" + point.rawValue)
            let previewMarker = "Synthetic replacement presentation: " + point.rawValue
            let tokenMarker = Date(timeIntervalSince1970: 101)
            let visibleMarker = Date(timeIntervalSince1970: 202)
            let visibleStateMarker = Date(timeIntervalSince1970: 303)
            let previewTimeMarker = Date(timeIntervalSince1970: 404)
            let sentenceMarker = Date(timeIntervalSince1970: 505)
            let responseMarker = Date(timeIntervalSince1970: 606)
            let actionMarker = ActionFeedback(actionID: ActionID.generateAnswer,
                title: "Synthetic replacement feedback: " + point.rawValue,
                message: "A separately owned presentation marker.", kind: .loading)
            @MainActor func replacePresentation() {
                guard !reentered else { return }
                reentered = true
                owner.activate(identity: replacement, persistenceTicket: 2,
                    triggerPath: .regenerate, startedAt: Date())
                app.generationUIState = .idle
                app.streamedSayFirst = previewMarker
                app.streamFirstTokenAt = tokenMarker
                app.streamFirstVisibleTextAt = visibleMarker
                app.firstVisibleStateSetAt = visibleStateMarker
                app.streamedSayFirstSetAt = previewTimeMarker
                app.streamFirstSentenceAt = sentenceMarker
                app.streamFullResponseAt = responseMarker
                app.deepseekFirstTokenMS = 77
                app.deepseekFirstVisibleMS = 88
                var telemetry = GenerationTelemetry.idle
                telemetry.generationID = replacement.generationID
                telemetry.questionID = replacement.acceptedQuestionID
                telemetry.firstDeepSeekTokenAt = tokenMarker
                telemetry.firstVisibleAt = visibleMarker
                app.currentGenerationTelemetry = telemetry
                if point == .infoLoadingPublication || point == .infoFeedbackPublication {
                    app.actionLoadingStates[ActionID.generateAnswer] = true
                    app.activeActionFeedbacks = [actionMarker]
                }
                app.actionFeedbackDismissTasks[ActionID.generateAnswer]?.cancel()
                app.actionFeedbackDismissTasks[ActionID.generateAnswer] = nil
            }
            if point.isCompletion {
                // Observe the last token-callback setter, then finish the very same
                // stream without emitting another token. Completion is the entry.
                let ready = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
                readiness = app.streamFirstSentenceAtUpdates.dropFirst().sink { value in
                    if value != nil { ready.continuation.yield(()) }
                }
                fixture.client.emitFirstAnswerPreview()
                _ = try await TestEventWaitTrace(label: "stage-a-presentation.completed-entry")
                    .nextEvent(in: ready.stream, event: "actual-token-callback-last-timestamp")
                readiness?.cancel(); readiness = nil; ready.continuation.finish()
                #expect(app.streamedSayFirst == StageAAwaitEntryClient.answer)
                #expect(app.streamFullResponseAt == nil)
                if point == .completedPreviewTimestamp { app.streamedSayFirstSetAt = nil }
            }
            switch point {
            case .firstTokenTimestamp:
                observation = app.streamFirstTokenAtUpdates.dropFirst().sink { value in
                    guard let value, !reentered else { return }
                    committedAtPublication = app.streamFirstTokenAt == value
                    replacePresentation()
                }
            case .firstTokenTelemetry:
                observation = app.generationTelemetryUpdates.dropFirst().sink { value in
                    guard value.firstDeepSeekTokenAt != nil, !reentered else { return }
                    committedAtPublication = app.currentGenerationTelemetry.firstDeepSeekTokenAt == value.firstDeepSeekTokenAt
                    replacePresentation()
                }
            case .firstTokenLatency:
                observation = app.deepseekFirstTokenMSUpdates.dropFirst().sink { value in
                    guard let value, !reentered else { return }
                    committedAtPublication = app.deepseekFirstTokenMS == value
                    replacePresentation()
                }
            case .firstVisibleLatency:
                observation = app.deepseekFirstVisibleMSUpdates.dropFirst().sink { value in
                    guard let value, !reentered else { return }
                    committedAtPublication = app.deepseekFirstVisibleMS == value
                    replacePresentation()
                }
            case .firstVisibleTimestamp:
                observation = app.streamFirstVisibleTextAtUpdates.dropFirst().sink { value in
                    guard let value, !reentered else { return }
                    committedAtPublication = app.streamFirstVisibleTextAt == value
                    replacePresentation()
                }
            case .firstVisibleStateTimestamp:
                observation = app.firstVisibleStateSetAtUpdates.dropFirst().sink { value in
                    guard let value, !reentered else { return }
                    committedAtPublication = app.firstVisibleStateSetAt == value
                    replacePresentation()
                }
            case .firstVisibleTelemetry:
                observation = app.generationTelemetryUpdates.dropFirst().sink { value in
                    guard value.firstVisibleAt != nil, !reentered else { return }
                    committedAtPublication = app.currentGenerationTelemetry.firstVisibleAt == value.firstVisibleAt
                    replacePresentation()
                }
            case .streamingPhase:
                observation = app.liveInterview.generationStateUpdates.dropFirst().sink { value in
                    guard case .streamingAnswer = value, !reentered else { return }
                    committedAtPublication = app.generationUIState == value
                    replacePresentation()
                }
            case .infoLoadingPublication:
                observation = app.actionLoadingStatesUpdates.dropFirst().sink { value in
                    guard case .streamingAnswer = app.generationUIState,
                          value[ActionID.generateAnswer] == false, !reentered else { return }
                    replacePresentation()
                }
            case .infoFeedbackPublication:
                observation = app.activeActionFeedbacksUpdates.dropFirst().sink { value in
                    guard value.contains(where: { $0.actionID == ActionID.generateAnswer && $0.title == "First answer visible" }),
                          !reentered else { return }
                    replacePresentation()
                }
            case .previewIntrinsic, .completedPreviewIntrinsic:
                observation = app.liveInterview.streamedSayFirstUpdates.dropFirst().sink { value in
                    guard value == StageAAwaitEntryClient.answer, !reentered else { return }
                    committedAtPublication = app.streamedSayFirst == value
                    replacePresentation()
                }
            case .previewTimestamp, .completedPreviewTimestamp:
                observation = app.streamedSayFirstSetAtUpdates.dropFirst().sink { value in
                    guard let value, !reentered else { return }
                    committedAtPublication = app.streamedSayFirstSetAt == value
                    replacePresentation()
                }
            case .firstSentenceTimestamp:
                observation = app.streamFirstSentenceAtUpdates.dropFirst().sink { value in
                    guard let value, !reentered else { return }
                    committedAtPublication = app.streamFirstSentenceAt == value
                    replacePresentation()
                }
            case .completedFullResponseTimestamp:
                observation = app.streamFullResponseAtUpdates.dropFirst().sink { value in
                    guard let value, !reentered else { return }
                    committedAtPublication = app.streamFullResponseAt == value
                    replacePresentation()
                }
            }
            if point.isCompletion { fixture.client.finishFirstAnswerWithoutAnotherToken() }
            else { fixture.client.emitFirstAnswerPreview() }
            try await fixture.join(request)
            _ = await child.result
            observation?.cancel(); observation = nil
            #expect(reentered && child.isCancelled && owner.isCurrent(replacement),
                "Replace from the actual registered child's callback; start no replacement provider.")
            #expect(committedAtPublication, "Read the published property inside its real subscriber.")
            #expect(fixture.client.firstAnswerCallCount == 1)
            #expect(app.generationUIState == .idle)
            #expect(app.streamedSayFirst == previewMarker, "The in-progress old setter must not overwrite its subscriber's replacement.")
            #expect(app.streamFirstTokenAt == tokenMarker)
            #expect(app.streamFirstVisibleTextAt == visibleMarker)
            #expect(app.firstVisibleStateSetAt == visibleStateMarker)
            #expect(app.streamedSayFirstSetAt == previewTimeMarker)
            #expect(app.streamFirstSentenceAt == sentenceMarker)
            #expect(app.streamFullResponseAt == responseMarker)
            #expect(app.deepseekFirstTokenMS == 77 && app.deepseekFirstVisibleMS == 88)
            #expect(app.currentGenerationTelemetry.firstDeepSeekTokenAt == tokenMarker)
            #expect(app.currentGenerationTelemetry.firstVisibleAt == visibleMarker)
            if point == .infoLoadingPublication || point == .infoFeedbackPublication {
                #expect(app.actionLoadingStates[ActionID.generateAnswer] == true,
                    "The old loading setter must preserve the subscriber's replacement state.")
                #expect(app.activeActionFeedbacks == [actionMarker],
                    "The old feedback setter must preserve the frozen replacement feedback ID/value.")
            }
            #expect(app.actionFeedbackDismissTasks[ActionID.generateAnswer] == nil,
                "Old callback tail must not install a new feedback dismissal task after replacement.")
            await fixture.close(roots: [request], children: [child])
            #expect(owner.pendingCleanupTaskCount == 0)
            #expect(fixture.clock.pendingCount == 0 && fixture.observerClock.pendingCount == 0)
        } catch {
            observation?.cancel(); readiness?.cancel()
            await fixture.close(roots: root.map { [$0] } ?? [],
                children: originalChild.map { [$0] } ?? [])
            throw error
        }
    }

    enum ProviderPhaseExit: String, CaseIterable, Sendable { case completed, failed }
    enum ProviderExitPublication: String, CaseIterable, Sendable { case providerPhase, summary, streamPhase }

    /// Actual retry entry and owned stream publication/exit. The summary can
    /// first publish while consuming a token, before EOF. That replacement
    /// must also survive the old awaiter's rejected-result audit tail.
    @Test(.timeLimit(.minutes(1)), arguments: ProviderPhaseExit.allCases, ProviderExitPublication.allCases)
    func actualStageAExitPhaseCannotOverwriteOrRetireReplacement(
        end: ProviderPhaseExit, publication: ProviderExitPublication
    ) async throws {
        let fixture = try StageAAwaitEntryFixture()
        let app = fixture.app
        let owner = app.generationCoordinator
        let replacementGate = StageAAwaitReleaseGate()
        var root: Task<Void, Never>?
        var child: Task<String, Error>?
        var replacementTimer: Task<Void, Never>?
        var observation: AnyCancellable?
        var reentered = false
        var committedAtPublication = false
        do {
            await fixture.submitAcceptedQuestion()
            let request = try #require(app.activeAITask)
            root = request
            try await fixture.waitForFirstAnswerAndBothDeadlines()
            let original = try #require(owner.activeGeneration?.identity)
            let stageA = try #require(owner.stageATask)
            child = stageA
            #expect(app.providerStreamActive)
            let replacement = GenerationIdentity(acceptedQuestionID: original.acceptedQuestionID,
                generationID: original.generationID, sessionID: original.sessionID,
                questionText: original.questionText, normalizedQuestionText: original.normalizedQuestionText,
                questionIntent: original.questionIntent, promptPrimaryQuestion: original.promptPrimaryQuestion,
                ingressIdentity: original.ingressIdentity, contextSnapshotID: "synthetic-exit-context-" + end.rawValue + "-" + publication.rawValue)
            let marker = "Synthetic replacement at provider phase exit: " + end.rawValue + " / " + publication.rawValue
            let time = Date(timeIntervalSince1970: 818)
            let feedback = ActionFeedback(actionID: ActionID.generateAnswer, title: marker,
                message: "Replacement-owned loading feedback.", kind: .loading)
            func replacePresentation(committed: Bool) {
                guard !reentered else { return }
                committedAtPublication = committed
                reentered = true
                owner.activate(identity: replacement, persistenceTicket: 2,
                    triggerPath: .regenerate, startedAt: Date(), answerProviderMode: .deepSeekPrimary)
                let timer = Task { await replacementGate.wait() }
                replacementTimer = timer
                app.registerFallbackWatchdogTask(timer, generationID: replacement.generationID)
                app.generationUIState = .idle
                app.currentSuggestion = nil
                app.providerStreamActive = true
                app.streamedSayFirst = marker
                app.isStreamingSayFirst = true
                app.isExpandingSuggestionCard = false
                app.currentSuggestionSetAt = time
                app.softFallbackUsed = false
                app.softFallbackLatencyMS = 828
                app.softFallbackShownAt = time
                app.finalVisibleSource = marker
                app.streamFirstTokenAt = time
                app.firstVisibleStateSetAt = time
                app.lastAlignmentError = marker
                app.lastProviderOperation = marker
                app.activeTaskSummary = marker
                app.actionLoadingStates[ActionID.generateAnswer] = true
                app.activeActionFeedbacks = [feedback]
                app.actionFeedbackDismissTasks[ActionID.generateAnswer]?.cancel()
                app.actionFeedbackDismissTasks[ActionID.generateAnswer] = nil
            }
            switch publication {
            case .providerPhase:
                observation = app.providerStreamActiveUpdates.dropFirst().sink { value in
                    guard !value else { return }
                    replacePresentation(committed: app.providerStreamActive == value)
                }
            case .summary:
                observation = app.activeTaskSummaryUpdates.dropFirst().sink { value in
                    replacePresentation(committed: app.activeTaskSummary == value)
                }
            case .streamPhase:
                observation = app.liveInterview.isStreamingSayFirstUpdates.dropFirst().sink { value in
                    guard !value else { return }
                    replacePresentation(committed: app.isStreamingSayFirst == value)
                }
            }
            switch end {
            case .completed: fixture.client.completeFirstAnswer()
            case .failed: fixture.client.failFirstAnswer()
            }
            try await fixture.join(request)
            if let child { _ = await child.result }
            observation?.cancel(); observation = nil
            let retained = try #require(replacementTimer)
            #expect(reentered && committedAtPublication,
                "Observe committed phase state inside the actual setter, not a copied callback.")
            #expect(owner.canPublish(replacement))
            #expect(owner.fallbackWatchdogTask == retained && !retained.isCancelled)
            #expect(app.fallbackWatchdogActive && app.providerStreamActive)
            #expect(app.generationUIState == .idle && app.currentSuggestion == nil)
            #expect(app.streamedSayFirst == marker && app.isStreamingSayFirst && !app.isExpandingSuggestionCard)
            #expect(app.currentSuggestionSetAt == time && app.softFallbackShownAt == time)
            #expect(!app.softFallbackUsed && app.softFallbackLatencyMS == 828 && app.finalVisibleSource == marker)
            #expect(app.streamFirstTokenAt == time && app.firstVisibleStateSetAt == time)
            #expect(app.lastAlignmentError == marker && app.lastProviderOperation == marker)
            #expect(app.activeTaskSummary == marker)
            #expect(app.activeActionFeedbacks == [feedback] && app.isActionLoading(ActionID.generateAnswer))
            #expect(app.actionFeedbackDismissTasks[ActionID.generateAnswer] == nil)
            #expect(fixture.client.firstAnswerCallCount == 1)
            replacementGate.release()
            await fixture.close(roots: [request], children: child.map { [$0] } ?? [], timers: [retained])
            #expect(owner.pendingCleanupTaskCount == 0)
            #expect(fixture.clock.pendingCount == 0 && fixture.observerClock.pendingCount == 0)
        } catch {
            observation?.cancel()
            replacementGate.release()
            await fixture.close(roots: root.map { [$0] } ?? [], children: child.map { [$0] } ?? [],
                timers: replacementTimer.map { [$0] } ?? [])
            throw error
        }
    }

    enum DiscardAttribution: String, CaseIterable, Sendable {
        case unknown, oldContext, current, replacedAtCounter, replacedAtTelemetry
    }

    @Test(.timeLimit(.minutes(1)), arguments: DiscardAttribution.allCases)
    func actualDiscardAuditCannotBorrowReplacementTelemetry(point: DiscardAttribution) async throws {
        let fixture = try StageAAwaitEntryFixture()
        let app = fixture.app
        let owner = app.generationCoordinator
        let original = GenerationIdentity(question: fixture.question, generationID: "synthetic-discard-generation",
            contextSnapshotID: "synthetic-discard-original-context")
        let replacement = GenerationIdentity(question: fixture.question, generationID: original.generationID,
            contextSnapshotID: "synthetic-discard-replacement-context")
        let marker = "Synthetic replacement diagnostic summary"
        var observation: AnyCancellable?
        var reentered = false
        func setPresentation() {
            var telemetry = GenerationTelemetry.idle
            telemetry.staleDiscardCount = 73
            app.currentGenerationTelemetry = telemetry
            app.activeTaskSummary = marker
        }
        @MainActor func replace() {
            guard !reentered else { return }
            reentered = true
            owner.activate(identity: replacement, persistenceTicket: 2,
                triggerPath: .regenerate, startedAt: Date())
            setPresentation()
        }
        owner.activate(identity: point == .oldContext ? replacement : original,
            persistenceTicket: 1, triggerPath: .regenerate, startedAt: Date())
        setPresentation()
        if point == .replacedAtCounter {
            observation = app.$staleAnswerDiscardCount.dropFirst().sink { _ in replace() }
        } else if point == .replacedAtTelemetry {
            observation = app.generationTelemetryUpdates.dropFirst().sink { _ in replace() }
        }
        let callbacksBefore = app.staleCallbackDiscardCount
        let answersBefore = app.staleAnswerDiscardCount
        app.recordStaleGenerationDiscard(attributedTo: point == .unknown ? nil : original)
        observation?.cancel()
        #expect(app.staleCallbackDiscardCount == callbacksBefore + 1)
        #expect(app.staleAnswerDiscardCount == answersBefore + 1,
            "Every rejected answer remains in cumulative diagnostics, even without current ownership.")
        if point == .current {
            #expect(app.currentGenerationTelemetry.staleDiscardCount == app.staleCallbackDiscardCount,
                "The existing telemetry field preserves its cumulative-counter semantics.")
            #expect(app.activeTaskSummary != marker)
        } else {
            #expect(app.currentGenerationTelemetry.staleDiscardCount == 73)
            #expect(app.activeTaskSummary == marker,
                "Unknown or replaced identity may not rewrite the current generation's diagnostic projection.")
        }
        if point == .replacedAtCounter || point == .replacedAtTelemetry {
            #expect(reentered && owner.isCurrent(replacement))
        }
        await fixture.close(roots: [])
        #expect(owner.pendingCleanupTaskCount == 0)
    }

    enum FeedbackDismissalEnd: String, CaseIterable, Sendable {
        case replacedWhileWaiting, replacedDuringExpiryPublication, expiresNormally
    }

    /// Uses the existing App entry, feedback IDs and delayProvider clock. No
    /// generation/provider starts; every worker handle is retained and joined.
    @Test(.timeLimit(.minutes(1)), arguments: FeedbackDismissalEnd.allCases)
    func actualFeedbackDismissalCannotRetireAReplacement(end: FeedbackDismissalEnd) async throws {
        let fixture = try StageAAwaitEntryFixture()
        let app = fixture.app
        var timers: [Task<Void, Never>] = []
        var observation: AnyCancellable?
        var replacementTask: Task<Void, Never>?
        var didReplace = false
        let original = ActionFeedback(actionID: ActionID.generateAnswer,
            title: "Synthetic expiring feedback", message: "Original worker", kind: .info, autoDismissAfter: 1)
        let replacement = ActionFeedback(actionID: ActionID.generateAnswer,
            title: "Synthetic replacement feedback", message: "Retained replacement worker", kind: .info, autoDismissAfter: 2)
        do {
            app.setActionFeedback(original)
            let oldTask = try #require(app.actionFeedbackDismissTasks[ActionID.generateAnswer])
            timers.append(oldTask)
            try await fixture.observerClock.waitUntilPending(nanoseconds: 1_000_000_000)
            switch end {
            case .replacedWhileWaiting:
                app.setActionFeedback(replacement)
                let next = try #require(app.actionFeedbackDismissTasks[ActionID.generateAnswer])
                replacementTask = next; timers.append(next); didReplace = true
            case .replacedDuringExpiryPublication:
                observation = app.activeActionFeedbacksUpdates.dropFirst().sink { value in
                    guard !didReplace, !value.contains(where: { $0.id == original.id }) else { return }
                    didReplace = true
                    app.setActionFeedback(replacement)
                    if let next = app.actionFeedbackDismissTasks[ActionID.generateAnswer] {
                        replacementTask = next; timers.append(next)
                    }
                }
                fixture.observerClock.advance(by: 1_000_000_000)
            case .expiresNormally:
                fixture.observerClock.advance(by: 1_000_000_000)
            }
            try await fixture.join(oldTask)
            observation?.cancel(); observation = nil
            switch end {
            case .replacedWhileWaiting, .replacedDuringExpiryPublication:
                let next = try #require(replacementTask)
                try await fixture.observerClock.waitUntilPending(nanoseconds: 2_000_000_000)
                #expect(didReplace && oldTask.isCancelled)
                #expect(!next.isCancelled)
                #expect(app.actionFeedbackDismissTasks[ActionID.generateAnswer] == next,
                    "After the exact old worker exits, its replacement's stored handle must remain authoritative.")
                #expect(app.activeActionFeedbacks == [replacement],
                    "The current replacement feedback ID/value remains owned by the replacement worker.")
            case .expiresNormally:
                #expect(!oldTask.isCancelled)
                #expect(app.actionFeedbackDismissTasks[ActionID.generateAnswer] == nil)
                #expect(app.activeActionFeedbacks.isEmpty)
            }
            #expect(fixture.client.firstAnswerCallCount == 0)
            await fixture.close(roots: [], timers: timers)
            #expect(fixture.observerClock.pendingCount == 0)
            #expect(app.actionFeedbackDismissTasks.isEmpty)
        } catch {
            observation?.cancel()
            await fixture.close(roots: [], timers: timers)
            throw error
        }
    }

    enum GenericActionReentry: String, CaseIterable, Sendable {
        case feedbackNewID, feedbackSameID, clearLoading, clearFeedback
        case beginLoading, completeLoading, infoLoading, warnLoading, failLoading, failFeedbackDiagnostic, failFeedbackSameValueDiagnostic
    }

    /// Reenter the real generic App action methods from their existing committed
    /// publishers. Retain each actual worker even when a broken slot loses it.
    @Test(.timeLimit(.minutes(1)), arguments: GenericActionReentry.allCases)
    func actualGenericActionPublicationCannotRetireReplacementFeedbackOrWorker(point: GenericActionReentry) async throws {
        let fixture = try StageAAwaitEntryFixture()
        let app = fixture.app
        var timers: [Task<Void, Never>] = []
        var observation: AnyCancellable?
        var replacementTask: Task<Void, Never>?
        var didReplace = false
        let baseline = ActionFeedback(actionID: ActionID.generateAnswer,
            title: "Synthetic baseline feedback", message: "Initial owned worker", kind: .info, autoDismissAfter: 1)
        let originalInput = ActionFeedback(actionID: ActionID.generateAnswer,
            title: "Synthetic original caller", message: "Outer caller's feedback", kind: .info, autoDismissAfter: 3)
        // A same-value replay is accepted by the current App API. Its newer
        // worker still has a distinct Task handle even when feedback.id is equal.
        var replacement = point == .feedbackSameID ? originalInput : ActionFeedback(
            actionID: ActionID.generateAnswer, title: "Synthetic subscriber replacement",
            message: "Frozen replacement marker", kind: .loading, autoDismissAfter: 2)
        do {
            app.setActionFeedback(baseline)
            let initialTask = try #require(app.actionFeedbackDismissTasks[ActionID.generateAnswer])
            timers.append(initialTask)
            app.actionLoadingStates[ActionID.generateAnswer] = point != .beginLoading
            try await fixture.observerClock.waitUntilPending(nanoseconds: 1_000_000_000)
            @MainActor func installReplacement() {
                guard !didReplace else { return }
                didReplace = true
                app.actionLoadingStates[ActionID.generateAnswer] = true
                app.setActionFeedback(replacement)
                if point == .failFeedbackDiagnostic || point == .failFeedbackSameValueDiagnostic {
                    app.updateDiagnostics { $0.lastError = "Synthetic replacement diagnostic marker" }
                }
                if let next = app.actionFeedbackDismissTasks[ActionID.generateAnswer] {
                    replacementTask = next; timers.append(next)
                }
            }
            switch point {
            case .feedbackNewID, .feedbackSameID:
                observation = app.activeActionFeedbacksUpdates.dropFirst().sink { value in
                    if value.contains(where: { $0.id == originalInput.id }) { installReplacement() }
                }
            case .failFeedbackSameValueDiagnostic:
                observation = app.activeActionFeedbacksUpdates.dropFirst().sink { values in
                    if let value = values.last(where: { $0.title == "Older failure caller" && $0.kind == .error }) {
                        // Replay the exact immutable error value through the actual
                        // setter. Its newly registered task revokes the old tail.
                        replacement = value
                        installReplacement()
                    }
                }
            case .failFeedbackDiagnostic:
                observation = app.activeActionFeedbacksUpdates.dropFirst().sink { value in
                    if value.contains(where: { $0.title == "Older failure caller" && $0.kind == .error }) { installReplacement() }
                }
            case .clearFeedback:
                observation = app.activeActionFeedbacksUpdates.dropFirst().sink { value in
                    if !value.contains(where: { $0.id == baseline.id }) { installReplacement() }
                }
            case .clearLoading, .beginLoading, .completeLoading, .infoLoading, .warnLoading, .failLoading:
                observation = app.actionLoadingStatesUpdates.dropFirst().sink { value in
                    if value[ActionID.generateAnswer] == (point == .beginLoading) { installReplacement() }
                }
            }
            switch point {
            case .feedbackNewID, .feedbackSameID: app.setActionFeedback(originalInput)
            case .clearLoading, .clearFeedback: app.clearActionFeedback(ActionID.generateAnswer)
            case .beginLoading: app.beginAction(ActionID.generateAnswer, title: "Older loading caller", message: "Original")
            case .completeLoading: app.completeAction(ActionID.generateAnswer, title: "Older success caller", message: "Original", autoDismissAfter: 3)
            case .infoLoading: app.infoAction(ActionID.generateAnswer, title: "Older generic info caller", message: "Original", autoDismissAfter: 3)
            case .warnLoading: app.warnAction(ActionID.generateAnswer, title: "Older warning caller", message: "Original", autoDismissAfter: 3)
            case .failLoading, .failFeedbackDiagnostic, .failFeedbackSameValueDiagnostic: app.failAction(ActionID.generateAnswer, title: "Older failure caller", message: "Original", autoDismissAfter: 3)
            }
            // Capture any obsolete task the old method installed over the real
            // replacement so cleanup owns that handle too, even in the RED run.
            if let current = app.actionFeedbackDismissTasks[ActionID.generateAnswer],
               !timers.contains(where: { $0 == current }) { timers.append(current) }
            observation?.cancel(); observation = nil
            let next = try #require(replacementTask)
            #expect(didReplace)
            #expect(!next.isCancelled)
            #expect(app.actionFeedbackDismissTasks[ActionID.generateAnswer] == next,
                "The exact subscriber-created worker remains the stored owner after the original method returns.")
            #expect(app.activeActionFeedbacks == [replacement])
            #expect(app.actionLoadingStates[ActionID.generateAnswer] == true)
            if point == .failFeedbackDiagnostic || point == .failFeedbackSameValueDiagnostic {
                #expect(app.diagnostics.lastError == "Synthetic replacement diagnostic marker")
            }
            #expect(fixture.client.firstAnswerCallCount == 0)
            await fixture.close(roots: [], timers: timers)
            #expect(fixture.observerClock.pendingCount == 0)
            #expect(app.actionFeedbackDismissTasks.isEmpty)
        } catch {
            observation?.cancel()
            await fixture.close(roots: [], timers: timers)
            throw error
        }
    }

    enum FullValueActionReentry: String, CaseIterable, Sendable { case feedbackPublication, clearLoadingPublication }

    @Test(.timeLimit(.minutes(1)), arguments: FullValueActionReentry.allCases)
    func actualFeedbackSameIDChangedValueCannotAdmitOldTail(point: FullValueActionReentry) async throws {
        let fixture = try StageAAwaitEntryFixture()
        let app = fixture.app
        var observation: AnyCancellable?
        var timers: [Task<Void, Never>] = []
        var didReplace = false
        let original = ActionFeedback(actionID: ActionID.generateAnswer,
            title: "Synthetic same-ID original", message: "Original immutable value", kind: .info,
            createdAt: Date(timeIntervalSince1970: 700),
            autoDismissAfter: point == .feedbackPublication ? 3 : nil)
        let replacement = ActionFeedback(id: original.id, actionID: original.actionID,
            title: "Synthetic same-ID changed value", message: "Replacement with no dismissal",
            kind: .loading, createdAt: original.createdAt, autoDismissAfter: nil)
        do {
            @MainActor func replace() {
                guard !didReplace else { return }
                didReplace = true
                app.setActionFeedback(replacement)
            }
            switch point {
            case .feedbackPublication:
                observation = app.activeActionFeedbacksUpdates.dropFirst().sink { value in
                    if value.contains(original) { replace() }
                }
                app.setActionFeedback(original)
            case .clearLoadingPublication:
                app.setActionFeedback(original)
                app.actionLoadingStates[original.actionID] = true
                observation = app.actionLoadingStatesUpdates.dropFirst().sink { value in
                    if value[original.actionID] == false { replace() }
                }
                app.clearActionFeedback(original.actionID)
            }
            if let current = app.actionFeedbackDismissTasks[original.actionID] { timers.append(current) }
            observation?.cancel(); observation = nil
            #expect(didReplace)
            #expect(app.activeActionFeedbacks == [replacement])
            #expect(app.actionFeedbackDismissTasks[original.actionID] == nil,
                "The changed full value has no dismissal even though its UUID is unchanged.")
            #expect(fixture.client.firstAnswerCallCount == 0)
            await fixture.close(roots: [], timers: timers)
            #expect(fixture.observerClock.pendingCount == 0)
        }
    }

    enum SettingsFeedbackBridgeReentry: String, CaseIterable, Sendable { case loading, feedback, acceptsNormally }

    /// The real App-composed Settings owner emits the missing-key error and
    /// returns before provider admission; no view rendering or provider is used.
    @Test(.timeLimit(.minutes(1)), arguments: SettingsFeedbackBridgeReentry.allCases)
    func actualSettingsFeedbackBridgePreservesSubscriberReplacement(point: SettingsFeedbackBridgeReentry) async throws {
        let fixture = try StageAAwaitEntryFixture()
        let app = fixture.app
        let actionID = ActionID.testDeepSeek
        let replacement = ActionFeedback(actionID: actionID,
            title: "Synthetic feature feedback replacement", message: "Exact replacement marker",
            kind: .loading, createdAt: Date(timeIntervalSince1970: 800), autoDismissAfter: 2)
        var observation: AnyCancellable?
        var emittedValue: ActionFeedback?
        var timers: [Task<Void, Never>] = []
        var replacementTask: Task<Void, Never>?
        var didReplace = false
        do {
            #expect(app.settingsState.providerConfigurations.contains(where: { $0.kind == .deepSeek }))
            #expect(!app.settingsState.keychainDeepSeekKeyExists)
            @MainActor func replace() {
                guard !didReplace else { return }
                didReplace = true
                app.actionLoadingStates[actionID] = true
                app.setActionFeedback(replacement)
                app.updateDiagnostics { $0.lastError = "Synthetic feature diagnostic replacement" }
                if let task = app.actionFeedbackDismissTasks[actionID] {
                    replacementTask = task; timers.append(task)
                }
            }
            if point == .loading {
                observation = app.actionLoadingStatesUpdates.dropFirst().sink { value in
                    if value[actionID] == false { replace() }
                }
            } else {
                observation = app.activeActionFeedbacksUpdates.dropFirst().sink { values in
                    if let value = values.last(where: { $0.actionID == actionID && $0.kind == .error }) {
                        emittedValue = value
                        if point == .feedback { replace() }
                    }
                }
            }
            app.settingsState.testDeepSeekConnection()
            if let current = app.actionFeedbackDismissTasks[actionID],
               !timers.contains(where: { $0 == current }) { timers.append(current) }
            observation?.cancel(); observation = nil
            if point == .acceptsNormally {
                let value = try #require(emittedValue)
                #expect(app.activeActionFeedbacks == [value], "The helper preserves the exact feature-supplied value.")
                #expect(app.actionLoadingStates[actionID] == false)
                #expect(app.diagnostics.lastError == value.message)
                #expect(app.actionFeedbackDismissTasks[actionID] == nil)
            } else {
                let task = try #require(replacementTask)
                #expect(didReplace)
                #expect(!task.isCancelled)
                #expect(app.actionFeedbackDismissTasks[actionID] == task)
                #expect(app.activeActionFeedbacks == [replacement])
                #expect(app.actionLoadingStates[actionID] == true)
                #expect(app.diagnostics.lastError == "Synthetic feature diagnostic replacement")
            }
            #expect(!app.settingsState.isTestingConnection)
            #expect(fixture.client.firstAnswerCallCount == 0)
            await fixture.close(roots: [], timers: timers)
            #expect(fixture.observerClock.pendingCount == 0)
        } catch {
            observation?.cancel()
            await fixture.close(roots: [], timers: timers)
            throw error
        }
    }

    enum ActionDismissalDrainCase: String, CaseIterable {
        case current, replacedTimer, sameValueReplay, cleared, replacementWithoutTimer
    }

    private enum ActionDismissalDrainEvent: Equatable {
        case willAwaitOld
        case entryObserved
        case returned(Bool)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ActionDismissalDrainCase.allCases)
    func actualActionDismissalShutdownJoinsCancelledLaunchUntilExit(_ change: ActionDismissalDrainCase) async throws {
        let fixture = try StageAAwaitEntryFixture()
        let app = fixture.app
        let release = StageAAwaitReleaseGate()
        let delay = StageAUncooperativeFirstActionDismissalDelay(gate: release, clock: fixture.observerClock)
        app.delayProvider = delay
        let actionID = "synthetic.action.dismissal-retirement"
        let feedback = ActionFeedback(actionID: actionID, title: "Synthetic old", message: "Synthetic old feedback",
            kind: .info, autoDismissAfter: 1)
        let events = AsyncStream<ActionDismissalDrainEvent>.makeStream(bufferingPolicy: .unbounded)
        let trace = TestEventWaitTrace(label: #function + "." + change.rawValue)
        var old: Task<Void, Never>?
        var replacement: Task<Void, Never>?
        var shutdown: Task<Bool, Never>?
        var shutdownReturned = false
        @MainActor func cleanup() async {
            old?.cancel(); replacement?.cancel(); shutdown?.cancel()
            release.release()
            fixture.observerClock.cancelAll()
            if let old { await old.value }
            if let replacement { await replacement.value }
            if let shutdown { _ = await shutdown.value }
            app.ancillaryTaskWillAwaitForTesting = nil
            app.verificationShutdownScopeDidObserveForTesting = nil
            delay.finishObservation()
            events.continuation.finish()
            await fixture.close(roots: [])
        }
        do {
            #expect(app.setActionFeedback(feedback))
            let original = try #require(app.actionFeedbackDismissTasks[actionID])
            old = original
            _ = try await trace.nextEvent(in: delay.entered.stream, event: "actual-old-dismissal-delay-entered")
            switch change {
            case .current: break
            case .replacedTimer:
                #expect(app.setActionFeedback(ActionFeedback(actionID: actionID, title: "Synthetic replacement",
                    message: "Synthetic new feedback", kind: .info, autoDismissAfter: 2)))
            case .sameValueReplay:
                #expect(app.setActionFeedback(feedback))
            case .cleared:
                app.clearActionFeedback(actionID)
            case .replacementWithoutTimer:
                #expect(app.setActionFeedback(ActionFeedback(actionID: actionID, title: "Synthetic permanent",
                    message: "Synthetic permanent feedback", kind: .info)))
            }
            if let next = app.actionFeedbackDismissTasks[actionID], next != original {
                replacement = next
                try await fixture.observerClock.waitUntilPending(nanoseconds:
                    change == .sameValueReplay ? 1_000_000_000 : 2_000_000_000)
            }
            if change != .current { #expect(original.isCancelled) }
            app.ancillaryTaskWillAwaitForTesting = { task in
                if task == original { events.continuation.yield(.willAwaitOld) }
            }
            shutdown = Task { @MainActor in
                let result = await app.shutdownResources()
                shutdownReturned = true
                events.continuation.yield(.returned(result))
                return result
            }
            let first = try await trace.nextEvent(in: events.stream, event: "actual-shutdown-old-join-or-return")
            #expect(first == .willAwaitOld,
                "Replacing or clearing an action slot must retain the actual cancelled launch for App drainage.")
            #expect(!shutdownReturned, "Shutdown cannot report completion before the old delay actually exits.")
            release.release()
            await original.value
            if let replacement { await replacement.value }
            let shutdownTask = try #require(shutdown)
            let result = await shutdownTask.value
            #expect(result)
            #expect(app.actionFeedbackDismissTasks.isEmpty)
            #expect(fixture.observerClock.pendingCount == 0)
            // Closed App admission must never create a new dismissal launch.
            #expect(app.setActionFeedback(feedback))
            #expect(app.actionFeedbackDismissTasks.isEmpty)
            #expect(fixture.client.firstAnswerCallCount == 0)
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    enum ActionDismissalInheritedShutdownCase: String, CaseIterable {
        case ownApp, ownAppWithExistingDrain, foreignApp
    }

    @Test(.timeLimit(.minutes(1)), arguments: ActionDismissalInheritedShutdownCase.allCases)
    func actualActionDismissalInheritedChildCannotBorrowItsOwnDrain(_ scope: ActionDismissalInheritedShutdownCase) async throws {
        let fixture = try StageAAwaitEntryFixture()
        let foreign = try StageAAwaitEntryFixture()
        let app = fixture.app
        let release = StageAAwaitReleaseGate()
        let tail = StageAAwaitReleaseGate()
        let childEvents = AsyncStream<ActionDismissalDrainEvent>.makeStream(bufferingPolicy: .unbounded)
        let externalEvents = AsyncStream<ActionDismissalDrainEvent>.makeStream(bufferingPolicy: .unbounded)
        let trace = TestEventWaitTrace(label: #function + "." + scope.rawValue)
        var old: Task<Void, Never>?
        var child: Task<Bool, Never>?
        var external: Task<Bool, Never>?
        let delay = StageAUncooperativeFirstActionDismissalDelay(gate: release, tail: tail,
            clock: fixture.observerClock, onFirstRelease: {
                let target = scope == .foreignApp ? foreign.app : app
                // This is an actual Task child of the actual delay caller;
                // it inherits execution scope while the exact old worker is live.
                child = Task { @MainActor in
                    let result = await target.shutdownResources()
                    childEvents.continuation.yield(.returned(result))
                    return result
                }
            })
        app.delayProvider = delay
        @MainActor func cleanup() async {
            old?.cancel(); child?.cancel(); external?.cancel()
            release.release(); tail.release()
            fixture.observerClock.cancelAll()
            // Releasing both gates lets the delay callback create its child
            // even if the owning test was cancelled before that registration.
            if let old { await old.value }
            if let child { _ = await child.value }
            if let external { _ = await external.value }
            app.ancillaryTaskWillAwaitForTesting = nil
            app.verificationShutdownScopeDidObserveForTesting = nil
            delay.finishObservation()
            childEvents.continuation.finish(); externalEvents.continuation.finish()
            await fixture.close(roots: [])
            await foreign.close(roots: [])
        }
        do {
            let actionID = "synthetic.action.dismissal-inherited-shutdown"
            #expect(app.setActionFeedback(ActionFeedback(actionID: actionID, title: "Synthetic old",
                message: "Synthetic old delay", kind: .info, autoDismissAfter: 1)))
            let original = try #require(app.actionFeedbackDismissTasks[actionID])
            old = original
            _ = try await trace.nextEvent(in: delay.entered.stream, event: "actual-old-dismissal-delay-entered")
            app.clearActionFeedback(actionID)
            #expect(original.isCancelled)
            app.ancillaryTaskWillAwaitForTesting = { task in
                guard task == original else { return }
                if scope == .ownAppWithExistingDrain {
                    externalEvents.continuation.yield(.willAwaitOld)
                } else {
                    childEvents.continuation.yield(.willAwaitOld)
                }
            }
            if scope == .ownAppWithExistingDrain {
                external = Task { @MainActor in
                    let result = await app.shutdownResources()
                    externalEvents.continuation.yield(.returned(result))
                    return result
                }
                let first = try await trace.nextEvent(in: externalEvents.stream,
                    event: "external-drain-old-join-or-return")
                #expect(first == .willAwaitOld)
                // Installed only after the external drain reaches the old
                // worker. This existing App entry hook precedes borrowing.
                app.verificationShutdownScopeDidObserveForTesting = { _ in
                    childEvents.continuation.yield(.entryObserved)
                }
            }
            release.release()
            let first = try await trace.nextEvent(in: childEvents.stream,
                event: "inherited-child-shutdown-entry-result-or-old-join")
            if scope == .ownAppWithExistingDrain {
                #expect(first == .entryObserved)
                // The guard runs synchronously after this existing entry hook.
                // Releasing here makes missing-guard borrowing finite too.
            } else {
                #expect(first == .returned(scope == .foreignApp),
                    "A still-live dismissal scope must reject its own App drainage and admit a foreign App.")
            }
            // Finite even for retention without the scope guard: the test owns
            // this tail gate instead of making the worker await its child.
            tail.release()
            await original.value
            let childTask = try #require(child)
            let result = await childTask.value
            #expect(result == (scope == .foreignApp))
            if let external { #expect(await external.value) }
            #expect(await app.shutdownResources())
            #expect(fixture.client.firstAnswerCallCount == 0)
            #expect(foreign.client.firstAnswerCallCount == 0)
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    enum RecoveryCase: String, CaseIterable, Sendable {
        case normal, afterFirstToken, nonFallbackMode, operationNewIdentity
        case operationReplacementStageB, operationReplacementStageA, operationContextRevoked
    }

    @Test(.timeLimit(.minutes(1)), arguments: RecoveryCase.allCases)
    func actualConfiguredFailureRecoveryKeepsExactNewWorkAndFrozenPolicy(_ change: RecoveryCase) async throws {
        let fixture = try StageAAwaitEntryFixture()
        let local = ManualSnapshotLocalProvider(id: "synthetic-configured-recovery")
        fixture.app.localLLMProviderOverride = local
        fixture.defaults.set("synthetic-recovery-model", forKey: HirevaPreferenceKeys.selectedQwenModel)
        fixture.app.answerProviderModeOverride = change == .nonFallbackMode
            ? .deepSeekPrimary : .deepSeekWithLocalQwenFallback
        let release = StageAAwaitReleaseGate()
        var root: Task<Void, Never>?
        var nextStageA: Task<String, Error>?
        var nextStageB: Task<Void, Never>?
        var observation: AnyCancellable?
        var reentered = false
        var expected: GenerationIdentity?
        do {
            await fixture.submitAcceptedQuestion()
            let originalRoot = try #require(fixture.app.activeAITask)
            root = originalRoot
            try await fixture.waitForFirstAnswerAndBothDeadlines()
            let identity = try #require(fixture.app.activeGenerationController?.identity)
            expected = identity
            if change == .afterFirstToken {
                let preview = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
                let values = fixture.app.liveInterview.streamedSayFirstUpdates.sink { value in
                    if value == StageAAwaitEntryClient.answer { preview.continuation.yield(()) }
                }
                fixture.client.emitFirstAnswerPreview()
                _ = try await TestEventWaitTrace(label: "configured-recovery.actual-first-token")
                    .nextEvent(in: preview.stream, event: "provider-token-published")
                values.cancel(); preview.continuation.finish()
                try #require(fixture.app.streamFirstTokenAt != nil)
            }
            observation = fixture.app.diagnosticsState.activeTaskSummaryUpdates.dropFirst().sink { _ in
                guard !reentered,
                      fixture.app.lastProviderOperation == "Local Qwen fallback generation started" else { return }
                switch change {
                case .normal, .afterFirstToken, .nonFallbackMode: return
                default: break
                }
                reentered = true
                switch change {
                case .operationNewIdentity:
                    var question = fixture.question
                    question.id = "synthetic-operation-next-question"
                    question.questionText = "Explain transaction isolation and atomicity."
                    fixture.app.activateGeneration(question: question,
                        generationID: "synthetic-operation-next-generation", triggerPath: .regenerate,
                        requestStart: Date(), source: .systemAudio, speaker: .unknown)
                    fixture.app.lastDetectedQuestion = question
                    expected = fixture.app.activeGenerationController?.identity
                    let task = Task<String, Error> { await release.wait(); return "Finite replacement provider" }
                    nextStageA = task
                    fixture.app.registerStageATask(task, generationID: "synthetic-operation-next-generation")
                case .operationReplacementStageB:
                    let task = Task { await release.wait() }
                    nextStageB = task
                    fixture.app.registerStageBTask(task, generationID: identity.generationID)
                case .operationReplacementStageA:
                    let task = Task<String, Error> { await release.wait(); return "Finite same-identity provider" }
                    nextStageA = task
                    fixture.app.registerStageATask(task, generationID: identity.generationID)
                case .operationContextRevoked:
                    fixture.app.selectInterviewDomain(.roboticsResearch)
                default: break
                }
            }
            fixture.client.failFirstAnswer()
            try await fixture.join(originalRoot)
            observation?.cancel(); observation = nil
            let requests = await local.requests()
            switch change {
            case .normal:
                #expect(requests.count == 1 && requests.first?.modelName == "synthetic-recovery-model")
                #expect(fixture.app.currentSuggestion?.sayFirstSource == "ollama_qwen")
                #expect(fixture.app.currentSuggestion?.detectedQuestionID == fixture.question.id)
                #expect(fixture.app.generationUIState.isTerminal)
            case .afterFirstToken:
                #expect(requests.isEmpty)
                #expect(fixture.app.currentSuggestion?.sayFirst == StageAAwaitEntryClient.answer)
                #expect(fixture.app.currentSuggestion?.sayFirstSource == "deepseek_stream")
            case .nonFallbackMode:
                #expect(requests.isEmpty && !reentered)
                #expect(fixture.app.generationUIState.isTerminal)
            case .operationContextRevoked:
                #expect(reentered && requests.isEmpty)
                #expect(fixture.app.currentGenerationID == nil && fixture.app.currentSuggestion == nil)
            case .operationNewIdentity, .operationReplacementStageA, .operationReplacementStageB:
                let retained = try #require(expected)
                #expect(reentered && requests.isEmpty,
                    "Replacement at the real operation publication cannot execute the old local recovery.")
                #expect(fixture.app.generationCoordinator.canPublish(retained))
                #expect(!fixture.app.generationUIState.isTerminal)
                if let nextStageA {
                    #expect(fixture.app.generationCoordinator.stageATask == nextStageA && !nextStageA.isCancelled)
                    #expect(fixture.app.providerStreamActive)
                }
                if let nextStageB {
                    #expect(fixture.app.stageBTask == nextStageB && !nextStageB.isCancelled)
                }
            }
            #expect(fixture.client.firstAnswerCallCount == 1)
            release.release()
            await fixture.close(roots: [originalRoot], children: nextStageA.map { [$0] } ?? [],
                timers: nextStageB.map { [$0] } ?? [])
            #expect(fixture.app.generationCoordinator.pendingCleanupTaskCount == 0)
        } catch {
            observation?.cancel(); release.release()
            await fixture.close(roots: root.map { [$0] } ?? [], children: nextStageA.map { [$0] } ?? [],
                timers: nextStageB.map { [$0] } ?? [])
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func actualLocalRecoveryAwaitCannotFailNewSameIdentityProvider() async throws {
        let fixture = try StageAAwaitEntryFixture()
        let oldRelease = StageAAwaitReleaseGate()
        let nextRelease = StageAAwaitReleaseGate()
        let local = StageARecoveryHeldLocalProvider(gate: oldRelease)
        fixture.app.localLLMProviderOverride = local
        fixture.app.answerProviderModeOverride = .deepSeekWithLocalQwenFallback
        var root: Task<Void, Never>?
        var next: Task<String, Error>?
        do {
            await fixture.submitAcceptedQuestion()
            let request = try #require(fixture.app.activeAITask)
            root = request
            try await fixture.waitForFirstAnswerAndBothDeadlines()
            let identity = try #require(fixture.app.activeGenerationController?.identity)
            fixture.client.failFirstAnswer()
            _ = try await TestEventWaitTrace(label: "configured-recovery.actual-held-local")
                .nextEvent(in: local.entered.stream, event: "real-local-sequence-entered")
            let originalLocal = try #require(fixture.app.generationCoordinator.stageATask)
            let replacement = Task<String, Error> {
                await nextRelease.wait()
                return "Finite later provider of this same identity"
            }
            next = replacement
            fixture.app.registerStageATask(replacement, generationID: identity.generationID)
            #expect(originalLocal.isCancelled)
            oldRelease.release()
            try await fixture.join(request)
            #expect(fixture.app.generationCoordinator.isCurrent(identity))
            #expect(fixture.app.generationCoordinator.canPublish(identity))
            #expect(fixture.app.generationCoordinator.stageATask == replacement && !replacement.isCancelled)
            #expect(fixture.app.providerStreamActive && !fixture.app.generationUIState.isTerminal)
            #expect(fixture.app.currentSuggestion == nil)
            #expect(await local.count() == 1)
            nextRelease.release()
            local.entered.continuation.finish()
            await fixture.close(roots: [request], children: [replacement])
            #expect(fixture.app.generationCoordinator.pendingCleanupTaskCount == 0)
        } catch {
            oldRelease.release(); nextRelease.release(); local.entered.continuation.finish()
            await fixture.close(roots: root.map { [$0] } ?? [], children: next.map { [$0] } ?? [])
            throw error
        }
    }

    enum TerminalHelperEntryCase: String, CaseIterable, Sendable {
        case fullNormal, fullTelemetryNewIdentity, fullPhaseNewIdentity, fullTerminalNewIdentity
        case fullTelemetryNewRole, fullOwnerPublicationNewRole, failureNormal, failureStreamingNewIdentity
        case failureTelemetryNewIdentity, failureTerminalNewIdentity, failureStreamingNewRole, failureOwnerPublicationNewIdentity
        var usesFullCard: Bool { rawValue.hasPrefix("full") }
        var replacesSameIdentityRole: Bool { self == .fullTelemetryNewRole || self == .failureStreamingNewRole || self == .fullOwnerPublicationNewRole }
        var isNormal: Bool { self == .fullNormal || self == .failureNormal }
    }

    // This isolates the actual terminal helpers at their admitted-result boundary.
    // It does not claim that a direct helper call creates a qualified UI answer.
    @Test(.timeLimit(.minutes(1)), arguments: TerminalHelperEntryCase.allCases)
    func actualTerminalHelperPublicationCannotClearNewProvider(_ change: TerminalHelperEntryCase) async throws {
        let fixture = try StageAAwaitEntryFixture()
        let release = StageAAwaitReleaseGate()
        var root: Task<Void, Never>?
        var child: Task<String, Error>?
        var observation: AnyCancellable?
        var reentered = false
        var expected: GenerationIdentity?
        do {
            await fixture.submitAcceptedQuestion()
            let originalRoot = try #require(fixture.app.activeAITask)
            root = originalRoot
            try await fixture.waitForFirstAnswerAndBothDeadlines()
            let controller = try #require(fixture.app.activeGenerationController)
            let original = controller.identity
            @MainActor func replaceProvider() {
                guard !change.isNormal, !reentered else { return }
                reentered = true
                if !change.replacesSameIdentityRole {
                    var question = fixture.question
                    question.id = "synthetic-helper-replacement-question"
                    question.questionText = "Explain transaction isolation and atomicity."
                    fixture.app.activateGeneration(question: question,
                        generationID: "synthetic-helper-replacement-generation", triggerPath: .regenerate,
                        requestStart: Date(), source: .systemAudio, speaker: .unknown)
                    fixture.app.lastDetectedQuestion = question
                }
                expected = fixture.app.activeGenerationController?.identity
                guard let identity = expected else { return }
                fixture.app.currentGenerationTelemetry.fullCardAt = nil
                fixture.app.currentGenerationTelemetry.failureReason = nil
                fixture.app.currentGenerationTelemetry.providerError = "synthetic-new-provider-marker"
                fixture.app.generationUIState = .generatingFirstAnswer(questionID: identity.acceptedQuestionID,
                    generationID: identity.generationID, triggerPath: controller.triggerPath)
                fixture.app.isStreamingSayFirst = true
                fixture.app.isExpandingSuggestionCard = true
                fixture.app.actionLoadingStates[ActionID.generateAnswer] = true
                fixture.app.actionLoadingStates[ActionID.manualGenerate] = true
                let next = Task<String, Error> { await release.wait(); return "Finite replacement provider" }
                child = next
                fixture.app.registerStageATask(next, generationID: identity.generationID)
            }
            switch change {
            case .fullTelemetryNewIdentity, .fullTelemetryNewRole:
                observation = fixture.app.liveInterview.generationTelemetryUpdates.dropFirst().sink { value in
                    if value.generationID == original.generationID && value.fullCardAt != nil { replaceProvider() }
                }
            case .fullPhaseNewIdentity:
                observation = fixture.app.providerStreamActiveUpdates.dropFirst().sink { value in
                    if !value { replaceProvider() }
                }
            case .fullTerminalNewIdentity, .failureTerminalNewIdentity:
                observation = fixture.app.liveInterview.generationStateUpdates.dropFirst().sink { value in
                    if value.generationID == original.generationID && value.isTerminal { replaceProvider() }
                }
            case .failureStreamingNewIdentity, .failureStreamingNewRole:
                observation = fixture.app.liveInterview.isStreamingSayFirstUpdates.dropFirst().sink { value in
                    if !value { replaceProvider() }
                }
            case .fullOwnerPublicationNewRole, .failureOwnerPublicationNewIdentity:
                observation = fixture.app.generationCoordinator.objectWillChange.sink {
                    if fixture.app.currentGenerationID == original.generationID &&
                        fixture.app.generationCoordinator.stageATask == nil { replaceProvider() }
                }
            case .failureTelemetryNewIdentity:
                observation = fixture.app.liveInterview.generationTelemetryUpdates.dropFirst().sink { value in
                    if value.generationID == original.generationID && value.failureReason != nil { replaceProvider() }
                }
            case .fullNormal, .failureNormal: break
            }
            if change.usesFullCard {
                fixture.app.markFullCardVisible(generationID: original.generationID)
            } else {
                fixture.app.markGenerationFailed(generationID: original.generationID,
                    reason: "Synthetic old provider failure", providerError: "Synthetic old provider diagnostic")
            }
            observation?.cancel(); observation = nil
            if change.isNormal {
                #expect(!reentered && fixture.app.generationUIState.isTerminal)
                #expect(!fixture.app.providerStreamActive && fixture.app.generationCoordinator.stageATask == nil)
                #expect(fixture.app.terminalGenerationIDs.contains(original.generationID))
            } else {
                let retained = try #require(expected)
                let next = try #require(child)
                #expect(reentered && fixture.app.generationCoordinator.isCurrent(retained))
                #expect(fixture.app.generationCoordinator.canPublish(retained))
                #expect(fixture.app.generationCoordinator.stageATask == next && !next.isCancelled)
                #expect(fixture.app.providerStreamActive && fixture.app.isStreamingSayFirst)
                #expect(fixture.app.isExpandingSuggestionCard && !fixture.app.generationUIState.isTerminal)
                #expect(fixture.app.isActionLoading(ActionID.generateAnswer))
                #expect(fixture.app.isActionLoading(ActionID.manualGenerate))
                #expect(fixture.app.currentGenerationTelemetry.providerError == "synthetic-new-provider-marker")
                #expect(fixture.app.currentGenerationTelemetry.failureReason == nil)
                #expect(fixture.app.currentGenerationTelemetry.fullCardAt == nil)
            }
            release.release()
            await fixture.close(roots: [originalRoot], children: child.map { [$0] } ?? [])
            #expect(fixture.app.generationCoordinator.pendingCleanupTaskCount == 0)
        } catch {
            observation?.cancel(); release.release()
            await fixture.close(roots: root.map { [$0] } ?? [], children: child.map { [$0] } ?? [])
            throw error
        }
    }

    enum LegacyGenerationField: String, CaseIterable, Sendable { case busyFailure, timeFailure, timeFullCard }

    @Test(.timeLimit(.minutes(1)), arguments: LegacyGenerationField.allCases)
    func actualTerminalHelperAppNotificationCannotOverwriteNewLiveField(_ field: LegacyGenerationField) async throws {
        let fixture = try StageAAwaitEntryFixture()
        let release = StageAAwaitReleaseGate()
        let originalTime = Date(timeIntervalSince1970: 100)
        let replacementTime = Date(timeIntervalSince1970: 200)
        var root: Task<Void, Never>?
        var child: Task<String, Error>?
        var observation: AnyCancellable?
        var matchingNotifications = 0
        var reentered = false
        var observedBusy: Bool?
        var observedTime: Date?
        var expected: GenerationIdentity?
        do {
            await fixture.submitAcceptedQuestion()
            let originalRoot = try #require(fixture.app.activeAITask)
            root = originalRoot
            try await fixture.waitForFirstAnswerAndBothDeadlines()
            let identity = try #require(fixture.app.activeGenerationController?.identity)
            fixture.app.suggestionGenerationStarted = true
            fixture.app.lastGenerationStateChangeAt = originalTime
            fixture.app.isStreamingSayFirst = true
            fixture.app.isExpandingSuggestionCard = true
            observation = fixture.app.objectWillChange.sink {
                guard !reentered, fixture.app.currentGenerationID == identity.generationID else { return }
                switch field {
                case .busyFailure:
                    guard !fixture.app.isStreamingSayFirst && !fixture.app.isExpandingSuggestionCard else { return }
                    // The first matching relay is expansion=false. Its immediate
                    // successor is the real busy setter's App notification.
                case .timeFailure, .timeFullCard:
                    guard fixture.app.terminalGenerationIDs.contains(identity.generationID),
                          fixture.app.generationUIState.isTerminal else { return }
                    // The first matching relay is the committed terminal owner.
                    // Its immediate successor is the real timestamp setter.
                }
                matchingNotifications += 1
                guard matchingNotifications == 2 else { return }
                reentered = true
                observedBusy = fixture.app.suggestionGenerationStarted
                observedTime = fixture.app.lastGenerationStateChangeAt
                var question = fixture.question
                question.id = "synthetic-committed-field-next-question"
                question.questionText = "Explain transaction isolation and atomicity."
                fixture.app.activateGeneration(question: question,
                    generationID: "synthetic-committed-field-next-generation", triggerPath: .regenerate,
                    requestStart: Date(), source: .systemAudio, speaker: .unknown)
                fixture.app.lastDetectedQuestion = question
                expected = fixture.app.activeGenerationController?.identity
                fixture.app.suggestionGenerationStarted = true
                fixture.app.lastGenerationStateChangeAt = replacementTime
                fixture.app.actionLoadingStates[ActionID.generateAnswer] = true
                let producer = Task<String, Error> { await release.wait(); return "Finite next generation provider" }
                child = producer
                fixture.app.registerStageATask(producer, generationID: "synthetic-committed-field-next-generation")
            }
            if field == .timeFullCard {
                fixture.app.markFullCardVisible(generationID: identity.generationID)
            } else {
                fixture.app.markGenerationFailed(generationID: identity.generationID, reason: "Synthetic prior field transition")
            }
            observation?.cancel(); observation = nil
            let retained = try #require(expected)
            let producer = try #require(child)
            #expect(reentered && matchingNotifications == 2)
            #expect(fixture.app.generationCoordinator.canPublish(retained))
            #expect(fixture.app.generationCoordinator.stageATask == producer && !producer.isCancelled)
            #expect(fixture.app.providerStreamActive && !fixture.app.generationUIState.isTerminal)
            #expect(fixture.app.suggestionGenerationStarted,
                "The old setter cannot overwrite the busy fact read by queueDrainBlockReasonForCurrentState.")
            #expect(fixture.app.lastGenerationStateChangeAt == replacementTime)
            #expect(fixture.app.isActionLoading(ActionID.generateAnswer))
            if field == .busyFailure {
                #expect(observedBusy == false, "The actual App notification must observe the committed busy=false value.")
            } else {
                #expect(observedTime != originalTime, "The actual App notification must observe the committed transition time.")
            }
            release.release()
            await fixture.close(roots: [originalRoot], children: [producer])
            #expect(fixture.app.generationCoordinator.pendingCleanupTaskCount == 0)
        } catch {
            observation?.cancel(); release.release()
            await fixture.close(roots: root.map { [$0] } ?? [], children: child.map { [$0] } ?? [])
            throw error
        }
    }

    enum End: String, CaseIterable { case completed, deadline, cancelled }
}

@MainActor
private final class StageAAwaitEntryFixture {
    let database: AppDatabase
    let suite = "com.langcheng.Hireva.tests.stage-a-await-" + UUID().uuidString
    let defaults: UserDefaults
    let clock = ControlledGenerationWatchdogClock()
    let observerClock = ControlledGenerationWatchdogClock()
    let client = StageAAwaitEntryClient()
    let app: AppState
    let question: DetectedQuestion
    init() throws {
        database = try AppDatabase(inMemory: true)
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(AnswerProviderMode.deepSeekPrimary.rawValue, forKey: HirevaPreferenceKeys.answerProviderMode)
        let settings = SettingsRepository(database: database)
        var initial = AppSettings.default
        initial.saveTranscriptsLocally = false
        try settings.saveSettings(initial)
        try settings.ensureDefaultProviderConfigurations()
        let configuration = try #require(settings.providerConfigurations().first { $0.kind == .deepSeek })
        try settings.setActiveRealtimeProvider(id: configuration.id)
        app = AppState(database: database, questionRoutingProvider: HermeticQuestionRoutingProvider(),
            llmRouter: LLMRouter(settingsRepository: settings, clients: [.deepSeek: client]),
            permissionService: HermeticPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            contextRetrievalService: StageAAwaitEmptyRetrieval(), dialogueDefaults: defaults)
        app.delayProvider = observerClock
        app.generationWatchdogDelayProvider = clock
        app.stageATimeoutSeconds = 6
        let session = try app.createContextBoundSession(mode: .mock)
        app.currentSession = session
        question = .init(id: UUID().uuidString, sessionID: session.id, transcriptSegmentID: nil,
            questionText: "Explain database transactions and atomicity.", intent: .technical,
            answerStrategy: .directAnswer, confidence: 1, reason: "Synthetic Stage A wait",
            shouldTrigger: true, questionComplete: true, modelName: "fixture", promptVersion: "fixture", createdAt: Date())
    }
    func submitAcceptedQuestion() async {
        // Real UI actions wait for their owned context readiness, rather than
        // bypassing it through the removed, unreachable recovery method.
        await app.automaticContextBuildTask?.value
        app.lastDetectedQuestion = question
        app.answerCurrentQuestionOrTranscriptNow()
    }
    func waitForFirstAnswerAndBothDeadlines() async throws {
        _ = try await TestEventWaitTrace(label: "stage-a-await.actual-service")
            .nextEvent(in: client.firstAnswerStarted.stream, event: "first-answer-started")
        // Separate clocks preserve the existing contract: delayProvider owns
        // the visible observer, generationWatchdogDelayProvider the task-group
        // race. Await their readiness, not a wall-clock scheduling delay.
        try await clock.waitUntilPending(nanoseconds: 6_000_000_000)
        try await observerClock.waitUntilPending(nanoseconds: 6_000_000_000)
    }
    func join(_ root: Task<Void, Never>) async throws {
        let clock = self.clock
        let observerClock = self.observerClock
        let client = self.client
        try await withTaskCancellationHandler {
            await root.value
            try Task.checkCancellation()
        } onCancel: {
            root.cancel()
            clock.cancelAll()
            observerClock.cancelAll()
            client.finishAll()
        }
    }
    func close(roots: [Task<Void, Never>], children: [Task<String, Error>] = [], timers: [Task<Void, Never>] = []) async {
        app.cancelActiveGenerationForContextChange()
        clock.cancelAll()
        observerClock.cancelAll()
        client.finishAll()
        roots.forEach { $0.cancel() }; children.forEach { $0.cancel() }; timers.forEach { $0.cancel() }
        for root in roots { await root.value }
        for child in children { _ = await child.result }
        for timer in timers { await timer.value }
        await app.shutdownForTesting()
        try? database.close()
        defaults.removePersistentDomain(forName: suite)
    }
}

private final class StageAAwaitEntryClient: LLMClientProtocol {
    let providerKind: LLMProviderKind = .deepSeek
    static let answer = "A database transaction groups operations into an atomic unit. Atomicity means all operations commit together or roll back together, and isolation controls which concurrent changes each transaction can observe."
    let firstAnswerStarted = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private struct State: Sendable {
        var continuations: [String: AsyncThrowingStream<String, Error>.Continuation] = [:]
        var firstAnswerCancelled = false
        var firstAnswerCallCount = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var firstAnswerCancelled: Bool { state.withLock { $0.firstAnswerCancelled } }
    var firstAnswerCallCount: Int { state.withLock { $0.firstAnswerCallCount } }
    func chatCompletionStream(configuration: LLMProviderConfiguration, messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?, options: LLMRequestOptions) -> AsyncThrowingStream<String, Error> {
        let isFirst = options.temperature == 0.1
        let phase = isFirst ? "firstAnswer" : "sections"
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { [weak self] end in
                guard isFirst, case .cancelled = end else { return }
                self?.state.withLock { $0.firstAnswerCancelled = true }
            }
            state.withLock { current in
                current.continuations[phase] = continuation
                if isFirst { current.firstAnswerCallCount += 1 }
            }
            if isFirst { firstAnswerStarted.continuation.yield(()) }
        }
    }
    func emitFirstAnswerPreview() {
        let continuation = state.withLock { $0.continuations["firstAnswer"] }
        continuation?.yield(Self.answer)
    }
    func completeFirstAnswer() {
        let continuation = state.withLock { $0.continuations.removeValue(forKey: "firstAnswer") }
        continuation?.yield(Self.answer)
        continuation?.finish()
    }
    func finishFirstAnswerWithoutAnotherToken() {
        let continuation = state.withLock { $0.continuations.removeValue(forKey: "firstAnswer") }
        continuation?.finish()
    }
    func failFirstAnswer() {
        let continuation = state.withLock { $0.continuations.removeValue(forKey: "firstAnswer") }
        continuation?.finish(throwing: LLMProviderError.invalidResponse("Synthetic Stage A stream failure"))
    }
    func finishAll() {
        let continuations = state.withLock { state in
            let values = Array(state.continuations.values); state.continuations.removeAll(); return values
        }
        for continuation in continuations { continuation.finish() }
        firstAnswerStarted.continuation.finish()
    }
    func chatCompletion(configuration: LLMProviderConfiguration, messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?, options: LLMRequestOptions) async throws -> LLMChatResult {
        throw LLMProviderError.notConfigured("Synthetic non-streaming request")
    }
    func testConnection(configuration: LLMProviderConfiguration) async throws -> LLMConnectionTestResult {
        .init(success: true, message: "Synthetic", latencyMS: 0, models: [])
    }
    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] { [] }
}

private final class StageAAwaitReleaseGate: Sendable {
    private struct State: Sendable {
        var released = false
        var continuation: CheckedContinuation<Void, Never>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    func wait() async {
        await withCheckedContinuation { continuation in
            let releaseNow = state.withLock { state in
                if state.released { return true }
                state.continuation = continuation
                return false
            }
            if releaseNow { continuation.resume() }
        }
    }
    func release() {
        let continuation = state.withLock { state in
            state.released = true
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

// Holds only the first actual dismissal sleep. Cancellation intentionally does
// not release this gate; every test path releases it and joins the real worker.
private final class StageAUncooperativeFirstActionDismissalDelay: DelayProvider, Sendable {
    private let first = OSAllocatedUnfairLock(initialState: true)
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private let gate: StageAAwaitReleaseGate
    private let tail: StageAAwaitReleaseGate?
    private let clock: ControlledGenerationWatchdogClock
    private let onFirstRelease: (@MainActor @Sendable () -> Void)?
    init(gate: StageAAwaitReleaseGate, tail: StageAAwaitReleaseGate? = nil,
        clock: ControlledGenerationWatchdogClock, onFirstRelease: (@MainActor @Sendable () -> Void)? = nil) {
        self.gate = gate; self.tail = tail; self.clock = clock; self.onFirstRelease = onFirstRelease
    }
    func sleep(nanoseconds: UInt64) async throws {
        let hold = first.withLock { first in
            if !first { return false }
            first = false
            return true
        }
        if hold {
            entered.continuation.yield(())
            await gate.wait()
            if let onFirstRelease { await onFirstRelease() }
            if let tail { await tail.wait() }
        } else {
            try await clock.sleep(nanoseconds: nanoseconds)
        }
    }
    func finishObservation() { entered.continuation.finish() }
}

private struct StageAAwaitEmptyRetrieval: ContextRetrievalService {
    func retrieveContextWithTrace(question: String, intent: QuestionIntent, maxCVWords: Int,
        maxJDWords: Int, strategy: AnswerStrategy?) async throws -> (context: RetrievedContext, trace: RetrievalTrace) {
        try Task.checkCancellation()
        return (RetrievedContext(cvChunks: [], jobDescriptionChunks: []),
            RetrievalTrace(id: UUID(), query: question, intent: intent.rawValue, createdAt: Date(),
                rankedCVChunks: [], rankedJDChunks: [], includedCVChunks: [], includedJDChunks: [],
                excludedCVChunks: [], excludedJDChunks: [], cvWordsUsed: 0, jdWordsUsed: 0,
                cvWordBudget: maxCVWords, jdWordBudget: maxJDWords, retrievalLatencyMS: 0,
                emptyQueryFallbackUsed: false, zeroScoreFallbackUsed: false))
    }
}

/// Ignores cancellation only behind the test-owned release gate. Every exit
/// releases it before fixture joins; no network or real model is involved.
private actor StageARecoveryHeldLocalProvider: LocalLLMProvider {
    nonisolated let id = "synthetic-held-configured-local-recovery"
    nonisolated var displayName: String { id }
    nonisolated let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private let gate: StageAAwaitReleaseGate
    private var requests = 0
    init(gate: StageAAwaitReleaseGate) { self.gate = gate }
    func count() -> Int { requests }
    func healthCheck(modelName: String) async -> LocalLLMHealth {
        .init(ollamaRunning: true, selectedModel: modelName, modelInstalled: true,
            providerSource: .ollamaQwen, lastError: nil)
    }
    nonisolated func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        requests += 1
        entered.continuation.yield(())
        await gate.wait()
        return AsyncThrowingStream { continuation in
            continuation.yield(.init(text: StageAAwaitEntryClient.answer, source: .ollamaQwen,
                modelName: request.modelName))
            continuation.finish()
        }
    }
}
