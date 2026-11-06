import Foundation
import os
import Testing
@testable import Hireva

/// Actual transcript entries and application shutdown, with synthetic services.
/// The DEBUG count observes actual shutdown handles; no clock/device/model seam.
@MainActor
struct LiveRAGPrefetchEntryTests {
    @Test(.timeLimit(.minutes(1)), arguments: Invalidation.allCases)
    func applicationShutdownCapturesReplacedPrefetchWorkers(action: Invalidation) async throws {
        let retrieval = PrefetchEntryGate()
        let fixture = try await PrefetchEntryFixture(retrieval: retrieval)
        let snapshot = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
        var old: Task<Void, Never>?
        var newer: Task<Void, Never>?
        var stopping: Task<Bool, Never>?
        try await withTaskCancellationHandler {
            do {
                await fixture.app.handleTranscriptSegment(fixture.segment(id: "old-synthetic-segment",
                    text: "Can you explain how transaction atomicity handles partial failures?"))
                let requiredOldPrefetch: Task<Void, Never> = try #require(fixture.app.precomputeDebounceTask)
                old = requiredOldPrefetch
                #expect(try await retrieval.nextStart() == 1)
                switch action {
                case .replacement: break
                case .context: try fixture.app.rollContextSnapshotForCurrentSession()
                case .document: fixture.app.deleteDocument(fixture.document)
                }
                await fixture.app.handleTranscriptSegment(fixture.segment(id: "new-synthetic-segment",
                    text: "Can you explain why concurrent transactions require isolation?"))
                let requiredNewerPrefetch: Task<Void, Never> = try #require(fixture.app.precomputeDebounceTask)
                newer = requiredNewerPrefetch
                #expect(try await retrieval.nextStart() == 2)
                #expect(old?.isCancelled == true)
                #expect(newer?.isCancelled == false)
                #expect(retrieval.pendingGateCount == 2)
                fixture.app.ragPrefetchShutdownSnapshotForTesting = { count in
                    snapshot.continuation.yield(count); snapshot.continuation.finish()
                }
                let shutdown = Task { await fixture.app.shutdownResources() }
                stopping = shutdown
                let capturedCount = try await TestEventWaitTrace(label: "prefetch.shutdown.\(action.rawValue)")
                    .nextEvent(in: snapshot.stream, event: "captured_handles")
                // Old baseline only captured its last slot (one) and loses the
                // earlier cancelled-but-still-running retrieval capability.
                #expect(capturedCount == 2)
                #expect(retrieval.pendingGateCount == 2)
                retrieval.releaseAll()
                await old?.value; await newer?.value
                #expect(await shutdown.value)
                #expect(retrieval.pendingGateCount == 0)
                #expect(retrieval.exitedCount == 2)
                #expect(fixture.app.precomputedRAGCache.isEmpty)
                try await fixture.close()
            } catch {
                snapshot.continuation.finish()
                retrieval.releaseAll()
                old?.cancel(); newer?.cancel(); stopping?.cancel()
                await old?.value; await newer?.value; _ = await stopping?.value
                try? await fixture.close()
                throw error
            }
        } onCancel: { retrieval.releaseAll(); snapshot.continuation.finish() }
    }

