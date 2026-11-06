import Foundation
import Testing
@testable import Hireva

/// New API characterization: apply after the ownership patch. The separate
/// LocalQwenStreamEntryOwnershipTests invokes unchanged pre-migration code.
@MainActor
struct GenerationLocalProviderOwnershipTests {
    @Test(.timeLimit(.minutes(1)))
    func localOwnerConsumesTheActualFrozenProviderStreamWithoutChangingProtocolInput() async throws {
        let provider = ControlledLocalAnswerProvider(id: "local-protocol-parity")
        let owner = GenerationCoordinator()
        let input = makeInput(provider: provider, generation: "local-protocol-parity")
        let pieces = ["ASCII ", "中文", "😀"]
        var reference: Task<String, Error>?
        var owned: Task<String, Error>?
        do {
            let direct = Task {
                let stream = try await provider.generateAnswer(request: input.request)
                var text = ""
                for try await token in stream { text += token.text }
                return text
            }
            reference = direct
            #expect(try await provider.nextStart() == 1)
            await provider.gate.release(1)
            #expect(try await provider.nextStream() == 1)
            pieces.forEach { provider.emit($0, ordinal: 1, model: input.request.modelName) }
            provider.finish(ordinal: 1)
            let directAnswer = try await direct.value
            activate(owner, context: input.context)
            var observed: [LLMToken] = []
            let pending = Task {
                try await owner.generateLocalAnswer(context: input.context, request: input.request, provider: provider) {
                    identity, token in
                    #expect(identity == input.context.identity)
                    observed.append(token)
                    return true
                }
            }
            owned = pending
            #expect(try await provider.nextStart() == 2)
            #expect(owner.stageATask != nil)
            #expect(owner.pendingCleanupTaskCount == 1)
            await provider.gate.release(2)
            #expect(try await provider.nextStream() == 2)
            pieces.forEach { provider.emit($0, ordinal: 2, model: input.request.modelName) }
            provider.finish(ordinal: 2)
            #expect(try await pending.value == directAnswer)
            #expect(observed.map(\.text) == pieces)
            #expect(observed.allSatisfy { $0.modelName == input.context.providerModel })
            let calls = await provider.gate.calls()
            #expect(calls == [input.request, input.request])
            #expect(owner.stageATask == nil)
            await owner.drainRetiredTasks()
            #expect(owner.pendingCleanupTaskCount == 0)
            await provider.releaseAll()
        } catch {
            reference?.cancel(); owned?.cancel()
            await provider.releaseAll()
            _ = await reference?.result; _ = await owned?.result
            _ = await owner.shutdownAndDrain()
            throw error
        }
    }

