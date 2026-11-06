import Combine
import Foundation
import os
import Testing
@testable import Hireva

/// Calls the existing async detection entry and its real QuestionDetectionService.
/// Direct callers own their root; this specifically characterizes admission when
/// cancellation is not the only possible session/context/config invalidation.
@MainActor
struct LiveAutomaticDetectionAdmissionTests {
    @Test(.timeLimit(.minutes(1)), arguments: DetectionOutput.allCases, [false, true])
    fileprivate func firstQuestionPublicationCannotUndoReentrantWorkspaceReplacement(
        output: DetectionOutput, replaceSession: Bool
    ) async throws {
        let fixture = try await DetectionAdmissionFixture(output: output)
        let app = fixture.app, gate = fixture.client
        app.detectionDebounceSeconds = 0
        var replaced = false
        var observedCommittedValue = false
        var replacementError: Error?
        var expectedCurrent: DetectedQuestion?
        var expectedPossible: DetectedQuestion?
        var expectedSessionID: String?
        let publisher: AnyPublisher<DetectedQuestion?, Never> = output == .qualified
            ? app.liveInterview.detectedQuestionUpdates
            : app.liveInterview.possibleQuestionUpdates
        let observer = publisher.dropFirst().sink { question in
            guard !replaced, let question else { return }
            replaced = true
            observedCommittedValue = output == .qualified
                ? app.lastDetectedQuestion == question : app.possibleQuestion == question
            if replaceSession {
                do {
                    let replacement = try app.createContextBoundSession(mode: .mock,
                        title: "Synthetic publication replacement session")
                    app.currentSession = replacement
                    var next = question
                    next.id = UUID().uuidString
                    next.sessionID = replacement.id
                    next.transcriptSegmentID = nil
                    next.questionText = "Explain how indexes change database read latency."
                    next.shouldTrigger = false
                    next.questionComplete = true
                    next.rawJSON = nil
                    next.taskDescriptor = nil
                    app.lastDetectedQuestion = next
                    app.possibleQuestion = output == .possible ? next : nil
                } catch { replacementError = error }
            } else {
                app.clearLiveSession()
            }
            expectedCurrent = app.lastDetectedQuestion
            expectedPossible = app.possibleQuestion
            expectedSessionID = app.currentSession?.id
        }
        var roots: [Task<Void, Never>] = []
        try await withTaskCancellationHandler {
            do {
                app.maybeRunAutomaticDetection(triggeringSegment: fixture.segment)
                let index = try await TestEventWaitTrace(label: "live-detection.question-publication.\(output.rawValue)")
                    .nextEvent(in: gate.entered.stream, event: "provider-held")
                let root = try #require(app.activeDetectionTask)
                roots.append(root)
                gate.release(index)
                await root.value
                let detectionReleased = await app.liveInterview.drainAutomaticDetection()
                await app.generationCoordinator.drainRetiredTasks()
                observer.cancel()
                if let replacementError { throw replacementError }
                #expect(replaced)
                #expect(observedCommittedValue,
                    "Observers must read the submitted question as committed before they replace the workspace.")
                #expect(detectionReleased)
                #expect(app.currentSession?.id == expectedSessionID)
                #expect(app.lastDetectedQuestion == expectedCurrent)
                #expect(app.possibleQuestion == expectedPossible)
                #expect(gate.exited.contains(index))
                #expect(app.liveInterview.pendingAutomaticDetectionTaskCount == 0)
                // The question was admitted before publication; legitimate old
                // history is not equated to a stale UI write or required absent.
                await fixture.close(roots)
            } catch {
                observer.cancel()
                gate.releaseAll()
                roots.forEach { $0.cancel() }
                for task in roots { await task.value }
                await fixture.close(roots)
                throw error
            }
        } onCancel: { gate.releaseAll() }
    }

    @Test(.timeLimit(.minutes(1)), arguments: DetectionOutput.allCases, [false, true])
    fileprivate func providerLabelRefreshKeepsTheSubmittedDetectorRequest(
        output: DetectionOutput, registeredEntry: Bool
    ) async throws {
        let fixture = try await DetectionAdmissionFixture(output: output)
        let app = fixture.app
        let gate = fixture.client
        let submitted = try #require(app.activeRealtimeProvider)
        let ticket = app.persistenceConsent.ticket()
        app.detectionDebounceSeconds = 0
        var roots: [Task<Void, Never>] = []
        try await withTaskCancellationHandler {
            do {
                if registeredEntry {
                    app.maybeRunAutomaticDetection(triggeringSegment: fixture.segment)
                } else {
                    roots.append(Task { @MainActor in
                        await app.runAutomaticDetection(session: fixture.session,
                            detectionTranscript: output.transcript,
                            suggestionTranscript: output.transcript,
                            triggeringSegmentID: fixture.segment.id)
                    })
                }
                let index = try await TestEventWaitTrace(label: "live-detection.provider-label.\(registeredEntry)")
                    .nextEvent(in: gate.entered.stream, event: "provider-held")
                #expect(index == 1)
                roots.append(try #require(app.activeDetectionTask))
                var renamed = submitted
                renamed.name = "Synthetic renamed display label"
                app.saveProviderConfiguration(renamed)
                let refreshed = try #require(app.activeRealtimeProvider)
                #expect(refreshed.name == renamed.name)
                #expect(refreshed.id == submitted.id)
                #expect(refreshed.kind == submitted.kind)
                #expect(refreshed.baseURL == submitted.baseURL)
                #expect(refreshed.model == submitted.model)
                #expect(refreshed.apiKeyAccount == submitted.apiKeyAccount)
                #expect(app.persistenceConsent.isCurrent(ticket: ticket))
                let countAtRelease = app.detectedQuestionsInSessionCount
                gate.release(index)
                for root in roots { await root.value }
                await app.generationCoordinator.drainRetiredTasks()
                let accepted = try #require(app.lastDetectedQuestion)
                #expect(accepted.sessionID == fixture.session.id)
                #expect(accepted.shouldTrigger == (output == .qualified))
                #expect(gate.requests.count == 1)
                #expect(gate.requests.first == submitted,
                    "The request keeps its submitted configuration; a label refresh does not rebuild it.")
                #expect(gate.exited.contains(index))
                let saved = try app.suggestionRepository.questions(sessionID: fixture.session.id)
                #expect(saved.contains { $0.id == accepted.id })
                if output == .qualified {
                    #expect(app.detectedQuestionsInSessionCount == countAtRelease + 1)
                } else {
                    #expect(app.possibleQuestion?.id == accepted.id)
                    #expect(app.detectedQuestionsInSessionCount == countAtRelease)
                }
                await fixture.close(roots)
            } catch {
                gate.releaseAll()
                roots.forEach { $0.cancel() }
                for root in roots { await root.value }
                await fixture.close(roots)
                throw error
            }
        } onCancel: { gate.releaseAll() }
    }

    @Test(.timeLimit(.minutes(1)), arguments: DetectionOutput.allCases,
        [false, true].flatMap { registered in [false, true].map { (registered, $0) } })
    fileprivate func normalAnswerModeSettingCannotReauthorizeAnOldDetector(
        output: DetectionOutput, entryAndMutation: (Bool, Bool)
    ) async throws {
        let (registeredEntry, changeMode) = entryAndMutation
        let fixture = try await DetectionAdmissionFixture(output: output)
        let app = fixture.app, gate = fixture.client
        // Remove the fixture-only effective-mode override before submission.
        // All semantic mutations below use the real product Settings entry.
        app.answerProviderModeOverride = nil
        app.setSelectedAnswerProviderMode(.deepSeekPrimary)
        #expect(app.selectedAnswerProviderMode == .deepSeekPrimary)
        #expect(app.settingsState.selectedAnswerProviderMode == .deepSeekPrimary)
        let ticket = app.persistenceConsent.ticket()
        app.detectionDebounceSeconds = 0
        var roots: [Task<Void, Never>] = []
        try await withTaskCancellationHandler {
            do {
                if registeredEntry {
                    app.maybeRunAutomaticDetection(triggeringSegment: fixture.segment)
                } else {
                    roots.append(Task { @MainActor in
                        await app.runAutomaticDetection(session: fixture.session,
                            detectionTranscript: output.transcript,
                            suggestionTranscript: output.transcript,
                            triggeringSegmentID: fixture.segment.id)
                    })
                }
                let index = try await TestEventWaitTrace(label: "live-detection.answer-mode.\(registeredEntry).\(changeMode)")
                    .nextEvent(in: gate.entered.stream, event: "provider-held")
                #expect(index == 1)
                let original = try #require(app.activeDetectionTask)
                roots.append(original)
                if changeMode {
                    app.setSelectedAnswerProviderMode(.localQwenPrimary)
                    #expect(app.selectedAnswerProviderMode == .localQwenPrimary)
                    app.setSelectedAnswerProviderMode(.deepSeekPrimary)
                } else {
                    app.setSelectedAnswerProviderMode(.deepSeekPrimary)
                }
                #expect(app.answerProviderModeOverride == nil)
                #expect(app.selectedAnswerProviderMode == .deepSeekPrimary)
                #expect(app.settingsState.selectedAnswerProviderMode == .deepSeekPrimary)
                #expect(app.persistenceConsent.isCurrent(ticket: ticket) == !changeMode)
                let currentAtRelease = app.lastDetectedQuestion
                let possibleAtRelease = app.possibleQuestion
                let countAtRelease = app.detectedQuestionsInSessionCount
                let queueAtRelease = app.pendingAcceptedQuestions.count
                let generationAtRelease = app.currentGenerationID
                let diagnosticsAtRelease = app.diagnosticsState.developer.lastDetectedQuestionJSON
                let resultAtRelease = app.lastQuestionDetectionResult
                gate.release(index)
                for task in roots { await task.value }
                let detectionReleased = await app.liveInterview.drainAutomaticDetection()
                await app.generationCoordinator.drainRetiredTasks()
                let saved = try app.suggestionRepository.questions(sessionID: fixture.session.id)
                #expect(detectionReleased)
                #expect(gate.requests.count == 1)
                #expect(gate.exited.contains(index))
                #expect(app.liveInterview.pendingAutomaticDetectionTaskCount == 0)
                if changeMode {
                    #expect(app.lastDetectedQuestion == currentAtRelease)
                    #expect(app.possibleQuestion == possibleAtRelease)
                    #expect(app.detectedQuestionsInSessionCount == countAtRelease)
                    #expect(app.pendingAcceptedQuestions.count == queueAtRelease)
                    #expect(app.currentGenerationID == generationAtRelease)
                    #expect(app.diagnosticsState.developer.lastDetectedQuestionJSON == diagnosticsAtRelease)
                    #expect(app.lastQuestionDetectionResult == resultAtRelease)
                    #expect(saved.isEmpty)
                    // SQL alone is insufficient: the existing mode action
                    // already invalidates this ticket. UI assertions above
                    // distinguish the missing detector admission boundary.
                } else {
                    let accepted = try #require(app.lastDetectedQuestion)
                    #expect(accepted.sessionID == fixture.session.id)
                    #expect(accepted.shouldTrigger == (output == .qualified))
                    #expect(saved.contains { $0.id == accepted.id })
                    if output == .qualified {
                        #expect(app.detectedQuestionsInSessionCount == countAtRelease + 1)
                    } else {
                        #expect(app.possibleQuestion?.id == accepted.id)
                        #expect(app.detectedQuestionsInSessionCount == countAtRelease)
                    }
                }
                await fixture.close(roots)
            } catch {
                gate.releaseAll()
                roots.forEach { $0.cancel() }
                for task in roots { await task.value }
                await fixture.close(roots)
                throw error
            }
        } onCancel: { gate.releaseAll() }
    }

    @Test(.timeLimit(.minutes(1)), arguments: DetectionABAMutation.allCases,
        DetectionOutput.allCases.flatMap { output in [false, true].map { (output, $0) } })
    fileprivate func detectionAdmissionDoesNotReturnAfterSemanticRoundTrip(
        mutation: DetectionABAMutation, outputAndEntry: (DetectionOutput, Bool)
    ) async throws {
        let (output, registeredEntry) = outputAndEntry
        let fixture = try await DetectionAdmissionFixture(output: output)
        let app = fixture.app
        let gate = fixture.client
        let submittedSession = fixture.session
        let submittedSnapshot = app.activeContextSnapshot
        // Provider switches use the real active-ID API. Saving A again would
        // alter updatedAt and would not reproduce an equality-restoring ABA.
        var alternateProvider = fixture.configuration
        alternateProvider.id = UUID()
        alternateProvider.name = "Synthetic alternate detector"
        alternateProvider.model = "synthetic-alternate-model"
        alternateProvider.isDefaultForRealtime = false
        alternateProvider.isDefaultForRecap = false
        app.saveProviderConfiguration(alternateProvider)
        let submittedProvider = try #require(app.activeRealtimeProvider)
        let submittedSelection = app.currentInterviewContextSelection
        let submittedMode = app.interviewSessionMode
        let submittedTicket = app.persistenceConsent.ticket()
        app.detectionDebounceSeconds = 0
        var roots: [Task<Void, Never>] = []
        try await withTaskCancellationHandler {
            do {
                if registeredEntry {
                    app.maybeRunAutomaticDetection(triggeringSegment: fixture.segment)
                } else {
                    let caller = Task { @MainActor in
                        await app.runAutomaticDetection(session: submittedSession,
                            detectionTranscript: output.transcript,
                            suggestionTranscript: output.transcript,
                            triggeringSegmentID: fixture.segment.id)
                    }
                    roots.append(caller)
                }
                let index = try await TestEventWaitTrace(label: "live-detection.aba.\(mutation.rawValue).\(registeredEntry)")
                    .nextEvent(in: gate.entered.stream, event: "provider-held")
                #expect(index == 1)
                let root = try #require(app.activeDetectionTask)
                roots.append(root)
                switch mutation {
                case .unchanged: break
                case .cosmeticSessionTitle:
                    var edited = submittedSession
                    edited.title = "Synthetic cosmetic title after submission"
                    app.currentSession = edited
                    #expect(app.currentSession?.contentRevision == submittedSession.contentRevision)
                case .sessionProjectionRoundTrip:
                    let replacement = try app.createContextBoundSession(mode: .mock,
                        title: "Synthetic temporary session for ABA")
                    app.currentSession = replacement
                    #expect(app.currentSession?.id != submittedSession.id)
                    app.currentSession = submittedSession
                    app.activeContextSnapshot = submittedSnapshot
                    #expect(app.currentSession == submittedSession)
                    #expect(app.activeContextSnapshot?.id == submittedSnapshot?.id)
                case .contextProjectionRoundTrip:
                    let domain = app.activeInterviewDomainID
                    app.activeInterviewDomainID = domain == .roboticsResearch ? .general : .roboticsResearch
                    #expect(app.currentInterviewContextSelection != submittedSelection)
                    app.activeInterviewDomainID = domain
                    #expect(app.currentInterviewContextSelection == submittedSelection)
                case .providerSelectionRoundTrip:
                    app.setActiveRealtimeProvider(alternateProvider)
                    #expect(app.activeRealtimeProvider?.id == alternateProvider.id)
                    app.setActiveRealtimeProvider(submittedProvider)
                    #expect(app.activeRealtimeProvider == submittedProvider)
                case .sessionModeRoundTrip:
                    app.interviewSessionMode = submittedMode == .presentation ? .panelQuestions : .presentation
                    #expect(app.interviewSessionMode != submittedMode)
                    app.interviewSessionMode = submittedMode
                    #expect(app.interviewSessionMode == submittedMode)
                case .contextActionRoundTrip:
                    let domain = app.activeInterviewDomainID
                    app.selectInterviewDomain(domain == .roboticsResearch ? .general : .roboticsResearch)
                    app.selectInterviewDomain(domain)
                    #expect(app.currentInterviewContextSelection == submittedSelection)
                    // Public context actions already roll immutable snapshots.
                    // This is a rejected negative control, not a restored ID.
                    #expect(app.currentSession?.contextSnapshotID != submittedSession.contextSnapshotID)
                }
                #expect(app.persistenceConsent.isCurrent(ticket: submittedTicket))
                let currentAtRelease = app.lastDetectedQuestion
                let possibleAtRelease = app.possibleQuestion
                let countAtRelease = app.detectedQuestionsInSessionCount
                let queueAtRelease = app.pendingAcceptedQuestions.count
                let generationAtRelease = app.currentGenerationID
                let diagnosticsAtRelease = app.diagnosticsState.developer.lastDetectedQuestionJSON
                let resultAtRelease = app.lastQuestionDetectionResult
                gate.release(index)
                for task in roots { await task.value }
                await app.generationCoordinator.drainRetiredTasks()
                let saved = try app.suggestionRepository.questions(sessionID: submittedSession.id)
                #expect(gate.requests.count == 1)
                #expect(gate.exited.contains(index))
                if mutation.keepsSubmission {
                    let accepted = try #require(app.lastDetectedQuestion)
                    #expect(accepted.sessionID == submittedSession.id)
                    #expect(accepted.shouldTrigger == (output == .qualified))
                    #expect(saved.contains { $0.id == accepted.id })
                    if output == .qualified {
                        #expect(app.detectedQuestionsInSessionCount == countAtRelease + 1)
                    } else {
                        #expect(app.possibleQuestion?.id == accepted.id)
                        #expect(app.detectedQuestionsInSessionCount == countAtRelease)
                    }
                } else {
                    #expect(app.lastDetectedQuestion == currentAtRelease)
                    #expect(app.possibleQuestion == possibleAtRelease)
                    #expect(app.detectedQuestionsInSessionCount == countAtRelease)
                    #expect(app.pendingAcceptedQuestions.count == queueAtRelease)
                    #expect(app.currentGenerationID == generationAtRelease)
                    #expect(app.diagnosticsState.developer.lastDetectedQuestionJSON == diagnosticsAtRelease)
                    #expect(app.lastQuestionDetectionResult == resultAtRelease)
                    #expect(saved.isEmpty,
                        "Restoring final inputs cannot reauthorize a detector invalidated by a semantic transition.")
                }
                await fixture.close(roots)
            } catch {
                gate.releaseAll()
                roots.forEach { $0.cancel() }
                for task in roots { await task.value }
                await fixture.close(roots)
                throw error
            }
        } onCancel: { gate.releaseAll() }
    }

    @Test(.timeLimit(.minutes(1)), arguments: DetectionMutation.allCases,
        DetectionOutput.allCases)
    fileprivate func lateDetectionCannotPublishAcrossItsSubmittedBoundary(
        mutation: DetectionMutation, output: DetectionOutput
    ) async throws {
        let fixture = try await DetectionAdmissionFixture(output: output)
        let app = fixture.app
        let gate = fixture.client
        let submitted = fixture.session
        let input = output.transcript
        let worker = Task { @MainActor in
            await app.runAutomaticDetection(session: submitted,
                detectionTranscript: input, suggestionTranscript: input,
                triggeringSegmentID: fixture.segment.id)
        }
        try await withTaskCancellationHandler {
            do {
                let index = try await TestEventWaitTrace(label: "live-detection.submitted")
                    .nextEvent(in: gate.entered.stream, event: "provider-held")
                #expect(index == 1)
                #expect(gate.requests.count == 1)
                #expect(gate.requests.first?.model == fixture.configuration.model)
                switch mutation {
                case .unchanged: break
                case .clear: app.clearLiveSession()
                case .newSession:
                    app.currentSession = try app.createContextBoundSession(mode: .mock,
                        title: "Synthetic replacement detection session")
                case .context:
                    try app.rollContextSnapshotForCurrentSession()
                    #expect(app.currentSession?.id == submitted.id)
                    #expect(app.currentSession?.contextSnapshotID != submitted.contextSnapshotID)
                case .providerConfiguration:
                    var updated = fixture.configuration
                    updated.model = "synthetic-replacement-detection-model"
                    updated.updatedAt = Date(timeIntervalSince1970: 1_800_000_001)
                    app.saveProviderConfiguration(updated)
                    #expect(app.activeRealtimeProvider?.model == updated.model)
                case .cancel: worker.cancel()
                case .privacyOffOn:
                    let ticket = app.persistenceConsent.ticket()
                    var preferences = app.settings
                    preferences.saveTranscriptsLocally = false
                    app.saveSettings(preferences)
                    preferences.saveTranscriptsLocally = true
                    app.saveSettings(preferences)
                    #expect(!app.persistenceConsent.isCurrent(ticket: ticket))
                }
                let detectedAtReplacement = app.detectedQuestionsInSessionCount
                let pendingAtReplacement = app.pendingAcceptedQuestions.count
                let currentAtReplacement = app.lastDetectedQuestion
                let possibleAtReplacement = app.possibleQuestion
                let generationAtReplacement = app.currentGenerationID
                let jsonAtReplacement = app.diagnosticsState.developer.lastDetectedQuestionJSON
                let resultAtReplacement = app.lastQuestionDetectionResult
                // The provider intentionally ignores cancellation until this exact
                // test releases it; no sleep, cloud API, or audio device is used.
                gate.release(index)
                await worker.value
                await app.generationCoordinator.drainRetiredTasks()
                #expect(gate.requests.count == 1)
                #expect(gate.exited.contains(index))
                let saved = try app.suggestionRepository.questions(sessionID: submitted.id)
                if mutation == .unchanged || mutation == .privacyOffOn {
                    let accepted = try #require(app.lastDetectedQuestion)
                    #expect(accepted.sessionID == submitted.id)
                    #expect(accepted.shouldTrigger == (output == .qualified))
                    if mutation == .privacyOffOn {
                        #expect(saved.isEmpty,
                            "Saving again does not reauthorize the detector's original ticket; its Live result remains usable.")
                    } else {
                        #expect(saved.contains { $0.id == accepted.id })
                    }
                    if output == .qualified {
                        #expect(app.detectedQuestionsInSessionCount == detectedAtReplacement + 1)
                    } else {
                        #expect(app.possibleQuestion?.id == accepted.id)
                        #expect(app.detectedQuestionsInSessionCount == detectedAtReplacement)
                    }
                } else {
                    #expect(app.lastDetectedQuestion == currentAtReplacement)
                    #expect(app.possibleQuestion == possibleAtReplacement)
                    #expect(app.detectedQuestionsInSessionCount == detectedAtReplacement)
                    #expect(app.pendingAcceptedQuestions.count == pendingAtReplacement)
                    #expect(app.currentGenerationID == generationAtReplacement)
                    #expect(app.diagnosticsState.developer.lastDetectedQuestionJSON == jsonAtReplacement)
                    #expect(app.lastQuestionDetectionResult == resultAtReplacement)
                    #expect(saved.isEmpty,
                        "A late detection must not acquire a new persistence ticket or create an obsolete question.")
                }
                await fixture.close([worker])
            } catch {
                gate.releaseAll()
                worker.cancel(); await worker.value
                await fixture.close([worker])
                throw error
            }
        } onCancel: { gate.releaseAll() }
    }
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    fileprivate func detectorAndQualifiedAnswerKeepTheOriginalPersistenceTicket(
        revokeAndRestoreSaving: Bool
    ) async throws {
        let fixture = try await DetectionAdmissionFixture(output: .qualified)
        let app = fixture.app
        let gate = fixture.client
        // Reuse the existing controlled provider and its qualified full answer.
        // This exercises the actual local answer workflow without a model call.
        let answerProvider = ManualSnapshotLocalProvider(id: "synthetic-detection-answer-consent")
        app.answerProviderModeOverride = .localQwenPrimary
        app.localLLMProviderOverride = answerProvider
        let ticket = app.persistenceConsent.ticket()
        let worker = Task { @MainActor in
            await app.runAutomaticDetection(session: fixture.session,
                detectionTranscript: DetectionOutput.qualified.transcript,
                suggestionTranscript: DetectionOutput.qualified.transcript,
                triggeringSegmentID: fixture.segment.id)
        }
        var roots = [worker]
        try await withTaskCancellationHandler {
            do {
                let index = try await TestEventWaitTrace(label: "live-detection.answer-consent")
                    .nextEvent(in: gate.entered.stream, event: "detector-held")
                #expect(index == 1)
                if revokeAndRestoreSaving {
                    var preferences = app.settings
                    preferences.saveTranscriptsLocally = false
                    app.saveSettings(preferences)
                    preferences.saveTranscriptsLocally = true
                    app.saveSettings(preferences)
                    #expect(!app.persistenceConsent.isCurrent(ticket: ticket))
                } else {
                    #expect(app.persistenceConsent.isCurrent(ticket: ticket))
                }
                #expect(app.settings.saveTranscriptsLocally)
                // These are real SQL parents in the isolated fixture. A missing
                // question/card must not be explained by deleting either parent.
                let storedSession = try app.sessionRepository.session(id: fixture.session.id)
                let storedSegment = try app.transcriptRepository.segmentByID(fixture.segment.id)
                #expect(storedSession?.id == fixture.session.id)
                #expect(storedSession?.endedAt == nil)
                #expect(storedSegment?.sessionID == fixture.session.id)
                gate.release(index)
                await worker.value
                if let answerRoot = app.activeAITask {
                    roots.append(answerRoot)
                    await answerRoot.value
                }
                // Includes the real admitted persistence task after root exit.
                await app.generationCoordinator.drainRetiredTasks()
                let question = try #require(app.lastDetectedQuestion)
                let card = try #require(app.currentSuggestion)
                let owner = try #require(app.activeGenerationController)
                #expect(question.sessionID == fixture.session.id)
                #expect(card.questionID == question.id)
                #expect(card.generationID == owner.generationID)
                #expect(card.isPartial == false)
                #expect(card.stageBCompleted == true)
                #expect(card.sayFirstSource == "ollama_qwen")
                #expect(QuestionRuntimeAcceptanceGuard.validateSuggestionCardForPersistence(card).accepted)
                #expect(await answerProvider.requests().count == 1)
                #expect(owner.persistenceTicket == ticket,
                    "The same accepted detector pipeline cannot reacquire permission after saving is restored.")
                let questions = try app.suggestionRepository.questions(sessionID: fixture.session.id)
                let cards = try app.suggestionRepository.suggestions(sessionID: fixture.session.id)
                if revokeAndRestoreSaving {
                    #expect(!questions.contains { $0.id == question.id })
                    #expect(!cards.contains { $0.id == card.id })
                    #expect(owner.persistenceTicket != app.persistenceConsent.ticket())
                } else {
                    #expect(questions.contains { $0.id == question.id })
                    #expect(cards.contains { $0.id == card.id })
                }
                await fixture.close(roots)
            } catch {
                gate.releaseAll()
                roots.forEach { $0.cancel() }
                for root in roots { await root.value }
                await fixture.close(roots)
                throw error
            }
        } onCancel: { gate.releaseAll() }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    fileprivate func registeredDetectionRootsRemainJoinableAfterReplacement(
        replaceBeforeShutdown: Bool
    ) async throws {
        let fixture = try await DetectionAdmissionFixture(output: .qualified)
        let app = fixture.app
        let gate = fixture.client
        app.detectionDebounceSeconds = 0
        var roots: [Task<Void, Never>] = []
        try await withTaskCancellationHandler {
            do {
                // This is the normal registered production entry, unlike the
                // direct async admission tests above. No capture is started.
                app.maybeRunAutomaticDetection(triggeringSegment: fixture.segment)
                let firstIndex = try await TestEventWaitTrace(label: "live-detection.retained-root.first")
                    .nextEvent(in: gate.entered.stream, event: "provider-held")
                #expect(firstIndex == 1)
                let first = try #require(app.activeDetectionTask)
                roots.append(first)
                var second: Task<Void, Never>?
                var secondIndex: Int?
                if replaceBeforeShutdown {
                    let segment = TranscriptSegment(id: UUID().uuidString,
                        sessionID: fixture.session.id, source: .mock, speaker: .interviewer,
                        text: "Explain how database isolation affects concurrent reads.",
                        confidence: 1, asrFinalizationReason: "final_accepted", recognitionIsFinal: true)
                    app.transcriptSegments.append(segment)
                    try app.transcriptRepository.saveSegment(segment)
                    app.maybeRunAutomaticDetection(triggeringSegment: segment)
                    let index = try await TestEventWaitTrace(label: "live-detection.retained-root.second")
                        .nextEvent(in: gate.entered.stream, event: "provider-held")
                    #expect(index == 2)
                    let replacement = try #require(app.activeDetectionTask)
                    #expect(replacement != first)
                    #expect(first.isCancelled)
                    roots.append(replacement)
                    second = replacement; secondIndex = index
                }
                var observedExactHandles: [Task<Void, Never>] = []
                // Stage-zero observes only a real original handle immediately
                // before its actual join. It releases that handle's fake gate.
                // Missing retirement never gets an invented join notification.
                app.liveInterview.automaticDetectionTaskWillAwaitForTesting = { task in
                    observedExactHandles.append(task)
                    if task == first { gate.release(firstIndex) }
                    if let second, let secondIndex, task == second { gate.release(secondIndex) }
                }
                let released = await app.shutdownResources()
                let exitedBeforeReturn = gate.exited
                app.liveInterview.automaticDetectionTaskWillAwaitForTesting = nil
                // The RED path can lose the first root. Release and join this
                // test's borrowed original handles before recording assertions.
                gate.releaseAll()
                for root in roots { await root.value }
                #expect(released)
                #expect(observedExactHandles.contains(first),
                    "A cancelled original detector remains owned through its real exit.")
                #expect(exitedBeforeReturn.contains(firstIndex),
                    "Application cleanup cannot complete while its retired detector is still held.")
                if let second, let secondIndex {
                    #expect(observedExactHandles.contains(second))
                    #expect(exitedBeforeReturn.contains(secondIndex))
                }
                #expect(app.lastDetectedQuestion == nil)
                #expect(app.currentSuggestion == nil)
                await fixture.close(roots)
            } catch {
                app.liveInterview.automaticDetectionTaskWillAwaitForTesting = nil
                gate.releaseAll()
                roots.forEach { $0.cancel() }
                for root in roots { await root.value }
                await fixture.close(roots)
                throw error
            }
        } onCancel: { gate.releaseAll() }
    }


    @Test(.timeLimit(.minutes(1)))
    fileprivate func detectorScopeDoesNotRevokeAnotherLiveOwnersDrain() async throws {
        let target = try await DetectionAdmissionFixture(output: .possible)
        let request = DetectionShutdownRequest()
        let source: DetectionAdmissionFixture
        do {
            source = try await DetectionAdmissionFixture(output: .qualified,
                beforeHold: { await request.beginInheritedShutdown() })
        } catch {
            await target.close([])
            throw error
        }
        request.app = target.app
        target.app.detectionDebounceSeconds = 0
        source.app.detectionDebounceSeconds = 0
        let targetGate = target.client, sourceGate = source.client
        let returned = request.returned
        var targetRoots: [Task<Void, Never>] = []
        var sourceRoots: [Task<Void, Never>] = []
        try await withTaskCancellationHandler {
            do {
                target.app.maybeRunAutomaticDetection(triggeringSegment: target.segment)
                let targetIndex = try await TestEventWaitTrace(label: "live-detection.foreign-scope.target")
                    .nextEvent(in: targetGate.entered.stream, event: "provider-held")
                let targetRoot = try #require(target.app.activeDetectionTask)
                targetRoots.append(targetRoot)
                target.app.liveInterview.automaticDetectionTaskWillAwaitForTesting = { task in
                    if task == targetRoot { targetGate.release(targetIndex) }
                }
                source.app.maybeRunAutomaticDetection(triggeringSegment: source.segment)
                let sourceIndex = try await TestEventWaitTrace(label: "live-detection.foreign-scope.source")
                    .nextEvent(in: sourceGate.entered.stream, event: "provider-held")
                let sourceRoot = try #require(source.app.activeDetectionTask)
                sourceRoots.append(sourceRoot)
                let releasedTarget = try await TestEventWaitTrace(label: "live-detection.foreign-scope.shutdown")
                    .nextEvent(in: returned.stream, event: "shutdown-returned")
                await targetRoot.value
                if let shutdown = request.shutdownTask { _ = await shutdown.value }
                #expect(releasedTarget,
                    "A different Live owner's execution scope is not a self-join for this target.")
                #expect(targetGate.exited.contains(targetIndex))
                #expect(target.app.liveInterview.pendingAutomaticDetectionTaskCount == 0)
                #expect(!sourceGate.exited.contains(sourceIndex))
                #expect(source.app.liveInterview.pendingAutomaticDetectionTaskCount == 1)
                // Now drain the source externally through its own exact handle.
                source.app.liveInterview.automaticDetectionTaskWillAwaitForTesting = { task in
                    if task == sourceRoot { sourceGate.release(sourceIndex) }
                }
                let releasedSource = await source.app.shutdownResources()
                sourceGate.releaseAll()
                await sourceRoot.value
                #expect(releasedSource)
                #expect(sourceGate.exited.contains(sourceIndex))
                #expect(source.app.liveInterview.pendingAutomaticDetectionTaskCount == 0)
                target.app.liveInterview.automaticDetectionTaskWillAwaitForTesting = nil
                source.app.liveInterview.automaticDetectionTaskWillAwaitForTesting = nil
                returned.continuation.finish()
                await source.close(sourceRoots)
                await target.close(targetRoots)
            } catch {
                targetGate.releaseAll(); sourceGate.releaseAll()
                targetRoots.forEach { $0.cancel() }; sourceRoots.forEach { $0.cancel() }
                for task in targetRoots + sourceRoots { await task.value }
                if let shutdown = request.shutdownTask { _ = await shutdown.value }
                target.app.liveInterview.automaticDetectionTaskWillAwaitForTesting = nil
                source.app.liveInterview.automaticDetectionTaskWillAwaitForTesting = nil
                returned.continuation.finish()
                await source.close(sourceRoots)
                await target.close(targetRoots)
                throw error
            }
        } onCancel: {
            targetGate.releaseAll(); sourceGate.releaseAll()
            returned.continuation.finish()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    fileprivate func inheritedDetectorShutdownCannotJoinItsOwnRoot() async throws {
        let request = DetectionShutdownRequest()
        let fixture = try await DetectionAdmissionFixture(output: .qualified,
            beforeHold: { await request.beginInheritedShutdown() })
        let app = fixture.app
        let gate = fixture.client
        request.app = app
        app.detectionDebounceSeconds = 0
        var observedOwnJoin = false
        app.liveInterview.automaticDetectionTaskWillAwaitForTesting = { task in
            guard task == request.borrowedDetector else { return }
            observedOwnJoin = true
            // The baseline is kept finite: its descendant drain borrows the
            // actual detector, and this real prejoin observation releases it.
            gate.release(1)
        }
        let returned = request.returned
        try await withTaskCancellationHandler {
            do {
                app.maybeRunAutomaticDetection(triggeringSegment: fixture.segment)
                let index = try await TestEventWaitTrace(label: "live-detection.self-scope")
                    .nextEvent(in: gate.entered.stream, event: "provider-held")
                #expect(index == 1)
                let root = try #require(request.borrowedDetector)
                let ownShutdown = try await TestEventWaitTrace(label: "live-detection.self-scope.shutdown")
                    .nextEvent(in: returned.stream, event: "shutdown-returned")
                let exitedAtReturn = gate.exited
                let pendingAtReturn = app.liveInterview.pendingAutomaticDetectionTaskCount
                #expect(!ownShutdown,
                    "The inherited detector chain must report incomplete cleanup instead of joining itself.")
                #expect(!observedOwnJoin,
                    "A descendant must not borrow the detector's own root as a drain target.")
                #expect(!exitedAtReturn.contains(index))
                #expect(pendingAtReturn == 1,
                    "Refusing a self-join retains the same root for an external lifecycle caller.")
                // The owning test is outside the detector scope. Its real drain
                // releases the exact provider gate through the hook above.
                let externalShutdown = await app.shutdownResources()
                gate.releaseAll()
                await root.value
                if let shutdown = request.shutdownTask { _ = await shutdown.value }
                #expect(externalShutdown)
                #expect(gate.exited.contains(index))
                #expect(app.liveInterview.pendingAutomaticDetectionTaskCount == 0)
                app.liveInterview.automaticDetectionTaskWillAwaitForTesting = nil
                returned.continuation.finish()
                await fixture.close([root])
            } catch {
                gate.releaseAll()
                request.borrowedDetector?.cancel()
                if let root = request.borrowedDetector { await root.value }
                if let shutdown = request.shutdownTask { _ = await shutdown.value }
                app.liveInterview.automaticDetectionTaskWillAwaitForTesting = nil
                returned.continuation.finish()
                await fixture.close([])
                throw error
            }
        } onCancel: {
            gate.releaseAll()
            returned.continuation.finish()
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: DetectionOutput.allCases, Array(0..<20))
    fileprivate func stoppingContinuousIngressRevokesHeldDetectorBeforeManualUse(
        output: DetectionOutput, schedule: Int
    ) async throws {
        let fixture = try await DetectionAdmissionFixture(output: output)
        let app = fixture.app, gate = fixture.client
        // Any unintended answer remains a finite synthetic request in the RED
        // path; neither the detector nor the answer uses a network transport.
        let answerProvider = ManualSnapshotLocalProvider(id: "synthetic-live-stop-answer")
        app.answerProviderModeOverride = .localQwenPrimary
        app.localLLMProviderOverride = answerProvider
        app.detectionDebounceSeconds = 0
        let submittedSession = fixture.session
        let submittedSelection = app.currentInterviewContextSelection
        let submittedProvider = app.activeRealtimeProvider
        let submittedTicket = app.persistenceConsent.ticket()
        var roots: [Task<Void, Never>] = []
        try await withTaskCancellationHandler {
            do {
                #expect(app.hirevaMode == .autoDetect)
                app.maybeRunAutomaticDetection(triggeringSegment: fixture.segment)
                let index = try await TestEventWaitTrace(label: "live-stop.detector.\(output.rawValue).\(schedule)")
                    .nextEvent(in: gate.entered.stream, event: "actual-provider-held")
                let original = try #require(app.activeDetectionTask)
                roots.append(original)
                #expect(!gate.exited.contains(index))
                // Four fixed event orders, repeated five times per output.
                // Only the real mode setter and stop entry are invoked.
                switch schedule % 4 {
                case 0:
                    app.stopAllContinuousPipelines(reason: .userRequested)
                case 1:
                    app.hirevaMode = .manualCapture
                case 2:
                    app.stopAllContinuousPipelines(reason: .userRequested)
                    app.stopAllContinuousPipelines(reason: .userRequested)
                default:
                    app.hirevaMode = .manualCapture
                    app.hirevaMode = .autoDetect
                }
                #expect(original.isCancelled,
                    "Stopping Live must cancel its exact submitted detector before Manual use.")
                #expect(app.activeDetectionTask == nil,
                    "Returning to Auto Detect cannot restore the old admission identity.")
                #expect(app.liveInterview.pendingAutomaticDetectionTaskCount >= 1,
                    "Cancellation must retain the held original until its actual exit.")
                #expect(app.currentSession == submittedSession)
                #expect(app.currentInterviewContextSelection == submittedSelection)
                #expect(app.activeRealtimeProvider == submittedProvider)
                #expect(app.persistenceConsent.isCurrent(ticket: submittedTicket))
                #expect(app.transcriptSegments.first { $0.id == fixture.segment.id } == fixture.segment)
                let questionAtStop = app.lastDetectedQuestion
                let possibleAtStop = app.possibleQuestion
                let cardAtStop = app.currentSuggestion
                let countAtStop = app.detectedQuestionsInSessionCount
                let queueAtStop = app.pendingAcceptedQuestions.count
                let requestAtStop = app.generationCoordinator.activeRequest?.id
                let generationAtStop = app.currentGenerationID
                let diagnosticsAtStop = app.diagnosticsState.developer.lastDetectedQuestionJSON
                let resultAtStop = app.lastQuestionDetectionResult
                let captureAtStop = app.currentCaptureRuntimeState
                var joinedOriginal = false
                app.liveInterview.automaticDetectionTaskWillAwaitForTesting = { task in
                    guard task == original else { return }
                    joinedOriginal = true
                    gate.release(index)
                }
                // Observe and release only the actual original through its real
                // owner's join. This keeps both the RED and GREEN paths finite.
                let detectionReleased = await app.liveInterview.drainAutomaticDetection()
                app.liveInterview.automaticDetectionTaskWillAwaitForTesting = nil
                await original.value
                if let unexpectedAnswer = app.activeAITask {
                    roots.append(unexpectedAnswer)
                    await withTaskCancellationHandler {
                        await unexpectedAnswer.value
                    } onCancel: { unexpectedAnswer.cancel() }
                }
                await app.generationCoordinator.drainRetiredTasks()
                #expect(detectionReleased)
                #expect(joinedOriginal)
                #expect(gate.exited.contains(index))
                #expect(app.liveInterview.pendingAutomaticDetectionTaskCount == 0)
                #expect(app.lastDetectedQuestion == questionAtStop)
                #expect(app.possibleQuestion == possibleAtStop)
                #expect(app.currentSuggestion == cardAtStop)
                #expect(app.detectedQuestionsInSessionCount == countAtStop)
                #expect(app.pendingAcceptedQuestions.count == queueAtStop)
                #expect(app.generationCoordinator.activeRequest?.id == requestAtStop)
                #expect(app.currentGenerationID == generationAtStop)
                #expect(app.diagnosticsState.developer.lastDetectedQuestionJSON == diagnosticsAtStop)
                #expect(app.lastQuestionDetectionResult == resultAtStop)
                #expect(app.currentCaptureRuntimeState == captureAtStop)
                #expect(await answerProvider.requests().isEmpty)
                let questions = try app.suggestionRepository.questions(sessionID: submittedSession.id)
                let cards = try app.suggestionRepository.suggestions(sessionID: submittedSession.id)
                #expect(questions.isEmpty,
                    "A still-valid saving ticket does not authorize a revoked detector result.")
                #expect(cards.isEmpty)
                await fixture.close(roots)
            } catch {
                app.liveInterview.automaticDetectionTaskWillAwaitForTesting = nil
                gate.releaseAll()
                roots.forEach { $0.cancel() }
                for root in roots { await root.value }
                await fixture.close(roots)
                throw error
            }
        } onCancel: { gate.releaseAll() }
    }

}

