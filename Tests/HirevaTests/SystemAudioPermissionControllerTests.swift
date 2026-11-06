import Combine
import Foundation
import Testing
@testable import Hireva

/// New-owner characterization tests. They call the real controller; probe and
/// stop substitute only native I/O. They are not old-AppState regression proof.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct SystemAudioPermissionControllerTests {
    @Test
    func unchangedPermissionObservationsDoNotInvalidateProductUI() async throws {
        let harness = PermissionControllerHarness(results: [.granted, .granted], label: "permission.unchangedPermissionObservationsDoNotInvalidateProductUI")
        let owner = harness.makeOwner()
        harness.releaseAll()
        do {
            owner.refreshPassive()
            _ = try await owner.probeNow()
            var publications = 0
            let subscription = owner.objectWillChange.sink { publications += 1 }
            defer { subscription.cancel() }
            owner.refreshPassive()
            _ = try await owner.probeNow()
            #expect(publications == 0)
            harness.permissions.screenState = .denied
            harness.permissions.systemState = .denied
            owner.refreshPassive()
            #expect(publications > 0, "Real permission changes still notify consumers")
            #expect(owner.permissionSnapshot.systemAudioCapture == .denied)
            #expect(owner.probeResult == nil)
            try await owner.shutdown()
        } catch {
            await harness.drain(owner)
            throw error
        }
    }

    @Test
    func passiveAndMicrophoneRefreshNeverStartNativeProbeButExplicitDiagnosticsCan() async throws {
        let harness = PermissionControllerHarness(results: [.granted], label: "permission.passiveAndMicrophoneRefreshNeverStartNativeProbeButExplicitDiagnosticsCan")
        let owner = harness.makeOwner()
        do {
            owner.refreshPassive()
            #expect(owner.microphonePermissionState == .authorized)
            #expect(owner.refresh(captureMode: .microphoneOnly) == nil)
            #expect(owner.refresh(captureMode: .systemAudioOnly, automaticallyProbe: false) == nil)
            #expect(harness.probeCalls == 0)
            harness.releaseAll()
            let result = try await owner.probeNow()
            #expect(result.streamAudioProbeSucceeded)
            #expect(harness.probeCalls == 1)
            #expect(owner.systemAudioPermissionState == .granted)
            #expect(owner.permissionSnapshot.systemAudioCapture == .granted)
            #expect(!owner.hasOwnedProbeWork)
            try await owner.shutdown()
            #expect(!owner.hasOwnedProbeWork)
        } catch {
            await harness.drain(owner)
            throw error
        }
    }

    @Test
    func automaticProbeCompletionClearsItsOwnHandleWithoutAnExternalJoin() async throws {
        let harness = PermissionControllerHarness(results: [.granted], label: "permission.automaticProbeCompletionClearsItsOwnHandleWithoutAnExternalJoin")
        let owner = harness.makeOwner()
        harness.releaseAll()
        do {
            let task = owner.refresh(captureMode: .systemAudioOnly)
            _ = try await task?.value
            #expect(!owner.hasOwnedProbeWork)
            #expect(!owner.hasUnreleasedProbeResources)
            #expect(owner.systemAudioPermissionState == .granted)
            try await owner.shutdown()
        } catch {
            await harness.drain(owner)
            throw error
        }
    }

    @Test
    func parentCancellationSignalsTheRetainedNativeStopBridgeBeforeProbeReturns() async throws {
        let harness = PermissionControllerHarness(results: [.granted], holdStops: true, label: "permission.parentCancellationSignalsTheRetainedNativeStopBridgeBeforeProbeReturns")
        let owner = harness.makeOwner()
        var parent: Task<ScreenSystemAudioPermissionProbeResult, Error>?
        do {
            parent = Task { @MainActor in try await owner.probeNow() }
            try await harness.waitForProbeEntry()
            parent?.cancel()
            try await harness.waitForStopEntry()
            #expect(harness.stopCalls > 0)
            #expect(owner.hasOwnedProbeWork, "A stop request cannot claim the pending native operation exited")
            harness.releaseAll()
            _ = await parent?.result
            try await owner.finishPreparingForCapture()
            #expect(owner.probeResult == nil)
            #expect(!owner.hasOwnedProbeWork)
            try await owner.shutdown()
        } catch {
            await harness.drain(owner, probes: [parent])
            throw error
        }
    }

    @Test
    func automaticHandleCancellationAlsoSignalsTheOwnedNativeStopBridge() async throws {
        let harness = PermissionControllerHarness(results: [.granted], holdStops: true, label: "permission.automaticHandleCancellationAlsoSignalsTheOwnedNativeStopBridge")
        let owner = harness.makeOwner()
        var task: Task<ScreenSystemAudioPermissionProbeResult, Error>?
        do {
            task = owner.refresh(captureMode: .systemAudioOnly)
            try await harness.waitForProbeEntry()
            task?.cancel()
            try await harness.waitForStopEntry()
            #expect(owner.hasOwnedProbeWork)
            harness.releaseAll()
            _ = await task?.result
            try await owner.finishPreparingForCapture()
            #expect(owner.probeResult == nil)
            #expect(!owner.hasOwnedProbeWork)
            try await owner.shutdown()
        } catch {
            await harness.drain(owner, probes: [task])
            throw error
        }
    }

    @Test
    func actualNativeProbeStopFenceRetainsPendingStartAndRejectsLateSuccess() async throws {
        let permissions = PermissionControllerService()
        let stream = PermissionControllerStream()
        let trace = stream.trace
        let helper = StreamAudioProbeHelper()
        let owner = SystemAudioPermissionController(permissions: permissions,
            probe: {
                trace.mark("controller.probe.entered")
                defer { trace.mark("controller.probe.return") }
                let success = await helper.runProbe(makeStream: { stream })
                return .init(preflightGranted: true, shareableContentProbeSucceeded: true,
                    streamAudioProbeSucceeded: success, errorDescription: nil, likelyIdentityMismatch: false)
            },
            stopProbe: { retryFailedResource in
                trace.mark("controller.stop.entered")
                defer { trace.mark("controller.stop.return") }
                try await helper.stop(retryFailedResource: retryFailedResource)
            })
        var probe: Task<ScreenSystemAudioPermissionProbeResult, Error>?
        var handoff: Task<Void, Error>?
        var handedOff = false
        @MainActor func cleanup() async {
            trace.mark("cleanup.entered")
            defer { trace.mark("cleanup.return") }
            await stream.startGate.release()
            await stream.stopGate.release()
            trace.mark("cleanup.gates_released")
            owner.cancelProbe()
            trace.mark("cleanup.probe_join.requested")
            _ = await probe?.result
            trace.mark("cleanup.probe_join.return")
            trace.mark("cleanup.handoff_join.requested")
            _ = await handoff?.result
            trace.mark("cleanup.handoff_join.return")
            trace.mark("cleanup.shutdown.requested")
            try? await owner.shutdown()
            trace.mark("cleanup.shutdown.return")
            try? await helper.stop()
            stream.startEntered.continuation.finish()
            stream.stopEntered.continuation.finish()
        }
        do {
            probe = owner.refresh(captureMode: .systemAudioOnly)
            try await waitForPermissionControllerEvent(stream.startEntered.stream,
                trace: trace, event: "native_start")
            owner.cancelProbe()
            handoff = Task { @MainActor in
                try await owner.finishPreparingForCapture()
                handedOff = true
            }
            #expect(helper.hasPendingProbeResult)
            #expect(helper.hasUnreleasedStream)
            #expect(!handedOff)
            await stream.startGate.release()
            try await waitForPermissionControllerEvent(stream.stopEntered.stream,
                trace: trace, event: "native_stop")
            #expect(helper.hasUnreleasedStream, "Framework stop has entered but not completed")
            #expect(!handedOff)
            await stream.stopGate.release()
            try await handoff?.value
            _ = await probe?.result
            #expect(handedOff)
            #expect(!helper.hasPendingProbeResult)
            #expect(!helper.hasUnreleasedStream)
            #expect(owner.probeResult == nil)
            #expect(!owner.hasOwnedProbeWork)
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    @Test
    func cancellationInvalidatesLateResultAndCaptureHandoffJoinsExactStop() async throws {
        let harness = PermissionControllerHarness(results: [.granted], holdStops: true, label: "permission.cancellationInvalidatesLateResultAndCaptureHandoffJoinsExactStop")
        let owner = harness.makeOwner()
        var probe: Task<ScreenSystemAudioPermissionProbeResult, Error>?
        var handoff: Task<Void, Error>?
        var handoffFinished = false
        do {
            probe = owner.refresh(captureMode: .systemAudioOnly)
            try await harness.waitForProbeEntry()
            owner.cancelProbe()
            handoff = Task { @MainActor in
                try await owner.finishPreparingForCapture()
                handoffFinished = true
            }
            try await harness.waitForStopEntry()
            #expect(!handoffFinished)
            #expect(owner.hasOwnedProbeWork)
            harness.releaseAll()
            try await handoff?.value
            _ = await probe?.result
            #expect(handoffFinished)
            #expect(owner.probeResult == nil)
            #expect(!owner.hasOwnedProbeWork)
            try await owner.shutdown()
        } catch {
            await harness.drain(owner, probes: [probe], joins: [handoff])
            throw error
        }
    }

    @Test
    func repeatedRefreshWaitsForRetiringProbeAndPublishesOnlyReplacementResult() async throws {
        let harness = PermissionControllerHarness(results: [.rejected, .granted], label: "permission.repeatedRefreshWaitsForRetiringProbeAndPublishesOnlyReplacementResult")
        let owner = harness.makeOwner()
        var first: Task<ScreenSystemAudioPermissionProbeResult, Error>?
        var second: Task<ScreenSystemAudioPermissionProbeResult, Error>?
        do {
            first = owner.refresh(captureMode: .systemAudioOnly)
            try await harness.waitForProbeEntry()
            second = owner.refresh(captureMode: .microphoneAndSystem)
            try await harness.waitForStopEntry()
            #expect(harness.probeCalls == 1, "Replacement must wait for the old operation to exit")
            harness.probeGates[0].release()
            try await harness.waitForProbeEntry()
            #expect(harness.probeCalls == 2)
            harness.probeGates[1].release()
            let result = try await second?.value
            _ = await first?.result
            #expect(result?.streamAudioProbeSucceeded == true)
            #expect(owner.probeResult?.streamAudioProbeSucceeded == true)
            #expect(owner.systemAudioPermissionState == .granted)
            try await owner.finishPreparingForCapture()
            #expect(!owner.hasOwnedProbeWork)
            try await owner.shutdown()
        } catch {
            await harness.drain(owner, probes: [first, second])
            throw error
        }
    }

    @Test
    func passiveRevocationRejectsPreviouslyGrantedPendingProbe() async throws {
        for revokeScreen in [true, false] {
            let harness = PermissionControllerHarness(results: [.granted], label: "permission.passiveRevocationRejectsPreviouslyGrantedPendingProbe")
            let owner = harness.makeOwner()
            var probe: Task<ScreenSystemAudioPermissionProbeResult, Error>?
            do {
                probe = owner.refresh(captureMode: .systemAudioOnly)
                try await harness.waitForProbeEntry()
                if revokeScreen { harness.permissions.screenState = .denied }
                else { harness.permissions.systemState = .denied }
                owner.refreshPassive()
                harness.releaseAll()
                try await owner.finishPreparingForCapture()
                _ = await probe?.result
                #expect(owner.probeResult == nil)
                #expect(revokeScreen ? owner.permissionSnapshot.screenRecording == .denied :
                    owner.permissionSnapshot.systemAudioCapture == .denied)
                #expect(owner.systemAudioPermissionState == .permissionMissing)
                try await owner.shutdown()
            } catch {
                await harness.drain(owner, probes: [probe])
                throw error
            }
        }
    }

    @Test
    func stopFailureRemainsVisibleAndCannotAuthorizeReplacementOrReleasedResources() async throws {
        let harness = PermissionControllerHarness(results: [.granted, .granted], label: "permission.stopFailureRemainsVisibleAndCannotAuthorizeReplacementOrReleasedResources")
        let owner = harness.makeOwner()
        harness.releaseAll()
        do {
            _ = try await owner.probeNow()
            #expect(owner.systemAudioPermissionState == .granted)
            harness.failStop = true
            do {
                _ = try await owner.probeNow()
                Issue.record("Failed native stop must throw")
            } catch is PermissionControllerFixtureError {}
            #expect(owner.cleanupFailureDescription != nil)
            #expect(!owner.hasOwnedProbeWork)
            #expect(owner.hasUnreleasedProbeResources)
            #expect(owner.systemAudioPermissionState != .granted)
            #expect(owner.permissionSnapshot.systemAudioCapture != .granted)
            #expect(owner.permissionSnapshot.screenRecording != .granted)
            let replacement = owner.refresh(captureMode: .systemAudioOnly)
            _ = await replacement?.result
            #expect(harness.probeCalls == 2)
            do {
                try await owner.shutdown()
                Issue.record("Failed stop cannot report successful shutdown")
            } catch is PermissionControllerFixtureError {}
            #expect(!owner.hasOwnedProbeWork)
            #expect(owner.hasUnreleasedProbeResources)
            #expect(owner.refresh(captureMode: .systemAudioOnly) == nil)
        } catch {
            await harness.drain(owner)
            throw error
        }
        // All fake tasks have exited. The cleanup failure remains authoritative;
        // this fixture creates no native stream to claim was released.
        await harness.drain(owner)
    }

    @Test
    func shutdownJoinsPendingWorkAndPermanentlyRejectsNewAdmission() async throws {
        let harness = PermissionControllerHarness(results: [.granted], label: "permission.shutdownJoinsPendingWorkAndPermanentlyRejectsNewAdmission")
        let owner = harness.makeOwner()
        var probe: Task<ScreenSystemAudioPermissionProbeResult, Error>?
        var shutdown: Task<Void, Error>?
        var exited = false
        do {
            probe = owner.refresh(captureMode: .systemAudioOnly)
            try await harness.waitForProbeEntry()
            shutdown = Task { @MainActor in
                try await owner.shutdown()
                exited = true
            }
            try await harness.waitForStopEntry()
            #expect(!exited)
            #expect(owner.hasOwnedProbeWork)
            harness.releaseAll()
            try await shutdown?.value
            _ = await probe?.result
            #expect(exited)
            #expect(!owner.hasOwnedProbeWork)
            #expect(owner.refresh(captureMode: .systemAudioOnly) == nil)
            do {
                _ = try await owner.probeNow()
                Issue.record("Closed owner must reject explicit diagnostics too")
            } catch is CancellationError {}
            #expect(harness.probeCalls == 1)
        } catch {
            await harness.drain(owner, probes: [probe], joins: [shutdown])
            throw error
        }
        await harness.drain(owner)
    }
}

