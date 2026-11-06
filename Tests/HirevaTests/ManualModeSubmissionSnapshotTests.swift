import Combine
import Foundation
import Testing
@testable import Hireva

/// Real manual entry points with an isolated snapshot fixture. Submission and
/// synchronous presentation are exercised before the queued worker can run.
@MainActor
struct ManualModeSubmissionSnapshotTests {
    @Test(.timeLimit(.minutes(1)), arguments: Entry.allCases)
    func submittedManualParentRetainsModeWhileUIChanges(entry: Entry) async throws {
        let fixture = try await ManualSnapshotFixture(mode: entry == .remoteAnswerNow
            ? .deepSeekPrimary : .localQwenPrimary)
        var pending: [Task<Void, Never>] = []
        do {
            fixture.app.interviewSessionMode = .auto
            let parent = fixture.parent(id: "submitted-parent", answer:
                "Use bounded retries for transient transaction failures.")
            fixture.app.currentSuggestion = parent
            let text = "Explain database transactions and atomicity."
            fixture.setTranscript(text)

            let request: Task<Void, Never>
            switch entry {
            case .localAnswerNow, .remoteAnswerNow:
                fixture.app.manualAnswerNow()
                request = try #require(fixture.app.activeAITask)
            case .regenerate:
                var visible = fixture.parent(id: "submitted-regenerate-question", answer:
                    "A database transaction groups operations into an atomic unit.")
                visible.questionText = text
                let questionID = try #require(visible.questionID)
                var question = DetectedQuestion(id: questionID, sessionID: fixture.session.id,
                    transcriptSegmentID: nil, questionText: text, intent: .technical,
                    answerStrategy: .directAnswer, confidence: 1, reason: "Synthetic current question",
                    shouldTrigger: true, questionComplete: true, modelName: fixture.originalModel,
                    promptVersion: "synthetic-mode-snapshot", createdAt: Date())
                var descriptor = InterviewTaskDescriptor(question: text)
                descriptor.conversationContextCaptured = true
                descriptor.conversationContext = .init(sessionID: fixture.session.id,
                    questionID: try #require(parent.questionID),
                    questionText: try #require(parent.questionText), answerText: parent.sayFirst,
                    contextSnapshotID: parent.contextSnapshotID, mode: InterviewSessionMode.auto.rawValue)
                question.taskDescriptor = descriptor
                fixture.app.lastDetectedQuestion = question
                fixture.app.currentSuggestion = visible
                fixture.app.regenerateVisibleSuggestion()
                request = try #require(fixture.app.activeAITask)
            case .capture:
                fixture.app.manualCaptureState = .transcriptReady
                fixture.app.manualCaptureTranscript = text
                fixture.app.sendManualCaptureToAI()
                request = try #require(fixture.app.stageBTask)
            }
            pending.append(request)

            // No suspension has occurred after the public action. The existing
            // mode policy intentionally keeps the queued generation alive.
            fixture.app.interviewSessionMode = .panelQuestions
            #expect(!request.isCancelled)
            #expect(fixture.app.interviewSessionMode == .panelQuestions)
            try await fixture.join(request)
            if let expansion = fixture.app.stageBTask {
                pending.append(expansion)
                try await fixture.join(expansion)
            }

            let descriptor = try #require(fixture.app.lastDetectedQuestion?.taskDescriptor)
            let captured = try #require(descriptor.conversationContext,
                "A later dialogue-mode selection must not erase the submitted manual parent.")
            #expect(descriptor.conversationContextCaptured == true)
            #expect(captured.sessionID == fixture.session.id)
            #expect(captured.questionID == parent.questionID)
            #expect(captured.questionText == parent.questionText)
            #expect(captured.answerText == parent.sayFirst)
            #expect(captured.contextSnapshotID == parent.contextSnapshotID)
            #expect(captured.mode == InterviewSessionMode.auto.rawValue)
            #expect(fixture.app.currentSuggestion?.questionText == (entry == .localAnswerNow
                ? "Explain database transactions and atomicity" : text))
            if entry == .remoteAnswerNow {
                #expect(!fixture.remote.requests().isEmpty)
                #expect(await fixture.original.requests().isEmpty)
            } else {
                #expect(fixture.remote.requests().isEmpty)
                #expect(await fixture.original.requests().count == 1)
            }
            try await fixture.close(pending)
        } catch {
            try? await fixture.close(pending)
            throw error
        }
    }


    enum BeforeActivationMutation: String, CaseIterable, Sendable {
        case answerMode, provider, originallyMissingActiveProvider, revokedConsent, context, originallyUnboundContext
    }

    /// A real Manual state publication precedes activateGeneration. Values
    /// captured before that synchronous callback must remain the owner's input.
    /// The queued worker is cancelled/joined without contacting any provider.
    @Test(.timeLimit(.minutes(1)), arguments: BeforeActivationMutation.allCases)
    func submittedManualSnapshotCannotBeRecapturedAtActivation(
        change: BeforeActivationMutation
    ) async throws {
        let fixture = try await ManualSnapshotFixture()
        var roots: [Task<Void, Never>] = []
        var observation: AnyCancellable?
        do {
            let replacementProvider = LLMProviderConfiguration.deepSeekDefault()
            var replacementSnapshot = try #require(fixture.app.activeContextSnapshot)
            replacementSnapshot.id = "synthetic-before-activation-replacement-context"
            if change == .originallyMissingActiveProvider {
                let settings = SettingsRepository(database: fixture.database)
                for configuration in try settings.providerConfigurations() {
                    try settings.deleteProviderConfiguration(id: configuration.id)
                }
                fixture.app.providerConfigurations = []
                fixture.app.activeRealtimeProvider = nil
            }
            if change == .originallyUnboundContext {
                var unbound = fixture.session
                unbound.contextSnapshotID = nil
                fixture.app.currentSession = unbound
                fixture.app.activeContextSnapshot = nil
            }
            let submittedMode = fixture.app.selectedAnswerProviderMode
            let submittedProvider = fixture.app.activeRealtimeProvider ?? (try? fixture.app.llmRouter.realtimeConfiguration())
            let submittedTicket = fixture.app.persistenceConsent.ticket()
            let submittedContext = fixture.app.currentSession?.contextSnapshotID
            fixture.app.manualCaptureTranscript = "Explain database transactions and atomicity."
            fixture.app.manualCaptureState = .transcriptReady
            var changed = false
            observation = fixture.app.manualCaptureController.stateUpdates.dropFirst().sink { state in
                guard !changed, state == .generatingSuggestion else { return }
                changed = true
                switch change {
                case .answerMode:
                    fixture.app.answerProviderModeOverride = .deepSeekWithLocalQwenFallback
                case .provider, .originallyMissingActiveProvider:
                    fixture.app.activeRealtimeProvider = replacementProvider
                case .revokedConsent:
                    fixture.app.persistenceConsent.invalidate()
                    fixture.app.persistenceConsent.update(enabled: true)
                case .context, .originallyUnboundContext:
                    fixture.app.activeContextSnapshot = replacementSnapshot
                }
            }
            fixture.app.sendManualCaptureToAI()
            let workflow = try #require(fixture.app.stageBTask)
            roots.append(workflow)
            observation?.cancel(); observation = nil
            let generation = try #require(fixture.app.activeGenerationController)
            #expect(changed)
            #expect(generation.answerProviderMode == submittedMode)
            #expect(generation.providerConfiguration == submittedProvider)
            #expect(generation.persistenceTicket == submittedTicket)
            #expect(generation.identity.contextSnapshotID == submittedContext)
            #expect(generation.identity.sessionID == fixture.app.currentSession?.id)
            if change == .originallyMissingActiveProvider {
                // The real router repairs absent defaults. This case freezes
                // that resolved configuration; query_only coverage separately
                // proves genuinely unavailable configuration remains nil.
                #expect(submittedProvider != nil)
            }
            if change == .originallyUnboundContext { #expect(generation.identity.contextSnapshotID == nil) }
            if change == .revokedConsent {
                #expect(!fixture.app.persistenceConsent.isCurrent(ticket: submittedTicket),
                    "Re-enabling saving cannot replace a revoked operation's submitted ticket.")
            }
            // Cancel before the first suspension, including the actor read.
            workflow.cancel()
            let requests = await fixture.original.requests()
            #expect(fixture.remote.requests().isEmpty && requests.isEmpty)
            try await fixture.close(roots)
            #expect(fixture.app.generationCoordinator.pendingCleanupTaskCount == 0)
        } catch {
            observation?.cancel()
            try? await fixture.close(roots)
            throw error
        }
    }

    enum PublicBeforeActivationChange: CaseIterable, Sendable { case answerMode, context, temporaryContext, stop }

    /// Public policy actions revoke this submitted operation while its actual
    /// Manual state setter is still publishing, before any worker can run.
    @Test(.timeLimit(.minutes(1)), arguments: PublicBeforeActivationChange.allCases)
    func publicChangeCannotReviveManualEntryBeforeActivation(
        change: PublicBeforeActivationChange
    ) async throws {
        let fixture = try await ManualSnapshotFixture()
        var roots: [Task<Void, Never>] = []
        var observation: AnyCancellable?
        var changed = false
        do {
            fixture.app.manualCaptureTranscript = "Explain database transactions and atomicity."
            fixture.app.manualCaptureState = .transcriptReady
            let originalSnapshot = fixture.app.currentSession?.contextSnapshotID
            if change == .temporaryContext {
                // A synthetic temporary session has no repository row. Its
                // selected context still revokes an already submitted operation.
                try fixture.app.sessionRepository.deleteSession(id: fixture.session.id)
            }
            observation = fixture.app.manualCaptureController.stateUpdates.dropFirst().sink { state in
                guard !changed, state == .generatingSuggestion else { return }
                changed = true
                switch change {
                case .answerMode: fixture.app.setSelectedAnswerProviderMode(.deepSeekPrimary)
                case .context, .temporaryContext: fixture.app.selectInterviewDomain(.roboticsResearch)
                case .stop: fixture.app.cancelActiveGenerationForStop()
                }
            }
            fixture.app.sendManualCaptureToAI()
            if let worker = fixture.app.stageBTask { roots.append(worker) }
            observation?.cancel(); observation = nil
            #expect(changed)
            #expect(fixture.app.activeGenerationController == nil)
            #expect(fixture.app.generationCoordinator.activeRequest == nil)
            #expect(fixture.app.stageBTask == nil)
            #expect(!fixture.app.isActionLoading(ActionID.manualGenerate))
            #expect(fixture.app.currentSuggestion == nil)
            if change == .context {
                #expect(fixture.app.currentSession?.contextSnapshotID != originalSnapshot)
            }
            roots.forEach { $0.cancel() }
            let requests = await fixture.original.requests()
            #expect(fixture.remote.requests().isEmpty && requests.isEmpty)
            try await fixture.close(roots)
            #expect(fixture.app.generationCoordinator.pendingCleanupTaskCount == 0)
        } catch {
            observation?.cancel()
            roots.forEach { $0.cancel() }
            try? await fixture.close(roots)
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [true, false])
    func actualPreactivationDeletionRevokesOnlyDeletedSession(current: Bool) async throws {
        let fixture = try await ManualSnapshotFixture()
        var roots: [Task<Void, Never>] = []
        var observation: AnyCancellable?
        var deleted = false
        do {
            let unrelated = try fixture.app.sessionRepository.createSession(mode: .mock,
                title: "Synthetic unrelated history")
            let selected = current ? fixture.session : unrelated
            fixture.app.manualCaptureTranscript = "Explain database transactions and atomicity."
            fixture.app.manualCaptureState = .transcriptReady
            observation = fixture.app.manualCaptureController.stateUpdates.dropFirst().sink { state in
                guard !deleted, state == .generatingSuggestion else { return }
                deleted = true
                #expect(!fixture.app.primaryHomeActionShouldStop,
                    "This preactivation entry has started no Live/capture resource; deletion is admitted.")
                fixture.app.deleteSession(selected)
            }
            fixture.app.sendManualCaptureToAI()
            if let worker = fixture.app.stageBTask { roots.append(worker) }
            observation?.cancel(); observation = nil
            #expect(deleted)
            #expect(try fixture.app.sessionRepository.session(id: selected.id) == nil)
            if current {
                #expect(fixture.app.currentSession == nil)
                #expect(fixture.app.activeGenerationController == nil)
                #expect(fixture.app.stageBTask == nil)
                #expect(!fixture.app.isActionLoading(ActionID.manualGenerate))
            } else {
                #expect(fixture.app.currentSession?.id == fixture.session.id)
                let owner = try #require(fixture.app.activeGenerationController)
                #expect(owner.identity.sessionID == fixture.session.id)
                let worker = try #require(fixture.app.stageBTask)
                #expect(!worker.isCancelled)
                #expect(fixture.app.isActionLoading(ActionID.manualGenerate))
            }
            roots.forEach { $0.cancel() }
            let requests = await fixture.original.requests()
            #expect(fixture.remote.requests().isEmpty && requests.isEmpty)
            try await fixture.close(roots)
            #expect(fixture.app.generationCoordinator.pendingCleanupTaskCount == 0)
        } catch {
            observation?.cancel(); roots.forEach { $0.cancel() }
            try? await fixture.close(roots)
            throw error
        }
    }

    /// The actual Cancel Recording button synchronously publishes idle from
    /// inside the generation-state notification. Its value must stay committed.
    @Test(.timeLimit(.minutes(1)))
    func actualCancelManualCaptureCannotBeOverwrittenByGeneratingSetter() async throws {
        let fixture = try await ManualSnapshotFixture()
        var roots: [Task<Void, Never>] = []
        var observation: AnyCancellable?
        var cancelled = false
        do {
            fixture.app.manualCaptureTranscript = "Explain database transactions and atomicity."
            fixture.app.manualCaptureState = .transcriptReady
            observation = fixture.app.manualCaptureController.stateUpdates.dropFirst().sink { state in
                guard !cancelled, state == .generatingSuggestion else { return }
                cancelled = true
                fixture.app.cancelManualCapture()
            }
            fixture.app.sendManualCaptureToAI()
            if let root = fixture.app.stageBTask { roots.append(root) }
            observation?.cancel(); observation = nil
            #expect(cancelled)
            #expect(fixture.app.manualCaptureState == .idle,
                "The old setter may not resurrect generatingSuggestion after actual Cancel Recording.")
            #expect(fixture.app.manualCaptureTranscript.isEmpty && fixture.app.manualCaptureSuggestion == nil)
            #expect(fixture.app.activeGenerationController == nil && fixture.app.stageBTask == nil)
            #expect(!fixture.app.isActionLoading(ActionID.manualGenerate))
            roots.forEach { $0.cancel() }
            let requests = await fixture.original.requests()
            #expect(fixture.remote.requests().isEmpty && requests.isEmpty)
            try await fixture.close(roots)
        } catch {
            observation?.cancel(); roots.forEach { $0.cancel() }
            try? await fixture.close(roots)
            throw error
        }
    }

    /// A later reviewed submission from Cancel's actual idle publication owns
    /// its transcript, loading state and task even in the same recorder epoch.
    @Test(.timeLimit(.minutes(1)))
    func actualCancelManualTailCannotRevokeNewReviewedSubmission() async throws {
        let fixture = try await ManualSnapshotFixture()
        var roots: [Task<Void, Never>] = []
        var observation: AnyCancellable?
        var submitted = false
        let replacementText = "Explain database transactions and atomicity."
        do {
            fixture.app.manualCaptureTranscript = "Compare retry policies."
            fixture.app.manualCaptureState = .transcriptReady
            observation = fixture.app.manualCaptureController.stateUpdates.dropFirst().sink { state in
                guard !submitted, state == .idle else { return }
                submitted = true
                fixture.app.manualCaptureTranscript = replacementText
                fixture.app.manualCaptureState = .transcriptReady
                fixture.app.sendManualCaptureToAI()
                if let worker = fixture.app.stageBTask { roots.append(worker) }
            }
            fixture.app.cancelManualCapture()
            observation?.cancel(); observation = nil
            #expect(submitted)
            let worker = try #require(roots.last)
            let accepted = try #require(fixture.app.activeGenerationController)
            #expect(accepted.identity.questionText == replacementText)
            #expect(fixture.app.stageBTask == worker && !worker.isCancelled)
            #expect(fixture.app.manualCaptureState == .generatingSuggestion)
            #expect(fixture.app.manualCaptureTranscript == replacementText)
            #expect(fixture.app.isActionLoading(ActionID.manualGenerate))
            #expect(fixture.app.generationUIState.isLoadingWithoutVisibleAnswer)
            roots.forEach { $0.cancel() }
            let requests = await fixture.original.requests()
            #expect(fixture.remote.requests().isEmpty && requests.isEmpty)
            try await fixture.close(roots)
        } catch {
            observation?.cancel(); roots.forEach { $0.cancel() }
            try? await fixture.close(roots)
            throw error
        }
    }

    enum Entry: String, CaseIterable {
        case localAnswerNow, remoteAnswerNow, regenerate, capture
    }
}
