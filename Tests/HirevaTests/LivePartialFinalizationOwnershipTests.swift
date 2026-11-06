import Foundation
import os
import Testing
@testable import Hireva

@MainActor
struct LivePartialFinalizationOwnershipTests {
    @Test(.timeLimit(.minutes(1)), arguments: 0..<20)
    func oldSnapshotExitCannotForgetTheReplacement(repetition: Int) async throws {
        let fixture = try PartialFinalizationFixture()
        let app = fixture.app, gate = PartialFinalizationGate()
        var roots: [Task<Void, Never>] = []
        var snapshotIndex = 0
        app.partialFinalizationDelayForTesting = { _ in }
        app.partialFinalizationBeforeSnapshotForTesting = { _ in
            snapshotIndex += 1
            await gate.hold(snapshotIndex)
        }
        try await withTaskCancellationHandler {
            do {
                let first = fixture.segment(text: "Synthetic older partial statement for this test.")
                app.transcriptSegments = [first]
                app.scheduleStablePartialUtteranceCandidateIfNeeded(first)
                let firstIndex = try await TestEventWaitTrace(label: "partial.old-snapshot-\(repetition)")
                    .nextEvent(in: gate.entered.stream, event: "snapshot-held")
                #expect(firstIndex == 1)
                let oldRoot = try #require(app.partialUtteranceFinalizationTasks[first.id])
                roots.append(oldRoot)
                let second = fixture.segment(text: "Synthetic replacement partial statement for this test.")
                app.transcriptSegments = [second]
                app.scheduleStablePartialUtteranceCandidateIfNeeded(second)
                let secondIndex = try await TestEventWaitTrace(label: "partial.replacement-snapshot-\(repetition)")
                    .nextEvent(in: gate.entered.stream, event: "snapshot-held")
                #expect(secondIndex == 2)
                let newRoot = try #require(app.partialUtteranceFinalizationTasks[second.id])
                roots.append(newRoot)
                #expect(oldRoot.isCancelled)
                #expect(!newRoot.isCancelled)
                gate.release(firstIndex)
                await oldRoot.value
                #expect(app.partialUtteranceFinalizationTasks[second.id] == newRoot,
                    "A late old snapshot/defer cannot erase the replacement's exact registration.")
                #expect(app.transcriptSegments.first?.text == second.text)
                #expect(app.transcriptSegments.first?.asrFinalizationReason == "partial")
                gate.release(secondIndex)
                await newRoot.value
                #expect(app.transcriptSegments.first?.text == second.text)
                #expect(app.transcriptSegments.first?.asrFinalizationReason == "stable_partial")
                #expect(app.partialUtteranceFinalizationTasks.isEmpty)
                #expect(app.currentSuggestion == nil)
                gate.releaseAll()
                try await fixture.close(roots)
            } catch {
                gate.releaseAll()
                try? await fixture.close(roots)
                throw error
            }
        } onCancel: { gate.releaseAll() }
    }

    @Test(.timeLimit(.minutes(1)))
    func actualApplicationShutdownJoinsAReplacedPartialRoot() async throws {
        let fixture = try PartialFinalizationFixture()
        let app = fixture.app, gate = PartialFinalizationGate()
        var roots: [Task<Void, Never>] = []
        var delayIndex = 0
        var observedJoins: [Task<Void, Never>] = []
        app.partialFinalizationDelayForTesting = { _ in
            delayIndex += 1
            await gate.hold(delayIndex)
        }
        try await withTaskCancellationHandler {
            do {
                let first = fixture.segment(text: "Synthetic first partial is awaiting its delay.")
                app.transcriptSegments = [first]
                app.scheduleStablePartialUtteranceCandidateIfNeeded(first)
                _ = try await TestEventWaitTrace(label: "partial.shutdown.old")
                    .nextEvent(in: gate.entered.stream, event: "delay-held")
                let oldRoot = try #require(app.partialUtteranceFinalizationTasks[first.id])
                roots.append(oldRoot)
                let second = fixture.segment(text: "Synthetic replacement partial is awaiting its delay.")
                app.transcriptSegments = [second]
                app.scheduleStablePartialUtteranceCandidateIfNeeded(second)
                _ = try await TestEventWaitTrace(label: "partial.shutdown.new")
                    .nextEvent(in: gate.entered.stream, event: "delay-held")
                let newRoot = try #require(app.partialUtteranceFinalizationTasks[second.id])
                roots.append(newRoot)
                let observe: @MainActor (Task<Void, Never>) -> Void = { task in
                    observedJoins.append(task)
                    if task == oldRoot { gate.release(1) }
                    if task == newRoot { gate.release(2) }
                }
                // Both are observations of real original-handle joins. The
                // baseline App array and migrated Live registry share the test.
                app.ancillaryTaskWillAwaitForTesting = observe
                app.liveInterview.automaticDetectionTaskWillAwaitForTesting = observe
                let released = await app.shutdownResources()
                #expect(released)
                #expect(observedJoins.contains(oldRoot),
                    "Shutdown must retain and await an overwritten cancelled root through real exit.")
                #expect(observedJoins.contains(newRoot))
                #expect(gate.exited.contains(1))
                #expect(gate.exited.contains(2))
                #expect(app.partialUtteranceFinalizationTasks.isEmpty)
                #expect(app.transcriptSegments.first?.asrFinalizationReason == "partial")
                gate.releaseAll() // Always makes the unjoined baseline root finite.
                try await fixture.close(roots)
            } catch {
                gate.releaseAll()
                try? await fixture.close(roots)
                throw error
            }
        } onCancel: { gate.releaseAll() }
    }
}