private enum PermissionControllerFixtureError: Error { case stopFailed }

@MainActor
private final class PermissionControllerGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private final class PermissionControllerService: PermissionService {
    var screenState: PermissionState = .granted
    var systemState: PermissionState = .granted
    override func refreshPermissions() -> PermissionSnapshot {
        .init(microphone: .granted, speechRecognition: .granted,
            screenRecording: screenState, systemAudioCapture: systemState)
    }
}

@MainActor
private final class PermissionControllerHarness {
    let permissions = PermissionControllerService()
    let trace: TestEventWaitTrace
    let probeGates: [PermissionControllerGate]
    let stopGate = PermissionControllerGate()
    private let results: [ScreenSystemAudioPermissionProbeResult]
    private let probeEntries = AsyncStream<Void>.makeStream()
    private let stopEntries = AsyncStream<Void>.makeStream()
    var probeCalls = 0
    var stopCalls = 0
    var failStop = false

    init(results: [ScreenSystemAudioPermissionProbeResult], holdStops: Bool = false, label: String) {
        trace = TestEventWaitTrace(label: label)
        self.results = results
        probeGates = results.map { _ in PermissionControllerGate() }
        if !holdStops { stopGate.release() }
        trace.mark("fixture.created")
    }

    func makeOwner() -> SystemAudioPermissionController {
        SystemAudioPermissionController(permissions: permissions,
            probe: { [self] in
                let index = probeCalls
                probeCalls += 1
                trace.mark("producer.probe.\(index).entered")
                defer { trace.mark("producer.probe.\(index).return") }
                let yielded = probeEntries.continuation.yield(())
                trace.mark("producer.probe.\(index).yield.\(permissionControllerYieldPhase(yielded))")
                guard results.indices.contains(index) else { throw CancellationError() }
                await probeGates[index].wait()
                return results[index]
            },
            stopProbe: { [self] in
                let index = stopCalls
                stopCalls += 1
                trace.mark("producer.stop.\(index).entered")
                defer { trace.mark("producer.stop.\(index).return") }
                let yielded = stopEntries.continuation.yield(())
                trace.mark("producer.stop.\(index).yield.\(permissionControllerYieldPhase(yielded))")
                await stopGate.wait()
                if failStop { throw PermissionControllerFixtureError.stopFailed }
            })
    }

