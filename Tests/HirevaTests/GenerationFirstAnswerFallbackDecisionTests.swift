import Foundation
import Testing
@testable import Hireva

// Owner characterizations added with the first-answer policy migration.
// These are post-integration checks, not a pre-integration baseline RED claim.
@MainActor
struct GenerationFirstAnswerFallbackDecisionTests {
    enum Scenario: CaseIterable, Equatable, Sendable {
        case initialEmpty, initialVisibleCard, initialBlankVisibleCard, initialVisibleTimestamp
        case localPrimary, projectionDeclined, staleIdentity, reentrantProjection
        case ragProfile, ragGeneral, ragVisibleCard, ragVisibleTimestamp
        var isRAG: Bool {
            switch self {
            case .ragProfile, .ragGeneral, .ragVisibleCard, .ragVisibleTimestamp: true
            default: false
            }
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: Scenario.allCases)
    func firstAnswerDeadlineUsesFrozenPolicyAndCompleteIdentity(scenario: Scenario) async throws {
        let owner = GenerationCoordinator()
        let clock = ControlledGenerationWatchdogClock()
        let started = Date()
        let text = scenario == .ragGeneral ? "Explain database transactions." : "Why do you want this role?"
        let question = DetectedQuestion(id: "synthetic-owner-fallback-question", sessionID: "synthetic-session",
            transcriptSegmentID: nil, questionText: text,
            intent: scenario == .ragGeneral ? .technical : .companyFit,
            answerStrategy: .directAnswer, confidence: 1, reason: "Synthetic owner policy characterization",
            shouldTrigger: true, questionComplete: true, modelName: "no-provider",
            promptVersion: "no-provider", createdAt: started)
        let session = InterviewSession(id: question.sessionID, title: "Synthetic deadline", company: nil,
            role: nil, startedAt: started, endedAt: nil, mode: .mock, createdAt: started)
        let context = GenerationExecutionContext.make(session: session, question: question,
            generationID: "synthetic-same-generation", triggerPath: .manualGenerate, provider: nil,
            retrievedContext: .init(cvChunks: [], jobDescriptionChunks: []), transcriptSnapshot: text,
            cvSummary: "Synthetic robotics role evidence.", jdSummary: "Synthetic robotics role.",
            startedAt: started, source: .mock, speaker: .interviewer, stage: .firstAnswer)
        let identity = context.identity
        let replacement = GenerationIdentity(acceptedQuestionID: identity.acceptedQuestionID,
            generationID: identity.generationID, sessionID: identity.sessionID,
            questionText: identity.questionText, normalizedQuestionText: identity.normalizedQuestionText,
            questionIntent: identity.questionIntent, promptPrimaryQuestion: identity.promptPrimaryQuestion,
            ingressIdentity: identity.ingressIdentity, contextSnapshotID: "synthetic-replacement-context")
        let admitted = scenario == .staleIdentity ? replacement : identity
        owner.activate(identity: admitted, persistenceTicket: 1, triggerPath: .manualGenerate,
            startedAt: started, answerProviderMode: scenario == .localPrimary ? .localQwenPrimary : .deepSeekPrimary)
        let observed = FirstAnswerDeadlineObservations()
        let visible = SuggestionCard(id: "synthetic-visible", sessionID: question.sessionID, questionID: question.id,
            strategy: "Synthetic", sayFirst: scenario == .initialBlankVisibleCard ? " \n " : "Synthetic existing card.",
            keyPoints: [], followUpReady: [], confidence: 1, caution: nil, evidenceUsed: [], riskLevel: .low,
            modelName: "no-provider", promptVersion: "no-provider", rawJSON: nil, createdAt: started)
        var tasks: [Task<Void, Never>] = []
        do {
            let presentation: @MainActor @Sendable (GenerationIdentity)
                -> (visibleCard: SuggestionCard?, firstVisibleTextAt: Date?)? = { submitted in
                observed.projections.append(submitted)
                if scenario == .projectionDeclined { return nil }
                if scenario == .reentrantProjection {
                    owner.activate(identity: replacement, persistenceTicket: 2,
                        triggerPath: .regenerate, startedAt: started, answerProviderMode: .deepSeekPrimary)
                }
                let card: SuggestionCard? = switch scenario {
                case .initialVisibleCard, .initialBlankVisibleCard, .ragVisibleCard: visible
                default: nil
                }
                let firstVisible: Date? = switch scenario {
                case .initialVisibleTimestamp, .ragVisibleTimestamp: Date(timeIntervalSince1970: 1)
                default: nil
                }
                return (card, firstVisible)
            }
            let onFallback: @MainActor @Sendable (GenerationIdentity, Int) -> Void = { submitted, elapsed in
                observed.values.append((submitted, elapsed))
            }
            let launched = scenario.isRAG
                ? owner.launchRAGFirstAnswerFallbackDeadline(context: context, delayProvider: clock,
                    presentation: presentation, onFallback: onFallback)
                : owner.launchInitialFirstAnswerFallbackDeadline(identity: identity, startedAt: started,
                    delayProvider: clock, presentation: presentation, onFallback: onFallback)
            if scenario == .localPrimary || scenario == .staleIdentity {
                #expect(launched == nil && clock.requestedNanoseconds.isEmpty)
                #expect(observed.projections.isEmpty && observed.values.isEmpty)
            } else {
                let task = try #require(launched)
                tasks.append(task)
                #expect(owner.fallbackWatchdogTask == task)
                try await withTaskCancellationHandler {
                    try await clock.waitUntilPending(nanoseconds: 1_500_000_000)
                    clock.advance(by: 1_500_000_000)
                    await task.value
                } onCancel: { task.cancel(); clock.cancelAll() }
                #expect(clock.requestedNanoseconds == [1_500_000_000])
                #expect(observed.projections == [identity])
                switch scenario {
                case .initialEmpty, .ragProfile, .ragVisibleCard:
                    #expect(observed.values.count == 1)
                    let event = try #require(observed.values.first)
                    #expect(event.0 == identity && event.1 >= 0)
                    // The UI/DB boundary still decides actual publication and terminal commit.
                    #expect(owner.canPublish(identity))
                case .reentrantProjection:
                    #expect(observed.values.isEmpty && task.isCancelled)
                    #expect(!owner.canPublish(identity) && owner.canPublish(replacement))
                default:
                    #expect(observed.values.isEmpty)
                    #expect(owner.canPublish(identity))
                }
            }
            await close(owner, clock: clock, tasks: tasks)
            #expect(owner.pendingCleanupTaskCount == 0 && clock.pendingCount == 0)
        } catch {
            await close(owner, clock: clock, tasks: tasks)
            throw error
        }
    }