    @Test(.timeLimit(.minutes(1)))
    func prefetchWireAndAcceptedQuestionCacheConsumptionRemainUnchanged() async throws {
        let retrieval = PrefetchEntryGate()
        let fixture = try await PrefetchEntryFixture(retrieval: retrieval)
        let text = "Can you explain how transaction atomicity handles partial failures?"
        let segmentID = "synthetic-prefetch-parity"
        var pending: Task<Void, Never>?
        try await withTaskCancellationHandler {
            do {
                await fixture.app.handleTranscriptSegment(fixture.segment(id: segmentID, text: text))
                let worker = try #require(fixture.app.precomputeDebounceTask)
                pending = worker
                #expect(try await retrieval.nextStart() == 1)
                retrieval.releaseAll()
                await worker.value
                #expect(retrieval.calls == [.init(question: text, intent: .unclear,
                    maxCVWords: 240, maxJDWords: 120, strategy: nil)])
                let intent = AnswerRelevancePolicy.intent(for: text)
                let key = fixture.app.ragPrecomputeCacheKey(segmentID: segmentID,
                    questionText: text, intent: intent)
                let cached = try #require(fixture.app.precomputedRAGCache[key])
                #expect(cached.rawText == text)
                #expect(cached.normalizedQuestionText == AnswerRelevancePolicy.normalizedQuestionText(for: text))
                #expect(cached.questionIntent == intent)
                #expect(cached.trace.query == text)
                #expect(cached.trace.cvWordBudget == 240)
                #expect(cached.trace.jdWordBudget == 120)
                let question = DetectedQuestion(id: UUID().uuidString, sessionID: fixture.session.id,
                    transcriptSegmentID: segmentID, questionText: text, intent: .technical,
                    answerStrategy: .directAnswer, confidence: 1, reason: "Synthetic prefetch wire",
                    shouldTrigger: true, questionComplete: true, modelName: "fixture",
                    promptVersion: "fixture", createdAt: Date())
                try await fixture.app.generateSuggestion(for: question, session: fixture.session,
                    transcript: text, autoGenerated: false)
                #expect(retrieval.calls.count == 1, "The actual accepted-question entry consumes its exact prefetch.")
                #expect(fixture.app.lastRetrievalTrace?.cvWordBudget == 240)
                #expect(fixture.app.precomputedRAGCache[key] == nil)
                #expect(fixture.app.currentSuggestion?.detectedQuestionID == question.id)
                #expect(fixture.app.currentSuggestion?.sayFirstSource == "ollama_qwen")
                try await fixture.close()
            } catch {
                retrieval.releaseAll(); pending?.cancel(); await pending?.value
                try? await fixture.close()
                throw error
            }
        } onCancel: { retrieval.releaseAll() }
    }

    @Test(.timeLimit(.minutes(1)))
    func transcriptIngressCannotCreatePrefetchAfterApplicationShutdown() async throws {
        let retrieval = PrefetchEntryGate()
        let fixture = try await PrefetchEntryFixture(retrieval: retrieval)
        var late: Task<Void, Never>?
        do {
            #expect(await fixture.app.shutdownResources())
            await fixture.app.handleTranscriptSegment(fixture.segment(id: "synthetic-late-prefetch",
                text: "Can you explain how transaction atomicity handles partial failures?"))
            late = fixture.app.precomputeDebounceTask
            #expect(late == nil, "Closed resource admission must block a late transcript's speculative task.")
            // Release and join even a regression-created task before closing SQL.
            late?.cancel(); retrieval.releaseAll(); await late?.value
            #expect(retrieval.calls.isEmpty)
            try await fixture.close()
        } catch {
            late?.cancel(); retrieval.releaseAll(); await late?.value
            try? await fixture.close()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: PrefetchStop.allCases)
    func stoppingLiveCaptureCancelsRetainsAndDrainsItsHeldPrefetch(action: PrefetchStop) async throws {
        let retrieval = PrefetchEntryGate()
        let fixture = try await PrefetchEntryFixture(retrieval: retrieval)
        var worker: Task<Void, Never>?
        try await withTaskCancellationHandler {
            do {
                await fixture.app.handleTranscriptSegment(fixture.segment(id: "synthetic-held-stop-prefetch",
                    text: "Can you explain how transaction atomicity handles partial failures?"))
                let pending = try #require(fixture.app.precomputeDebounceTask)
                worker = pending
                #expect(try await retrieval.nextStart() == 1)
                action.apply(to: fixture.app)
                #expect(pending.isCancelled, "Actual Live stop invalidates the speculative worker before requesting its cancellation.")
                #expect(fixture.app.precomputeDebounceTask == nil)
                #expect(fixture.app.liveRAGPrefetch.pendingTaskCount == 1,
                    "Noncooperative retrieval cleanup remains retained, not misreported as exited.")
                retrieval.releaseAll()
                await pending.value
                #expect(retrieval.exitedCount == 1 && retrieval.pendingGateCount == 0)
                #expect(fixture.app.liveRAGPrefetch.pendingTaskCount == 0)
                #expect(fixture.app.precomputedRAGCache.isEmpty,
                    "Late retrieval cannot repopulate a stopped Live cache.")
                try await fixture.close()
            } catch {
                retrieval.releaseAll(); worker?.cancel(); await worker?.value
                try? await fixture.close(); throw error
            }
        } onCancel: { retrieval.releaseAll() }
    }

    @Test(.timeLimit(.minutes(1)), arguments: PrefetchStop.allCases)
    func stoppingLiveCaptureClearsAlreadyCompletedSpeculativeCache(action: PrefetchStop) async throws {
        let retrieval = PrefetchEntryGate()
        let fixture = try await PrefetchEntryFixture(retrieval: retrieval)
        var worker: Task<Void, Never>?
        try await withTaskCancellationHandler {
            do {
                await fixture.app.handleTranscriptSegment(fixture.segment(id: "synthetic-cached-stop-prefetch",
                    text: "Can you explain how transaction atomicity handles partial failures?"))
                let pending = try #require(fixture.app.precomputeDebounceTask)
                worker = pending
                #expect(try await retrieval.nextStart() == 1)
                retrieval.releaseAll(); await pending.value
                #expect(fixture.app.precomputedRAGCache.count == 1)
                action.apply(to: fixture.app)
                #expect(fixture.app.precomputedRAGCache.isEmpty)
                #expect(fixture.app.liveRAGPrefetch.pendingTaskCount == 0)
                try await fixture.close()
            } catch {
                retrieval.releaseAll(); worker?.cancel(); await worker?.value
                try? await fixture.close(); throw error
            }
        } onCancel: { retrieval.releaseAll() }
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingOneGenerationDoesNotStopIndependentLivePrefetch() async throws {
        let retrieval = PrefetchEntryGate()
        let fixture = try await PrefetchEntryFixture(retrieval: retrieval)
        var worker: Task<Void, Never>?
        try await withTaskCancellationHandler {
            do {
                await fixture.app.handleTranscriptSegment(fixture.segment(id: "synthetic-generation-independent-prefetch",
                    text: "Can you explain how transaction atomicity handles partial failures?"))
                let pending = try #require(fixture.app.precomputeDebounceTask)
                worker = pending
                #expect(try await retrieval.nextStart() == 1)
                fixture.app.cancelActiveGenerationForStop()
                #expect(!pending.isCancelled)
                #expect(fixture.app.precomputeDebounceTask != nil)
                #expect(fixture.app.liveRAGPrefetch.pendingTaskCount == 1)
                retrieval.releaseAll(); await pending.value
                #expect(fixture.app.precomputedRAGCache.count == 1)
                try await fixture.close()
            } catch {
                retrieval.releaseAll(); worker?.cancel(); await worker?.value
                try? await fixture.close(); throw error
            }
        } onCancel: { retrieval.releaseAll() }
    }

    @Test(.timeLimit(.minutes(1)))
    func transcriptPrefetchFreezesActualHybridConfigurationBeforeDebounce() async throws {
        let gate = PrefetchEntryGate()
        let fixture = try await PrefetchEntryFixture(retrieval: gate)
        let configuration = PrefetchSubmissionConfiguration()
        configuration.settings.embeddingModelName = "synthetic-before-submission"
        fixture.app.contextRetrievalService = HybridContextRetrievalService(
            documentRepository: DocumentRepository(database: fixture.database), configurationProvider: {
                configuration.observations += 1
                return (configuration.settings, nil)
            })
        var pending: Task<Void, Never>?
        do {
            await fixture.app.handleTranscriptSegment(fixture.segment(id: "synthetic-configuration-freeze",
                text: "Can you explain how transaction atomicity handles partial failures?"))
            let worker = try #require(fixture.app.precomputeDebounceTask)
            pending = worker
            #expect(configuration.observations == 1,
                "The actual concrete configuration pair is captured synchronously, before any debounce await.")
            configuration.settings.embeddingModelName = "synthetic-after-submission"
            configuration.settings.hybridSemanticWeight = 0.17
            await worker.value
            let cached = try #require(fixture.app.precomputedRAGCache.values.first)
            #expect(configuration.observations == 1)
            #expect(cached.trace.embeddingModel == "synthetic-before-submission")
            #expect(cached.trace.hybridSemanticWeight == AppSettings.default.hybridSemanticWeight)
            #expect(cached.trace.retrievalMode == "keywordOnly")
            try await fixture.close()
        } catch {
            pending?.cancel(); gate.releaseAll(); await pending?.value
            try? await fixture.close(); throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func sessionSwitchBeforeDebounceCannotRebindOldTranscriptPrefetch() async throws {
        let gate = PrefetchEntryGate()
        let fixture = try await PrefetchEntryFixture(retrieval: gate)
        var pending: Task<Void, Never>?
        try await withTaskCancellationHandler {
            do {
                await fixture.app.handleTranscriptSegment(fixture.segment(id: "synthetic-session-freeze",
                    text: "Can you explain how transaction atomicity handles partial failures?"))
                let worker = try #require(fixture.app.precomputeDebounceTask)
                pending = worker
                let replacement = try fixture.app.createContextBoundSession(mode: .mock,
                    title: "Synthetic replacement before debounce")
                fixture.app.currentSession = replacement
                #expect(replacement.id != fixture.session.id)
                // A closed, releasable gate also lets an old regression finish:
                // joining cannot hang even if it wrongly attempts retrieval.
                gate.releaseAll()
                await worker.value
                #expect(gate.calls.isEmpty,
                    "A later session must not adopt a question received by the earlier session.")
                #expect(fixture.app.precomputedRAGCache.isEmpty)
                #expect(fixture.app.liveRAGPrefetch.pendingTaskCount == 0)
                try await fixture.close()
            } catch {
                gate.releaseAll(); pending?.cancel(); await pending?.value
                try? await fixture.close(); throw error
            }
        } onCancel: { gate.releaseAll() }
    }

    @Test(.timeLimit(.minutes(1)), arguments: PrefetchStop.allCases)
    func synchronousConfigurationCallbackCannotRegisterPrefetchAfterStop(action: PrefetchStop) async throws {
        let gate = PrefetchEntryGate()
        let fixture = try await PrefetchEntryFixture(retrieval: gate)
        let resolver = PrefetchReentrantFreezeService(gate: gate) { action.apply(to: fixture.app) }
        fixture.app.contextRetrievalService = resolver
        var pending: Task<Void, Never>?
        try await withTaskCancellationHandler {
            do {
                await fixture.app.handleTranscriptSegment(fixture.segment(id: "synthetic-freeze-stop",
                    text: "Can you explain how transaction atomicity handles partial failures?"))
                pending = fixture.app.precomputeDebounceTask
                #expect(resolver.observations == 1)
                #expect(pending == nil,
                    "Stop invalidates the same preparing identity before the resolver can return a stale request.")
                // Clean the exact regression-created worker as well.
                pending?.cancel(); gate.releaseAll(); await pending?.value
                #expect(gate.calls.isEmpty)
                #expect(fixture.app.liveRAGPrefetch.pendingTaskCount == 0)
                #expect(fixture.app.precomputedRAGCache.isEmpty)
                try await fixture.close()
            } catch {
                pending?.cancel(); gate.releaseAll(); await pending?.value
                try? await fixture.close(); throw error
            }
        } onCancel: { gate.releaseAll() }
    }

    // One cumulative owner must retain all65 results across MainActor scheduling.
    // This host safety bound is not the production retrieval deadline.
    @Test(.timeLimit(.minutes(2)))
    func completedSpeculativeCacheHasAnExplicitThirtyTwoEntryBound() async throws {
        let gate = PrefetchEntryGate()
        gate.releaseAll()
        let owner = LiveRAGPrefetch(delay: ImmediatePrefetchDelay())
        let scope = LiveRAGPrefetch.Scope(sessionID: "synthetic-bound-session",
            snapshotID: "synthetic-bound-context", cacheContextID: "synthetic-bound-context")
        let trace = TestEventWaitTrace(label: "Prefetch.same-owner.bound-65")
        var worker: Task<Void, Never>?
        try await withTaskCancellationHandler {
            do {
                for ordinal in 0..<65 {
                    try Task.checkCancellation()
                    trace.mark("ordinal.\(ordinal).schedule.before.pending.\(owner.pendingTaskCount)")
                    owner.schedule(resolve: {
                        .init(scope: scope, segmentID: "synthetic-unused-\(ordinal)",
                            question: "Explain transaction isolation under concurrent updates.", service: gate)
                    }, isScopeCurrent: { $0 == scope })
                    let pending = try #require(owner.currentTask)
                    worker = pending
                    trace.mark("ordinal.\(ordinal).worker.join.requested")
                    await pending.value
                    try Task.checkCancellation()
                    trace.mark("ordinal.\(ordinal).worker.join.returned.cache_count.\(owner.cachedItems.count).pending.\(owner.pendingTaskCount)")
                    #expect(owner.cachedItems.count <= 32,
                        "Thirty-two unused results is this engineering cache bound, not a model quality threshold.")
                }
                #expect(owner.cachedItems.count == 32)
                #expect(owner.pendingTaskCount == 0)
                trace.mark("all65.assertions.recorded.cache_count.\(owner.cachedItems.count)")
                await owner.shutdown()
                trace.mark("owner.shutdown.returned.pending.\(owner.pendingTaskCount)")
            } catch {
                trace.mark("cleanup.requested")
                gate.releaseAll(); worker?.cancel(); await worker?.value
                trace.mark("cleanup.worker.joined")
                await owner.shutdown()
                trace.mark("cleanup.owner.shutdown.returned.pending.\(owner.pendingTaskCount)")
                throw error
            }
        } onCancel: { trace.mark("parent.cancel.requested"); gate.releaseAll() }
    }

    @Test(.timeLimit(.minutes(1)))
    func staleAcceptedQuestionEvictsOnlyItsContextAndSegmentVariant() async throws {
        let gate = PrefetchEntryGate()
        gate.releaseAll()
        let owner = LiveRAGPrefetch(delay: ImmediatePrefetchDelay())
        let scope = LiveRAGPrefetch.Scope(sessionID: "synthetic_stale_session",
            snapshotID: "synthetic_context_with_underscores", cacheContextID: "synthetic_context_with_underscores")
        let unrelated = LiveRAGPrefetch.Scope(sessionID: "synthetic_other_session",
            snapshotID: "synthetic_other_context", cacheContextID: "synthetic_other_context")
        let segmentID = "synthetic_segment_with_underscores"
        let question = "Explain transaction rollback under partial failure."
        var worker: Task<Void, Never>?
        try await withTaskCancellationHandler {
            do {
                for requestScope in [scope, unrelated] {
                    owner.schedule(resolve: {
                        .init(scope: requestScope, segmentID: segmentID, question: question, service: gate)
                    }, isScopeCurrent: { $0 == requestScope })
                    let pending = try #require(owner.currentTask)
                    worker = pending; await pending.value
                }
                #expect(owner.cachedItems.count == 2)
                let accepted = "Explain transaction isolation under concurrent updates."
                let result = owner.consume(scope: scope, admission: owner.cacheAdmission, segmentID: segmentID,
                    questionText: accepted, intent: AnswerRelevancePolicy.intent(for: accepted))
                if case .miss(let removed) = result { #expect(removed == 1) }
                else { Issue.record("A different accepted question must be a cache miss.") }
                #expect(owner.cachedItems.count == 1)
                let unrelatedKey = LiveRAGPrefetch.cacheKey(contextID: unrelated.cacheContextID,
                    segmentID: segmentID, questionText: question, intent: AnswerRelevancePolicy.intent(for: question))
                #expect(owner.cachedItems[unrelatedKey]?.rawText == question)
                await owner.shutdown()
            } catch {
                gate.releaseAll(); worker?.cancel(); await worker?.value
                await owner.shutdown(); throw error
            }
        } onCancel: { gate.releaseAll() }
    }

    @Test(.timeLimit(.minutes(1)), arguments: RAGDependencyChange.allCases)
    func actualSettingsChangeInvalidatesCompletedSpeculativeContext(change: RAGDependencyChange) async throws {
        let gate = PrefetchEntryGate()
        let fixture = try await PrefetchEntryFixture(retrieval: gate)
        var worker: Task<Void, Never>?
        try await withTaskCancellationHandler {
            do {
                await fixture.app.handleTranscriptSegment(fixture.segment(id: "synthetic-settings-cached",
                    text: "Can you explain how transaction atomicity handles partial failures?"))
                let pending = try #require(fixture.app.precomputeDebounceTask)
                worker = pending
                #expect(try await gate.nextStart() == 1)
                gate.releaseAll(); await pending.value
                #expect(fixture.app.precomputedRAGCache.count == 1)
                var next = fixture.app.settings
                change.apply(to: &next)
                fixture.app.settings = next
                #expect(fixture.app.precomputedRAGCache.isEmpty,
                    "The actual SettingsState change reaches the one prefetch owner before a later request can consume old configuration.")
                #expect(fixture.app.liveRAGPrefetch.pendingTaskCount == 0)
                try await fixture.close()
            } catch {
                gate.releaseAll(); worker?.cancel(); await worker?.value
                try? await fixture.close(); throw error
            }
        } onCancel: { gate.releaseAll() }
    }

    @Test(.timeLimit(.minutes(1)))
    func unrelatedDisplaySettingPreservesAnOtherwiseValidSpeculativeContext() async throws {
        let gate = PrefetchEntryGate()
        let fixture = try await PrefetchEntryFixture(retrieval: gate)
        var worker: Task<Void, Never>?
        try await withTaskCancellationHandler {
            do {
                await fixture.app.handleTranscriptSegment(fixture.segment(id: "synthetic-display-cached",
                    text: "Can you explain how transaction atomicity handles partial failures?"))
                let pending = try #require(fixture.app.precomputeDebounceTask)
                worker = pending
                #expect(try await gate.nextStart() == 1)
                gate.releaseAll(); await pending.value
                #expect(fixture.app.precomputedRAGCache.count == 1)
                var next = fixture.app.settings
                next.floatingWindowOpacity = 0.61
                fixture.app.settings = next
                #expect(fixture.app.precomputedRAGCache.count == 1)
                try await fixture.close()
            } catch {
                gate.releaseAll(); worker?.cancel(); await worker?.value
                try? await fixture.close(); throw error
            }
        } onCancel: { gate.releaseAll() }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func onlyTheConfiguredEmbeddingAccountInvalidatesPrefetchWhenItsMockKeyChanges(relevant: Bool) async throws {
        let gate = PrefetchEntryGate()
        let fixture = try await PrefetchEntryFixture(retrieval: gate)
        var worker: Task<Void, Never>?
        try await withTaskCancellationHandler {
            do {
                var initial = fixture.app.settings
                initial.embeddingApiKeyAccount = "synthetic-prefetch-embedding-account"
                fixture.app.saveSettings(initial)
                await fixture.app.handleTranscriptSegment(fixture.segment(id: "synthetic-key-cached",
                    text: "Can you explain how transaction atomicity handles partial failures?"))
                let pending = try #require(fixture.app.precomputeDebounceTask)
                worker = pending
                #expect(try await gate.nextStart() == 1)
                gate.releaseAll(); await pending.value
                #expect(fixture.app.precomputedRAGCache.count == 1)
                let account = relevant ? initial.embeddingApiKeyAccount : "synthetic-unrelated-account"
                fixture.app.settingsState.saveEmbeddingAPIKey("synthetic-mock-key-no-network", account: account)
                #expect(fixture.app.precomputedRAGCache.isEmpty == relevant)
                try await fixture.close()
            } catch {
                gate.releaseAll(); worker?.cancel(); await worker?.value
                try? await fixture.close(); throw error
            }
        } onCancel: { gate.releaseAll() }
    }

    @Test(.timeLimit(.minutes(1)))
    func actualEmbeddingCompletionInvalidatesSpeculativeResultsReadFromThePreviousIndex() async throws {
        let gate = PrefetchEntryGate()
        let fixture = try await PrefetchEntryFixture(retrieval: gate)
        var worker: Task<Void, Never>?
        var rebuilding: Task<Void, Never>?
        try await withTaskCancellationHandler {
            do {
                var initial = fixture.app.settings
                initial.enableVectorRAG = true
                initial.embeddingProviderKind = .mock
                initial.embeddingModelName = "controlled-mock-model"
                initial.autoGenerateEmbeddingsOnDocumentSave = false
                fixture.app.saveSettings(initial)
                await fixture.app.handleTranscriptSegment(fixture.segment(id: "synthetic-index-cached",
                    text: "Can you explain how transaction atomicity handles partial failures?"))
                let pending = try #require(fixture.app.precomputeDebounceTask)
                worker = pending
                #expect(try await gate.nextStart() == 1)
                gate.releaseAll(); await pending.value
                #expect(fixture.app.precomputedRAGCache.count == 1)
                fixture.app.rebuildAllEmbeddings()
                let indexJob = try #require(fixture.app.activeEmbeddingRebuildTask)
                rebuilding = indexJob; await indexJob.value
                #expect((fixture.app.documentsState.embeddings.coverage?.chunksWithEmbeddings ?? 0) > 0)
                #expect(fixture.app.precomputedRAGCache.isEmpty,
                    "The actual index job's committed changed callback revokes cached rankings without changing the question or context snapshot.")
                try await fixture.close()
            } catch {
                gate.releaseAll(); worker?.cancel(); rebuilding?.cancel()
                await worker?.value; await rebuilding?.value
                try? await fixture.close(); throw error
            }
        } onCancel: { gate.releaseAll() }
    }

    @Test(.timeLimit(.minutes(1)))
    func cacheInvalidationDuringHeldRetrievalCannotBeUndoneByItsLateReturn() async throws {
        let gate = PrefetchEntryGate()
        let owner = LiveRAGPrefetch(delay: ImmediatePrefetchDelay())
        let scope = LiveRAGPrefetch.Scope(sessionID: "synthetic-clear-session",
            snapshotID: "synthetic-clear-context", cacheContextID: "synthetic-clear-context")
        var worker: Task<Void, Never>?
        try await withTaskCancellationHandler {
            do {
                owner.schedule(resolve: {
                    .init(scope: scope, segmentID: "synthetic-clear-held",
                        question: "Explain transaction isolation under concurrent updates.", service: gate)
                }, isScopeCurrent: { $0 == scope })
                let pending = try #require(owner.currentTask)
                worker = pending
                #expect(try await gate.nextStart() == 1)
                owner.clearCache()
                #expect(!pending.isCancelled,
                    "Invalidating cache admission does not pretend that a running resource has exited.")
                #expect(owner.pendingTaskCount == 1)
                gate.releaseAll(); await pending.value
                #expect(gate.exitedCount == 1)
                #expect(owner.pendingTaskCount == 0)
                #expect(owner.cachedItems.isEmpty,
                    "A result admitted under the revoked cache revision cannot repopulate it after an await.")
                await owner.shutdown()
            } catch {
                gate.releaseAll(); worker?.cancel(); await worker?.value
                await owner.shutdown(); throw error
            }
        } onCancel: { gate.releaseAll() }
    }

    @Test(.timeLimit(.minutes(1)))
    func anExplicitlyMissingFrozenRetrieverCannotBeRecoveredFromCompletedSpeculation() async throws {
        let gate = PrefetchEntryGate()
        let fixture = try await PrefetchEntryFixture(retrieval: gate)
        let text = "Can you explain how transaction atomicity handles partial failures?"
        let segmentID = "synthetic-missing-retrieval-cached"
        var worker: Task<Void, Never>?
        try await withTaskCancellationHandler {
            do {
                await fixture.app.handleTranscriptSegment(fixture.segment(id: segmentID, text: text))
                let pending = try #require(fixture.app.precomputeDebounceTask)
                worker = pending
                #expect(try await gate.nextStart() == 1)
                gate.releaseAll(); await pending.value
                #expect(fixture.app.precomputedRAGCache.count == 1)
                let question = DetectedQuestion(id: UUID().uuidString, sessionID: fixture.session.id,
                    transcriptSegmentID: segmentID, questionText: text, intent: .technical,
                    answerStrategy: .directAnswer, confidence: 1, reason: "Synthetic explicit missing retriever",
                    shouldTrigger: true, questionComplete: true, modelName: "fixture",
                    promptVersion: "fixture", createdAt: Date())
                var rejected = false
                do {
                    try await fixture.app.generateSuggestion(for: question, session: fixture.session,
                        transcript: text, autoGenerated: false, answerMode: .localQwenPrimary,
                        retrievalService: nil, prefetchAdmission: fixture.app.liveRAGPrefetch.cacheAdmission)
                } catch {
                    if let failure = error as? LLMProviderError, case .notConfigured = failure {
                        rejected = true
                    } else { throw error }
                }
                #expect(rejected,
                    "An explicitly frozen missing retrieval capability is a failure; old speculative output must not replace it.")
                #expect(fixture.app.currentSuggestion == nil)
                try await fixture.close()
            } catch {
                gate.releaseAll(); worker?.cancel(); await worker?.value
                try? await fixture.close(); throw error
            }
        } onCancel: { gate.releaseAll() }
    }

    enum RAGDependencyChange: String, CaseIterable {
        case vector, forceHybrid, provider, baseURL, model, account, dimension, semanticWeight, keywordWeight, timeout
        func apply(to settings: inout AppSettings) {
            switch self {
            case .vector: settings.enableVectorRAG.toggle()
            case .forceHybrid: settings.forceHybridRAG.toggle()
            case .provider: settings.embeddingProviderKind = .mock
            case .baseURL: settings.embeddingBaseURL = "http://127.0.0.1:1/synthetic-unused"
            case .model: settings.embeddingModelName = "synthetic-changed-model"
            case .account: settings.embeddingApiKeyAccount = "synthetic-changed-account"
            case .dimension: settings.embeddingDimension += 1
            case .semanticWeight: settings.hybridSemanticWeight = 0.19
            case .keywordWeight: settings.hybridKeywordWeight = 0.81
            case .timeout: settings.embeddingTimeoutSeconds += 1
            }
        }
    }

    enum PrefetchStop: String, CaseIterable {
        case userStop, clearLive, stopAllContinuous
        @MainActor
        func apply(to app: AppState) {
            switch self {
            case .userStop: app.stopListening(reason: .userRequested)
            case .clearLive: app.clearLiveSession()
            case .stopAllContinuous: app.stopAllContinuousPipelines(reason: .userRequested)
            }
        }
    }

    enum Invalidation: String, CaseIterable { case replacement, context, document }
}

