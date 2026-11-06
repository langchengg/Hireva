import Combine
import Foundation
import Testing
@testable import Hireva

/// Calls the current production entry; no copied retry/parser/validator logic.
/// Reuses the existing isolated DB/defaults/provider fixture. Its opaque fake
/// owns only controlled startup continuations and streams, not native I/O.
@MainActor
struct LocalQwenRetryEntryOwnershipTests {
    @Test(.timeLimit(.minutes(1)), arguments: 0..<20)
    func firstEmptyRetryKeepsOneOwnedSequenceAcrossTwentyCancellationOrders(order: Int) async throws {
        try await LocalRetryEntryFixture.run(controlledRetry: true) { fixture in
            let observed = AsyncStream<LocalRetryOwnerObservation>.makeStream(bufferingPolicy: .bufferingOldest(1))
            let app = fixture.entry.app
            // Capture the exact handle synchronously at the actual parser
            // diagnostic publication, before the test task can resume.
            let subscription = app.$ollamaDiagnostics.map(\.sectionParserResult)
                .removeDuplicates().filter { $0 == "empty_input" }
                .sink { _ in
                    observed.continuation.yield(.init(task: app.generationCoordinator.stageATask,
                        pendingCleanupCount: app.generationCoordinator.pendingCleanupTaskCount))
                }
            defer { subscription.cancel(); observed.continuation.finish() }
            let pending = fixture.start()
            #expect(try await fixture.entry.provider.nextStart() == 1)
            await fixture.entry.provider.gate.release(1)
            #expect(try await fixture.entry.provider.nextStream() == 1)
            fixture.entry.provider.finish(ordinal: 1)
            let observation = try await TestEventWaitTrace(label: "local-empty-retry-owner-\(order)")
                .nextEvent(in: observed.stream, event: "parsed-empty")
            let child = try #require(observation.task,
                "The first empty attempt cleared Stage A while its retry sequence was still active.")
            #expect(observation.pendingCleanupCount >= 1)
            try await GenerationCoordinator.withTimeout(seconds: 5) {
                try await fixture.clock.waitUntilPending(nanoseconds: 150_000_000)
            }
            #expect(fixture.clock.requestedNanoseconds == [150_000_000])
            #expect(await fixture.entry.provider.gate.calls().count == 1)
            let identity = try #require(app.generationCoordinator.activeGeneration?.identity)
            var replacementIdentity: GenerationIdentity?
            switch order % 4 {
            case 0:
                app.cancelActiveGenerationForContextChange()
            case 1:
                app.generationCoordinator.invalidateAndCancel()
            case 2:
                pending.cancel()
            default:
                app.activateGeneration(question: fixture.entry.question,
                    generationID: fixture.entry.generationID + "-replacement",
                    triggerPath: .manualGenerate, requestStart: Date(),
                    source: .mock, speaker: .unknown, answerProviderMode: .localQwenPrimary)
                replacementIdentity = app.generationCoordinator.activeGeneration?.identity
            }
            #expect(child.isCancelled)
            #expect(try await pending.value == false)
            _ = await child.result
            await app.generationCoordinator.drainRetiredTasks()
            #expect(fixture.clock.pendingCount == 0)
            #expect(await fixture.entry.provider.gate.calls().count == 1,
                "Cancellation of the registered retry delay must not begin a second provider request.")
            #expect(app.currentSuggestion == nil)
            // Direct parent cancellation does not itself replace the
            // generation identity. The cancelled exact task/slot fences
            // late output; only explicit invalidation or activation revokes
            // the identity. Preserve this existing runtime distinction.
            if order % 4 == 2 {
                #expect(app.generationCoordinator.isCurrent(identity))
                #expect(app.generationCoordinator.stageATask == nil)
            } else {
                #expect(!app.generationCoordinator.canPublish(identity))
            }
            if let replacementIdentity {
                #expect(app.generationCoordinator.canPublish(replacementIdentity))
            }
            #expect(app.generationCoordinator.pendingCleanupTaskCount == 0)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func synchronousParserObserverRevocationCancelsTheSameSequenceBeforeRetryScheduling() async throws {
        try await LocalRetryEntryFixture.run(controlledRetry: true) { fixture in
            let app = fixture.entry.app
            let observed = AsyncStream<LocalRetryOwnerObservation>.makeStream(bufferingPolicy: .bufferingOldest(1))
            let subscription = app.$ollamaDiagnostics.map(\.sectionParserResult)
                .removeDuplicates().filter { $0 == "empty_input" }
                .sink { _ in
                    let child = app.generationCoordinator.stageATask
                    observed.continuation.yield(.init(task: child,
                        pendingCleanupCount: app.generationCoordinator.pendingCleanupTaskCount))
                    // Actual synchronous observer reentrancy; neither the test
                    // task nor another provider response drives this revocation.
                    app.cancelActiveGenerationForContextChange()
                }
            defer { subscription.cancel(); observed.continuation.finish() }
            let pending = fixture.start()
            #expect(try await fixture.entry.provider.nextStart() == 1)
            await fixture.entry.provider.gate.release(1)
            #expect(try await fixture.entry.provider.nextStream() == 1)
            fixture.entry.provider.finish(ordinal: 1)
            let observation = try await TestEventWaitTrace(label: "local-retry-parser-reentry")
                .nextEvent(in: observed.stream, event: "parsed-empty")
            let child = try #require(observation.task,
                "A synchronous parser observer cannot cancel an already discarded sequence handle.")
            #expect(child.isCancelled)
            #expect(try await pending.value == false)
            _ = await child.result
            #expect(fixture.clock.requestedNanoseconds.isEmpty,
                "Recheck identity after the UI callback, before scheduling the first-empty retry delay.")
            #expect(await fixture.entry.provider.gate.calls().count == 1)
            #expect(app.currentSuggestion == nil)
            await app.generationCoordinator.drainRetiredTasks()
            #expect(app.generationCoordinator.pendingCleanupTaskCount == 0)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func actualFourAttemptRequestsRemainFrozenAndOrderedAfterFirstEmptyStream() async throws {
        try await LocalRetryEntryFixture.run { fixture in
            let pending = fixture.start()
            for ordinal in 1...4 {
                #expect(try await fixture.entry.provider.nextStart() == ordinal)
                if ordinal == 1 {
                    // Direct isolated preference writes preserve the submitted
                    // request, without simulating Settings' cancellation policy.
                    fixture.entry.defaults.set("synthetic-future-model", forKey: HirevaPreferenceKeys.selectedQwenModel)
                    fixture.entry.app.localLLMProviderOverride = fixture.replacement
                }
                await fixture.entry.provider.gate.release(ordinal)
                #expect(try await fixture.entry.provider.nextStream() == ordinal)
                if ordinal == 4 { fixture.entry.provider.emit(LocalQwenStreamEntryOwnershipTests.answer, ordinal: ordinal) }
                fixture.entry.provider.finish(ordinal: ordinal)
            }
            #expect(try await pending.value)
            let requests = await fixture.entry.provider.gate.calls()
            try #require(requests.count == 4)
            #expect(requests[0] == requests[1], "Both primary attempts must use the same frozen request.")
            #expect(requests[2].prompt != requests[0].prompt)
            #expect(requests[3].prompt != requests[2].prompt)
            #expect(requests[2].prompt.contains("Current interview question:"))
            #expect(requests[3].prompt.contains("Selected candidate, opportunity, and separately labeled task reference material:"))
            #expect(requests.map(\.modelName) == Array(repeating: fixture.entry.model, count: 4))
            #expect(requests.map(\.temperature) == [0.1, 0.1, 0.1, 0.0])
            #expect(requests.map(\.numPredict) == [180, 180, 180, 220])
            #expect(requests.allSatisfy { $0.prompt.contains(fixture.entry.question.questionText) && !$0.thinkingEnabled })
            #expect(await fixture.replacement.gate.calls().isEmpty)
            let card = try #require(fixture.entry.app.currentSuggestion)
            #expect(card.sayFirst == LocalQwenStreamEntryOwnershipTests.answer)
            #expect(card.questionID == fixture.entry.question.id)
            #expect(card.generationID == fixture.entry.generationID)
            #expect(card.modelName == fixture.entry.model)
            #expect(card.alignmentVerdict == .aligned)
            #expect(card.sayFirstSource == AnswerSource.ollamaQwen.rawValue)
            #expect(QuestionRuntimeAcceptanceGuard.validateSuggestionCardForPersistence(card).accepted)
            await fixture.entry.app.generationCoordinator.drainRetiredTasks()
            #expect(fixture.entry.app.generationCoordinator.pendingCleanupTaskCount == 0)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func nonemptyMisalignmentKeepsPrimaryRetryImmediateAndStillRunsAllRecoveryRequests() async throws {
        try await LocalRetryEntryFixture.run { fixture in
            fixture.entry.app.delayProvider = LocalRetryForbiddenDelay()
            let unrelated = "You should say a strong answer about database transactions and atomicity, then structure your answer using the STAR method and connect it to the prompt. Mention your experience instead of answering the question directly."
            #expect(LocalQwenAnswerParser.parse(unrelated).sayFirst == unrelated)
            let comparison = QuestionAnswerAlignmentEvaluator.evaluate(
                questionText: fixture.entry.question.questionText, answerText: unrelated,
                sayFirst: unrelated, stageBCompleted: true)
            try #require(comparison.verdict == .mismatched)
            #expect(QuestionAnswerAlignmentEvaluator.containsGenericCoachingTemplate(unrelated))
            let pending = fixture.start()
            for ordinal in 1...4 {
                #expect(try await fixture.entry.provider.nextStart() == ordinal)
                await fixture.entry.provider.gate.release(ordinal)
                #expect(try await fixture.entry.provider.nextStream() == ordinal)
                if ordinal == 1 { fixture.entry.provider.emit(unrelated, ordinal: ordinal) }
                if ordinal == 4 { fixture.entry.provider.emit(LocalQwenStreamEntryOwnershipTests.answer, ordinal: ordinal) }
                fixture.entry.provider.finish(ordinal: ordinal)
            }
            // A migration that inserts the 150ms empty delay for an actual
            // nonempty alignment rejection throws from the forbidden clock.
            #expect(try await pending.value)
            let requests = await fixture.entry.provider.gate.calls()
            try #require(requests.count == 4)
            #expect(requests[0] == requests[1])
            #expect(requests.map(\.numPredict) == [180, 180, 180, 220])
            #expect(fixture.entry.app.currentSuggestion?.sayFirst == LocalQwenStreamEntryOwnershipTests.answer)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func actualTransportFailureStopsWithoutStartingAnyRecoveryRequest() async throws {
        try await LocalRetryEntryFixture.run { fixture in
            fixture.entry.app.delayProvider = LocalRetryForbiddenDelay()
            let pending = fixture.start()
            #expect(try await fixture.entry.provider.nextStart() == 1)
            await fixture.entry.provider.gate.release(1)
            #expect(try await fixture.entry.provider.nextStream() == 1)
            fixture.entry.provider.finish(ordinal: 1, error: URLError(.cannotConnectToHost))
            switch await pending.result {
            case .success:
                Issue.record("A transport error was incorrectly reported as a completed local answer.")
            case .failure(let error):
                let local = try #require(error as? LocalQwenGenerationError)
                #expect(local.category == .providerHTTPError)
            }
            #expect(await fixture.entry.provider.gate.calls().count == 1)
            #expect(fixture.entry.app.currentSuggestion == nil)
            #expect(fixture.entry.app.ollamaDiagnostics.finalErrorCategory == .providerHTTPError)
            await fixture.entry.app.generationCoordinator.drainRetiredTasks()
            #expect(fixture.entry.app.generationCoordinator.pendingCleanupTaskCount == 0)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func exhaustedActualFourEmptyStreamsKeepTheLastParserFailureAndDoNotPublishAPlaceholder() async throws {
        try await LocalRetryEntryFixture.run { fixture in
            let pending = fixture.start()
            for ordinal in 1...4 {
                #expect(try await fixture.entry.provider.nextStart() == ordinal)
                await fixture.entry.provider.gate.release(ordinal)
                #expect(try await fixture.entry.provider.nextStream() == ordinal)
                fixture.entry.provider.finish(ordinal: ordinal)
            }
            switch await pending.result {
            case .success:
                Issue.record("Four empty streams incorrectly completed an answer.")
            case .failure(let error):
                let local = try #require(error as? LocalQwenGenerationError)
                #expect(local.category == .providerReturnedNoContent)
                #expect(local.diagnostic == "empty_input")
            }
            #expect(await fixture.entry.provider.gate.calls().count == 4)
            #expect(fixture.entry.app.currentSuggestion == nil)
            #expect(fixture.entry.app.ollamaDiagnostics.sectionParserResult == "empty_input")
            #expect(fixture.entry.app.ollamaDiagnostics.finalErrorCategory == .providerReturnedNoContent)
            await fixture.entry.app.generationCoordinator.drainRetiredTasks()
            #expect(fixture.entry.app.generationCoordinator.pendingCleanupTaskCount == 0)
        }
    }
}

private struct LocalRetryOwnerObservation: Sendable {
    let task: Task<String, Error>?
    let pendingCleanupCount: Int
}

private struct LocalRetryForbiddenDelay: DelayProvider {
    func sleep(nanoseconds: UInt64) async throws {
        throw NSError(domain: "SyntheticUnexpectedLocalRetryDelay", code: 1)
    }
}

@MainActor
private final class LocalRetryEntryFixture {
    let entry: LocalQwenOwnedEntryFixture
    let clock = ControlledGenerationWatchdogClock()
    let replacement = ControlledLocalAnswerProvider(id: "synthetic-future-provider")
    private var pending: Task<Bool, Error>?

    init(controlledRetry: Bool) async throws {
        entry = try await LocalQwenOwnedEntryFixture()
        if controlledRetry { entry.app.delayProvider = clock }
    }
    func start() -> Task<Bool, Error> {
        precondition(pending == nil)
        let entry = entry
        let task = Task { try await entry.finishLocal() }
        pending = task
        return task
    }
    private func close() async throws {
        pending?.cancel()
        // Always release the clock/startup/stream gates before awaiting tasks;
        // a broken owner path cannot strand the host with a held continuation.
        clock.cancelAll()
        await replacement.releaseAll()
        try await entry.close(pending.map { [$0] } ?? [])
    }
    static func run(controlledRetry: Bool = false,
        _ body: (LocalRetryEntryFixture) async throws -> Void) async throws {
        let fixture = try await LocalRetryEntryFixture(controlledRetry: controlledRetry)
        do {
            try await body(fixture)
            try await fixture.close()
        } catch {
            try? await fixture.close()
            throw error
        }
    }
}
