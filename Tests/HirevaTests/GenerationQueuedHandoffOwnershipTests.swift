import Foundation
import Combine
import os
import Testing
@testable import Hireva

#if DEBUG
/// Mixed seam: freezes a finite noncooperative clock and forwards to the actual
/// private App scheduling entry. It never calls a provider or an audio device.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct GenerationQueuedHandoffOwnershipTests {
    @Test
    func replacedHandoffAndStoppedCurrentHandoffRemainOwnedUntilTheirActualExit() async throws {
        let fixture = try await HandoffApplicationFixture()
        let app = fixture.app
        let firstClock = HandoffHeldClock()
        let secondClock = HandoffHeldClock()
        var first: Task<Void, Never>?
        var second: Task<Void, Never>?
        try await withTaskCancellationHandler {
            do {
                await app.automaticContextBuildTask?.value
                let session = try app.createContextBoundSession(mode: .mock, title: "Synthetic queue handoff")
                app.currentSession = session
                let active = question(session: session, suffix: "active")
                let pending = question(session: session, suffix: "queued")
                app.activateGeneration(question: active, generationID: UUID().uuidString,
                    triggerPath: .autoDetect, requestStart: Date(), source: .systemAudio, speaker: .unknown)
                app.pendingAcceptedQuestions = [.init(question: pending, session: session,
                    transcript: pending.questionText, canonicalQuestion: pending.questionText,
                    intent: AnswerRelevancePolicy.intent(for: pending.questionText), promptPrimaryQuestion: pending.questionText,
                    duplicateKey: "synthetic-handoff-queued", queuedAt: Date(),
                    consentTicket: app.persistenceConsent.ticket())]
                app.queuedQuestionHandoffDelayProviderForTesting = firstClock
                app.scheduleQueuedQuestionHandoffForTesting(questionID: pending.id, sessionID: session.id)
                let requiredFirstHandoff: Task<Void, Never> = try #require(app.queuedQuestionHandoffTask)
                first = requiredFirstHandoff
                try await firstClock.waitForStart()
                #expect(firstClock.requestedNanoseconds == 2_000_000_000,
                    "Ownership changes must keep the existing two-second handoff policy.")

                app.queuedQuestionHandoffDelayProviderForTesting = secondClock
                app.scheduleQueuedQuestionHandoffForTesting(questionID: pending.id, sessionID: session.id)
                let requiredSecondHandoff: Task<Void, Never> = try #require(app.queuedQuestionHandoffTask)
                second = requiredSecondHandoff
                try await secondClock.waitForStart()
                #expect(first != second)
                #expect(first?.isCancelled == true)
                #expect(!firstClock.hasExited)
                #expect(app.generationCoordinator.retiringTaskCount == 1,
                    "Replacement cancelled the real old timer but may not discard its still-running handle.")
                #expect(app.generationCoordinator.pendingCleanupTaskCount == 2,
                    "Both the replaced timer and the current timer are still held by their real clocks.")

                // This is the actual public App cancellation boundary. The old
                // implementation only knows its Generation children, not this timer.
                app.cancelActiveGenerationForStop()
                #expect(second?.isCancelled == true)
                #expect(app.queuedQuestionHandoffTask == nil)
                #expect(app.generationCoordinator.retiringTaskCount == 2)
                #expect(app.generationCoordinator.pendingCleanupTaskCount == 2)
                #expect(!firstClock.hasExited && !secondClock.hasExited)
                #expect(app.activeQuestionID == nil)

                firstClock.release(); secondClock.release()
                await first?.value; await second?.value
                await app.generationCoordinator.drainRetiredTasks()
                #expect(firstClock.hasExited && secondClock.hasExited)
                #expect(app.generationCoordinator.pendingCleanupTaskCount == 0)
                #expect(app.pendingAcceptedQuestions.first?.question.id == pending.id,
                    "Cancelled timers cannot advance the business queue or launch a provider.")
            } catch {
                first?.cancel(); second?.cancel()
                firstClock.release(); secondClock.release()
                await first?.value; await second?.value
                app.generationCoordinator.closeAdmission()
                await app.generationCoordinator.drainRetiredTasks()
                app.queuedQuestionHandoffDelayProviderForTesting = nil
                try await fixture.shutdown()
                throw error
            }
            first?.cancel(); second?.cancel()
            firstClock.release(); secondClock.release()
            await first?.value; await second?.value
            app.queuedQuestionHandoffDelayProviderForTesting = nil
            try await fixture.shutdown()
        } onCancel: {
            // Lock-owned gates can release without waiting for MainActor. The
            // owning test still joins both exact task handles before closing DB.
            firstClock.release(); secondClock.release()
        }
    }

    enum DrainReplacement: String, CaseIterable, Sendable {
        case differentHead, revisedSameHead, session, fullIdentity, exactTimer, blockedDrain
    }

    /// Actual application dequeue entry; the finite timer is still held when
    /// clearTask publishes. Replacement keeps one queued item, so an unfixed
    /// dequeue fails ordinary assertions instead of crashing removeFirst().
    @Test(arguments: DrainReplacement.allCases)
    func ownershipPublicationCannotDequeueReplacedApplicationAuthority(change: DrainReplacement) async throws {
        let fixture = try await HandoffApplicationFixture()
        let app = fixture.app
        let owner = app.generationCoordinator
        let firstClock = HandoffHeldClock()
        let nextClock = HandoffHeldClock()
        var tasks: [Task<Void, Never>] = []
        var subscription: AnyCancellable?
        try await withTaskCancellationHandler {
            do {
                await app.automaticContextBuildTask?.value
                var settings = app.settings
                settings.saveTranscriptsLocally = false
                app.saveSettings(settings)
                let session = try app.createContextBoundSession(mode: .mock, title: "Synthetic drain reentry")
                app.currentSession = session
                let active = question(session: session, suffix: "active")
                let identity = GenerationIdentity(question: active, generationID: UUID().uuidString,
                    contextSnapshotID: "synthetic-initial-context")
                owner.activate(identity: identity, persistenceTicket: 1,
                    triggerPath: .autoDetect, startedAt: Date())
                // Existing idle UI policy permits FIFO without invoking any
                // provider. The held timer gives clearTask an exact resource.
                app.generationUIState = .idle
                let original = queuedQuestion(question(session: session, suffix: "queued"), session: session)
                app.pendingAcceptedQuestions = [original]
                app.queuedQuestionHandoffDelayProviderForTesting = firstClock
                app.scheduleQueuedQuestionHandoffForTesting(questionID: original.question.id, sessionID: session.id)
                let first = try #require(app.queuedQuestionHandoffTask)
                tasks.append(first)
                try await firstClock.waitForStart()
                var expectedHead = original
                var expectedSessionID = session.id
                var expectedIdentity = identity
                var replacement: Task<Void, Never>?
                var replaced = false
                subscription = owner.objectWillChange.sink { _ in
                    guard !replaced, owner.queuedQuestionHandoffTask == nil,
                          !firstClock.hasExited else { return }
                    replaced = true
                    switch change {
                    case .differentHead:
                        expectedHead = queuedQuestion(question(session: session, suffix: "replacement"), session: session)
                        app.pendingAcceptedQuestions = [expectedHead]
                    case .revisedSameHead:
                        expectedHead = queuedQuestion(original.question, session: session,
                            transcript: original.transcript + " Synthetic revised context.", queuedAt: original.queuedAt)
                        app.pendingAcceptedQuestions = [expectedHead]
                    case .session:
                        var next = session; next.id = UUID().uuidString
                        expectedSessionID = next.id
                        app.currentSession = next
                    case .fullIdentity:
                        expectedIdentity = GenerationIdentity(question: active,
                            generationID: identity.generationID, contextSnapshotID: "synthetic-replaced-context")
                        owner.activate(identity: expectedIdentity, persistenceTicket: 2,
                            triggerPath: .regenerate, startedAt: Date())
                    case .exactTimer:
                        // The full value identity can be reused. A new exact
                        // timer receipt must still defeat the older drain.
                        owner.activate(identity: identity, persistenceTicket: 2,
                            triggerPath: .regenerate, startedAt: Date())
                        app.queuedQuestionHandoffDelayProviderForTesting = nextClock
                        app.scheduleQueuedQuestionHandoffForTesting(questionID: original.question.id, sessionID: session.id)
                        replacement = app.queuedQuestionHandoffTask
                    case .blockedDrain:
                        app.providerStreamActive = true
                    }
                }
                app.processNextQueuedAutoQuestionIfIdle()
                // Capture before cancelling any incorrectly admitted root. No
                // suspension allows that root to enter its provider operation.
                let headAfterDrain = app.pendingAcceptedQuestions.first
                let depthAfterDrain = app.pendingAcceptedQuestions.count
                let requestAfterDrain = owner.activeRequest?.id
                let identityAfterDrain = owner.activeGeneration?.identity
                let sessionAfterDrain = app.currentSession?.id
                let replacementAfterDrain = owner.queuedQuestionHandoffTask
                if let root = owner.activeRequest?.task { tasks.append(root) }
                if let replacement { tasks.append(replacement) }
                subscription?.cancel(); subscription = nil
                app.cancelActiveGenerationForStop()
                #expect(replaced, "The actual dequeue clear must synchronously publish committed timer retirement.")
                #expect(depthAfterDrain == 1 && headAfterDrain?.question == expectedHead.question)
                #expect(headAfterDrain?.transcript == expectedHead.transcript)
                #expect(requestAfterDrain == nil, "The obsolete drain must not launch any provider root.")
                #expect(identityAfterDrain == expectedIdentity)
                #expect(sessionAfterDrain == expectedSessionID)
                if change == .exactTimer {
                    #expect(replacement != nil && replacementAfterDrain == replacement,
                        "Do not clear or replace a newly registered same-identity handoff.")
                }
                firstClock.release(); nextClock.release()
                for task in tasks { await task.value }
                await owner.drainRetiredTasks()
                #expect(owner.pendingCleanupTaskCount == 0)
            } catch {
                subscription?.cancel(); owner.closeAdmission()
                firstClock.release(); nextClock.release()
                for task in tasks { await task.value }
                await owner.drainRetiredTasks()
                app.queuedQuestionHandoffDelayProviderForTesting = nil
                try await fixture.shutdown()
                throw error
            }
            subscription?.cancel(); owner.closeAdmission()
            firstClock.release(); nextClock.release()
            for task in tasks { await task.value }
            await owner.drainRetiredTasks()
            app.queuedQuestionHandoffDelayProviderForTesting = nil
            try await fixture.shutdown()
        } onCancel: { firstClock.release(); nextClock.release() }
    }

    @Test(arguments: ["differentHead", "revisedSameHead", "session", "fullIdentity", "exactTimer", "blockedDrain", "stop"])
    func finalQueueNotificationCannotRunOldCoordinationAfterReplacement(change: String) async throws {
        let fixture = try await HandoffApplicationFixture()
        let app = fixture.app
        let runtime = app.generationCoordinator
        var subscription: AnyCancellable?
        do {
            await app.automaticContextBuildTask?.value
            var settings = app.settings; settings.saveTranscriptsLocally = false
            app.saveSettings(settings)
            let session = try app.createContextBoundSession(mode: .mock, title: "Synthetic queue notification")
            app.currentSession = session
            let active = question(session: session, suffix: "notification-active")
            let identity = GenerationIdentity(question: active, generationID: UUID().uuidString)
            runtime.activate(identity: identity, persistenceTicket: 1, triggerPath: .autoDetect, startedAt: Date())
            app.generationUIState = .idle
            let first = queuedQuestion(question(session: session, suffix: "notification-first"), session: session)
            let next = queuedQuestion(question(session: session, suffix: "notification-next"), session: session)
            app.pendingAcceptedQuestions = [first, next]
            let canary = question(session: session, suffix: "notification-canary")
            var replaced = false
            var registeredBeforeNotification: Task<Void, Never>?
            var expectedHead = next
            var expectedSessionID = session.id
            var expectedIdentity: GenerationIdentity?
            var expectedTimer: Task<Void, Never>?
            subscription = app.liveInterview.objectWillChange.sink { _ in
                guard !replaced, let submittedRoot = app.activeAITask,
                      app.pendingAcceptedQuestions.first == next else { return }
                replaced = true
                registeredBeforeNotification = submittedRoot
                switch change {
                case "differentHead":
                    expectedHead = queuedQuestion(question(session: session, suffix: "notification-replacement"), session: session)
                    app.pendingAcceptedQuestions = [expectedHead]
                case "revisedSameHead":
                    expectedHead = queuedQuestion(next.question, session: session,
                        transcript: next.transcript + " Synthetic revised context.", queuedAt: next.queuedAt)
                    app.pendingAcceptedQuestions = [expectedHead]
                case "session":
                    var replacement = session; replacement.id = UUID().uuidString
                    expectedSessionID = replacement.id
                    app.currentSession = replacement
                case "fullIdentity":
                    let replacement = GenerationIdentity(question: active, generationID: identity.generationID,
                        contextSnapshotID: "synthetic-notification-context")
                    expectedIdentity = replacement
                    runtime.activate(identity: replacement, persistenceTicket: 2, triggerPath: .regenerate, startedAt: Date())
                case "exactTimer":
                    expectedIdentity = identity
                    runtime.activate(identity: identity, persistenceTicket: 2, triggerPath: .regenerate, startedAt: Date())
                    app.scheduleQueuedQuestionHandoffForTesting(questionID: next.question.id, sessionID: session.id)
                    expectedTimer = app.queuedQuestionHandoffTask
                case "blockedDrain":
                    app.providerStreamActive = true
                case "stop":
                    app.cancelActiveGenerationForStop()
                default:
                    Issue.record("Unexpected synthetic replacement order")
                }
                // Any old post-notification tail would overwrite this value.
                app.lastDetectedQuestion = canary
            }
            app.processNextQueuedAutoQuestionIfIdle()
            subscription?.cancel(); subscription = nil
            #expect(replaced && registeredBeforeNotification != nil)
            #expect(app.pendingAcceptedQuestions == [expectedHead])
            #expect(app.currentSession?.id == expectedSessionID)
            #expect(app.lastDetectedQuestion == canary)
            if let expectedIdentity { #expect(runtime.activeGeneration?.identity == expectedIdentity) }
            if change == "exactTimer" { #expect(expectedTimer != nil && app.queuedQuestionHandoffTask == expectedTimer) }
            if change == "blockedDrain" { #expect(app.providerStreamActive) }
            if change == "stop" {
                #expect(registeredBeforeNotification?.isCancelled == true && app.activeAITask == nil)
                #expect(app.pendingAcceptedQuestions.first == next, "Stop must not consume another queued head.")
            }
            // The submitted root has not had an actor turn to call any provider.
            app.cancelActiveGenerationForStop()
            try await fixture.shutdown()
        } catch {
            subscription?.cancel()
            app.cancelActiveGenerationForStop()
            try await fixture.shutdown()
            throw error
        }
    }

    // Counterfactuals for the new queue notification added by this migration.
    // These do not claim a reproduction against the original non-notifying queue.
    @Test
    func queueNotificationUserStopCannotBeOverwrittenByTranscriptListeningTail() async throws {
        let fixture = try await HandoffApplicationFixture()
        let app = fixture.app
        var subscription: AnyCancellable?
        do {
            await app.automaticContextBuildTask?.value
            var settings = app.settings
            settings.saveTranscriptsLocally = false
            settings.audioCaptureMode = .systemAudioOnly
            settings.automaticQuestionDetectionEnabled = true
            settings.manualOnlyMode = false
            app.saveSettings(settings)
            let session = try app.createContextBoundSession(mode: .mock, title: "Synthetic transcript queue stop")
            app.currentSession = session
            let active = question(session: session, suffix: "transcript-stop-active")
            app.activateGeneration(question: active, generationID: UUID().uuidString,
                triggerPath: .autoDetect, requestStart: Date(), source: .systemAudio, speaker: .interviewer)
            let incomingText = "Explain transaction isolation and visibility."
            let segmentID = "synthetic-transcript-queue-stop"
            var stopped = false
            subscription = app.liveInterview.objectWillChange.sink { _ in
                guard !stopped, app.pendingAcceptedQuestions.contains(where: { $0.question.transcriptSegmentID == segmentID }) else { return }
                stopped = true
                app.stopListening()
            }
            let segment = TranscriptSegment(id: segmentID, sessionID: session.id,
                source: .systemAudio, speaker: .interviewer, text: incomingText)
            await app.handleTranscriptSegment(segment)
            subscription?.cancel(); subscription = nil
            #expect(stopped, "The actual transcript path must publish its queued question in this fixture.")
            #expect(app.liveState == .stopped)
            #expect(app.stopReason == .userRequested)
            #expect(app.activeAITask == nil && app.queuedQuestionHandoffTask == nil)
            #expect(app.pendingAcceptedQuestions.contains { $0.question.transcriptSegmentID == segmentID },
                "Stopping cancels handoff, preserving the accepted pending question.")
            try await fixture.shutdown()
        } catch {
            subscription?.cancel(); app.cancelActiveGenerationForStop()
            try await fixture.shutdown()
            throw error
        }
    }

    @Test
    func rejectedStageBQueueNotificationStopCannotLaunchThirdQuestionFromOldCaller() async throws {
        let fixture = try await HandoffApplicationFixture()
        let app = fixture.app
        var subscription: AnyCancellable?
        do {
            await app.automaticContextBuildTask?.value
            var settings = app.settings; settings.saveTranscriptsLocally = false
            app.saveSettings(settings)
            let session = try app.createContextBoundSession(mode: .mock, title: "Synthetic rejected expansion queue stop")
            app.currentSession = session
            let original = question(session: session, suffix: "rejected-original")
            let second = queuedQuestion(question(session: session, suffix: "rejected-second"), session: session)
            let third = queuedQuestion(question(session: session, suffix: "rejected-third"), session: session)
            let originalID = UUID().uuidString
            app.activateGeneration(question: original, generationID: originalID,
                triggerPath: .autoDetect, requestStart: Date(), source: .systemAudio, speaker: .interviewer)
            app.pendingAcceptedQuestions = [second, third]
            let identity = try #require(app.activeGenerationController?.identity)
            var stopped = false
            var secondRoot: Task<Void, Never>?
            subscription = app.liveInterview.objectWillChange.sink { _ in
                guard !stopped, app.pendingAcceptedQuestions.first == third,
                      let requestID = app.generationCoordinator.activeRequest?.id,
                      let submittedRoot = app.activeAITask else { return }
                stopped = true
                secondRoot = submittedRoot
                // The real submitted Q2 can enter preparation before a user
                // stop. Its nonterminal presentation must not enable Q1's tail.
                app.activateGeneration(question: second.question, generationID: UUID().uuidString,
                    triggerPath: .autoDetect, requestStart: Date(), source: .systemAudio,
                    speaker: .interviewer, requestID: requestID)
                app.stopListening()
            }
            let plan = StageBApplicationPlan(generationID: originalID, detectedQuestionID: original.id,
                action: .applyFullCard, fallbackReason: nil, shouldPersist: false,
                shouldUpdateVisibleCard: true, safeDiagnostics: [:], identity: identity)
            try await app.applyStageBApplicationPlan(plan,
                sections: .init(strategy: "Explanation", sayFirst: "", keyPoints: [], followUpReady: [], caution: ""),
                cardID: "synthetic-rejected-expansion", generationID: originalID,
                question: original, session: session, requestStart: Date(), stageBStreamStartedMS: nil,
                retrievedChunks: [], triggerPath: .autoDetect, source: .systemAudio,
                speaker: .interviewer, preserveFallbackSayFirst: false)
            subscription?.cancel(); subscription = nil
            #expect(stopped, "The fixture must reach actual rejected-expansion FIFO admission before stop.")
            #expect(secondRoot?.isCancelled == true)
            #expect(app.liveState == .stopped && app.stopReason == .userRequested)
            #expect(app.activeAITask == nil && app.activeGenerationController == nil,
                "An obsolete rejected Q1 branch cannot start Q3 after the Q2 user stop.")
            #expect(app.pendingAcceptedQuestions == [third])
            app.cancelActiveGenerationForStop() // Cancel an incorrectly admitted root before any actor turn.
            try await fixture.shutdown()
        } catch {
            subscription?.cancel(); app.cancelActiveGenerationForStop()
            try await fixture.shutdown()
            throw error
        }
    }

    // New-notification counterfactual after the outer caller fences. No audio
    // device or provider body can enter before this synchronous rejection returns.
    @Test
    func rejectedStageBSameGenerationReplacementKeepsItsCapturePresentation() async throws {
        let fixture = try await HandoffApplicationFixture()
        let app = fixture.app
        var subscription: AnyCancellable?
        do {
            await app.automaticContextBuildTask?.value
            var settings = app.settings; settings.saveTranscriptsLocally = false
            app.saveSettings(settings)
            let session = try app.createContextBoundSession(mode: .mock, title: "Synthetic same-generation rejection")
            app.currentSession = session
            let original = question(session: session, suffix: "same-generation-original")
            let second = queuedQuestion(question(session: session, suffix: "same-generation-second"), session: session)
            let third = queuedQuestion(question(session: session, suffix: "same-generation-third"), session: session)
            let replacement = question(session: session, suffix: "same-generation-replacement")
            let generationID = UUID().uuidString
            app.activateGeneration(question: original, generationID: generationID,
                triggerPath: .autoDetect, requestStart: Date(), source: .systemAudio, speaker: .interviewer)
            app.pendingAcceptedQuestions = [second, third]
            let identity: GenerationIdentity = try #require(app.activeGenerationController?.identity)
            var replaced = false
            var secondRoot: Task<Void, Never>?
            var replacementIdentity: GenerationIdentity?
            var retainedRequestID: String?
            subscription = app.liveInterview.objectWillChange.sink { _ in
                guard !replaced, app.pendingAcceptedQuestions.first == third,
                      let requestID = app.generationCoordinator.activeRequest?.id,
                      let submittedRoot = app.activeAITask else { return }
                replaced = true
                secondRoot = submittedRoot
                retainedRequestID = requestID
                // Reusing a generation ID does not grant the old question any
                // ownership over the newly committed complete identity.
                app.activateGeneration(question: replacement, generationID: generationID,
                    triggerPath: .regenerate, requestStart: Date(), source: .systemAudio,
                    speaker: .interviewer, requestID: requestID)
                replacementIdentity = app.activeGenerationController?.identity
                app.liveState = .generatingSuggestion
                app.currentCaptureRuntimeState = .generating
            }
            let plan = StageBApplicationPlan(generationID: generationID, detectedQuestionID: original.id,
                action: .applyFullCard, fallbackReason: nil, shouldPersist: false,
                shouldUpdateVisibleCard: true, safeDiagnostics: [:], identity: identity)
            try await app.applyStageBApplicationPlan(plan,
                sections: .init(strategy: "Explanation", sayFirst: "", keyPoints: [], followUpReady: [], caution: ""),
                cardID: "synthetic-same-generation-rejection", generationID: generationID,
                question: original, session: session, requestStart: Date(), stageBStreamStartedMS: nil,
                retrievedChunks: [], triggerPath: .autoDetect, source: .systemAudio,
                speaker: .interviewer, preserveFallbackSayFirst: false)
            subscription?.cancel(); subscription = nil
            #expect(replaced && secondRoot != nil && replacementIdentity != nil,
                "The actual rejected-expansion queue notification must install the replacement.")
            #expect(replacementIdentity?.generationID == identity.generationID)
            #expect(replacementIdentity?.acceptedQuestionID == replacement.id && replacement.id != original.id)
            #expect(app.activeGenerationController?.identity == replacementIdentity)
            #expect(app.generationCoordinator.activeRequest?.id == retainedRequestID)
            #expect(app.liveState == .generatingSuggestion,
                "The old inner terminal helper must not restore the replacement's capture presentation.")
            #expect(app.currentCaptureRuntimeState == .generating)
            #expect(!app.anyCaptureRunning, "This fixture exercises presentation only, never a real audio device.")
            #expect(app.pendingAcceptedQuestions == [third])
            app.cancelActiveGenerationForStop() // Before any submitted root can call a provider.
            try await fixture.shutdown()
        } catch {
            subscription?.cancel(); app.cancelActiveGenerationForStop()
            try await fixture.shutdown()
            throw error
        }
    }

    private func queuedQuestion(_ question: DetectedQuestion, session: InterviewSession,
        transcript: String? = nil, queuedAt: Date = Date()) -> AppState.PendingAcceptedQuestion {
        .init(question: question, session: session, transcript: transcript ?? question.questionText,
            canonicalQuestion: question.questionText, intent: AnswerRelevancePolicy.intent(for: question.questionText),
            promptPrimaryQuestion: question.questionText, duplicateKey: "synthetic-drain-" + question.id,
            queuedAt: queuedAt, consentTicket: nil)
    }

    /// Positive contract: timer retirement alone must not stop same-authority
    /// FIFO, including a terminal generation whose timer was already cancelled.
    @Test(arguments: [false, true])
    func unchangedApplicationAuthorityStillDequeuesExactlyOneFIFOHead(terminal: Bool) async throws {
        let fixture = try await HandoffApplicationFixture()
        let app = fixture.app
        let owner = app.generationCoordinator
        let clock = HandoffHeldClock()
        var tasks: [Task<Void, Never>] = []
        try await withTaskCancellationHandler {
            do {
                await app.automaticContextBuildTask?.value
                var settings = app.settings
                settings.saveTranscriptsLocally = false
                app.saveSettings(settings)
                let session = try app.createContextBoundSession(mode: .mock, title: "Synthetic same-authority FIFO")
                app.currentSession = session
                let active = question(session: session, suffix: "active")
                let identity = GenerationIdentity(question: active, generationID: UUID().uuidString)
                owner.activate(identity: identity, persistenceTicket: 1,
                    triggerPath: .autoDetect, startedAt: Date())
                app.generationUIState = .idle
                let first = queuedQuestion(question(session: session, suffix: "first"), session: session)
                let next = queuedQuestion(question(session: session, suffix: "second"), session: session)
                app.pendingAcceptedQuestions = [first, next]
                app.queuedQuestionHandoffDelayProviderForTesting = clock
                app.scheduleQueuedQuestionHandoffForTesting(questionID: first.question.id, sessionID: session.id)
                let timer = try #require(app.queuedQuestionHandoffTask)
                tasks.append(timer)
                try await clock.waitForStart()
                if terminal {
                    owner.markTerminal(generationID: identity.generationID)
                    app.generationUIState = .timeout(questionID: active.id, generationID: identity.generationID,
                        triggerPath: .autoDetect, reason: "Synthetic completed deadline")
                }
                app.processNextQueuedAutoQuestionIfIdle()
                let headAfterDrain = app.pendingAcceptedQuestions.first?.question.id
                let depthAfterDrain = app.pendingAcceptedQuestions.count
                let dequeued = app.lastDetectedQuestion?.id
                let root = owner.activeRequest?.task
                if let root { tasks.append(root) }
                app.cancelActiveGenerationForStop() // before any provider operation can enter
                #expect(root != nil && dequeued == first.question.id)
                #expect(depthAfterDrain == 1 && headAfterDrain == next.question.id)
                clock.release()
                for task in tasks { await task.value }
                await owner.drainRetiredTasks()
                #expect(owner.pendingCleanupTaskCount == 0)
            } catch {
                owner.closeAdmission(); clock.release()
                for task in tasks { await task.value }
                await owner.drainRetiredTasks()
                app.queuedQuestionHandoffDelayProviderForTesting = nil
                try await fixture.shutdown()
                throw error
            }
            owner.closeAdmission(); clock.release()
            for task in tasks { await task.value }
            await owner.drainRetiredTasks()
            app.queuedQuestionHandoffDelayProviderForTesting = nil
            try await fixture.shutdown()
        } onCancel: { clock.release() }
    }

    /// New-role characterization; stage only after the owner migration. This
    /// is not a historical RED against an API that did not previously exist.
    @Test(arguments: [false, true])
    func oldHandoffExitCannotClearANewerTimerOrPublishItsFrozenContext(replaceContext: Bool) async throws {
        let owner = GenerationCoordinator()
        let firstClock = HandoffHeldClock()
        let secondClock = HandoffHeldClock()
        let firstIdentity = handoffIdentity(context: "synthetic-original")
        let nextIdentity = replaceContext ? handoffIdentity(context: "synthetic-replacement") : firstIdentity
        var tasks: [Task<Void, Never>] = []
        var publications: [GenerationIdentity] = []
        owner.activate(identity: firstIdentity, persistenceTicket: 1, triggerPath: .autoDetect, startedAt: Date())
        try await withTaskCancellationHandler {
            do {
                let first = try #require(owner.launchQueuedQuestionHandoff(identity: firstIdentity,
                    nanoseconds: 2_000_000_000, delayProvider: firstClock) { publications.append($0) })
                tasks.append(first)
                try await firstClock.waitForStart()
                if replaceContext {
                    owner.activate(identity: nextIdentity, persistenceTicket: 2, triggerPath: .regenerate, startedAt: Date())
                }
                let next = try #require(owner.launchQueuedQuestionHandoff(identity: nextIdentity,
                    nanoseconds: 2_000_000_000, delayProvider: secondClock) { publications.append($0) })
                tasks.append(next)
                try await secondClock.waitForStart()
                #expect(first.isCancelled && !next.isCancelled)
                firstClock.release(); await first.value
                #expect(publications.isEmpty)
                #expect(owner.queuedQuestionHandoffTask == next,
                    "The old worker's exact-registration defer cannot clear its replacement.")
                secondClock.release(); await next.value
                await owner.drainRetiredTasks()
                #expect(publications == [nextIdentity])
                #expect(owner.queuedQuestionHandoffTask == nil)
                #expect(owner.pendingCleanupTaskCount == 0)
            } catch {
                owner.closeAdmission()
                firstClock.release(); secondClock.release()
                for task in tasks { await task.value }
                await owner.drainRetiredTasks()
                throw error
            }
            owner.closeAdmission()
            firstClock.release(); secondClock.release()
            for task in tasks { await task.value }
            await owner.drainRetiredTasks()
        } onCancel: { firstClock.release(); secondClock.release() }
    }

    @Test
    func terminalGenerationCancelsItsHandoffAndKeepsItUntilRealExit() async throws {
        let owner = GenerationCoordinator()
        let clock = HandoffHeldClock()
        let identity = handoffIdentity(context: "synthetic-terminal")
        var work: Task<Void, Never>?
        owner.activate(identity: identity, persistenceTicket: 1, triggerPath: .autoDetect, startedAt: Date())
        try await withTaskCancellationHandler {
            do {
                let task = try #require(owner.launchQueuedQuestionHandoff(identity: identity,
                    nanoseconds: 2_000_000_000, delayProvider: clock) { _ in
                        Issue.record("A terminal generation fired a queued handoff.")
                    })
                work = task
                try await clock.waitForStart()
                owner.markTerminal(generationID: identity.generationID)
                #expect(task.isCancelled)
                #expect(owner.queuedQuestionHandoffTask == nil)
                #expect(owner.retiringTaskCount == 1 && owner.pendingCleanupTaskCount == 1)
                #expect(!clock.hasExited)
                clock.release(); await task.value
                await owner.drainRetiredTasks()
                #expect(owner.pendingCleanupTaskCount == 0)
            } catch {
                owner.closeAdmission(); clock.release()
                await work?.value
                await owner.drainRetiredTasks()
                throw error
            }
            owner.closeAdmission(); clock.release()
            await work?.value
            await owner.drainRetiredTasks()
        } onCancel: { clock.release() }
    }

    @Test(arguments: [false, true])
    func completionPublicationCannotHandOffAReactivatedSameIdentity(registerNewTimer: Bool) async throws {
        let owner = GenerationCoordinator()
        let firstClock = HandoffHeldClock()
        let nextClock = HandoffHeldClock()
        let identity = handoffIdentity(context: "synthetic-completion-reentry")
        var tasks: [Task<Void, Never>] = []
        var replacement: Task<Void, Never>?
        var publications: [String] = []
        var replaced = false
        owner.activate(identity: identity, persistenceTicket: 1, triggerPath: .autoDetect, startedAt: Date())
        let subscription = owner.objectWillChange.sink { _ in
            guard !replaced, firstClock.hasExited, owner.queuedQuestionHandoffTask == nil else { return }
            replaced = true
            owner.activate(identity: identity, persistenceTicket: 2, triggerPath: .regenerate, startedAt: Date())
            if registerNewTimer {
                replacement = owner.launchQueuedQuestionHandoff(identity: identity,
                    nanoseconds: 2_000_000_000, delayProvider: nextClock) { _ in publications.append("replacement") }
            }
        }
        try await withTaskCancellationHandler {
            do {
                let task = try #require(owner.launchQueuedQuestionHandoff(identity: identity,
                    nanoseconds: 2_000_000_000, delayProvider: firstClock) { _ in publications.append("obsolete") })
                tasks.append(task)
                try await firstClock.waitForStart()
                firstClock.release(); await task.value
                subscription.cancel()
                #expect(replaced)
                #expect(publications.isEmpty,
                    "A completion notification can reactivate the same value identity; its new registration wins.")
                if registerNewTimer {
                    let next = try #require(replacement)
                    tasks.append(next)
                    try await nextClock.waitForStart()
                    #expect(owner.queuedQuestionHandoffTask == next && !next.isCancelled)
                    nextClock.release(); await next.value
                    #expect(publications == ["replacement"])
                }
                await owner.drainRetiredTasks()
                #expect(owner.pendingCleanupTaskCount == 0)
            } catch {
                subscription.cancel(); owner.closeAdmission()
                firstClock.release(); nextClock.release()
                for task in tasks { await task.value }
                await replacement?.value
                await owner.drainRetiredTasks()
                throw error
            }
            subscription.cancel(); owner.closeAdmission()
            firstClock.release(); nextClock.release()
            for task in tasks { await task.value }
            await replacement?.value
            await owner.drainRetiredTasks()
        } onCancel: { firstClock.release(); nextClock.release() }
    }

    private func handoffIdentity(context: String) -> GenerationIdentity {
        .init(acceptedQuestionID: "synthetic-handoff-question", generationID: "synthetic-shared-handoff-generation",
            sessionID: "synthetic-handoff-session", questionText: "Explain transaction isolation?",
            promptPrimaryQuestion: "Explain transaction isolation?", contextSnapshotID: context)
    }

    private func question(session: InterviewSession, suffix: String) -> DetectedQuestion {
        .init(id: "synthetic-" + suffix + "-" + UUID().uuidString, sessionID: session.id,
            transcriptSegmentID: nil, questionText: "Explain transaction atomicity and isolation?",
            intent: .technical, answerStrategy: .technicalExplanation, confidence: 1,
            reason: "Synthetic handoff ownership", shouldTrigger: true, questionComplete: true,
            modelName: "synthetic-no-provider", promptVersion: "synthetic", createdAt: Date())
    }
}

