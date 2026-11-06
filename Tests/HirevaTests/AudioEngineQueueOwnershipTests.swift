import AVFoundation
import Foundation
import Testing
import os
@testable import Hireva

@MainActor
struct AudioEngineQueueOwnershipTests {
    @Test(.timeLimit(.minutes(1)))
    func pcmDeliveryDoesNotWaitForAStartingEngineControlQueue() async throws {
        let io = QueueSyntheticEngine()
        let manager = AudioEngineManager(testingOperations: io.operations)
        let receiver = QueuePCMReceiver()
        let registration = QueueRegistrationThread(manager: manager, receiver: receiver)
        let guardOwner = QueueContractGuard()
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat:
            AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!, frameCapacity: 1))
        buffer.frameLength = 1
        buffer.floatChannelData![0][0] = 0
        let callback = QueuePCMThread(manager: manager, buffer: buffer, guardOwner: guardOwner)
        let trace = TestEventWaitTrace(label: #function)
        do {
            registration.start()
            _ = try await trace.nextEvent(in: io.startEntered.stream, event: "native_start_held")
            callback.start()
            let event = try await trace.nextEvent(in: guardOwner.events.stream, event: "pcm_or_fixture_guard")
            #expect(event == .completed,
                "PCM membership/time publication must not synchronously wait for engine.start on the control queue.")
            #expect(receiver.count == (event == .completed ? 1 : 0))
            await cleanupPCM(io, manager, receiver, registration, callback, guardOwner)
        } catch {
            await cleanupPCM(io, manager, receiver, registration, callback, guardOwner)
            throw error
        }
        #expect(receiver.count == 1)
        #expect(manager.lastAudioBufferAt != nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func debouncedRecoveryExecutesOnItsOwnInstanceAndClearsCompletedWork() async throws {
        let io = QueueSyntheticEngine(holdStart: false)
        let delay = QueueHeldRouteDelay()
        let targets = AsyncStream<ObjectIdentifier>.makeStream(bufferingPolicy: .bufferingOldest(4))
        let manager = AudioEngineManager(testingOperations: io.operations,
            routeDelayProvider: delay,
            routeRebuildOverride: { target, _ in targets.continuation.yield(target) })
        let trace = TestEventWaitTrace(label: #function)
        var captured: [Task<Void, Never>] = []
        do {
            manager.restartForRouteChange(reason: "Synthetic route change")
            captured = manager.ownedRouteRecoveryTasksForTesting
            let id = try await trace.nextEvent(in: delay.entries.stream, event: "route_delay_held")
            await delay.release(id)
            let actualTarget = try await trace.nextEvent(in: targets.stream, event: "actual_rebuild_target")
            #expect(actualTarget == ObjectIdentifier(manager),
                "A non-shared instance must never dispatch its recovery to the global shared engine.")
            for task in captured { await task.value }
            #expect(manager.ownedRouteRecoveryTasksForTesting.isEmpty,
                "The worker must retire its own completed handle without a cleanup Task.")
            await cleanupRoutes(delay, manager, captured)
        } catch {
            await cleanupRoutes(delay, manager, captured)
            targets.continuation.finish()
            throw error
        }
        targets.continuation.finish()
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationJoinsTheRetiredDelayBeforeReportingNoOwnedRecoveryWork() async throws {
        let io = QueueSyntheticEngine(holdStart: false)
        let delay = QueueHeldRouteDelay()
        let joinEntered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let guardOwner = QueueContractGuard()
        let manager = AudioEngineManager(testingOperations: io.operations,
            routeDelayProvider: delay, routeRebuildOverride: { _, _ in },
            onRouteJoinStarted: { joinEntered.continuation.yield(()) })
        let trace = TestEventWaitTrace(label: #function)
        var captured: [Task<Void, Never>] = []
        var stop: Task<Void, Never>?
        do {
            manager.restartForRouteChange(reason: "Old route")
            let old = manager.ownedRouteRecoveryTasksForTesting
            captured += old
            _ = try await trace.nextEvent(in: delay.entries.stream, event: "old_delay_held")
            manager.restartForRouteChange(reason: "Replacement route")
            let replacement = manager.ownedRouteRecoveryTasksForTesting.filter { !old.contains($0) }
            captured += replacement
            let replacementID = try await trace.nextEvent(in: delay.entries.stream, event: "replacement_delay_held")
            stop = Task { @MainActor in
                await manager.cancelAndJoinRouteRecovery()
                guardOwner.complete()
            }
            _ = try await trace.nextEvent(in: joinEntered.stream, event: "actual_join_entered")
            await delay.release(replacementID)
            for task in replacement { await task.value }
            guardOwner.arm()
            let first = try await trace.nextEvent(in: guardOwner.events.stream, event: "early_stop_or_guard")
            #expect(first == .guardExpired,
                "Awaited cancellation cannot return while the captured old non-cooperative delay is still owned.")
            await delay.releaseAll()
            if let stop { await stop.value }
            for task in captured { await task.value }
            #expect(manager.ownedRouteRecoveryTasksForTesting.isEmpty)
            await guardOwner.cancelAndJoin()
        } catch {
            await delay.releaseAll()
            if let stop { await stop.value }
            await cleanupRoutes(delay, manager, captured)
            await guardOwner.cancelAndJoin()
            joinEntered.continuation.finish()
            throw error
        }
        joinEntered.continuation.finish()
    }

    @Test(.timeLimit(.minutes(1)))
    func shutdownRejectsRecoveryFromALateRouteNotification() async {
        let io = QueueSyntheticEngine(holdStart: false)
        let delay = QueueHeldRouteDelay()
        let manager = AudioEngineManager(testingOperations: io.operations,
            routeDelayProvider: delay, routeRebuildOverride: { _, _ in })
        await manager.shutdownRouteRecovery()
        manager.restartForRouteChange(reason: "Late notification after shutdown")
        let captured = manager.ownedRouteRecoveryTasksForTesting
        #expect(!manager.hasOwnedRouteRecoveryWork,
            "Shutdown must close admission, rather than merely clearing the current Task slot.")
        await cleanupRoutes(delay, manager, captured)
    }

    private func cleanupPCM(_ io: QueueSyntheticEngine, _ manager: AudioEngineManager,
        _ receiver: QueuePCMReceiver, _ registration: QueueRegistrationThread,
        _ callback: QueuePCMThread, _ guardOwner: QueueContractGuard) async {
        // Retained and immediately joined: parent test cancellation cannot skip
        // release of a native-I/O fixture gate or strand either owned Thread.
        let cleanup = Task { @MainActor in
            io.releaseStart()
            await registration.join()
            await callback.join()
            manager.unregister(receiver)
            await guardOwner.cancelAndJoin()
        }
        await cleanup.value
    }

    private func cleanupRoutes(_ delay: QueueHeldRouteDelay, _ manager: AudioEngineManager,
        _ captured: [Task<Void, Never>]) async {
        let cleanup = Task { @MainActor in
            await delay.releaseAll()
            await manager.cancelAndJoinRouteRecovery()
            for task in captured { await task.value }
        }
        await cleanup.value
    }
}