@MainActor
private final class PrefetchEntryFixture {
    let database: AppDatabase
    let suiteName = "com.langcheng.Hireva.tests.rag-prefetch." + UUID().uuidString
    let defaults: UserDefaults
    let app: AppState
    let session: InterviewSession
    let document: DocumentRecord
    init(retrieval: any ContextRetrievalService) async throws {
        database = try await TestSupport.makeInMemoryDatabase()
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(AnswerProviderMode.localQwenPrimary.rawValue, forKey: HirevaPreferenceKeys.answerProviderMode)
        var settings = AppSettings.default
        settings.saveTranscriptsLocally = false
        settings.automaticQuestionDetectionEnabled = false
        settings.manualOnlyMode = true
        settings.audioCaptureMode = .systemAudioOnly
        settings.enableVectorRAG = false
        settings.embeddingProviderKind = .disabled
        try SettingsRepository(database: database).saveSettings(settings)
        document = try DocumentRepository(database: database).saveDocument(type: .additionalNotes,
            title: "Synthetic transaction note",
            content: "Atomicity groups database changes into one commit or rollback. Isolation defines which concurrent changes are visible to transactions.")
        app = AppState(database: database, questionRoutingProvider: HermeticQuestionRoutingProvider(),
            permissionService: HermeticPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            contextRetrievalService: retrieval, dialogueDefaults: defaults)
        app.localLLMProviderOverride = ManualSnapshotLocalProvider(id: "synthetic-prefetch-answer")
        session = try app.createContextBoundSession(mode: .mock, title: "Synthetic prefetch ownership")
        app.currentSession = session
    }
    func segment(id: String, text: String) -> TranscriptSegment {
        .init(id: id, sessionID: session.id, source: .systemAudio, speaker: .interviewer,
            text: text, asrFinalizationReason: "final")
    }
    func close() async throws {
        await app.shutdownForTesting()
        try database.close()
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private final class PrefetchEntryGate: ContextRetrievalService, Sendable {
    struct Call: Equatable, Sendable {
        let question: String
        let intent: QuestionIntent
        let maxCVWords: Int
        let maxJDWords: Int
        let strategy: AnswerStrategy?
    }
    private struct State: Sendable {
        var calls: [Call] = []
        var closed = false
        var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
        var exited = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let started = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(4))
    var calls: [Call] { state.withLock { $0.calls } }
    var pendingGateCount: Int { state.withLock { $0.waiters.count } }
    var exitedCount: Int { state.withLock { $0.exited } }
    func nextStart() async throws -> Int {
        try await TestEventWaitTrace(label: "prefetch.actual-entry")
            .nextEvent(in: started.stream, event: "retrieval_entered")
    }
    func releaseAll() {
        let waiters = state.withLock { state in
            state.closed = true
            let captured = Array(state.waiters.values)
            state.waiters.removeAll()
            return captured
        }
        waiters.forEach { $0.resume() }
        started.continuation.finish()
    }
    func retrieveContextWithTrace(question: String, intent: QuestionIntent,
        maxCVWords: Int, maxJDWords: Int, strategy: AnswerStrategy?) async throws
        -> (context: RetrievedContext, trace: RetrievalTrace) {
        let ordinal = state.withLock { state in
            state.calls.append(.init(question: question, intent: intent,
                maxCVWords: maxCVWords, maxJDWords: maxJDWords, strategy: strategy))
            return state.calls.count
        }
        await withCheckedContinuation { continuation in
            let resume = state.withLock { state in
                if state.closed { return true }
                state.waiters[ordinal] = continuation
                return false
            }
            started.continuation.yield(ordinal)
            if resume { continuation.resume() }
        }
        state.withLock { $0.exited += 1 }
        // Intentionally noncooperative, finite, and always released by its owner.
        return (RetrievedContext(cvChunks: [], jobDescriptionChunks: []),
            RetrievalTrace(id: UUID(), query: question, intent: intent.rawValue, createdAt: Date(),
                rankedCVChunks: [], rankedJDChunks: [], includedCVChunks: [], includedJDChunks: [],
                excludedCVChunks: [], excludedJDChunks: [], cvWordsUsed: 0, jdWordsUsed: 0,
                cvWordBudget: maxCVWords, jdWordBudget: maxJDWords, retrievalLatencyMS: 0,
                emptyQueryFallbackUsed: false, zeroScoreFallbackUsed: false))
    }
}

/// Apply only after the production owner exists. These controlled-clock cases
/// characterize cancellation/publication ownership, not model or audio quality.
@MainActor
struct LiveRAGPrefetchOwnerTests {
    @Test(.timeLimit(.minutes(1)), arguments: 0..<20)
    func twentyFixedInterleavingsRetainOnlyCurrentPublicationAndJoinAllWorkers(ordinal: Int) async throws {
        let gate = PrefetchEntryGate()
        let clock = ImmediatePrefetchDelay()
        let owner = LiveRAGPrefetch(delay: clock)
        let scope = LiveRAGPrefetch.Scope(sessionID: "synthetic-session", snapshotID: "synthetic-context",
            cacheContextID: "synthetic-context")
        var scopeCurrent = true
        var scopeChecks = 0
        var old: Task<Void, Never>?
        var newer: Task<Void, Never>?
        try await withTaskCancellationHandler {
            do {
                owner.schedule(resolve: {
                    .init(scope: scope, segmentID: "old-\(ordinal)",
                        question: "Explain transaction rollback under partial failure.", service: gate)
                }, isScopeCurrent: { _ in
                    scopeChecks += 1
                    if ordinal % 5 == 4 && scopeChecks > 1 { owner.cancelAndClear() }
                    return scopeCurrent
                })
                let requiredOldWorker: Task<Void, Never> = try #require(owner.currentTask)
                old = requiredOldWorker
                #expect(try await gate.nextStart() == 1)
                switch ordinal % 5 {
                case 1: owner.cancelAndClear()
                case 2: scopeCurrent = false
                case 3: owner.closeAdmission()
                default: break
                }
                if ordinal % 5 < 2 {
                    owner.schedule(resolve: {
                        .init(scope: scope, segmentID: "new-\(ordinal)",
                            question: "Explain transaction isolation under concurrent updates.", service: gate)
                    }, isScopeCurrent: { _ in true })
                    let requiredNewerWorker: Task<Void, Never> = try #require(owner.currentTask)
                    newer = requiredNewerWorker
                    #expect(try await gate.nextStart() == 2)
                    #expect(owner.pendingTaskCount == 2)
                    #expect(old?.isCancelled == true)
                    #expect(newer?.isCancelled == false)
                } else if ordinal % 5 == 3 {
                    owner.schedule(resolve: {
                        Issue.record("Closed admission must not even resolve a newer request.")
                        return nil
                    }, isScopeCurrent: { _ in true })
                    #expect(owner.currentTask == nil)
                    #expect(owner.pendingTaskCount == 1)
                }
                gate.releaseAll()
                await old?.value; await newer?.value
                #expect(gate.pendingGateCount == 0)
                if ordinal % 5 < 2 {
                    #expect(owner.cachedItems.count == 1)
                    #expect(owner.cachedItems.values.first?.rawText == "Explain transaction isolation under concurrent updates.")
                } else {
                    #expect(owner.cachedItems.isEmpty)
                }
                #expect(owner.pendingTaskCount == 0)
                #expect(clock.sleeps.allSatisfy { $0 == 400_000_000 })
                await owner.shutdown()
                #expect(owner.pendingTaskCount == 0)
            } catch {
                gate.releaseAll(); old?.cancel(); newer?.cancel()
                await old?.value; await newer?.value
                await owner.shutdown()
                throw error
            }
        } onCancel: { gate.releaseAll() }
    }
    @Test(.timeLimit(.minutes(1)), arguments: CacheScopeChange.allCases)
    func explicitScopeCannotAliasAnotherRequestThroughTheLegacyStringKey(change: CacheScopeChange) async throws {
        let gate = PrefetchEntryGate()
        gate.releaseAll()
        let owner = LiveRAGPrefetch(delay: ImmediatePrefetchDelay())
        let scope = LiveRAGPrefetch.Scope(sessionID: "synthetic-scope-session",
            snapshotID: "synthetic-scope-snapshot", cacheContextID: "synthetic_shared_context")
        let question = "Explain transaction isolation under concurrent updates."
        let segmentID = "synthetic_shared_segment"
        var worker: Task<Void, Never>?
        try await withTaskCancellationHandler {
            do {
                let admission = try #require(owner.cacheAdmission)
                owner.schedule(resolve: {
                    .init(scope: scope, segmentID: segmentID, question: question, service: gate)
                }, isScopeCurrent: { $0 == scope })
                let pending = try #require(owner.currentTask)
                worker = pending; await pending.value
                let otherScope: LiveRAGPrefetch.Scope
                switch change {
                case .session:
                    otherScope = .init(sessionID: "synthetic-replacement-session", snapshotID: scope.snapshotID,
                        cacheContextID: scope.cacheContextID)
                case .snapshot:
                    otherScope = .init(sessionID: scope.sessionID, snapshotID: "synthetic-replacement-snapshot",
                        cacheContextID: scope.cacheContextID)
                case .context:
                    otherScope = .init(sessionID: scope.sessionID, snapshotID: scope.snapshotID,
                        cacheContextID: "synthetic_other_context")
                }
                let rejected = owner.consume(scope: otherScope, admission: admission, segmentID: segmentID,
                    questionText: question, intent: AnswerRelevancePolicy.intent(for: question))
                if case .hit = rejected { Issue.record("Different scope must not consume the cached result.") }
                #expect(owner.cachedItems.count == 1,
                    "Rejecting unrelated scope also preserves the original request's valid cache entry.")
                let accepted = owner.consume(scope: scope, admission: admission, segmentID: segmentID,
                    questionText: question, intent: AnswerRelevancePolicy.intent(for: question))
                if case .hit(let item) = accepted {
                    #expect(item.scope == scope && item.segmentID == segmentID && item.admission == admission)
                    #expect(item.trace.query == question)
                } else { Issue.record("The unchanged scope and admission must preserve the exact hit.") }
                await owner.shutdown()
            } catch {
                gate.releaseAll(); worker?.cancel(); await worker?.value
                await owner.shutdown(); throw error
            }
        } onCancel: { gate.releaseAll() }
    }

    @Test(.timeLimit(.minutes(1)), arguments: 0..<20)
    func retiredAdmissionNeverConsumesOrDeletesAReplacementCache(repetition: Int) async throws {
        // Five explicit invalidation orders repeated four times. These are
        // controlled owner contracts, not twenty distinct model/hardware schedules.
        let gate = PrefetchEntryGate()
        gate.releaseAll()
        let owner = LiveRAGPrefetch(delay: ImmediatePrefetchDelay())
        let scope = LiveRAGPrefetch.Scope(sessionID: "synthetic-revision-session",
            snapshotID: "synthetic-revision-snapshot", cacheContextID: "synthetic-revision-context")
        let question = "Explain transaction isolation under concurrent updates."
        let segmentID = "synthetic-revision-segment"
        var worker: Task<Void, Never>?
        try await withTaskCancellationHandler {
            do {
                let old = try #require(owner.cacheAdmission)
                owner.schedule(resolve: {
                    .init(scope: scope, segmentID: segmentID, question: question, service: gate)
                }, isScopeCurrent: { $0 == scope })
                let first = try #require(owner.currentTask)
                worker = first; await first.value
                switch repetition % 5 {
                case 0: owner.clearCache()
                case 1: owner.cancelAndClear()
                case 2:
                    let before = AppSettings.default
                    var changed = before; changed.embeddingModelName = "synthetic-intermediate-model"
                    owner.configurationDidChange(previous: before, current: changed)
                    owner.configurationDidChange(previous: changed, current: before)
                case 3: owner.credentialWillChange(account: "synthetic-account", configuredAccount: "synthetic-account")
                default: owner.indexDidChange()
                }
                #expect(owner.cacheAdmission != old)
                owner.schedule(resolve: {
                    .init(scope: scope, segmentID: segmentID, question: question, service: gate)
                }, isScopeCurrent: { $0 == scope })
                let second = try #require(owner.currentTask)
                worker = second; await second.value
                let new = try #require(owner.cacheAdmission)
                let rejected = owner.consume(scope: scope, admission: old, segmentID: segmentID,
                    questionText: question, intent: AnswerRelevancePolicy.intent(for: question))
                if case .hit = rejected { Issue.record("An old submission cannot revive after a replacement cache is filled.") }
                #expect(owner.cachedItems.count == 1)
                let accepted = owner.consume(scope: scope, admission: new, segmentID: segmentID,
                    questionText: question, intent: AnswerRelevancePolicy.intent(for: question))
                if case .hit(let item) = accepted { #expect(item.admission == new) }
                else { Issue.record("The newly admitted request must retain its own exact cache hit.") }
                #expect(owner.cachedItems.isEmpty)
                #expect(owner.pendingTaskCount == 0)
                await owner.shutdown()
            } catch {
                gate.releaseAll(); worker?.cancel(); await worker?.value
                await owner.shutdown(); throw error
            }
        } onCancel: { gate.releaseAll() }
    }

    enum CacheScopeChange: String, CaseIterable { case session, snapshot, context }
}

private final class ImmediatePrefetchDelay: DelayProvider {
    private let values = OSAllocatedUnfairLock(initialState: [UInt64]())
    var sleeps: [UInt64] { values.withLock { $0 } }
    func sleep(nanoseconds: UInt64) async throws {
        try Task.checkCancellation()
        values.withLock { $0.append(nanoseconds) }
    }
}

@MainActor
private final class PrefetchSubmissionConfiguration {
    var settings = AppSettings.default
    var observations = 0
    init() { settings.enableVectorRAG = false; settings.embeddingProviderKind = .disabled }
}

@MainActor
private final class PrefetchReentrantFreezeService: ContextRetrievalService {
    nonisolated let gate: PrefetchEntryGate
    private let callback: @MainActor @Sendable () -> Void
    var observations = 0
    init(gate: PrefetchEntryGate, callback: @escaping @MainActor @Sendable () -> Void) {
        self.gate = gate; self.callback = callback
    }
    func freezeConfiguration() -> any ContextRetrievalService {
        observations += 1
        callback()
        return gate
    }
    nonisolated func retrieveContextWithTrace(question: String, intent: QuestionIntent,
        maxCVWords: Int, maxJDWords: Int, strategy: AnswerStrategy?) async throws
        -> (context: RetrievedContext, trace: RetrievalTrace) {
        try await gate.retrieveContextWithTrace(question: question, intent: intent,
            maxCVWords: maxCVWords, maxJDWords: maxJDWords, strategy: strategy)
    }
}
