import AVFoundation
import Combine
import Foundation
import Testing
import os
@testable import Hireva

/// Actual diagnostics start/stop and registered native delegate entry. All six
/// engine operations and device metadata are synthetic; no permission, shared
/// manager, input-node access, ASR or native microphone is used.
@MainActor
struct MicrophoneDiagnosticsAdmissionTests {
    @Test(arguments: DiagnosticsSyntheticEvent.allCases)
    func queuedOldCallbackCannotRestoreDisplayAfterActualStop(event: DiagnosticsSyntheticEvent) async throws {
        let buffer = try makeDiagnosticsBuffer()
        let io = DiagnosticsSyntheticEngine()
        let manager = AudioEngineManager(testingOperations: io.operations)
        let jobs = DiagnosticsObservedJobs()
        let labels = DiagnosticsSyntheticLabels()
        let service = MicrophoneDiagnosticsService(manager: manager,
            inputDeviceName: { labels.next() }, onCallbackScheduled: { jobs.record($0) })
        service.startMicTest()
        #expect(service.isRunning)
        let selectedWhenRunning = service.selectedInputDeviceName

        // No await allows the MainActor display worker to run before stop.
        // These are the same registered delegate functions used by broadcast
        // and real route-rebuild success/failure, not copied callback logic.
        switch event {
        case .pcm:
            manager.broadcast(buffer: buffer,
                time: AVAudioTime(sampleTime: 0, atRate: 16_000))
        case .routeSuccess:
            manager.rebuildInputTap()
        case .routeFailure:
            io.failNextStart()
            manager.rebuildInputTap()
        }
        service.stopMicTest()
        #expect(!service.isRunning)
        #expect(manager.registeredDelegateCountForTesting == 0)
        let queued = jobs.snapshot
        #expect(queued.count == 1, "Fixture must observe the actual queued callback worker.")

        // Join the exact callback tasks even when an expectation fails. This
        // optional observer is a fixture receipt, not a production owner.
        for task in queued { await task.value }
        #expect(!service.isRunning)
        #expect(service.rmsLevel == 0 && service.decibels == -90,
            "Old PCM must not repaint the stopped meter.")
        #expect(service.lastError == nil, "Old failure must not restore an error after stop.")
        #expect(service.selectedInputDeviceName == selectedWhenRunning,
            "Old route completion must not refresh metadata after stop.")
        #expect(!manager.isEngineRunning && !io.tapInstalled)
        service.stopMicTest()
    }

    @Test
    func onePendingNumericWorkerCoalescesAThousandPCMCallbacks() async throws {
        let buffer = try makeDiagnosticsBuffer()
        let io = DiagnosticsSyntheticEngine()
        let manager = AudioEngineManager(testingOperations: io.operations)
        let jobs = DiagnosticsObservedJobs()
        let service = MicrophoneDiagnosticsService(manager: manager,
            inputDeviceName: { "Synthetic Input" }, onCallbackScheduled: { jobs.record($0) })
        service.startMicTest()
        for frame in 0..<1_000 {
            manager.broadcast(buffer: buffer,
                time: AVAudioTime(sampleTime: AVAudioFramePosition(frame), atRate: 16_000))
        }
        let queued = jobs.snapshot
        #expect(queued.count <= 1,
            "Coalescible metering must bound work before MainActor execution; a throttle inside 1,000 already-created tasks is too late.")
        service.stopMicTest()
        for task in queued { await task.value }
        #expect(manager.registeredDelegateCountForTesting == 0)
        #expect(!manager.isEngineRunning && !io.tapInstalled)
        #expect(service.rmsLevel == 0 && service.decibels == -90)
        #expect(service.lastError == nil)
    }

    @Test
    func anActiveNativeFailureRemainsVisibleInsteadOfBeingDroppedWithLevels() async throws {
        let buffer = try makeDiagnosticsBuffer()
        let io = DiagnosticsSyntheticEngine()
        let manager = AudioEngineManager(testingOperations: io.operations)
        let jobs = DiagnosticsObservedJobs()
        let service = MicrophoneDiagnosticsService(manager: manager,
            inputDeviceName: { "Synthetic Input" }, onCallbackScheduled: { jobs.record($0) })
        service.startMicTest()
        manager.broadcast(buffer: buffer,
            time: AVAudioTime(sampleTime: 0, atRate: 16_000))
        io.failNextStart()
        manager.rebuildInputTap()
        let queued = jobs.snapshot
        for task in queued { await task.value }
        #expect(service.lastError == DiagnosticsSyntheticFailure.engineStart.localizedDescription)
        service.stopMicTest()
        #expect(service.lastError == nil)
        #expect(manager.registeredDelegateCountForTesting == 0)
        #expect(!manager.isEngineRunning && !io.tapInstalled)
    }

    @Test
    func liveMeteringAdmitsLevelsWithoutClaimingStandaloneTestIsRunning() async throws {
        let buffer = try makeDiagnosticsBuffer()
        let io = DiagnosticsSyntheticEngine()
        let manager = AudioEngineManager(testingOperations: io.operations)
        let jobs = DiagnosticsObservedJobs()
        let service = MicrophoneDiagnosticsService(manager: manager,
            inputDeviceName: { "Synthetic Input" }, onCallbackScheduled: { jobs.record($0) })
        try service.startMeteringForCapture()
        #expect(!service.isRunning, "Existing Live entry does not represent a standalone microphone test.")
        manager.broadcast(buffer: buffer, time: AVAudioTime(sampleTime: 0, atRate: 16_000))
        for task in jobs.snapshot { await task.value }
        #expect(service.rmsLevel > 0 && service.decibels > -90)
        service.stopMicTest()
        await service.finishStoppingMicTest()
        #expect(!service.hasOwnedCallbackWork && manager.registeredDelegateCountForTesting == 0)
    }

    @Test
    func aCopiedOldReceiverCannotQueueOrPublishIntoTheNewRegistration() async throws {
        let buffer = try makeDiagnosticsBuffer()
        let io = DiagnosticsSyntheticEngine()
        let manager = AudioEngineManager(testingOperations: io.operations)
        let jobs = DiagnosticsObservedJobs()
        let labels = DiagnosticsSyntheticLabels()
        let service = MicrophoneDiagnosticsService(manager: manager,
            inputDeviceName: { labels.next() }, onCallbackScheduled: { jobs.record($0) })
        defer { service.stopMicTest() }
        service.startMicTest()
        let oldReceiver = try #require(service.activeReceiverForTesting)
        service.stopMicTest()
        service.startMicTest()
        let currentName = service.selectedInputDeviceName
        let currentReceiver = try #require(service.activeReceiverForTesting)
        oldReceiver.audioEngineManager(manager, didReceive: buffer,
            at: AVAudioTime(sampleTime: 0, atRate: 16_000))
        oldReceiver.audioEngineManager(manager, didFailWith: DiagnosticsSyntheticFailure.engineStart)
        oldReceiver.audioEngineManagerDidRestartAfterRouteChange(manager)
        #expect(jobs.snapshot.isEmpty, "An invalidated copied native receiver must fail admission before creating work.")
        #expect(service.isRunning && service.selectedInputDeviceName == currentName)
        #expect(service.rmsLevel == 0 && service.decibels == -90 && service.lastError == nil)
        currentReceiver.audioEngineManager(manager, didReceive: buffer,
            at: AVAudioTime(sampleTime: 1, atRate: 16_000))
        for task in jobs.snapshot { await task.value }
        #expect(service.rmsLevel > 0 && service.lastError == nil)
        service.stopMicTest()
        await service.finishStoppingMicTest()
        #expect(!service.hasOwnedCallbackWork && manager.registeredDelegateCountForTesting == 0)
    }

    @Test
    func fullOrderedControlFIFOStopsMeteringWithAnExplicitFailureCause() async throws {
        let io = DiagnosticsSyntheticEngine()
        let manager = AudioEngineManager(testingOperations: io.operations)
        let jobs = DiagnosticsObservedJobs()
        let labels = DiagnosticsSyntheticLabels()
        let service = MicrophoneDiagnosticsService(manager: manager,
            inputDeviceName: { labels.next() }, onCallbackScheduled: { jobs.record($0) })
        defer { service.stopMicTest() }
        service.startMicTest()
        let receiver = try #require(service.activeReceiverForTesting)
        for _ in 0..<32 { receiver.audioEngineManagerDidRestartAfterRouteChange(manager) }
        receiver.audioEngineManager(manager, didFailWith: DiagnosticsSyntheticFailure.engineStart)
        #expect(service.pendingControlCountForTesting == 33,
            "Keep32 admitted controls and one explicit terminal overflow event, not unbounded per-control Tasks.")
        #expect(jobs.snapshot.count == 1)
        for task in jobs.snapshot { await task.value }
        #expect(!service.isRunning)
        #expect(service.lastError?.contains("control backlog exceeded 32 events") == true)
        #expect(service.lastError?.contains(DiagnosticsSyntheticFailure.engineStart.localizedDescription) == true,
            "The trigger's actual failure must remain visible; overflow must not become silent success.")
        #expect(manager.registeredDelegateCountForTesting == 0)
        #expect(!manager.isEngineRunning && !io.tapInstalled)
        service.stopMicTest()
        await service.finishStoppingMicTest()
        #expect(!service.hasOwnedCallbackWork)
    }

    @Test(.timeLimit(.minutes(1)))
    func shutdownRetainsAndJoinsACancelledWorkerUntilItsOwnedDelayActuallyExits() async throws {
        let buffer = try makeDiagnosticsBuffer()
        let io = DiagnosticsSyntheticEngine()
        let manager = AudioEngineManager(testingOperations: io.operations)
        let jobs = DiagnosticsObservedJobs()
        let gate = DiagnosticsHeldDelay()
        let trace = TestEventWaitTrace(label: "microphone-diagnostic-scalar-worker-exit")
        let service = MicrophoneDiagnosticsService(manager: manager,
            inputDeviceName: { "Synthetic Input" }, onCallbackScheduled: { jobs.record($0) },
            delay: gate, now: { 1 })
        var stopping: Task<Void, Never>?
        try await withTaskCancellationHandler {
            do {
                service.startMicTest()
                manager.broadcast(buffer: buffer, time: AVAudioTime(sampleTime: 0, atRate: 16_000))
                for task in jobs.snapshot { await task.value } // First publication uses no delay.
                manager.broadcast(buffer: buffer, time: AVAudioTime(sampleTime: 1, atRate: 16_000))
                #expect(try await trace.nextEvent(in: gate.events, event: "delay.entered") == .entered)
                stopping = Task {
                    await service.shutdown()
                    gate.reportShutdownReturn()
                }
                #expect(try await trace.nextEvent(in: gate.events, event: "cancel.or.return") == .cancelled,
                    "Cancellation must be observed while the exact child remains owned; setting its property nil is not resource exit.")
                #expect(service.hasOwnedCallbackWork)
                #expect(!service.isRunning && service.rmsLevel == 0 && service.lastError == nil)
                gate.release()
                await stopping?.value
                for task in jobs.snapshot { await task.value }
                #expect(!service.hasOwnedCallbackWork && service.pendingCallbackTaskCount == 0)
                #expect(manager.registeredDelegateCountForTesting == 0)
                #expect(!manager.isEngineRunning && !io.tapInstalled)
                gate.finish()
            } catch {
                gate.release()
                stopping?.cancel()
                await stopping?.value
                await service.shutdown()
                for task in jobs.snapshot { await task.value }
                gate.finish()
                throw error
            }
        } onCancel: { gate.release() }
    }
    @Test(arguments: DiagnosticsReentrantStop.allCases)
    func synchronousNumericSubscriberCannotLeaveAnOldFirstSetterOrRemainingEffects(action: DiagnosticsReentrantStop) async throws {
        let buffer = try makeDiagnosticsBuffer()
        let io = DiagnosticsSyntheticEngine()
        let manager = AudioEngineManager(testingOperations: io.operations)
        let jobs = DiagnosticsObservedJobs()
        let labels = DiagnosticsSyntheticLabels()
        let service = MicrophoneDiagnosticsService(manager: manager,
            inputDeviceName: { labels.next() }, onCallbackScheduled: { jobs.record($0) })
        defer { service.stopMicTest() }
        service.startMicTest()
        var fired = false
        let observer = service.$rmsLevel.dropFirst().sink { incoming in
            guard !fired, incoming > 0 else { return }
            fired = true
            service.stopMicTest()
            #expect(manager.registeredDelegateCountForTesting == 0,
                "Native admission closes before reentrant stop returns, even though this Published setter has not stored its value yet.")
            #expect(service.activeReceiverForTesting == nil)
            switch action {
            case .stop: break
            case .replace: service.startMicTest()
            case .shutdownPriority:
                service.startMicTest()
                service.closeAdmission()
                service.startMicTest() // Admission cannot reopen.
            }
        }
        manager.broadcast(buffer: buffer, time: AVAudioTime(sampleTime: 0, atRate: 16_000))
        for task in jobs.snapshot { await task.value }
        #expect(fired, "The actual synchronous publisher must perform the stop/replacement.")
        #expect(service.rmsLevel == 0,
            "The first old setter must be corrected after its willSet subscriber returns; checking identity only before later fields is insufficient.")
        #expect(service.decibels == -90 && service.lastError == nil,
            "The obsolete publisher sequence must not continue into later fields.")
        switch action {
        case .replace:
            #expect(service.isRunning && service.selectedInputDeviceName == "Synthetic Input 2")
            #expect(manager.registeredDelegateCountForTesting == 1)
        case .stop, .shutdownPriority:
            #expect(!service.isRunning && manager.registeredDelegateCountForTesting == 0)
            #expect(!manager.isEngineRunning && !io.tapInstalled)
        }
        observer.cancel()
        await service.shutdown()
        for task in jobs.snapshot { await task.value }
        #expect(!service.hasOwnedCallbackWork && manager.registeredDelegateCountForTesting == 0)
    }

    @Test
    func synchronousStoppedPublisherReplacementOutlivesTheOldResetSequence() async {
        let io = DiagnosticsSyntheticEngine()
        let manager = AudioEngineManager(testingOperations: io.operations)
        let jobs = DiagnosticsObservedJobs()
        let labels = DiagnosticsSyntheticLabels()
        let service = MicrophoneDiagnosticsService(manager: manager,
            inputDeviceName: { labels.next() }, onCallbackScheduled: { jobs.record($0) })
        defer { service.stopMicTest() }
        service.startMicTest()
        var fired = false
        let observer = service.$isRunning.dropFirst().sink { incoming in
            guard !fired, !incoming else { return }
            fired = true
            service.startMicTest()
        }
        service.stopMicTest()
        #expect(fired)
        #expect(service.isRunning,
            "The old stop's first false setter must not resume after a replacement and leave the new registration displayed as stopped.")
        #expect(service.selectedInputDeviceName == "Synthetic Input 2")
        #expect(service.rmsLevel == 0 && service.decibels == -90 && service.lastError == nil)
        #expect(manager.registeredDelegateCountForTesting == 1)
        observer.cancel()
        await service.shutdown()
        for task in jobs.snapshot { await task.value }
        #expect(!service.hasOwnedCallbackWork && manager.registeredDelegateCountForTesting == 0)
    }

    @Test
    func synchronousDevicePublisherReplacementCannotBeOverwrittenByTheOuterStart() async {
        let io = DiagnosticsSyntheticEngine()
        let manager = AudioEngineManager(testingOperations: io.operations)
        let jobs = DiagnosticsObservedJobs()
        let labels = DiagnosticsSyntheticLabels()
        let service = MicrophoneDiagnosticsService(manager: manager,
            inputDeviceName: { labels.next() }, onCallbackScheduled: { jobs.record($0) })
        var replacementReceipt: (any AudioEngineBufferDelegate)?
        defer {
            service.stopMicTest()
            // A failing baseline may lose this synchronously-created lease.
            // Retain and clean only its actual synthetic registration receipt.
            if let replacementReceipt { manager.unregister(replacementReceipt) }
        }
        service.startMicTest()
        var fired = false
        let observer = service.$selectedInputDeviceName.dropFirst().sink { _ in
            guard !fired else { return }
            fired = true
            service.startMicTest()
            replacementReceipt = service.activeReceiverForTesting
        }
        service.startMicTest()
        #expect(fired)
        #expect(service.selectedInputDeviceName == "Synthetic Input 3",
            "A replacement publishes its own frozen metadata after the outer setter returns.")
        #expect(service.isRunning && manager.registeredDelegateCountForTesting == 1,
            "The outer start must not replace the new authoritative lease or retain a second live registration.")
        observer.cancel()
        await service.shutdown()
        if let replacementReceipt { manager.unregister(replacementReceipt) }
        for task in jobs.snapshot { await task.value }
        #expect(!service.hasOwnedCallbackWork && manager.registeredDelegateCountForTesting == 0)
    }

    @Test
    func synchronousPresentationRefreshDoesNotCancelAnOtherwiseCurrentStartup() async {
        let io = DiagnosticsSyntheticEngine()
        let manager = AudioEngineManager(testingOperations: io.operations)
        let jobs = DiagnosticsObservedJobs()
        let labels = DiagnosticsSyntheticLabels()
        let service = MicrophoneDiagnosticsService(manager: manager,
            inputDeviceName: { labels.next() }, onCallbackScheduled: { jobs.record($0) })
        defer { service.stopMicTest() }
        var fired = false
        let observer = service.$isRunning.dropFirst().sink { _ in
            guard !fired else { return }
            fired = true
            service.refreshSelectedInputDevice()
        }
        service.startMicTest()
        #expect(fired && service.isRunning)
        #expect(service.lastError == nil && manager.registeredDelegateCountForTesting == 1,
            "Deferred metadata is presentation work, not a new lifecycle identity or a cancellation of valid startup.")
        observer.cancel()
        await service.shutdown()
        for task in jobs.snapshot { await task.value }
        #expect(!service.hasOwnedCallbackWork && manager.registeredDelegateCountForTesting == 0)
    }

    @Test
    func synchronousDevicePublisherStopPreventsTheOuterStartAndLateMetadataStorage() async {
        let io = DiagnosticsSyntheticEngine()
        let manager = AudioEngineManager(testingOperations: io.operations)
        let jobs = DiagnosticsObservedJobs()
        let labels = DiagnosticsSyntheticLabels()
        let service = MicrophoneDiagnosticsService(manager: manager,
            inputDeviceName: { labels.next() }, onCallbackScheduled: { jobs.record($0) })
        defer { service.stopMicTest() }
        service.startMicTest()
        let selectedBeforeStop = service.selectedInputDeviceName
        var fired = false
        let observer = service.$selectedInputDeviceName.dropFirst().sink { _ in
            guard !fired else { return }
            fired = true
            service.stopMicTest()
            #expect(manager.registeredDelegateCountForTesting == 0)
        }
        service.startMicTest()
        #expect(fired)
        #expect(!service.isRunning && manager.registeredDelegateCountForTesting == 0,
            "Stop during metadata publication must invalidate the outer start before it registers.")
        #expect(service.selectedInputDeviceName == selectedBeforeStop,
            "The old metadata setter must not resume storage after the stop receipt captured the last selected device.")
        observer.cancel()
        await service.shutdown()
        for task in jobs.snapshot { await task.value }
        #expect(!service.hasOwnedCallbackWork && !manager.isEngineRunning && !io.tapInstalled)
    }

    @Test
    func synchronousStartupErrorSubscriberReplacementCannotRetainTheOldFailure() async {
        let io = DiagnosticsSyntheticEngine()
        let manager = AudioEngineManager(testingOperations: io.operations)
        let jobs = DiagnosticsObservedJobs()
        let service = MicrophoneDiagnosticsService(manager: manager,
            inputDeviceName: { "Synthetic Input" }, onCallbackScheduled: { jobs.record($0) })
        defer { service.stopMicTest() }
        var fired = false
        let observer = service.$lastError.dropFirst().sink { incoming in
            guard !fired, incoming != nil else { return }
            fired = true
            service.startMicTest()
        }
        io.failNextStart()
        service.startMicTest()
        #expect(fired)
        #expect(service.isRunning && service.lastError == nil,
            "The replacement's successful startup must outlive the old error's willSet storage.")
        #expect(service.rmsLevel == 0 && service.decibels == -90)
        #expect(manager.registeredDelegateCountForTesting == 1)
        observer.cancel()
        await service.shutdown()
        for task in jobs.snapshot { await task.value }
        #expect(!service.hasOwnedCallbackWork && manager.registeredDelegateCountForTesting == 0)
    }

    @Test
    func synchronousNativeFailureSubscriberCannotPublishItsOldErrorIntoAReplacement() async throws {
        let io = DiagnosticsSyntheticEngine()
        let manager = AudioEngineManager(testingOperations: io.operations)
        let jobs = DiagnosticsObservedJobs()
        let service = MicrophoneDiagnosticsService(manager: manager,
            inputDeviceName: { "Synthetic Input" }, onCallbackScheduled: { jobs.record($0) })
        defer { service.stopMicTest() }
        service.startMicTest()
        let receiver = try #require(service.activeReceiverForTesting)
        var fired = false
        let observer = service.$rmsLevel.dropFirst().sink { _ in
            guard !fired else { return }
            fired = true
            service.stopMicTest()
            service.startMicTest()
        }
        receiver.audioEngineManager(manager, didFailWith: DiagnosticsSyntheticFailure.engineStart)
        for task in jobs.snapshot { await task.value }
        #expect(fired)
        #expect(service.isRunning && service.lastError == nil,
            "Post-publisher identity checks stop the old failure before its later error write.")
        #expect(service.rmsLevel == 0 && service.decibels == -90)
        #expect(manager.registeredDelegateCountForTesting == 1)
        observer.cancel()
        await service.shutdown()
        for task in jobs.snapshot { await task.value }
        #expect(!service.hasOwnedCallbackWork && manager.registeredDelegateCountForTesting == 0)
    }

}

