import Combine
import Foundation
import Testing
@testable import Hireva

@MainActor
struct GenerationWatchdogClockTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func captureRestorePublicationCannotOverwriteReentrantGeneration(capturePublication: Bool) async throws {
        let state = try await makeState()
        let fixture = ControlledGenerationWatchdogFixture(app: state.app)
        state.app.liveState = .generatingSuggestion
        state.app.currentCaptureRuntimeState = .generating
        var replacement = state.question
        replacement.id = UUID().uuidString
        replacement.questionText = "Explain transaction isolation and visibility."
        let replacementID = UUID().uuidString
        let child = Task<String, Error> { "Finite Q2 child" }
        var replaced = false
        let replace: () -> Void = {
            guard !replaced else { return }
            replaced = true
            state.app.activateGeneration(question: replacement, generationID: replacementID,
                triggerPath: .regenerate, requestStart: Date(), source: .mock, speaker: .unknown,
                answerProviderMode: .localQwenPrimary)
            state.app.registerStageATask(child, generationID: replacementID)
            state.app.liveState = .generatingSuggestion
            state.app.currentCaptureRuntimeState = .generating
            state.app.beginAction(ActionID.generateAnswer, title: "Q2 pending", message: "Synthetic replacement")
        }
        let subscription: AnyCancellable
        if capturePublication {
            subscription = state.app.liveInterview.captureRuntimeStateUpdates.dropFirst().sink {
                if case .stopped = $0 { replace() }
            }
        } else {
            subscription = state.app.liveInterview.liveStateUpdates.dropFirst().sink {
                if $0 == .stopped { replace() }
            }
        }
        defer { subscription.cancel() }
        try await fixture.run {
            state.app.startFullCardWatchdog(generationID: state.generationID,
                cardID: "synthetic-restoration-deadline", question: state.question,
                session: state.session, requestStart: state.requestStart, triggerPath: .manualGenerate)
            let watchdog = try #require(state.app.fullCardWatchdogTask)
            try await fixture.clock.waitUntilPending(nanoseconds: 1_000_000_000)
            fixture.clock.advance(by: 1_000_000_000)
            await watchdog.value
            #expect(replaced)
            #expect(state.app.currentGenerationID == replacementID)
            #expect(state.app.liveState == .generatingSuggestion)
            #expect(state.app.currentCaptureRuntimeState == .generating)
            #expect(state.app.isActionLoading(ActionID.generateAnswer))
            #expect(state.app.generationCoordinator.stageATask == child)
            #expect(!child.isCancelled)
            subscription.cancel()
        }
        _ = await child.result
    }

    private static let sections = StreamingSuggestionSections(
        strategy: "Database transaction explanation",
        sayFirst: "A database transaction groups operations into an atomic unit: all operations commit together or roll back together. Isolation controls which concurrent changes each transaction can observe.",
        keyPoints: ["Atomicity commits or rolls back all operations together.",
                    "Isolation controls visibility of concurrent changes."],
        followUpReady: [], caution: "")

    @Test(arguments: [false, true])
    func actualWatchdogRespectsExplicitDeadlineAndCompletionOrder(timeoutFirst: Bool) async throws {
        // Repeat each controlled ordering with a fresh fixture after the prior
        // iteration has joined its tasks; unrelated suites remain parallel.
        for iteration in 0..<20 {
            let state = try await makeState()
            let fixture = ControlledGenerationWatchdogFixture(app: state.app)
            try await fixture.run {
                state.app.startFullCardWatchdog(generationID: state.generationID,
                    cardID: "controlled-watchdog-card", question: state.question, session: state.session,
                    requestStart: state.requestStart, triggerPath: .manualGenerate)
                let watchdog = try #require(state.app.fullCardWatchdogTask)
                try await GenerationCoordinator.withTimeout(seconds: 30) {
                    try await fixture.clock.waitUntilScheduled()
                }
                #expect(fixture.clock.requestedNanoseconds == [1_000_000_000])
                #expect(!state.app.generationUIState.isTerminal)
                // Vary ordering using explicit clock instants, without wall-clock sleeps.
                let beforeDeadline: UInt64 = iteration.isMultiple(of: 2) ? 999_999_999 : 500_000_000
                fixture.clock.advance(by: beforeDeadline)
                #expect(fixture.clock.pendingCount == 1)
                #expect(!state.app.generationUIState.isTerminal)

                if timeoutFirst {
                    // Exercise the partial-completion contract through the actual
                    // publication gate, rather than assuming an empty fallback is
                    // a usable first answer when no frozen context exists.
                    #expect(state.app.publishStreamingSections(Self.sections,
                        cardID: "first-answer-controlled-card", generationID: state.generationID,
                        question: state.question, session: state.session, requestStart: state.requestStart,
                        stageBStreamStartedMS: nil))
                    let firstAnswer = try #require(state.app.currentSuggestion)
                    #expect(QuestionRuntimeAcceptanceGuard.validateSuggestionCardForPersistence(firstAnswer).accepted)
                    #expect(!state.app.generationUIState.isTerminal)
                    fixture.clock.advance(by: 1_000_000_000 - beforeDeadline)
                    await watchdog.value
                    if case .answerReady = state.app.generationUIState {} else {
                        Issue.record("A qualified first answer must remain ready after the expansion deadline.")
                    }
                    let terminalCard = try #require(state.app.currentSuggestion)
                    let terminalUI = state.app.generationUIState
                    // The existing policy promotes a complete substantive provider
                    // first answer to a completed card after expansion times out.
                    #expect(terminalCard.stageBStatus == "completed")
                    #expect(terminalCard.stageBCompleted == true)
                    #expect(terminalCard.sayFirst == firstAnswer.sayFirst)
                    #expect(terminalCard.finalVisibleSource == firstAnswer.finalVisibleSource)
                    #expect(QuestionRuntimeAcceptanceGuard.validateSuggestionCardForPersistence(terminalCard).accepted)
                    #expect(state.app.terminalGenerationIDs.contains(state.generationID))
                    #expect(!state.app.publishStreamingSections(Self.sections,
                        cardID: "late-controlled-card", generationID: state.generationID,
                        question: state.question, session: state.session, requestStart: state.requestStart,
                        stageBStreamStartedMS: nil, markFullCardVisible: true))
                    #expect(state.app.currentSuggestion == terminalCard)
                    #expect(state.app.generationUIState == terminalUI)
                } else {
                    #expect(state.app.publishStreamingSections(Self.sections,
                        cardID: "completed-controlled-card", generationID: state.generationID,
                        question: state.question, session: state.session, requestStart: state.requestStart,
                        stageBStreamStartedMS: nil, markFullCardVisible: true))
                    let answer = try #require(state.app.currentSuggestion)
                    #expect(QuestionRuntimeAcceptanceGuard.validateSuggestionCardForPersistence(answer).accepted)
                    #expect(state.app.finishGenerationWithVisibleCard(answer,
                        generationID: state.generationID, question: state.question, session: state.session,
                        requestStart: state.requestStart, retrievedChunks: [], triggerPath: .manualGenerate,
                        timedOut: false))
                    await watchdog.value
                    let terminalCard = state.app.currentSuggestion
                    let terminalUI = state.app.generationUIState
                    fixture.clock.advance(by: 1_000_000_000 - beforeDeadline)
                    #expect(state.app.currentSuggestion == terminalCard)
                    #expect(state.app.generationUIState == terminalUI)
                    #expect(state.app.currentSuggestion?.stageBStatus == "completed")
                    #expect(watchdog.isCancelled)
                }
            }
            #expect(fixture.clock.pendingCount == 0)
        }
    }

    @Test
    func rejectedNoAnswerFallbackDeadlineEndsGenerationWithoutPlaceholderOrLatePublication() async throws {
        let state = try await makeState()
        let fixture = ControlledGenerationWatchdogFixture(app: state.app)
        try await fixture.run {
            let identity = try #require(state.app.activeGenerationController?.identity)
            let fallback = state.app.makeInitialFirstAnswerFallbackCard(
                cardID: "rejected-empty-controlled-fallback", question: state.question,
                session: state.session, requestStart: state.requestStart)
            #expect(fallback.sayFirst.isEmpty)
            #expect(!QuestionRuntimeAcceptanceGuard.validateSuggestionCardForPersistence(fallback).accepted)
            // Prove the real UI boundary rejects this no-evidence fallback.
            #expect(!state.app.displaySuggestionIfAligned(fallback, question: state.question,
                generationID: state.generationID, triggerPath: .manualGenerate))
            #expect(state.app.currentSuggestion == nil)
            state.app.startFullCardWatchdog(generationID: state.generationID,
                cardID: "rejected-empty-controlled-fallback", question: state.question,
                session: state.session, requestStart: state.requestStart, triggerPath: .manualGenerate)
            let watchdog = try #require(state.app.fullCardWatchdogTask)
            try await GenerationCoordinator.withTimeout(seconds: 30) {
                try await fixture.clock.waitUntilScheduled()
            }
            fixture.clock.advance(by: 1_000_000_000)
            await watchdog.value
            if case .timeout = state.app.generationUIState {} else {
                Issue.record("A rejected no-answer fallback must still end the generation as timeout.")
            }
            #expect(state.app.generationUIState.isTerminal)
            #expect(!state.app.generationCoordinator.canPublish(identity))
            #expect(!state.app.suggestionGenerationStarted)
            #expect(!state.app.isActionLoading(ActionID.generateAnswer))
            #expect(state.app.currentSuggestion == nil)
            #expect(try state.app.suggestionRepository.suggestions(sessionID: state.session.id).isEmpty)
            let terminalUI = state.app.generationUIState
            #expect(!state.app.publishStreamingSections(Self.sections,
                cardID: "late-after-rejected-controlled-fallback", generationID: state.generationID,
                question: state.question, session: state.session, requestStart: state.requestStart,
                stageBStreamStartedMS: nil, markFullCardVisible: true))
            #expect(state.app.currentSuggestion == nil)
            #expect(state.app.generationUIState == terminalUI)
            #expect(try state.app.suggestionRepository.suggestions(sessionID: state.session.id).isEmpty)
        }
        #expect(fixture.clock.pendingCount == 0)
    }

    @Test(arguments: [false, true])
    nonisolated func controlledClockCancellationReclaimsRegisteredAndUnregisteredSleeps(cancelBeforeRegistration: Bool) async throws {
        // This lock-protected clock contract uses no UI state. Keep its sleeper
        // independent of the MainActor used by the actual app watchdog tests.
        let trace = TestEventWaitTrace(label: "clockReclamation.cancelBeforeRegistration.\(cancelBeforeRegistration)")
        let clock = ControlledGenerationWatchdogClock(trace: trace)
        trace.mark("parent.task_create_requested")
        let task = Task {
            trace.mark("sleeper.task_entered")
            try await clock.sleep(nanoseconds: 1_000_000_000)
        }
        do {
            if !cancelBeforeRegistration {
                trace.mark("parent.registration_wait_requested")
                try await GenerationCoordinator.withTimeout(seconds: 30) { try await clock.waitUntilScheduled() }
                #expect(clock.pendingCount == 1)
            }
            trace.mark("parent.sleeper_cancel_requested")
            task.cancel()
            #expect(clock.pendingCount == 0)
            // A failing reclamation assertion must still release the latch, so
            // this regression cannot hang the complete ordinary test suite.
            clock.cancelAll()
            let cancelled = await task.result
            switch cancelled {
            case .failure(let error): #expect(error is CancellationError)
            case .success: Issue.record("Cancelling a held clock sleep must throw cancellation.")
            }
            #expect(clock.pendingCount == 0)
        } catch {
            task.cancel()
            clock.cancelAll()
            _ = await task.result
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func throwingFixtureBodyCancelsAndJoinsActualWatchdog() async throws {
        enum Abort: Error { case expected }
        let state = try await makeState()
        let fixture = ControlledGenerationWatchdogFixture(app: state.app)
        var ownedWatchdog: Task<Void, Never>?
        do {
            try await fixture.run {
                state.app.startFullCardWatchdog(generationID: state.generationID,
                    cardID: "aborted-controlled-card", question: state.question, session: state.session,
                    requestStart: state.requestStart, triggerPath: .manualGenerate)
                let watchdog = try #require(state.app.fullCardWatchdogTask)
                ownedWatchdog = watchdog
                try await fixture.clock.waitUntilScheduled()
                throw Abort.expected
            }
            Issue.record("The fixture should propagate the original body error after cleanup.")
        } catch Abort.expected {}
        #expect(ownedWatchdog?.isCancelled == true)
        #expect(fixture.clock.pendingCount == 0)
        #expect(state.app.generationCoordinator.requestTask == nil)
        #expect(state.app.fullCardWatchdogTask == nil)
    }

    private struct State {
        let app: AppState
        let session: InterviewSession
        let question: DetectedQuestion
        let generationID: String
        let requestStart: Date
    }

    private func makeState() async throws -> State {
        // The controlled deadline tests need real SQL admission, not file durability.
        let database = try await TestSupport.makeInMemoryDatabase()
        let app = AppState(database: database,
            questionRoutingProvider: HermeticQuestionRoutingProvider(),
            permissionService: HermeticPermissionService())
        let session = try app.sessionRepository.createSession(mode: .mock)
        app.currentSession = session
        app.generationFullCardWatchdogNanoseconds = 1_000_000_000
        let question = DetectedQuestion(id: UUID().uuidString, sessionID: session.id,
            transcriptSegmentID: nil, questionText: "Explain database transactions and atomicity.",
            intent: .technical, answerStrategy: .directAnswer, confidence: 1,
            reason: "Synthetic controlled watchdog regression", shouldTrigger: true,
            questionComplete: true, modelName: "fixture", promptVersion: "fixture", createdAt: Date())
        try app.suggestionRepository.saveDetectedQuestion(question)
        let generationID = UUID().uuidString
        let requestStart = Date()
        app.activateGeneration(question: question, generationID: generationID, triggerPath: .manualGenerate,
            requestStart: requestStart, source: nil, speaker: nil, answerProviderMode: .deepSeekPrimary)
        return State(app: app, session: session, question: question,
            generationID: generationID, requestStart: requestStart)
    }
}
