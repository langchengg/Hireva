import Dispatch
import Combine
import Foundation
import Testing
import os
@testable import Hireva

@MainActor
struct AudioDeviceObserverOwnershipTests {
    @Test(.timeLimit(.minutes(1)))
    func shutdownClosesAdmissionBeforeAwaitingHeldMetadataAndJoinsPublication() async throws {
        let io = ControlledDeviceMetadataIO()
        try await withTaskCancellationHandler {
            let manager = AudioDeviceManager(testingOperations: io.operations)
            let trace = TestEventWaitTrace(label: #function)
            var stop: Task<Bool, Never>?
            do {
                _ = try await trace.nextEvent(in: io.firstReadEntered.stream, event: "metadata_read_held")
                let oldCallback = try #require(io.copiedObserver)
                stop = Task { await manager.shutdown() }
                _ = try await trace.nextEvent(in: io.admissionClosed.stream, event: "actual_metadata_admission_closed")
                let heartbeat = Task { @MainActor in true }
                #expect(await heartbeat.value)
                #expect(!io.cancellationReleaseUsed, "Shutdown must suspend without blocking MainActor on held CoreAudio work.")
                #expect(!io.readRanOnMainThread)
                io.releaseFirstRead()
                #expect(await stop!.value)
                #expect(manager.pendingRefreshCountForTesting == 0)
                #expect(manager.currentInputDeviceName == "Default Input",
                    "An admitted old snapshot cannot publish after shutdown closes its revision.")
                let reads = io.readCount
                oldCallback()
                await manager.finishRefreshesForTesting()
                #expect(io.readCount == reads)
                #expect(manager.currentInputDeviceName == "Default Input")
                await cleanup(io, manager, stop)
            } catch {
                await cleanup(io, manager, stop)
                throw error
            }
            #expect(!io.cancellationReleaseUsed)
        } onCancel: { io.releaseForOwningTestCancellation() }
    }

