import Foundation
import Testing
@testable import Hireva

// These characterize launchFullCardDeadline after the production pure move.
// The current baseline has no such API; this is not a baseline RED fixture.
@MainActor
struct GenerationFullCardDeadlineDecisionTests {
    @Test(.timeLimit(.minutes(1)), arguments: ["visible", "stream", "empty"])
    func localPrimaryDeadlineNeverPromotesAnUnfinishedAnswer(_ presentation: String) async throws {
        let coordinator = GenerationCoordinator()
        let clock = ControlledGenerationWatchdogClock()
        let identity = makeIdentity(context: "synthetic-local-deadline")
        coordinator.activate(identity: identity, persistenceTicket: 1,
            triggerPath: .autoDetect, startedAt: Date(), answerProviderMode: .localQwenPrimary)
        let values = FullCardDeadlinePublications()
        let period: UInt64 = 8_000_000_000
        let launched = coordinator.launchFullCardDeadline(identity: identity, startedAt: Date(),
            nanoseconds: period, delayProvider: clock, presentation: { _ in
                (presentation == "visible" ? makeCard(identity: identity, sayFirst: Self.answer) : nil,
                 presentation == "stream" ? "Uncommitted local answer text." : "")
            }, onTimeout: { plan, card, streamed, elapsed in values.values.append((plan, card, streamed, elapsed)) })
        let task = try #require(launched)
        do {
            try await clock.waitUntilPending(nanoseconds: period)
            clock.advance(by: period)
            await join(task, clocks: [clock])
            let plan = try #require(values.values.first?.0)
            #expect(values.values.count == 1)
            #expect(plan.action == .markProviderFailed)
            #expect(!plan.shouldPersist && !plan.shouldUpdateVisibleCard)
            #expect(coordinator.canPublish(identity), "Application owns the terminal publication boundary")
            await close(coordinator, clocks: [clock], tasks: [task])
            #expect(coordinator.pendingCleanupTaskCount == 0)
        } catch {
            await close(coordinator, clocks: [clock], tasks: [task])
            throw error
        }
    }

    enum Scenario: CaseIterable, Equatable, Sendable {
        case visibleCardPrecedence, streamOnly, emptyFallback
        case projectionDeclined, staleIdentity, reentrantProjection
    }