    enum ImmediateScenario: CaseIterable, Equatable, Sendable {
        case eligible, notLoading, visibleAnswer, localPrimary, ownedRemoteOverridesLocalInput
        case legacyLocalInput, projectionDeclined, staleIdentity, terminalIdentity, closedAdmission
        case reentrantProjection, boundaryDeclined, reentrantApplication
    }

    @Test(.timeLimit(.minutes(1)), arguments: ImmediateScenario.allCases)
    func immediateFallbackUsesOwnerPolicyAndAdmittedBoundary(scenario: ImmediateScenario) async throws {
        let owner = GenerationCoordinator()
        let identity = GenerationIdentity(acceptedQuestionID: "synthetic-immediate-question",
            generationID: "synthetic-immediate-generation", sessionID: "synthetic-immediate-session",
            questionText: "Why this role?", normalizedQuestionText: "why this role?",
            questionIntent: .whyRole, promptPrimaryQuestion: "Why this role?", ingressIdentity: nil,
            contextSnapshotID: "synthetic-immediate-context")
        let replacement = GenerationIdentity(acceptedQuestionID: identity.acceptedQuestionID,
            generationID: identity.generationID, sessionID: identity.sessionID,
            questionText: identity.questionText, normalizedQuestionText: identity.normalizedQuestionText,
            questionIntent: identity.questionIntent, promptPrimaryQuestion: identity.promptPrimaryQuestion,
            ingressIdentity: identity.ingressIdentity, contextSnapshotID: "synthetic-other-context")
        let mode: AnswerProviderMode? = switch scenario {
        case .localPrimary: .localQwenPrimary
        case .legacyLocalInput: nil
        default: .deepSeekPrimary
        }
        owner.activate(identity: scenario == .staleIdentity ? replacement : identity,
            persistenceTicket: 1, triggerPath: .manualGenerate, startedAt: Date(), answerProviderMode: mode)
        if scenario == .terminalIdentity { owner.markTerminal(generationID: identity.generationID) }
        if scenario == .closedAdmission { owner.closeAdmission() }
        let observed = FirstAnswerDeadlineObservations()
        let applied = owner.applyImmediateFirstAnswerFallback(identity: identity,
            providerModeIfUnspecified: scenario == .legacyLocalInput || scenario == .ownedRemoteOverridesLocalInput
                ? .localQwenPrimary : .deepSeekPrimary,
            presentation: { submitted in
                observed.projections.append(submitted)
                if scenario == .projectionDeclined { return nil }
                if scenario == .reentrantProjection {
                    owner.activate(identity: replacement, persistenceTicket: 2,
                        triggerPath: .regenerate, startedAt: Date(), answerProviderMode: .deepSeekPrimary)
                }
                return (scenario != .notLoading, scenario == .visibleAnswer)
            },
            onFallback: { submitted, elapsed, retireWatchdog in
                observed.values.append((submitted, elapsed))
                if scenario == .reentrantApplication {
                    owner.activate(identity: replacement, persistenceTicket: 2,
                        triggerPath: .regenerate, startedAt: Date(), answerProviderMode: .deepSeekPrimary)
                }
                return scenario != .boundaryDeclined && retireWatchdog()
            })
        switch scenario {
        case .eligible, .ownedRemoteOverridesLocalInput:
            #expect(applied && observed.projections == [identity] && observed.values.count == 1)
            #expect(owner.canPublish(identity))
        case .boundaryDeclined, .reentrantApplication:
            #expect(!applied && observed.projections == [identity] && observed.values.count == 1)
        case .localPrimary, .legacyLocalInput, .staleIdentity, .terminalIdentity, .closedAdmission:
            #expect(!applied && observed.projections.isEmpty && observed.values.isEmpty)
        default:
            #expect(!applied && observed.projections == [identity] && observed.values.isEmpty)
        }
        if scenario == .reentrantProjection || scenario == .reentrantApplication {
            #expect(owner.canPublish(replacement) && !owner.canPublish(identity))
        }
        if let submitted = observed.values.first { #expect(submitted.0 == identity && submitted.1 >= 0) }
        owner.closeAdmission()
        await owner.drainRetiredTasks()
        #expect(owner.pendingCleanupTaskCount == 0)
    }

    enum StageAExitReceipt: CaseIterable, Equatable, Sendable {
        case admitted, declined, replacedIdentity, replacedRole, terminal, closed
    }

    /// Post-integration characterization of the actual owner exit method.
    @Test(.timeLimit(.minutes(1)), arguments: StageAExitReceipt.allCases)
    func stageAExitRetiresOnlyItsCapturedFallbackRole(scenario: StageAExitReceipt) async throws {
        let owner = GenerationCoordinator()
        let clock = ControlledGenerationWatchdogClock()
        let replacementClock = ControlledGenerationWatchdogClock()
        let identity = GenerationIdentity(acceptedQuestionID: "synthetic-exit-question",
            generationID: "synthetic-exit-generation", sessionID: "synthetic-exit-session",
            questionText: "Explain transactions", promptPrimaryQuestion: "Explain transactions",
            contextSnapshotID: "synthetic-exit-context")
        let replacement = GenerationIdentity(acceptedQuestionID: identity.acceptedQuestionID,
            generationID: identity.generationID, sessionID: identity.sessionID,
            questionText: identity.questionText, normalizedQuestionText: identity.normalizedQuestionText,
            questionIntent: identity.questionIntent, promptPrimaryQuestion: identity.promptPrimaryQuestion,
            ingressIdentity: identity.ingressIdentity, contextSnapshotID: "synthetic-other-exit-context")
        owner.activate(identity: identity, persistenceTicket: 1,
            triggerPath: .manualGenerate, startedAt: Date(), answerProviderMode: .deepSeekPrimary)
        var tasks: [Task<Void, Never>] = []
        var newer: Task<Void, Never>?
        let observed = FirstAnswerDeadlineObservations()
        do {
            let original = try #require(owner.launchDeadline(identity: identity, role: .fallbackWatchdog,
                nanoseconds: 1_500_000_000, delayProvider: clock) { _, _ in
                    Issue.record("The held deadline must not fire in an exit-receipt characterization.")
                })
            tasks.append(original)
            try await withTaskCancellationHandler {
                try await clock.waitUntilPending(nanoseconds: 1_500_000_000)
            } onCancel: { original.cancel(); clock.cancelAll(); replacementClock.cancelAll() }
            if scenario == .terminal { owner.markTerminal(generationID: identity.generationID) }
            if scenario == .closed { owner.closeAdmission() }
            let admitted = owner.applyStageAStreamExit(identity: identity) { submitted in
                observed.projections.append(submitted)
                if scenario == .replacedIdentity {
                    owner.activate(identity: replacement, persistenceTicket: 2,
                        triggerPath: .regenerate, startedAt: Date(), answerProviderMode: .deepSeekPrimary)
                }
                if scenario == .replacedRole {
                    newer = owner.launchDeadline(identity: identity, role: .fallbackWatchdog,
                        nanoseconds: 1_500_000_000, delayProvider: replacementClock) { _, _ in
                            Issue.record("The replacement deadline must remain held until cleanup.")
                        }
                }
                return scenario != .declined
            }
            if let newer { tasks.append(newer) }
            #expect(admitted == (scenario == .admitted))
            #expect(observed.projections == (scenario == .terminal || scenario == .closed ? [] : [identity]))
            switch scenario {
            case .admitted, .terminal:
                #expect(owner.fallbackWatchdogTask == nil && original.isCancelled)
            case .declined:
                #expect(owner.fallbackWatchdogTask == original && !original.isCancelled)
            case .replacedIdentity:
                #expect(owner.canPublish(replacement) && original.isCancelled)
            case .replacedRole:
                let retained = try #require(newer)
                #expect(owner.fallbackWatchdogTask == retained && !retained.isCancelled && original.isCancelled)
            case .closed:
                #expect(owner.activeGeneration == nil && original.isCancelled)
            }
            replacementClock.cancelAll()
            await close(owner, clock: clock, tasks: tasks)
            #expect(owner.pendingCleanupTaskCount == 0 && clock.pendingCount == 0 && replacementClock.pendingCount == 0)
        } catch {
            replacementClock.cancelAll()
            await close(owner, clock: clock, tasks: tasks)
            throw error
        }
    }