    @Test(.timeLimit(.minutes(1)))
    func refreshStormKeepsOnlyOneActiveAndOnePendingCopiedSnapshot() async throws {
        let io = ControlledDeviceMetadataIO()
        try await withTaskCancellationHandler {
            let manager = AudioDeviceManager(testingOperations: io.operations)
            let trace = TestEventWaitTrace(label: #function)
            do {
                _ = try await trace.nextEvent(in: io.firstReadEntered.stream, event: "metadata_read_held")
                io.setLatest(.init(inputName: "Synthetic Latest", outputName: "Synthetic Output",
                    inputID: "latest-input", outputID: "latest-output", isUsingHeadphonesOrBluetooth: true))
                for _ in 0..<200 { manager.refreshDevices() }
                #expect(manager.pendingRefreshCountForTesting == 2)
                io.releaseFirstRead()
                _ = try await trace.nextEvent(in: io.secondReadEntered.stream, event: "coalesced_second_read")
                await manager.finishRefreshesForTesting()
                #expect(io.readCount == 2, "Display metadata refreshes must not become an unbounded queue.")
                #expect(manager.pendingRefreshCountForTesting == 0)
                #expect(manager.currentInputDeviceName == "Synthetic Latest")
                #expect(manager.currentInputDeviceID == "latest-input")
                #expect(manager.isUsingHeadphonesOrBluetooth)
                #expect(!io.readRanOnMainThread)
                await cleanup(io, manager, nil)
            } catch {
                await cleanup(io, manager, nil)
                throw error
            }
            #expect(!io.cancellationReleaseUsed)
        } onCancel: { io.releaseForOwningTestCancellation() }
    }

    @Test(.timeLimit(.minutes(1)))
    func failedExactObserverRemovalRemainsOwnedAndRetriesWithoutReopeningAdmission() async throws {
        let io = ControlledDeviceMetadataIO()
        try await withTaskCancellationHandler {
            io.setRemovalAllowed(false)
            let manager = AudioDeviceManager(testingOperations: io.operations)
            let trace = TestEventWaitTrace(label: #function)
            do {
                _ = try await trace.nextEvent(in: io.firstReadEntered.stream, event: "metadata_read_held")
                let lateCallback = try #require(io.copiedObserver)
                io.releaseFirstRead()
                await manager.finishRefreshesForTesting()
                #expect(!(await manager.shutdown()), "Removal failure must not report native cleanup complete.")
                #expect(io.removalAttempts == 1)
                #expect(io.copiedObserver != nil, "The exact failed observer removal must stay retained.")
                let reads = io.readCount
                lateCallback()
                await manager.finishRefreshesForTesting()
                #expect(io.readCount == reads)
                io.setRemovalAllowed(true)
                #expect(await manager.shutdown())
                #expect(io.removalAttempts == 2)
                #expect(io.copiedObserver == nil)
                lateCallback()
                await manager.finishRefreshesForTesting()
                #expect(io.readCount == reads, "Retrying cleanup must never reopen callback admission.")
                await cleanup(io, manager, nil)
            } catch {
                io.setRemovalAllowed(true)
                await cleanup(io, manager, nil)
                throw error
            }
            #expect(!io.cancellationReleaseUsed)
        } onCancel: { io.releaseForOwningTestCancellation() }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func synchronousRouteObserversSeeOneCommittedSnapshotDuringNestedRefresh(reenter: Bool) async throws {
        let io = ControlledDeviceMetadataIO()
        try await withTaskCancellationHandler {
            let manager = AudioDeviceManager(testingOperations: io.operations)
            let firstPublisher = manager.objectWillChange
            #expect(firstPublisher === manager.objectWillChange,
                "The observable manager must retain the publisher subscribed by SwiftUI clients.")
            let trace = TestEventWaitTrace(label: #function)
            var observation: AnyCancellable?
            do {
                _ = try await trace.nextEvent(in: io.firstReadEntered.stream, event: "metadata_read_held")
                let initial = routeSnapshot(manager)
                #expect(manager.routeDescription == "Input: Default, Output: Default",
                    "The route placeholder remains compatible before the synthetic first read commits.")
                let first = AudioDeviceRouteSnapshot(inputName: "Synthetic First", outputName: "Synthetic Output",
                    inputID: "first-input", outputID: "first-output", isUsingHeadphonesOrBluetooth: false)
                let latest = AudioDeviceRouteSnapshot(inputName: "Synthetic Latest", outputName: "Latest Output",
                    inputID: "latest-input", outputID: "latest-output", isUsingHeadphonesOrBluetooth: true)
                var didReenter = false
                var observedSnapshots: [AudioDeviceRouteSnapshot] = []
                var descriptionsMatchSnapshots = true
                observation = manager.objectWillChange.sink { _ in
                    // This actual manager publishes synchronously on MainActor.
                    // The fixture never calls native CoreAudio or a hardware tap.
                    MainActor.assumeIsolated {
                        let captured = routeSnapshot(manager)
                        observedSnapshots.append(captured)
                        descriptionsMatchSnapshots = descriptionsMatchSnapshots &&
                            manager.routeDescription == (captured == initial ? "Input: Default, Output: Default" :
                                AudioDeviceManager.makeRouteDescription(
                                    inputName: captured.inputName, outputName: captured.outputName))
                        if reenter && !didReenter {
                            didReenter = true
                            io.setLatest(latest)
                            manager.refreshDevices()
                        }
                    }
                }
                io.releaseFirstRead()
                await manager.finishRefreshesForTesting()
                observation?.cancel(); observation = nil
                #expect(!observedSnapshots.isEmpty)
                #expect(observedSnapshots.allSatisfy { [initial, first, latest].contains($0) },
                    "A metadata observation must never combine fields from different queued reads.")
                #expect(descriptionsMatchSnapshots,
                    "The displayed route description belongs to the same committed metadata snapshot.")
                #expect(routeSnapshot(manager) == (reenter ? latest : first))
                #expect(io.readCount == (reenter ? 2 : 1))
                #expect(manager.pendingRefreshCountForTesting == 0)
                #expect(!io.readRanOnMainThread)
                await cleanup(io, manager, nil)
            } catch {
                observation?.cancel()
                await cleanup(io, manager, nil)
                throw error
            }
            #expect(!io.cancellationReleaseUsed)
        } onCancel: { io.releaseForOwningTestCancellation() }
    }

    private func routeSnapshot(_ manager: AudioDeviceManager) -> AudioDeviceRouteSnapshot {
        .init(inputName: manager.currentInputDeviceName, outputName: manager.currentOutputDeviceName,
            inputID: manager.currentInputDeviceID, outputID: manager.currentOutputDeviceID,
            isUsingHeadphonesOrBluetooth: manager.isUsingHeadphonesOrBluetooth)
    }

    private func cleanup(_ io: ControlledDeviceMetadataIO, _ manager: AudioDeviceManager,
        _ stop: Task<Bool, Never>?) async {
        io.releaseFirstRead()
        io.setRemovalAllowed(true)
        if let stop { _ = await stop.value }
        #expect(await manager.shutdown(), "Synthetic metadata observer cleanup must finish before the test returns.")
        io.finishEvents()
    }
}