enum DiagnosticsReentrantStop: CaseIterable, Sendable {
    case stop, replace, shutdownPriority
}

enum DiagnosticsSyntheticEvent: CaseIterable, Sendable {
    case pcm, routeSuccess, routeFailure
}

private enum DiagnosticsSyntheticFailure: Error, LocalizedError {
    case engineStart, duplicateTap
    var errorDescription: String? {
        switch self {
        case .engineStart: "Synthetic diagnostics engine start failed."
        case .duplicateTap: "Synthetic diagnostics duplicate tap."
        }
    }
}

private final class DiagnosticsObservedJobs: Sendable {
    private let jobs = OSAllocatedUnfairLock(initialState: [Task<Void, Never>]())
    func record(_ task: Task<Void, Never>) { jobs.withLock { $0.append(task) } }
    var snapshot: [Task<Void, Never>] { jobs.withLock { $0 } }
}

private final class DiagnosticsSyntheticLabels: Sendable {
    private let sequence = OSAllocatedUnfairLock(initialState: 0)
    func next() -> String { sequence.withLock { $0 += 1; return "Synthetic Input \($0)" } }
}

private final class DiagnosticsSyntheticEngine: Sendable {
    private struct State: Sendable {
        var running = false
        var tap = false
        var startFailures = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var tapInstalled: Bool { state.withLock { $0.tap } }
    func failNextStart() { state.withLock { $0.startFailures += 1 } }
    var operations: AudioEngineStartupTestingOperations {
        .init(installAndPrepareTap: { [self] in
            try state.withLock { value in
                guard !value.tap else { throw DiagnosticsSyntheticFailure.duplicateTap }
                value.tap = true
            }
        }, start: { [self] in
            try state.withLock { value in
                if value.startFailures > 0 {
                    value.startFailures -= 1
                    throw DiagnosticsSyntheticFailure.engineStart
                }
                value.running = true
            }
        }, stop: { [self] in state.withLock { $0.running = false } },
        removeTap: { [self] in state.withLock { $0.tap = false } },
        reset: {}, isRunning: { [self] in state.withLock { $0.running } })
    }
}

@MainActor
private func makeDiagnosticsBuffer() throws -> AVAudioPCMBuffer {
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000, channels: 1, interleaved: false))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
    buffer.frameLength = 4
    let samples = try #require(buffer.floatChannelData)
    for index in 0..<4 { samples[0][index] = 0.5 }
    return buffer
}