private actor QueueHeldRouteDelay: DelayProvider {
    nonisolated let entries = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingOldest(8))
    private var nextID = 0
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var closed = false
    func sleep(nanoseconds: UInt64) async throws {
        // Deliberately ignores cancellation until this test releases it. Every
        // owning case releases ALL waiters before joining its captured Tasks.
        guard !closed else { return }
        nextID += 1
        let id = nextID
        await withCheckedContinuation { continuation in
            waiters[id] = continuation
            entries.continuation.yield(id)
        }
    }
    func release(_ id: Int) { waiters.removeValue(forKey: id)?.resume() }
    func releaseAll() {
        closed = true
        let owned = Array(waiters.values)
        waiters.removeAll()
        owned.forEach { $0.resume() }
        entries.continuation.finish()
    }
}

private enum QueueContractEvent: Sendable, Equatable { case completed, guardExpired }

/// Independent, owned fixture safety bound. It does not change the product's
/// 800ms debounce. Cancellation is acknowledged by the source's cancel handler.
private final class QueueContractGuard: Sendable {
    private struct State { var closed = false; var source: (any DispatchSourceTimer)? }
    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    let events = AsyncStream<QueueContractEvent>.makeStream(bufferingPolicy: .bufferingOldest(4))
    private let cancelled = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    func complete() { events.continuation.yield(.completed) }
    func arm() {
        state.withLockUnchecked { value in
            guard !value.closed, value.source == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "hireva.test.pcm-guard.\(UUID())"))
            let events = events.continuation, cancelled = cancelled.continuation
            source.setEventHandler { events.yield(.guardExpired) }
            source.setCancelHandler { cancelled.yield(()); cancelled.finish() }
            source.schedule(deadline: .now() + .seconds(2))
            value.source = source
            source.activate()
        }
    }
    func cancelAndJoin() async {
        let active = state.withLockUnchecked { value in
            value.closed = true
            guard let source = value.source else { return false }
            source.cancel()
            return true
        }
        if active { var iterator = cancelled.stream.makeAsyncIterator(); _ = await iterator.next() }
        else { cancelled.continuation.finish() }
        events.continuation.finish()
    }
}