@MainActor
private final class PartialFinalizationFixture {
    let database: AppDatabase
    let app: AppState
    let session: InterviewSession
    init() throws {
        database = try AppDatabase(inMemory: true)
        app = AppState(database: database, questionRoutingProvider: HermeticQuestionRoutingProvider(),
            permissionService: HermeticPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()), dialogueDefaults: nil)
        session = try app.sessionRepository.createSession(mode: .mock)
        app.currentSession = session
        var settings = app.settings
        settings.automaticQuestionDetectionEnabled = false
        settings.saveTranscriptsLocally = false
        app.saveSettings(settings)
    }
    func segment(text: String) -> TranscriptSegment {
        .init(id: "synthetic-stable-partial", sessionID: session.id, source: .systemAudio,
            speaker: .unknown, text: text, asrFinalizationReason: "partial")
    }
    func close(_ roots: [Task<Void, Never>]) async throws {
        app.partialFinalizationDelayForTesting = nil
        app.partialFinalizationBeforeSnapshotForTesting = nil
        app.ancillaryTaskWillAwaitForTesting = nil
        app.liveInterview.automaticDetectionTaskWillAwaitForTesting = nil
        roots.forEach { $0.cancel() }
        for task in roots { await task.value }
        await app.shutdownForTesting()
        try database.close()
    }
}