fileprivate enum DetectionMutation: String, CaseIterable, Sendable {
    case unchanged, clear, newSession, context, providerConfiguration, cancel, privacyOffOn
}

fileprivate enum DetectionABAMutation: String, CaseIterable, Sendable {
    case unchanged, cosmeticSessionTitle
    case sessionProjectionRoundTrip, contextProjectionRoundTrip
    case providerSelectionRoundTrip, sessionModeRoundTrip, contextActionRoundTrip
    var keepsSubmission: Bool { self == .unchanged || self == .cosmeticSessionTitle }
}

fileprivate enum DetectionOutput: String, CaseIterable, Sendable {
    case qualified, possible
    var transcript: String {
        switch self {
        case .qualified: return "Explain how transaction atomicity prevents partial updates."
        // A deliberately incomplete prefix exercises the product's possible
        // question path without its strong-complete-question normalization.
        case .possible: return "Could you explain"
        }
    }
    var wire: String {
        switch self {
        case .qualified:
            return #"{"should_trigger":true,"question_complete":true,"question_text":"Explain how transaction atomicity prevents partial updates.","intent":"technical","answer_strategy":"direct_answer","confidence":0.95,"reason":"Synthetic complete question"}"#
        case .possible:
            return #"{"should_trigger":false,"question_complete":false,"question_text":"Could you explain","intent":"unclear","answer_strategy":"wait","confidence":0.60,"reason":"Synthetic incomplete prompt"}"#
        }
    }
}