private enum DiagnosticsDelayEvent: Sendable { case entered, cancelled, shutdownReturned }

/// Explicitly releasable noncooperative test delay. Test cancellation always
/// releases it; it never leaves a suspended continuation in the test host.
private final class DiagnosticsHeldDelay: DelayProvider, Sendable {
    private struct State: Sendable {
        var released = false
        var continuation: CheckedContinuation<Void, Never>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    let events: AsyncStream<DiagnosticsDelayEvent>
    private let continuation: AsyncStream<DiagnosticsDelayEvent>.Continuation
    init() {
        let pair = AsyncStream<DiagnosticsDelayEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }
    func sleep(nanoseconds: UInt64) async throws {
        try await withTaskCancellationHandler {
            await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
                let alreadyReleased = state.withLock { value in
                    if value.released { return true }
                    precondition(value.continuation == nil)
                    value.continuation = waiter
                    return false
                }
                if alreadyReleased { waiter.resume() }
                continuation.yield(.entered)
            }
            try Task.checkCancellation()
        } onCancel: { self.continuation.yield(.cancelled) }
    }
    func release() {
        let waiter = state.withLock { value in
            value.released = true
            let waiter = value.continuation
            value.continuation = nil
            return waiter
        }
        waiter?.resume()
    }
    func reportShutdownReturn() { continuation.yield(.shutdownReturned) }
    func finish() { release(); continuation.finish() }
}