/// Finite, test-owned suspension. Cancellation is observable but does not
/// release the latch; every success, throw and parent cancellation releases it.
private final class PartialFinalizationGate: Sendable {
    let entered = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(4))
    private struct State: Sendable {
        var gates: [Int: CheckedContinuation<Void, Never>] = [:]
        var released = Set<Int>()
        var exited = Set<Int>()
        var releaseEverything = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var exited: Set<Int> { state.withLock { $0.exited } }
    func hold(_ index: Int) async {
        defer { _ = state.withLock { $0.exited.insert(index) } }
        await withCheckedContinuation { continuation in
            let releaseNow = state.withLock { state in
                if state.releaseEverything || state.released.contains(index) { return true }
                state.gates[index] = continuation
                return false
            }
            if releaseNow { continuation.resume() }
            entered.continuation.yield(index)
        }
    }
    func release(_ index: Int) {
        let continuation = state.withLock { state in
            state.released.insert(index)
            return state.gates.removeValue(forKey: index)
        }
        continuation?.resume()
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
}

extension LivePartialFinalizationOwnershipTests {
    @Test(.timeLimit(.minutes(1)), arguments: [-3, 900, 1_200, 1_500, 9_999])
    func realStabilityWindowKeepsItsExistingClampAcrossStopAndRestart(windowMS: Int) async throws {
        let fixture = try PartialFinalizationFixture()
        let app = fixture.app, gate = PartialFinalizationGate()
        var roots: [Task<Void, Never>] = []
        var delays: [UInt64] = []
        app.partialStabilityWindowMS = windowMS
        app.partialFinalizationDelayForTesting = { delay in
            delays.append(delay)
            await gate.hold(delays.count)
        }
        try await withTaskCancellationHandler {
            do {
                let segment = fixture.segment(text: "Synthetic stable partial remains delayed for the clamp test.")
                app.transcriptSegments = [segment]
                app.scheduleStablePartialUtteranceCandidateIfNeeded(segment)
                _ = try await TestEventWaitTrace(label: "partial.clamp.first-\(windowMS)")
                    .nextEvent(in: gate.entered.stream, event: "delay-held")
                roots.append(try #require(app.partialUtteranceFinalizationTasks[segment.id]))
                #expect(delays == [UInt64(max(900, min(windowMS, 1_500))) * 1_000_000])
                #expect(app.liveInterview.pendingPartialFinalizationTaskCount == 1)
                #expect(app.liveInterview.pendingAutomaticDetectionTaskCount == 0)
                app.markRuntimeAudioStopped()
                #expect(app.partialUtteranceFinalizationTasks.isEmpty)
                #expect(roots[0].isCancelled)
                #expect(app.liveInterview.pendingPartialFinalizationTaskCount == 1)
                // Audio stop revokes this round, but does not close application
                // admission. A later explicit transcript round can start.
                app.scheduleStablePartialUtteranceCandidateIfNeeded(segment)
                _ = try await TestEventWaitTrace(label: "partial.clamp.restart-\(windowMS)")
                    .nextEvent(in: gate.entered.stream, event: "delay-held")
                roots.append(try #require(app.partialUtteranceFinalizationTasks[segment.id]))
                #expect(delays.count == 2)
                #expect(app.liveInterview.pendingPartialFinalizationTaskCount == 2)
                #expect(app.liveInterview.pendingAutomaticDetectionTaskCount == 0)
                app.liveInterview.automaticDetectionTaskWillAwaitForTesting = { task in
                    if task == roots[0] { gate.release(1) }
                    if task == roots[1] { gate.release(2) }
                }
                #expect(await app.shutdownResources())
                #expect(app.liveInterview.pendingPartialFinalizationTaskCount == 0)
                #expect(gate.exited == [1, 2])
                #expect(app.transcriptSegments.first?.asrFinalizationReason == "partial")
                gate.releaseAll()
                try await fixture.close(roots)
            } catch {
                gate.releaseAll(); try? await fixture.close(roots); throw error
            }
        } onCancel: { gate.releaseAll() }
    }

    @Test(.timeLimit(.minutes(1)))
    func finalTranscriptCancelsOnlyItsPartialRoleAndKeepsTheDetectorOwned() async throws {
        let fixture = try PartialFinalizationFixture()
        let app = fixture.app, gate = PartialFinalizationGate()
        var roots: [Task<Void, Never>] = []
        app.partialFinalizationDelayForTesting = { _ in await gate.hold(1) }
        try await withTaskCancellationHandler {
            do {
                let segment = fixture.segment(text: "Synthetic partial has a later matching final transcript.")
                app.transcriptSegments = [segment]
                app.scheduleStablePartialUtteranceCandidateIfNeeded(segment)
                _ = try await TestEventWaitTrace(label: "partial.final.partial")
                    .nextEvent(in: gate.entered.stream, event: "delay-held")
                let partial = try #require(app.partialUtteranceFinalizationTasks[segment.id])
                roots.append(partial)
                let detector = try #require(app.liveInterview.submitAutomaticDetection { _ in await gate.hold(2) })
                roots.append(detector)
                _ = try await TestEventWaitTrace(label: "partial.final.detector")
                    .nextEvent(in: gate.entered.stream, event: "detector-held")
                var final = segment
                final.asrFinalizationReason = "final"
                final.recognitionIsFinal = true
                await app.handleTranscriptSegment(final)
                #expect(partial.isCancelled)
                #expect(!detector.isCancelled)
                #expect(app.partialUtteranceFinalizationTasks.isEmpty)
                #expect(app.liveInterview.activeDetectionTask == detector)
                #expect(app.liveInterview.pendingPartialFinalizationTaskCount == 1)
                #expect(app.liveInterview.pendingAutomaticDetectionTaskCount == 1)
                #expect(app.transcriptSegments.first?.asrFinalizationReason == "final")
                app.liveInterview.automaticDetectionTaskWillAwaitForTesting = { task in
                    if task == partial { gate.release(1) }
                    if task == detector { gate.release(2) }
                }
                #expect(await app.shutdownResources())
                #expect(app.liveInterview.pendingPartialFinalizationTaskCount == 0)
                #expect(app.liveInterview.pendingAutomaticDetectionTaskCount == 0)
                gate.releaseAll(); try await fixture.close(roots)
            } catch {
                gate.releaseAll(); try? await fixture.close(roots); throw error
            }
        } onCancel: { gate.releaseAll() }
    }

    @Test(.timeLimit(.minutes(1)))
    func sessionRoundTripPermanentlyRevokesTheSubmittedPartial() async throws {
        let fixture = try PartialFinalizationFixture()
        let app = fixture.app, gate = PartialFinalizationGate()
        var roots: [Task<Void, Never>] = []
        app.partialFinalizationDelayForTesting = { _ in await gate.hold(1) }
        try await withTaskCancellationHandler {
            do {
                let segment = fixture.segment(text: "Synthetic partial cannot revive after the session is replaced.")
                app.transcriptSegments = [segment]
                app.scheduleStablePartialUtteranceCandidateIfNeeded(segment)
                _ = try await TestEventWaitTrace(label: "partial.session-roundtrip")
                    .nextEvent(in: gate.entered.stream, event: "delay-held")
                let root = try #require(app.partialUtteranceFinalizationTasks[segment.id])
                roots.append(root)
                app.currentSession = nil
                app.currentSession = fixture.session
                #expect(root.isCancelled)
                #expect(app.partialUtteranceFinalizationTasks.isEmpty)
                #expect(app.liveInterview.pendingPartialFinalizationTaskCount == 1)
                gate.release(1)
                await root.value
                #expect(app.transcriptSegments.first?.asrFinalizationReason == "partial")
                #expect(app.currentSuggestion == nil)
                gate.releaseAll(); try await fixture.close(roots)
                #expect(app.liveInterview.pendingPartialFinalizationTaskCount == 0)
            } catch {
                gate.releaseAll(); try? await fixture.close(roots); throw error
            }
        } onCancel: { gate.releaseAll() }
    }

    @Test(.timeLimit(.minutes(1)))
    func closedApplicationCannotAdmitAnotherPartial() async throws {
        let fixture = try PartialFinalizationFixture()
        let app = fixture.app
        #expect(await app.shutdownResources())
        var delayStarted = false
        app.partialFinalizationDelayForTesting = { _ in delayStarted = true }
        let segment = fixture.segment(text: "Synthetic partial submitted after permanent application shutdown.")
        app.transcriptSegments = [segment]
        app.scheduleStablePartialUtteranceCandidateIfNeeded(segment)
        #expect(app.partialUtteranceFinalizationTasks.isEmpty)
        #expect(app.liveInterview.pendingPartialFinalizationTaskCount == 0)
        #expect(!delayStarted)
        try await fixture.close([])
    }
}

extension LivePartialFinalizationOwnershipTests {
    @Test(.timeLimit(.minutes(1)))
    func inheritedPartialShutdownRefusesSelfJoinAndExternalShutdownDrainsIt() async throws {
        let fixture = try PartialFinalizationFixture()
        let app = fixture.app, gate = PartialFinalizationGate()
        let returned = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        var roots: [Task<Void, Never>] = []
        var child: Task<Bool, Never>?
        app.partialFinalizationDelayForTesting = { _ in
            child = Task { @MainActor in
                let result = await app.shutdownResources()
                returned.continuation.yield(result)
                return result
            }
            // The original root does not await its inherited shutdown child.
            // Both have exact retained handles; the test can always release it.
            await gate.hold(1)
        }
        try await withTaskCancellationHandler {
            do {
                let segment = fixture.segment(text: "Synthetic partial root owns an inherited shutdown caller.")
                app.transcriptSegments = [segment]
                app.scheduleStablePartialUtteranceCandidateIfNeeded(segment)
                _ = try await TestEventWaitTrace(label: "partial.self-scope.entered")
                    .nextEvent(in: gate.entered.stream, event: "delay-held")
                let root = try #require(app.partialUtteranceFinalizationTasks[segment.id])
                roots.append(root)
                let ownReleased = try await TestEventWaitTrace(label: "partial.self-scope.returned")
                    .nextEvent(in: returned.stream, event: "shutdown-returned")
                #expect(!ownReleased)
                #expect(!app.isShuttingDown)
                #expect(!gate.exited.contains(1))
                #expect(app.liveInterview.pendingPartialFinalizationTaskCount == 1)
                app.liveInterview.automaticDetectionTaskWillAwaitForTesting = { task in
                    if task == root { gate.release(1) }
                }
                #expect(await app.shutdownResources())
                #expect(gate.exited.contains(1))
                #expect(app.liveInterview.pendingPartialFinalizationTaskCount == 0)
                gate.releaseAll(); returned.continuation.finish()
                if let child { _ = await child.value }
                try await fixture.close(roots)
            } catch {
                gate.releaseAll(); returned.continuation.finish()
                for root in roots { await root.value }
                if let child { _ = await child.value }
                try? await fixture.close(roots); throw error
            }
        } onCancel: {
            gate.releaseAll()
            returned.continuation.finish()
        }
    }
}