@MainActor
private final class DetectionAdmissionFixture {
    let database: AppDatabase
    let app: AppState
    let client: DetectionAdmissionClient
    let configuration: LLMProviderConfiguration
    let session: InterviewSession
    let segment: TranscriptSegment
    private let clock: ControlledGenerationWatchdogClock
    private var closed = false

    init(output: DetectionOutput, beforeHold: (@Sendable () async -> Void)? = nil) async throws {
        let clock = ControlledGenerationWatchdogClock()
        // Admission and lifecycle assertions use one real SQLite queue. Disk
        // durability and reopening have their own repository tests.
        let database = try await TestSupport.makeInMemoryDatabase()
        var setupApp: AppState?
        do {
            let settings = SettingsRepository(database: database)
            try settings.ensureDefaultProviderConfigurations()
            var configuration = LLMProviderConfiguration.deepSeekDefault(model: "synthetic-submitted-detection-model")
            configuration.baseURL = "test://controlled-local-only"
            configuration.apiKeyAccount = nil
            try settings.saveProviderConfiguration(configuration)
            try settings.setActiveRealtimeProvider(id: configuration.id)
            let client = DetectionAdmissionClient(output: output, beforeHold: beforeHold)
            let router = LLMRouter(settingsRepository: settings, clients: [.deepSeek: client])
            let app = AppState(database: database,
                questionRoutingProvider: HermeticQuestionRoutingProvider(), llmRouter: router,
                permissionService: HermeticPermissionService(),
                keychainService: KeychainService(store: InMemoryMockKeychainStore()),
                dialogueDefaults: nil)
            setupApp = app
            app.answerProviderModeOverride = .deepSeekPrimary
            app.delayProvider = clock
            app.generationWatchdogDelayProvider = clock
            var preferences = app.settings
            preferences.saveTranscriptsLocally = true
            app.saveSettings(preferences)
            let session = try makeHermeticContextBoundSession(appState: app,
                prefix: "detection-admission-\(UUID().uuidString)", mode: .mock)
            app.currentSession = session
            let segment = TranscriptSegment(id: UUID().uuidString, sessionID: session.id,
                source: .mock, speaker: .interviewer, text: output.transcript,
                confidence: 1, asrFinalizationReason: "final_accepted", recognitionIsFinal: true)
            app.transcriptSegments = [segment]
            // The production question row references this segment. Persist only
            // this fixture's synthetic input so a rejected write proves admission,
            // rather than an unrelated foreign-key violation.
            try app.transcriptRepository.saveSegment(segment)
            let storedSession = try app.sessionRepository.session(id: session.id)
            let storedSegment = try app.transcriptRepository.segmentByID(segment.id)
            #expect(storedSession?.id == session.id)
            #expect(storedSegment?.id == segment.id)
            #expect(storedSegment?.sessionID == session.id)
            self.clock = clock
            self.database = database; self.app = app; self.client = client
            self.configuration = configuration; self.session = session; self.segment = segment
        } catch {
            await setupApp?.shutdownForTesting()
            try? database.close()
            throw error
        }
    }

