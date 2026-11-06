import Foundation
import os
import Testing
@testable import Hireva

/// Calls the real Answer Fallback/regenerate entry and existing router. The synthetic provider
/// owns no network, audio device or background worker. Its startup gate ignores
/// cancellation until the test always releases it, making retirement observable.
@MainActor
struct LiveRoutingEntryOwnershipTests {
    // Allow full-suite MainActor queueing; product deadlines use the controlled clock.
    @Test(.timeLimit(.minutes(2)), arguments: ["same", "changedModel", "changedContext", "retiredRouterPolicy"])
    func autoFailureRegeneratePreservesSuccessfulFrozenRoute(change: String) async throws {
        let trace = TestEventWaitTrace(label: "auto-route-retry.\(change)")
        trace.mark("body.entered")
        let fixture = try await ManualSnapshotFixture(useAnswerProviderForRouting: true)
        trace.mark("fixture.ready")
        let provider = ControlledLocalAnswerProvider(id: "synthetic-auto-route-retry")
        fixture.app.localLLMProviderOverride = provider
        var roots: [Task<Void, Never>] = []
        let route = "{\"task\":\"generalKnowledge\",\"personalEvidence\":\"notRequired\",\"basis\":\"generalKnowledge\",\"relation\":\"independent\",\"clarification\":\"\"}"
        do {
            let text = "Explain database transactions and atomicity."
            let segment = TranscriptSegment(id: UUID().uuidString, sessionID: fixture.session.id,
                source: .systemAudio, speaker: .interviewer, text: text)
            fixture.app.processExtractedSystemAudioQuestions(SystemAudioQuestionExtractor.extract(from: text),
                segment: segment, session: fixture.session, suggestionTranscript: text)
            let original = try #require(fixture.app.activeAITask)
            roots.append(original)
            #expect(try await provider.nextStart() == 1)
            trace.mark("route.started")
            await provider.gate.release(1)
            #expect(try await provider.nextStream() == 1)
            provider.emit(route, ordinal: 1, model: fixture.originalModel)
            provider.finish(ordinal: 1)
            #expect(try await provider.nextStart() == 2)
            trace.mark("answer.started")
            let routed = try #require(fixture.app.activeGenerationController?.questionSnapshot)
            let decision = try #require(routed.taskDescriptor?.decision)
            #expect(decision.failure == nil)
            if change == "changedModel" { fixture.app.setSelectedQwenModelName("synthetic-changed-route-model") }
            if change == "changedContext" {
                var replacement = fixture.session
                replacement.contextSnapshotID = UUID().uuidString
                fixture.app.currentSession = replacement
            }
            let questionBeforeFailure = fixture.app.lastDetectedQuestion
            let feedbackBeforeFailure = fixture.app.latestActionFeedback(for: ActionID.generateAnswer)
            await provider.gate.release(2)
            #expect(try await provider.nextStream() == 2)
            provider.finish(ordinal: 2, error: URLError(.cannotConnectToHost))
            try await fixture.join(original)
            trace.mark("original.joined")
            if change == "changedContext" {
                #expect(fixture.app.lastDetectedQuestion == questionBeforeFailure)
                #expect(fixture.app.latestActionFeedback(for: ActionID.generateAnswer) == feedbackBeforeFailure)
                await provider.releaseAll()
                try await fixture.close(roots)
                return
            }
            #expect(fixture.app.latestActionFeedback(for: ActionID.generateAnswer)?.kind == .error)
            #expect(fixture.app.lastDetectedQuestion?.taskDescriptor?.decision == decision)
            #expect(fixture.app.activeGenerationController?.questionSnapshot?.taskDescriptor?.decision == decision)

            if change == "retiredRouterPolicy" {
                // A retired-policy decision is historical input; the real
                // Regenerate entry must route it under the current policy.
                var previousQuestion = try #require(fixture.app.lastDetectedQuestion)
                var previousTask = try #require(previousQuestion.taskDescriptor)
                var payload = try #require(try JSONSerialization.jsonObject(with:
                    JSONEncoder().encode(decision)) as? [String: Any])
                payload["routerVersion"] = InterviewQuestionRouter.version + "-retired"
                let previousDecision = try JSONDecoder().decode(InterviewQuestionDecision.self,
                    from: JSONSerialization.data(withJSONObject: payload))
                previousTask.apply(previousDecision)
                previousQuestion.taskDescriptor = previousTask
                fixture.app.lastDetectedQuestion = previousQuestion
            }