@MainActor
private final class HandoffApplicationFixture {
    let database: AppDatabase
    let suite: String
    let defaults: UserDefaults
    let app: AppState
    private var closed = false
    init() async throws {
        database = try await TestSupport.makeInMemoryDatabase()
        suite = "com.langcheng.Hireva.tests.handoff." + UUID().uuidString
        guard let value = UserDefaults(suiteName: suite) else {
            try? database.close()
            throw CancellationError()
        }
        defaults = value
        app = AppState(database: database, questionRoutingProvider: HermeticQuestionRoutingProvider(),
            permissionService: HermeticPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            verificationMocksEnabled: false, dialogueDefaults: value,
            embeddingProviderResolverOverride: { _ in nil })
    }
    func shutdown() async throws {
        guard !closed else { return }
        closed = true
        await app.shutdownForTesting()
        try database.close()
        defaults.removePersistentDomain(forName: suite)
    }
}

/// Ignores task cancellation while held; every owning test releases and joins.
/// State/continuation transitions are atomic, and resume occurs outside the lock.
private final class HandoffHeldClock: DelayProvider, Sendable {
    private struct State: Sendable {
        var released = false
        var exited = false
        var nanoseconds: UInt64?
        var waiter: CheckedContinuation<Void, Never>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    var requestedNanoseconds: UInt64? { state.withLock { $0.nanoseconds } }
    var hasExited: Bool { state.withLock { $0.exited } }
    func sleep(nanoseconds: UInt64) async throws {
        defer { state.withLock { $0.exited = true } }
        state.withLock { $0.nanoseconds = nanoseconds }
        started.continuation.yield(()); started.continuation.finish()
        await withCheckedContinuation { continuation in
            let resume = state.withLock { current in
                if current.released { return true }
                current.waiter = continuation
                return false
            }
            if resume { continuation.resume() }
        }
    }
    func waitForStart() async throws {
        _ = try await TestEventWaitTrace(label: "generation.queue-handoff").nextEvent(in: started.stream, event: "clock-entered")
    }
    func release() {
        let waiter = state.withLock { current in
            current.released = true
            let captured = current.waiter; current.waiter = nil
            return captured
        }
        waiter?.resume()
    }
}

@MainActor
extension GenerationQueuedHandoffOwnershipTests {
    /// Actual App drain entry observes both original timers while still held.
    /// The test then releases and joins those timers and the shutdown caller.
    @Test(.timeLimit(.minutes(1)))
    func actualApplicationShutdownRetainsBothHeldHandoffRootsUntilTheirExit() async throws {
        let fixture = try await HandoffApplicationFixture()
        let app = fixture.app
        let firstClock = HandoffHeldClock()
        let secondClock = HandoffHeldClock()
        let entered = AsyncStream<(pending: Int, retiring: Int)>.makeStream(bufferingPolicy: .bufferingOldest(1))
        var first: Task<Void, Never>?
        var second: Task<Void, Never>?
        var shutdown: Task<Bool, Never>?
        var shutdownCompleted = false
        app.generationShutdownWillDrainForTesting = { pending, retiring in
            entered.continuation.yield((pending: pending, retiring: retiring))
        }
        @MainActor func cleanup() async throws {
            defer { entered.continuation.finish() }
            first?.cancel(); second?.cancel()
            firstClock.release(); secondClock.release()
            await first?.value; await second?.value
            _ = await shutdown?.value
            app.generationShutdownWillDrainForTesting = nil
            app.queuedQuestionHandoffDelayProviderForTesting = nil
            try await fixture.shutdown()
        }
        try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                await app.automaticContextBuildTask?.value
                try Task.checkCancellation()
                var settings = app.settings
                settings.saveTranscriptsLocally = false
                app.saveSettings(settings)
                let session = try app.createContextBoundSession(mode: .mock, title: "Synthetic held handoff shutdown")
                app.currentSession = session
                let active = question(session: session, suffix: "active-shutdown")
                let pending = question(session: session, suffix: "queued-shutdown")
                app.activateGeneration(question: active, generationID: UUID().uuidString,
                    triggerPath: .autoDetect, requestStart: Date(), source: .systemAudio, speaker: .unknown)
                app.pendingAcceptedQuestions = [.init(question: pending, session: session,
                    transcript: pending.questionText, canonicalQuestion: pending.questionText,
                    intent: AnswerRelevancePolicy.intent(for: pending.questionText), promptPrimaryQuestion: pending.questionText,
                    duplicateKey: "synthetic-handoff-shutdown", queuedAt: Date(), consentTicket: nil)]
                app.queuedQuestionHandoffDelayProviderForTesting = firstClock
                app.scheduleQueuedQuestionHandoffForTesting(questionID: pending.id, sessionID: session.id)
                let original = try #require(app.queuedQuestionHandoffTask)
                first = original
                try await firstClock.waitForStart()
                app.queuedQuestionHandoffDelayProviderForTesting = secondClock
                app.scheduleQueuedQuestionHandoffForTesting(questionID: pending.id, sessionID: session.id)
                let current = try #require(app.queuedQuestionHandoffTask)
                second = current
                try await secondClock.waitForStart()
                #expect(original != current)
                #expect(firstClock.requestedNanoseconds == 2_000_000_000)
                #expect(secondClock.requestedNanoseconds == 2_000_000_000)

                // Capture the caller instead of awaiting shutdown while gates
                // are held. The actual drain-entry receipt controls release.
                let shutdownCall = Task { @MainActor in
                    let released = await app.shutdownResources()
                    shutdownCompleted = true
                    return released
                }
                shutdown = shutdownCall
                let receipt = try await TestEventWaitTrace(label: #function)
                    .nextEvent(in: entered.stream, event: "actual_app_generation_drain_entered")
                try Task.checkCancellation()
                #expect(app.isShuttingDown)
                #expect(original.isCancelled && current.isCancelled)
                #expect(app.queuedQuestionHandoffTask == nil)
                #expect(receipt.pending == 2 && receipt.retiring == 2,
                    "App must retain both overwritten and current original timers at its generation cleanup entry.")
                #expect(!firstClock.hasExited && !secondClock.hasExited)
                #expect(!shutdownCompleted)

                firstClock.release(); secondClock.release()
                await original.value; await current.value
                let released = await shutdownCall.value
                try Task.checkCancellation()
                #expect(released && shutdownCompleted)
                #expect(firstClock.hasExited && secondClock.hasExited)
                #expect(app.generationCoordinator.pendingCleanupTaskCount == 0)
                #expect(app.generationCoordinator.retiringTaskCount == 0)
                #expect(app.pendingAcceptedQuestions.first?.question.id == pending.id,
                    "Shutdown revokes timer admission without advancing the business queue.")
            } catch {
                try await cleanup()
                throw error
            }
            try await cleanup()
        } onCancel: {
            // Lock-owned release works even before continuation installation.
            // The owning test still joins every captured original handle.
            firstClock.release(); secondClock.release()
            entered.continuation.finish()
        }
    }
}
#endif