    func close(_ roots: [Task<Void, Never>]) async {
        guard !closed else { return }
        closed = true
        client.releaseAll()
        roots.forEach { $0.cancel() }
        for task in roots { await task.value }
        clock.cancelAll()
        let released = await app.shutdownResources()
        #expect(released)
        #expect(app.generationCoordinator.pendingCleanupTaskCount == 0)
        do { try database.close() }
        catch { Issue.record("Synthetic detection database cleanup failed: \(error)") }
    }
}

/// Checked, per-instance admission/release. Noncooperation is bounded by the
/// owning test's always-release cancellation and cleanup handlers.
private final class DetectionAdmissionClient: LLMClientProtocol {
    let providerKind: LLMProviderKind = .deepSeek
    let entered = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private let output: DetectionOutput
    private let beforeHold: (@Sendable () async -> Void)?
    private struct State: Sendable {
        var requests: [LLMProviderConfiguration] = []
        var gates: [Int: CheckedContinuation<Void, Never>] = [:]
        var released = Set<Int>()
        var releaseEverything = false
        var exited = Set<Int>()
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    init(output: DetectionOutput, beforeHold: (@Sendable () async -> Void)? = nil) {
        self.output = output; self.beforeHold = beforeHold
    }
    var requests: [LLMProviderConfiguration] { state.withLock { $0.requests } }
    var exited: Set<Int> { state.withLock { $0.exited } }