            try #require(fixture.app.liveState.canAnswerNow)
            fixture.app.answerCurrentQuestionOrTranscriptNow()
            trace.mark("retry.submitted")
            let retry = try #require(fixture.app.activeAITask)
            roots.append(retry)
            var ordinal = try await provider.nextStart()
            trace.mark("retry.started")
            #expect(ordinal == 3)
            var request = try #require(await provider.gate.calls().last)
            if request.responseSchema == InterviewQuestionRouter.Wire.schema {
                await provider.gate.release(ordinal)
                #expect(try await provider.nextStream() == ordinal)
                provider.emit(route, ordinal: ordinal, model: request.modelName)
                provider.finish(ordinal: ordinal)
                ordinal = try await provider.nextStart()
                trace.mark("retry.answer.started")
                #expect(ordinal == 4)
                request = try #require(await provider.gate.calls().last)
            }
            await provider.gate.release(ordinal)
            #expect(try await provider.nextStream() == ordinal)
            let answer = request.responseSchema == LocalQwenAnswerParser.scopedResponseSchema
                ? try TestSupport.scriptedLocalAnswer(LocalQwenStreamEntryOwnershipTests.answer, request: request)
                : LocalQwenStreamEntryOwnershipTests.answer
            provider.emit(answer, ordinal: ordinal, model: request.modelName)
            provider.finish(ordinal: ordinal)
            try await fixture.join(retry)
            trace.mark("retry.joined")
            let requests = await provider.gate.calls()
            #expect(requests.filter { $0.responseSchema == InterviewQuestionRouter.Wire.schema }.count == (change == "same" ? 1 : 2))
            #expect(fixture.app.currentSuggestion?.questionDecision?.routerVersion == InterviewQuestionRouter.version)
            #expect(fixture.app.currentSuggestion?.detectedQuestionID == routed.id)
            #expect(fixture.remote.requests().isEmpty)
            await provider.releaseAll()
            try await fixture.close(roots)
            trace.mark("fixture.closed")
            #expect(fixture.app.generationCoordinator.pendingCleanupTaskCount == 0)
        } catch {
            trace.mark("test.catch")
            await provider.releaseAll()
            try? await fixture.close(roots)
            trace.mark("catch.cleanup.completed")
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func publicAnswerFallbackOwnsRoutingWhileFrozenProviderStartupIsHeld() async throws {
        let fixture = try await ManualSnapshotFixture(useAnswerProviderForRouting: true)
        let routing = RoutingEntryHeldProvider(answerProvider: fixture.original)
        fixture.app.localLLMProviderOverride = routing
        var pending: Task<Void, Never>?
        do {
            let question = submittedQuestion(session: fixture.session)
            fixture.app.lastDetectedQuestion = question
            fixture.app.answerCurrentQuestionOrTranscriptNow()
            let request = try #require(fixture.app.activeAITask)
            pending = request
            let index = try await TestEventWaitTrace(label: "live-routing.submitted")
                .nextEvent(in: routing.entered.stream, event: "provider-startup-held")
            #expect(index == 1)
            let identity = try #require(fixture.app.generationCoordinator.activeGeneration?.identity)
            #expect(identity.acceptedQuestionID == question.id)
            #expect(identity.questionText == question.questionText)
            // This is an ownership regression, not an assertion that the old
            // App root failed all stale-result or shutdown safeguards.
            #expect(fixture.app.generationCoordinator.activeGeneration?.hasTasks == true)
            #expect(fixture.app.generationCoordinator.pendingCleanupTaskCount == 3,
                "The single owner retains the Answer Fallback root, routing child and local full-card deadline.")
            #expect(await fixture.original.requests().isEmpty)
            #expect(fixture.remote.requests().isEmpty)
            let submitted = try #require(routing.requests.first)
            #expect(submitted.modelName == fixture.originalModel)
            #expect(submitted.prompt.contains(question.questionText))
            // These configuration setters apply to the next request. There is
            // no second route/provider resolution after this suspension.
            fixture.app.setSelectedQwenModelName("synthetic-later-model")
            fixture.app.localLLMProviderOverride = fixture.replacement
            routing.release(index)
            try await fixture.join(request)
            #expect(routing.requests.count == 1)
            #expect(await fixture.replacement.requests().isEmpty)
            #expect(fixture.app.currentSuggestion?.detectedQuestionID == question.id)
            #expect(fixture.app.currentSuggestion?.modelName == fixture.originalModel)
            #expect(fixture.app.currentSuggestion?.sayFirstSource == "ollama_qwen")
            #expect(fixture.app.lastDetectedQuestion?.taskDescriptor?.decision?.model == fixture.originalModel)
            #expect(fixture.remote.requests().isEmpty)
            routing.releaseAll()
            try await fixture.close([request])
            #expect(fixture.app.generationCoordinator.pendingCleanupTaskCount == 0)
        } catch {
            routing.releaseAll()
            pending?.cancel()
            await pending?.value
            try? await fixture.close(pending.map { [$0] } ?? [])
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: 0..<20)
    func lateOldRoutingCleanupCannotClearNewRoutingChild(repetition: Int) async throws {
        // Twenty independent cases retain this same fixed release order.
        // This does not prove arbitrary interleaving safety.
        let fixture = try await ManualSnapshotFixture(useAnswerProviderForRouting: true)
        let routing = RoutingEntryHeldProvider(answerProvider: fixture.original)
        fixture.app.localLLMProviderOverride = routing
        var pending: [Task<Void, Never>] = []
        do {
            let firstQuestion = submittedQuestion(session: fixture.session)
            fixture.app.lastDetectedQuestion = firstQuestion
            fixture.app.answerCurrentQuestionOrTranscriptNow()
            let first = try #require(fixture.app.activeAITask)
            pending.append(first)
            let oldIndex = try await TestEventWaitTrace(label: "live-routing.old-\(repetition)")
                .nextEvent(in: routing.entered.stream, event: "old-provider-held")
            #expect(oldIndex == 1)
            let oldWatchdog = try #require(fixture.app.fullCardWatchdogTask)

            let secondQuestion = submittedQuestion(session: fixture.session,
                text: "Explain database isolation and concurrency.")
            // The real UI refuses a new answer while Q1 is busy. Use its
            // production cancellation policy before submitting the accepted Q2.
            #expect(fixture.app.cancelActiveGenerationForContextChange())
            fixture.app.lastDetectedQuestion = secondQuestion
            fixture.app.answerCurrentQuestionOrTranscriptNow()
            let second = try #require(fixture.app.activeAITask)
            pending.append(second)
            let newIndex = try await TestEventWaitTrace(label: "live-routing.new-\(repetition)")
                .nextEvent(in: routing.entered.stream, event: "new-provider-held")
            #expect(newIndex == 2)
            let newIdentity = try #require(fixture.app.generationCoordinator.activeGeneration?.identity)
            #expect(newIdentity.acceptedQuestionID == secondQuestion.id)
            #expect(first.isCancelled)
            #expect(routing.cancelled.contains(oldIndex))
            #expect(!routing.cancelled.contains(newIndex))
            #expect(oldWatchdog.isCancelled)
            #expect((5...6).contains(fixture.app.generationCoordinator.pendingCleanupTaskCount),
                "Both roots and both routing children plus the new deadline remain owned; the cancelled old timer may still be retiring.")
            #expect(!routing.exited.contains(oldIndex))
            #expect(await fixture.original.requests().isEmpty)

            // Finish the old startup first, while the new startup remains
            // held. This deterministically exercises old defer/retirement.
            routing.release(oldIndex)
            try await fixture.join(first)
            await fixture.app.generationCoordinator.drainRetiredTasks()
            #expect(routing.exited.contains(oldIndex))
            #expect(fixture.app.generationCoordinator.activeGeneration?.identity == newIdentity)
            #expect(fixture.app.generationCoordinator.activeGeneration?.hasTasks == true)
            #expect(fixture.app.generationCoordinator.pendingCleanupTaskCount == 3)
            #expect(!second.isCancelled)
            #expect(!routing.cancelled.contains(newIndex))
            #expect(fixture.app.currentSuggestion == nil)
            #expect(await fixture.original.requests().isEmpty)
            #expect(fixture.remote.requests().isEmpty)

            routing.release(newIndex)
            try await fixture.join(second)
            #expect(fixture.app.currentSuggestion?.detectedQuestionID == secondQuestion.id)
            #expect(fixture.app.currentSuggestion?.questionText == secondQuestion.questionText)
            #expect(fixture.app.currentSuggestion?.sayFirstSource == "ollama_qwen")
            #expect(fixture.remote.requests().isEmpty)
            #expect(try fixture.app.suggestionRepository.suggestions(sessionID: fixture.session.id).isEmpty,
                "The fixture's history consent remains disabled for both questions.")
            routing.releaseAll()
            try await fixture.close(pending)
            #expect(fixture.app.generationCoordinator.pendingCleanupTaskCount == 0)
        } catch {
            routing.releaseAll()
            pending.forEach { $0.cancel() }
            for task in pending { await task.value }
            try? await fixture.close(pending)
            throw error
        }
    }

    private func submittedQuestion(session: InterviewSession,
        text: String = "Explain database transactions and atomicity.") -> DetectedQuestion {
        .init(id: UUID().uuidString, sessionID: session.id, transcriptSegmentID: nil,
            questionText: text, intent: .technical, answerStrategy: .directAnswer,
            confidence: 1, reason: "Synthetic routing ownership", shouldTrigger: true,
            questionComplete: true, modelName: "fixture", promptVersion: "fixture", createdAt: Date())
    }
}