    @Test(.serialized, .timeLimit(.minutes(1)), arguments: 0..<20)
    func oldLocalAttemptCannotPublishOrClearTheNextStageARegistration(order: Int) async throws {
        // Five predetermined orderings, four executions each. This is a bounded
        // scheduling check, not twenty distinct topologies or a race proof.
        do {
            let provider = ControlledLocalAnswerProvider(id: "local-controlled-\(order)")
            let owner = GenerationCoordinator()
            let input = makeInput(provider: provider, generation: "local-old-\(order)", snapshotID: "old-context-\(order)")
            var old: Task<String, Error>?
            var replacement: Task<String, Error>?
            var outputs: [String] = []
            do {
                activate(owner, context: input.context)
                let first = Task {
                    try await owner.generateLocalAnswer(context: input.context, request: input.request, provider: provider) {
                        _, token in outputs.append("old:" + token.text); return true
                    }
                }
                old = first
                #expect(try await provider.nextStart() == 1)
                let oldChild = try #require(owner.stageATask)
                var next: (context: GenerationExecutionContext, request: LocalLLMRequest)?
                switch order % 5 {
                case 0: first.cancel()
                case 1: owner.markTerminal(generationID: input.context.generationID)
                case 2:
                    next = makeInput(provider: provider, generation: "local-new-\(order)")
                    activate(owner, context: try #require(next).context)
                case 3:
                    next = makeInput(provider: provider, generation: input.context.generationID,
                        snapshotID: "new-context-\(order)")
                    activate(owner, context: try #require(next).context)
                default:
                    next = input
                }
                if let next {
                    let second = Task {
                        try await owner.generateLocalAnswer(context: next.context, request: next.request, provider: provider) {
                            identity, token in
                            #expect(identity == next.context.identity)
                            outputs.append("new:" + token.text)
                            return true
                        }
                    }
                    replacement = second
                    #expect(try await provider.nextStart() == 2)
                    let currentChild = try #require(owner.stageATask)
                    #expect(!currentChild.isCancelled)
                    #expect(oldChild.isCancelled)
                    // The old provider ignores cancellation during startup.
                    // Release it first so its cleanup overlaps the new child.
                    await provider.gate.release(1)
                    #expect(try await provider.nextStream() == 1)
                    provider.emit("old must not publish", ordinal: 1)
                    provider.finish(ordinal: 1)
                    #expect(await rejected(first))
                    #expect(outputs.isEmpty)
                    #expect(owner.stageATask != nil)
                    #expect(!currentChild.isCancelled)
                    await provider.gate.release(2)
                    #expect(try await provider.nextStream() == 2)
                    provider.emit("new frozen output", ordinal: 2, model: next.request.modelName)
                    provider.finish(ordinal: 2)
                    #expect(try await second.value == "new frozen output")
                    #expect(outputs == ["new:new frozen output"])
                } else {
                    if order % 5 == 0 { #expect(oldChild.isCancelled) }
                    await provider.gate.release(1)
                    #expect(try await provider.nextStream() == 1)
                    provider.emit("old must not publish", ordinal: 1)
                    provider.finish(ordinal: 1)
                    #expect(await rejected(first))
                    #expect(outputs.isEmpty)
                }
                #expect(owner.stageATask == nil)
                await owner.drainRetiredTasks()
                #expect(owner.pendingCleanupTaskCount == 0)
                await provider.releaseAll()
                #expect(provider.openStreamCount() == 0)
                #expect(await provider.gate.pendingCount() == 0)
            } catch {
                old?.cancel(); replacement?.cancel()
                await provider.releaseAll()
                _ = await old?.result; _ = await replacement?.result
                _ = await owner.shutdownAndDrain()
                throw error
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func shutdownDeadlineKeepsAnUnreleasedLocalStartupOwnedUntilItsActualExit() async throws {
        let provider = ControlledLocalAnswerProvider(id: "local-held-shutdown")
        let owner = GenerationCoordinator()
        let input = makeInput(provider: provider, generation: "local-held-shutdown")
        let clock = ControlledGenerationWatchdogClock()
        var request: Task<String, Error>?
        var stop: Task<Bool, Never>?
        do {
            activate(owner, context: input.context)
            let pending = Task {
                try await owner.generateLocalAnswer(context: input.context, request: input.request, provider: provider) { _, _ in
                    Issue.record("A revoked startup must not deliver output"); return false
                }
            }
            request = pending
            #expect(try await provider.nextStart() == 1)
            let stopping = Task { await owner.shutdownAndDrain(timeout: 2, delayProvider: clock) }
            stop = stopping
            try await clock.waitUntilScheduled()
            clock.advance(by: 2_000_000_000)
            #expect(await stopping.value == false)
            #expect(owner.pendingCleanupTaskCount == 1)
            #expect(await provider.gate.pendingCount() == 1)
            await provider.releaseAll()
            #expect(await rejected(pending))
            await owner.drainRetiredTasks()
            #expect(owner.pendingCleanupTaskCount == 0)
            clock.cancelAll()
        } catch {
            request?.cancel(); stop?.cancel(); clock.cancelAll()
            await provider.releaseAll()
            _ = await request?.result; _ = await stop?.value
            _ = await owner.shutdownAndDrain()
            throw error
        }
    }

    private func makeInput(provider: ControlledLocalAnswerProvider, generation: String, snapshotID: String? = nil)
        -> (context: GenerationExecutionContext, request: LocalLLMRequest) {
        let date = Date(timeIntervalSince1970: 1)
        var session = InterviewSession(id: "synthetic-local-owned-session", title: "Synthetic local ownership",
            company: nil, role: nil, startedAt: date, endedAt: nil, mode: .mock, createdAt: date)
        session.contextSnapshotID = snapshotID
        let snapshot = snapshotID.map { InterviewContextSnapshot(id: $0, sessionID: session.id,
            candidateProfileID: nil, candidateProfileVersion: nil, opportunityContextID: nil,
            opportunityContextVersion: nil, domainProfileID: InterviewDomainID.general.rawValue,
            candidateEvidence: [], opportunityEvidence: [], createdAt: date) }
        let question = DetectedQuestion(id: "question-" + generation, sessionID: session.id, transcriptSegmentID: nil,
            questionText: "Explain database transactions and atomicity.", intent: .technical, answerStrategy: .directAnswer,
            confidence: 1, reason: "Synthetic local owned stream", shouldTrigger: true, questionComplete: true,
            modelName: "synthetic-frozen-model", promptVersion: "synthetic", createdAt: date)
        let prompt = PromptContextBuilder.promptSnapshot(question: question,
            context: .init(cvChunks: [], jobDescriptionChunks: []), transcriptContext: "",
            cvSummary: "", jdSummary: "", stage: .firstAnswer, interviewContextSnapshot: snapshot)
        let context = GenerationExecutionContext(session: session, question: question, generationID: generation,
            triggerPath: .manualGenerate, providerID: provider.id, providerModel: "synthetic-frozen-model",
            retrievedContext: prompt.ragContextSnapshot, promptSnapshot: prompt, transcriptSnapshot: "",
            startedAt: date, source: .mock, speaker: .unknown, interviewContextSnapshot: snapshot)
        let request = LocalLLMRequest(prompt: prompt.prompt, systemPrompt: "Synthetic frozen system instruction",
            modelName: context.providerModel, temperature: 0.1, numPredict: 180)
        return (context, request)
    }
    private func activate(_ owner: GenerationCoordinator, context: GenerationExecutionContext) {
        owner.activate(identity: context.identity, persistenceTicket: 0, triggerPath: context.triggerPath,
            startedAt: context.startedAt, answerProviderMode: .localQwenPrimary)
    }
    private func rejected(_ task: Task<String, Error>) async -> Bool {
        switch await task.result {
        case .success: return false
        case .failure(let error): return error is CancellationError
        }
    }
}