private final class ControlledDeviceMetadataIO: Sendable {
    private struct State: Sendable {
        var readCount = 0
        var readRanOnMainThread = false
        var latest = AudioDeviceRouteSnapshot(inputName: "Synthetic First", outputName: "Synthetic Output",
            inputID: "first-input", outputID: "first-output", isUsingHeadphonesOrBluetooth: false)
        var observer: (@Sendable () -> Void)?
        var removalAllowed = true
        var removalAttempts = 0
        var firstReadReleased = false
        var cancellationReleaseUsed = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let readGate = DispatchSemaphore(value: 0)
    let firstReadEntered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let secondReadEntered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let admissionClosed = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(4))
    var operations: AudioDeviceManagerTestingOperations {
        .init(read: { self.read() }, observe: { callback in self.install(callback) },
            onAdmissionClosed: { self.admissionClosed.continuation.yield(()) })
    }
    var cancellationReleaseUsed: Bool { state.withLock { $0.cancellationReleaseUsed } }
    var readCount: Int { state.withLock { $0.readCount } }
    var readRanOnMainThread: Bool { state.withLock { $0.readRanOnMainThread } }
    var removalAttempts: Int { state.withLock { $0.removalAttempts } }
    var copiedObserver: (@Sendable () -> Void)? { state.withLock { $0.observer } }
    func setLatest(_ value: AudioDeviceRouteSnapshot) { state.withLock { $0.latest = value } }
    func setRemovalAllowed(_ value: Bool) { state.withLock { $0.removalAllowed = value } }
    func releaseFirstRead() {
        let signal = state.withLock {
            guard !$0.firstReadReleased else { return false }
            $0.firstReadReleased = true; return true
        }
        if signal { readGate.signal() }
    }
    // Install the owning test's cancellation handler before constructing the
    // manager. Releasing the synthetic native queue needs no MainActor turn.
    // The whole-case one-minute bound remains; every normal/error path joins.
    func releaseForOwningTestCancellation() {
        state.withLock { $0.cancellationReleaseUsed = true }
        releaseFirstRead()
        finishEvents()
    }
    private func read() -> AudioDeviceRouteSnapshot {
        let captured = state.withLock {
            $0.readCount += 1
            $0.readRanOnMainThread = $0.readRanOnMainThread || Thread.isMainThread
            return ($0.readCount, $0.latest)
        }
        if captured.0 == 1 {
            firstReadEntered.continuation.yield(())
            readGate.wait() // The synthetic device queue, never MainActor.
        } else if captured.0 == 2 { secondReadEntered.continuation.yield(()) }
        return captured.1
    }
    private func install(_ callback: @escaping @Sendable () -> Void) -> @Sendable () -> Bool {
        state.withLock { $0.observer = callback }
        return {
            self.state.withLock {
                $0.removalAttempts += 1
                guard $0.removalAllowed else { return false }
                $0.observer = nil; return true
            }
        }
    }
    func finishEvents() {
        firstReadEntered.continuation.finish()
        secondReadEntered.continuation.finish()
        admissionClosed.continuation.finish()
    }
}


extension AudioDeviceObserverOwnershipTests {
    // This is an existing public API characterization, not a RED assertion:
    // the six generated $field entry names must remain usable by sink clients.
    @Test(.timeLimit(.minutes(1)))
    func generatedPublicFieldPublishersRetainCurrentValueAndEachCopiedRouteUpdate() async throws {
        let io = ControlledDeviceMetadataIO()
        try await withTaskCancellationHandler {
            let manager = AudioDeviceManager(testingOperations: io.operations)
            var inputNames: [String] = [], outputNames: [String] = []
            var inputIDs: [String] = [], outputIDs: [String] = []
            var usingHeadphones: [Bool] = [], descriptions: [String] = []
            let subscribers = [
                manager.$currentInputDeviceName.sink { inputNames.append($0) },
                manager.$currentOutputDeviceName.sink { outputNames.append($0) },
                manager.$currentInputDeviceID.sink { inputIDs.append($0) },
                manager.$currentOutputDeviceID.sink { outputIDs.append($0) },
                manager.$isUsingHeadphonesOrBluetooth.sink { usingHeadphones.append($0) },
                manager.$routeDescription.sink { descriptions.append($0) }
            ]
            defer { subscribers.forEach { $0.cancel() } }
            let trace = TestEventWaitTrace(label: #function)
            do {
                _ = try await trace.nextEvent(in: io.firstReadEntered.stream, event: "metadata_read_held")
                #expect(inputNames == ["Default Input"])
                #expect(outputNames == ["Default Output"])
                #expect(inputIDs == ["default"])
                #expect(outputIDs == ["default"])
                #expect(usingHeadphones == [false])
                #expect(descriptions == ["Input: Default, Output: Default"])
                io.releaseFirstRead()
                await manager.finishRefreshesForTesting()
                #expect(inputNames == ["Default Input", "Synthetic First"])
                #expect(outputNames == ["Default Output", "Synthetic Output"])
                #expect(inputIDs == ["default", "first-input"])
                #expect(outputIDs == ["default", "first-output"])
                #expect(usingHeadphones == [false, false])
                #expect(descriptions == ["Input: Default, Output: Default",
                    "Input: Synthetic First, Output: Synthetic Output"])
                await cleanup(io, manager, nil)
            } catch { await cleanup(io, manager, nil); throw error }
            #expect(!io.cancellationReleaseUsed)
        } onCancel: { io.releaseForOwningTestCancellation() }
    }
}