    func waitForProbeEntry() async throws { try await waitForEvent(probeEntries.stream, event: "probe") }
    func waitForStopEntry() async throws { try await waitForEvent(stopEntries.stream, event: "stop") }
    private func waitForEvent(_ stream: AsyncStream<Void>, event: String) async throws {
        do {
            _ = try await trace.nextEvent(in: stream, event: event)
            trace.mark("consumer.\(event).success")
        } catch {
            trace.mark("consumer.\(event).failure.\(permissionControllerWaitFailurePhase(error))")
            throw error
        }
    }
    func releaseAll() {
        trace.mark("fixture.release_all.requested")
        probeGates.forEach { $0.release() }
        stopGate.release()
        trace.mark("fixture.release_all.return")
    }
    func drain(_ owner: SystemAudioPermissionController,
        probes: [Task<ScreenSystemAudioPermissionProbeResult, Error>?] = [],
        joins: [Task<Void, Error>?] = []) async {
        trace.mark("cleanup.entered")
        defer { trace.mark("cleanup.return") }
        releaseAll()
        owner.cancelProbe()
        for (index, task) in probes.enumerated() {
            trace.mark("cleanup.probe_join.\(index).requested")
            _ = await task?.result
            trace.mark("cleanup.probe_join.\(index).return")
        }
        for (index, task) in joins.enumerated() {
            trace.mark("cleanup.other_join.\(index).requested")
            _ = await task?.result
            trace.mark("cleanup.other_join.\(index).return")
        }
        trace.mark("cleanup.shutdown.requested")
        _ = try? await owner.shutdown()
        trace.mark("cleanup.shutdown.return")
        probeEntries.continuation.finish()
        stopEntries.continuation.finish()
    }
}