    enum ManualFirstDeadlineScenario: CaseIterable, Equatable, Sendable {
        case eligible, localPrimary, forcedConfiguredOnLocal, unspecifiedMode, existingManualCard
        case routeIncomplete, projectionDeclined, staleIdentity, terminalIdentity, closedAdmission
        case reentrantIdentity, reentrantTimer
    }

    /// Post-integration owner characterization. Route uses the actual existing
    /// router transport fixture; this does not grade routing/model quality.
    @Test(.timeLimit(.minutes(1)), arguments: ManualFirstDeadlineScenario.allCases)
    func manualFirstDeadlineUsesOwnedRouteModeAndAdmittedPresentation(
        scenario: ManualFirstDeadlineScenario
    ) async throws {
        let owner = GenerationCoordinator()
        let clock = ControlledGenerationWatchdogClock()
        let newerClock = ControlledGenerationWatchdogClock()
        let started = Date()
        let question = DetectedQuestion(id: "synthetic-manual-owner-question", sessionID: "synthetic-manual-owner-session",
            transcriptSegmentID: nil, questionText: "Why do you want this role?", intent: .companyFit,
            answerStrategy: .directAnswer, confidence: 1, reason: "Synthetic manual deadline ownership",
            shouldTrigger: true, questionComplete: true, modelName: "no-model", promptVersion: "no-model", createdAt: started)
        let identity = GenerationIdentity(question: question, generationID: "synthetic-manual-owner-generation",
            promptPrimaryQuestion: question.questionText, contextSnapshotID: "synthetic-manual-owner-context")
        let replacement = GenerationIdentity(acceptedQuestionID: identity.acceptedQuestionID,
            generationID: identity.generationID, sessionID: identity.sessionID,
            questionText: identity.questionText, normalizedQuestionText: identity.normalizedQuestionText,
            questionIntent: identity.questionIntent, promptPrimaryQuestion: identity.promptPrimaryQuestion,
            ingressIdentity: identity.ingressIdentity, contextSnapshotID: "synthetic-other-manual-context")
        let mode: AnswerProviderMode? = switch scenario {
        case .localPrimary, .forcedConfiguredOnLocal: .localQwenPrimary
        case .unspecifiedMode: nil
        default: .deepSeekPrimary
        }
        owner.activate(identity: identity, persistenceTicket: 1, triggerPath: .manualCapture,
            startedAt: started, answerProviderMode: mode, questionSnapshot: question)
        var tasks: [Task<Void, Never>] = []
        var newer: Task<Void, Never>?
        let observed = FirstAnswerDeadlineObservations()
        var routed: [DetectedQuestion] = []
        do {
            if scenario != .routeIncomplete {
                _ = try await owner.routeQuestion(identity: identity,
                    input: .init(question: question.questionText, questionID: question.id,
                        contextSnapshotID: identity.contextSnapshotID),
                    provider: HermeticQuestionRoutingProvider(), model: "hermetic-only")
                try #require(owner.activeGeneration?.questionSnapshot?.taskDescriptor?.decision != nil)
            }
            if scenario == .staleIdentity {
                owner.activate(identity: replacement, persistenceTicket: 2, triggerPath: .regenerate,
                    startedAt: started, answerProviderMode: .deepSeekPrimary)
            }
            if scenario == .terminalIdentity { owner.markTerminal(generationID: identity.generationID) }
            if scenario == .closedAdmission { owner.closeAdmission() }
            let launched = owner.launchManualFirstAnswerFallbackDeadline(identity: identity,
                forceDeepSeek: scenario == .forcedConfiguredOnLocal,
                startedAt: started, delayProvider: clock,
                hasManualCard: { submitted in
                    observed.projections.append(submitted)
                    if scenario == .projectionDeclined { return nil }
                    if scenario == .reentrantIdentity {
                        owner.activate(identity: replacement, persistenceTicket: 2, triggerPath: .regenerate,
                            startedAt: started, answerProviderMode: .deepSeekPrimary)
                    }
                    if scenario == .reentrantTimer {
                        newer = owner.launchDeadline(identity: identity, role: .fallbackWatchdog,
                            nanoseconds: 2_500_000_000, delayProvider: newerClock) { _, _ in
                                Issue.record("The replacement Manual timer must remain held until cleanup.")
                            }
                    }
                    return scenario == .existingManualCard
                },
                onFallback: { submitted, question, elapsed in
                    observed.values.append((submitted, elapsed)); routed.append(question)
                })
            let blocked = scenario == .staleIdentity || scenario == .terminalIdentity || scenario == .closedAdmission
            if blocked {
                #expect(launched == nil && observed.projections.isEmpty && clock.requestedNanoseconds.isEmpty)
            } else {
                let original = try #require(launched)
                tasks.append(original)
                #expect(owner.fallbackWatchdogTask == original)
                try await withTaskCancellationHandler {
                    try await clock.waitUntilPending(nanoseconds: 1_500_000_000)
                    clock.advance(by: 1_500_000_000)
                    await original.value
                } onCancel: { original.cancel(); clock.cancelAll(); newerClock.cancelAll() }
                if let newer { tasks.append(newer) }
                #expect(clock.requestedNanoseconds == [1_500_000_000] && observed.projections == [identity])
                if scenario == .reentrantTimer {
                    let retained = try #require(newer)
                    #expect(original.isCancelled && owner.fallbackWatchdogTask == retained && !retained.isCancelled)
                }
            }
            let expected = scenario == .eligible || scenario == .forcedConfiguredOnLocal || scenario == .unspecifiedMode
            #expect(observed.values.count == (expected ? 1 : 0) && routed.count == (expected ? 1 : 0))
            if expected {
                let value = try #require(observed.values.first)
                let completed = try #require(routed.first)
                #expect(value.0 == identity && value.1 >= 0 && completed.id == identity.acceptedQuestionID)
                #expect(completed == owner.activeGeneration?.questionSnapshot && completed.taskDescriptor?.decision != nil)
                #expect(owner.canPublish(identity))
            }
            if scenario == .reentrantIdentity { #expect(!owner.canPublish(identity) && owner.canPublish(replacement)) }
            newerClock.cancelAll()
            await close(owner, clock: clock, tasks: tasks)
            #expect(owner.pendingCleanupTaskCount == 0 && clock.pendingCount == 0 && newerClock.pendingCount == 0)
        } catch {
            newerClock.cancelAll()
            await close(owner, clock: clock, tasks: tasks)
            throw error
        }
    }

    private func close(_ owner: GenerationCoordinator, clock: ControlledGenerationWatchdogClock,
        tasks: [Task<Void, Never>]) async {
        owner.closeAdmission()
        clock.cancelAll()
        for task in tasks { await task.value }
        await owner.drainRetiredTasks()
    }
}

@MainActor
private final class FirstAnswerDeadlineObservations {
    var projections: [GenerationIdentity] = []
    var values: [(GenerationIdentity, Int)] = []
}