private final class QueueSyntheticEngine: Sendable {
    private struct State: Sendable { var running = false; var tap = false }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let startGate = DispatchSemaphore(value: 0)
    private let holdStart: Bool
    let startEntered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    init(holdStart: Bool = true) { self.holdStart = holdStart }
    func releaseStart() { startGate.signal() }
    var operations: AudioEngineStartupTestingOperations {
        .init(installAndPrepareTap: { [self] in state.withLock { $0.tap = true } },
            start: { [self] in
                if holdStart { startEntered.continuation.yield(()); startGate.wait() }
                state.withLock { $0.running = true }
            }, stop: { [self] in state.withLock { $0.running = false } },
            removeTap: { [self] in state.withLock { $0.tap = false } }, reset: {},
            isRunning: { [self] in state.withLock { $0.running } })
    }
}

private final class QueuePCMReceiver: AudioEngineBufferDelegate, Sendable {
    private let received = OSAllocatedUnfairLock(initialState: 0)
    var count: Int { received.withLock { $0 } }
    func audioEngineManager(_ manager: AudioEngineManager, didReceive buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        _ = manager.lastAudioBufferAt
        received.withLock { $0 += 1 }
    }
}

/// Foundation's target/selector entry explicitly owns one synthetic worker.
/// Immutable AVA/manager references are borrowed only by run(), not captured
/// in a new Sendable closure or hidden behind an unchecked conformance.
private final class QueueRegistrationThread: NSObject {
    private let manager: AudioEngineManager
    private let receiver: QueuePCMReceiver
    @MainActor private var thread: Thread?
    private let completed = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    init(manager: AudioEngineManager, receiver: QueuePCMReceiver) { self.manager = manager; self.receiver = receiver }
    @MainActor func start() { thread = Thread(target: self, selector: #selector(run), object: nil); thread?.start() }
    @objc private func run() {
        _ = manager.register(receiver)
        completed.continuation.yield(())
        completed.continuation.finish()
    }
    @MainActor func join() async {
        guard let thread else { return }
        var iterator = completed.stream.makeAsyncIterator(); _ = await iterator.next()
        // This bounds only the OS worker's final return, after its work ended.
        for _ in 0..<1000 {
            if thread.isFinished { return }
            do { try await Task.sleep(nanoseconds: 1_000_000) }
            catch { Issue.record("Owned Thread join was unexpectedly cancelled."); return }
        }
        Issue.record("Owned synthetic registration Thread did not exit.")
    }
}

private final class QueuePCMThread: NSObject {
    private let manager: AudioEngineManager
    private let buffer: AVAudioPCMBuffer
    private let guardOwner: QueueContractGuard
    @MainActor private var thread: Thread?
    private let completed = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    init(manager: AudioEngineManager, buffer: AVAudioPCMBuffer, guardOwner: QueueContractGuard) {
        self.manager = manager; self.buffer = buffer; self.guardOwner = guardOwner
    }
    @MainActor func start() { thread = Thread(target: self, selector: #selector(run), object: nil); thread?.start() }
    @objc private func run() {
        guardOwner.arm()
        manager.broadcast(buffer: buffer, time: AVAudioTime(sampleTime: 0, atRate: 16000))
        guardOwner.complete()
        completed.continuation.yield(())
        completed.continuation.finish()
    }
    @MainActor func join() async {
        guard let thread else { return }
        var iterator = completed.stream.makeAsyncIterator(); _ = await iterator.next()
        for _ in 0..<1000 {
            if thread.isFinished { return }
            do { try await Task.sleep(nanoseconds: 1_000_000) }
            catch { Issue.record("Owned Thread join was unexpectedly cancelled."); return }
        }
        Issue.record("Owned synthetic PCM Thread did not exit.")
    }
}