private final class RoutingEntryHeldProvider: LocalLLMProvider {
    let id = "synthetic-routing-entry-provider"
    var displayName: String { id }
    let entered = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(2))
    private struct State: Sendable {
        var requests: [LocalLLMRequest] = []
        var gates: [Int: CheckedContinuation<Void, Never>] = [:]
        var released = Set<Int>()
        var releaseEverything = false
        var cancelled = Set<Int>()
        var exited = Set<Int>()
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let answerProvider: ManualSnapshotLocalProvider
    init(answerProvider: ManualSnapshotLocalProvider) { self.answerProvider = answerProvider }
    var requests: [LocalLLMRequest] { state.withLock { $0.requests } }
    var cancelled: Set<Int> { state.withLock { $0.cancelled } }
    var exited: Set<Int> { state.withLock { $0.exited } }
    func healthCheck(modelName: String) async -> LocalLLMHealth {
        .init(ollamaRunning: true, selectedModel: modelName, modelInstalled: true,
            providerSource: .ollamaQwen, lastError: nil)
    }
    func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func release(_ index: Int) {
        let gate = state.withLock { state in
            state.released.insert(index)
            return state.gates.removeValue(forKey: index)
        }
        gate?.resume()
    }
    func releaseAll() {
        let gates = state.withLock { state in
            state.releaseEverything = true
            let gates = Array(state.gates.values)
            state.gates.removeAll()
            return gates
        }
        for gate in gates { gate.resume() }
        entered.continuation.finish()
    }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        guard request.responseSchema != nil else {
            return try await answerProvider.generateAnswer(request: request)
        }
        let index = state.withLock { state in
            state.requests.append(request)
            return state.requests.count
        }
        defer { _ = state.withLock { $0.exited.insert(index) } }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let releaseNow = state.withLock { state in
                    if state.releaseEverything || state.released.contains(index) { return true }
                    state.gates[index] = continuation
                    return false
                }
                if releaseNow { continuation.resume() }
                entered.continuation.yield(index)
            }
        } onCancel: {
            _ = self.state.withLock { $0.cancelled.insert(index) }
        }
        try Task.checkCancellation()
        return try await HermeticQuestionRoutingProvider().generateAnswer(request: request)
    }
}