private extension ScreenSystemAudioPermissionProbeResult {
    static var granted: Self {
        .init(preflightGranted: true, shareableContentProbeSucceeded: true,
            streamAudioProbeSucceeded: true, errorDescription: nil, likelyIdentityMismatch: false)
    }
    static var rejected: Self {
        .init(preflightGranted: false, shareableContentProbeSucceeded: false,
            streamAudioProbeSucceeded: false, errorDescription: "Synthetic old rejection", likelyIdentityMismatch: false)
    }
}

private final class PermissionControllerStream: SystemAudioCaptureStream {
    let trace = TestEventWaitTrace(label: "permission.actualNativeProbeStopFenceRetainsPendingStartAndRejectsLateSuccess")
    let startGate = PermissionControllerNativeGate()
    let stopGate = PermissionControllerNativeGate()
    let startEntered = AsyncStream<Void>.makeStream()
    let stopEntered = AsyncStream<Void>.makeStream()
    func startCapture() async throws {
        trace.mark("producer.native_start.entered")
        defer { trace.mark("producer.native_start.return") }
        let yielded = startEntered.continuation.yield(())
        trace.mark("producer.native_start.yield.\(permissionControllerYieldPhase(yielded))")
        await startGate.wait()
    }
    func stopCapture() async throws {
        trace.mark("producer.native_stop.entered")
        defer { trace.mark("producer.native_stop.return") }
        let yielded = stopEntered.continuation.yield(())
        trace.mark("producer.native_stop.yield.\(permissionControllerYieldPhase(yielded))")
        await stopGate.wait()
    }
}

private actor PermissionControllerNativeGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private func waitForPermissionControllerEvent(_ stream: AsyncStream<Void>,
    trace: TestEventWaitTrace, event: String) async throws {
    do {
        _ = try await trace.nextEvent(in: stream, event: event)
        trace.mark("consumer.\(event).success")
    } catch {
        trace.mark("consumer.\(event).failure.\(permissionControllerWaitFailurePhase(error))")
        throw error
    }
}

private func permissionControllerYieldPhase(_ result: AsyncStream<Void>.Continuation.YieldResult) -> String {
    switch result {
    case .enqueued(_): return "enqueued"
    case .dropped(_): return "dropped"
    case .terminated: return "terminated"
    @unknown default: return "unknown"
    }
}

private func permissionControllerWaitFailurePhase(_ error: Error) -> String {
    if error is CancellationError { return "cancelled" }
    let error = error as NSError
    if error.domain == "TimeoutDomain", error.code == 1 { return "timeout_observed" }
    return "other"
}