    func chatCompletion(configuration: LLMProviderConfiguration,
        messages: [LLMChatMessage], responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions) async throws -> LLMChatResult {
        guard messages.contains(where: { $0.content.contains("Decide whether the interviewer has asked") }) else {
            throw LLMProviderError.notConfigured("Synthetic answer not evaluated")
        }
        let index = state.withLock { current in
            current.requests.append(configuration)
            return current.requests.count
        }
        await beforeHold?()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let releaseNow = state.withLock { current in
                if current.releaseEverything || current.released.contains(index) { return true }
                current.gates[index] = continuation
                return false
            }
            entered.continuation.yield(index)
            if releaseNow { continuation.resume() }
        }
        _ = state.withLock { $0.exited.insert(index) }
        return .init(content: output.wire, modelName: configuration.model,
            providerKind: .deepSeek, providerName: "Synthetic gated detector",
            baseURL: configuration.baseURL, latencyMS: 0, isLocal: false,
            rawResponse: output.wire)
    }
    func release(_ index: Int) {
        let captured = state.withLock { current in
            current.released.insert(index)
            return current.gates.removeValue(forKey: index)
        }
        captured?.resume()
    }
    func releaseAll() {
        let captured = state.withLock { current in
            current.releaseEverything = true
            let all = Array(current.gates.values); current.gates.removeAll()
            return all
        }
        captured.forEach { $0.resume() }
        entered.continuation.finish()
    }
    func chatCompletionStream(configuration: LLMProviderConfiguration,
        messages: [LLMChatMessage], responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions) -> AsyncThrowingStream<String, Error> {
        // Extra generation caused by obsolete detection must remain finite.
        // No fake generated answer is counted as model/quality evidence.
        AsyncThrowingStream { $0.finish() }
    }
    func testConnection(configuration: LLMProviderConfiguration) async throws -> LLMConnectionTestResult {
        .init(success: true, message: "Synthetic only", latencyMS: 0, models: [])
    }
    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] { [] }
}


/// This fixture retains both original handles. The provider does not await its
/// shutdown child, so the current API RED can always release the original root.
/// A truly inline baseline self-await would form an unreleasable Task.value cycle
/// and is intentionally not executed before the production admission repair.
@MainActor
private final class DetectionShutdownRequest {
    weak var app: AppState?
    let returned = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private(set) var borrowedDetector: Task<Void, Never>?
    private(set) var shutdownTask: Task<Bool, Never>?

    func beginInheritedShutdown() {
        guard shutdownTask == nil, let app else { return }
        borrowedDetector = app.activeDetectionTask
        let returned = self.returned
        shutdownTask = Task { @MainActor in
            let released = await app.shutdownResources()
            returned.continuation.yield(released)
            return released
        }
    }
}