    @Test(.timeLimit(.minutes(1)), arguments: Scenario.allCases)
    func fullCardDeadlineChoosesOnceUnderItsCompleteIdentity(scenario: Scenario) async throws {
        let coordinator = GenerationCoordinator()
        let clock = ControlledGenerationWatchdogClock()
        let replacementClock = ControlledGenerationWatchdogClock()
        let captured = FullCardDeadlinePublications()
        let identity = makeIdentity(context: "synthetic-original-context")
        let replacement = makeIdentity(context: "synthetic-replacement-context")
        let period: UInt64 = 8_000_000_000
        let current = scenario == .staleIdentity ? replacement : identity
        coordinator.activate(identity: current, persistenceTicket: 1,
            triggerPath: .manualGenerate, startedAt: Date())
        let visible = makeCard(identity: identity,
            sayFirst: scenario == .streamOnly || scenario == .emptyFallback ? " \n " : Self.answer)
        let streamed = scenario == .emptyFallback ? " \n " : "  Synthetic streamed first answer.  "
        var tasks: [Task<Void, Never>] = []
        do {
            let launched = coordinator.launchFullCardDeadline(identity: identity, startedAt: Date(),
                nanoseconds: period, delayProvider: clock, presentation: { submitted in
                    captured.projections.append(submitted)
                    if scenario == .projectionDeclined { return nil }
                    if scenario == .reentrantProjection {
                        coordinator.activate(identity: replacement, persistenceTicket: 2,
                            triggerPath: .manualGenerate, startedAt: Date())
                        captured.replacementTask = coordinator.launchFullCardDeadline(
                            identity: replacement, startedAt: Date(), nanoseconds: period,
                            delayProvider: replacementClock, presentation: { submitted in
                                captured.replacementProjections.append(submitted)
                                return nil
                            }, onTimeout: { _, _, _, _ in
                                Issue.record("The replacement declined its projection")
                            })
                    }
                    return (visible, streamed)
                }, onTimeout: { plan, card, firstAnswer, elapsedMS in
                    captured.values.append((plan, card, firstAnswer, elapsedMS))
                })
            if scenario == .staleIdentity {
                #expect(launched == nil)
                #expect(clock.requestedNanoseconds.isEmpty)
                #expect(coordinator.fullCardWatchdogTask == nil)
                #expect(captured.projections.isEmpty)
                #expect(captured.values.isEmpty)
                #expect(coordinator.canPublish(replacement))
            } else {
                let task = try #require(launched)
                tasks.append(task)
                try await clock.waitUntilPending(nanoseconds: period)
                #expect(clock.requestedNanoseconds == [period])
                clock.advance(by: period)
                await join(task, clocks: [clock, replacementClock])
                #expect(captured.projections == [identity])
                switch scenario {
                case .visibleCardPrecedence, .streamOnly, .emptyFallback:
                    let publication = try #require(captured.values.first)
                    #expect(captured.values.count == 1)
                    #expect(publication.0.identity == identity)
                    #expect(publication.0.generationID == identity.generationID)
                    #expect(publication.0.detectedQuestionID == identity.acceptedQuestionID)
                    #expect(publication.0.fallbackReason == "full-card watchdog timeout")
                    #expect(publication.0.shouldPersist)
                    #expect(publication.0.shouldUpdateVisibleCard)
                    #expect(publication.0.safeDiagnostics["stageBClassification"] == StageBResultClassification.timedOut.rawValue)
                    #expect(publication.3 >= 0)
                    if scenario == .visibleCardPrecedence {
                        #expect(publication.0.action == .keepVisibleFirstAnswer)
                        #expect(publication.1 == visible)
                        #expect(publication.2 == "Synthetic streamed first answer.")
                    } else if scenario == .streamOnly {
                        #expect(publication.0.action == .keepVisibleFirstAnswer)
                        #expect(publication.1 == nil)
                        #expect(publication.2 == "Synthetic streamed first answer.")
                    } else {
                        #expect(publication.0.action == .useSemanticFallback)
                        #expect(publication.1 == nil)
                        #expect(publication.2.isEmpty)
                    }
                    // The owner does not mark terminal before the real UI/DB apply.
                    #expect(coordinator.canPublish(identity))
                    coordinator.clearTask(role: .fullCardWatchdog,
                        generationID: identity.generationID, cancel: false)
                    await coordinator.drainRetiredTasks()
                    #expect(coordinator.fullCardWatchdogTask == nil)
                case .projectionDeclined:
                    #expect(captured.values.isEmpty)
                    #expect(coordinator.canPublish(identity))
                case .reentrantProjection:
                    let replacementTask = try #require(captured.replacementTask)
                    try await replacementClock.waitUntilPending(nanoseconds: period)
                    #expect(task.isCancelled)
                    #expect(!replacementTask.isCancelled)
                    #expect(coordinator.isCurrent(identity.generationID))
                    #expect(!coordinator.canPublish(identity))
                    #expect(coordinator.canPublish(replacement))
                    #expect(coordinator.fullCardWatchdogTask != nil)
                    #expect(captured.values.isEmpty)
                    #expect(captured.replacementProjections.isEmpty)
                case .staleIdentity:
                    Issue.record("The stale identity must be refused before clock registration")
                }
            }
            await close(coordinator, clocks: [clock, replacementClock],
                tasks: tasks + (captured.replacementTask.map { [$0] } ?? []))
            #expect(coordinator.pendingCleanupTaskCount == 0)
        } catch {
            await close(coordinator, clocks: [clock, replacementClock],
                tasks: tasks + (captured.replacementTask.map { [$0] } ?? []))
            throw error
        }
    }

    private func makeIdentity(context: String) -> GenerationIdentity {
        .init(acceptedQuestionID: "synthetic-deadline-question", generationID: "synthetic-shared-generation",
            sessionID: "synthetic-deadline-session", questionText: "Explain database transactions.",
            promptPrimaryQuestion: "Explain database transactions.", contextSnapshotID: context)
    }

    private func makeCard(identity: GenerationIdentity, sayFirst: String) -> SuggestionCard {
        var card = SuggestionCard(id: "synthetic-visible-card", sessionID: identity.sessionID,
            questionID: identity.acceptedQuestionID, strategy: "Explanation", sayFirst: sayFirst,
            keyPoints: ["Synthetic visible-card precedence marker"], followUpReady: [], confidence: 0.9,
            caution: nil, evidenceUsed: [], riskLevel: .low, modelName: "synthetic-no-provider",
            promptVersion: "synthetic-no-provider", rawJSON: nil, createdAt: Date())
        card.generationID = identity.generationID
        card.questionText = identity.questionText
        card.promptPrimaryQuestion = identity.promptPrimaryQuestion
        card.contextSnapshotID = identity.contextSnapshotID
        return card
    }

    private func join(_ task: Task<Void, Never>, clocks: [ControlledGenerationWatchdogClock]) async {
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
            for clock in clocks { clock.cancelAll() }
        }
    }

    private func close(_ coordinator: GenerationCoordinator,
        clocks: [ControlledGenerationWatchdogClock], tasks: [Task<Void, Never>]) async {
        coordinator.closeAdmission()
        for clock in clocks { clock.cancelAll() }
        for task in tasks { await task.value }
        await coordinator.drainRetiredTasks()
    }

    private static let answer = "A transaction commits every operation together or rolls the operations back together."
}

@MainActor
private final class FullCardDeadlinePublications {
    var projections: [GenerationIdentity] = []
    var replacementProjections: [GenerationIdentity] = []
    var values: [(StageBApplicationPlan, SuggestionCard?, String, Int)] = []
    var replacementTask: Task<Void, Never>?
}
