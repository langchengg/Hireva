import AVFoundation
import Foundation
import Testing
import os
@testable import Hireva

/// Actual registration and route-rebuild functions, with six per-instance I/O
/// operations replaced. No permission, microphone device, ASR or global hooks.
@MainActor
struct MicrophoneRegistrationStartupBoundaryTests {
    @Test
    func anEngineStartFailureReturnsItsCauseAndRollsBackTapAndDelegate() {
        let io = SyntheticMicrophoneEngine(startFailures: 1)
        let manager = AudioEngineManager(testingOperations: io.operations)
        let receiver = MicrophoneStartupReceiver()
        defer { manager.unregister(receiver); io.releaseSyntheticTap() }
        let result = manager.register(receiver)
        #expect(throws: MicrophoneStartupFailure.engineStart) { try result.get() }
        #expect(!io.tapInstalled)
        #expect(!manager.isEngineRunning)
        #expect(manager.registeredDelegateCountForTesting == 0)
        #expect(manager.audioRecoveryState == "Failed")
        manager.unregister(receiver)
        #expect(!io.tapInstalled, "Unregister after failed start cannot leave the installed tap alive.")
    }

    @Test
    func failedStartDoesNotPoisonTheNextIndependentRegistration() throws {
        let io = SyntheticMicrophoneEngine(startFailures: 1)
        let manager = AudioEngineManager(testingOperations: io.operations)
        let rejected = MicrophoneStartupReceiver(), current = MicrophoneStartupReceiver()
        defer {
            manager.unregister(rejected)
            manager.unregister(current)
            io.releaseSyntheticTap()
        }
        #expect(throws: MicrophoneStartupFailure.engineStart) { try manager.register(rejected).get() }
        try manager.register(current).get()
        #expect(manager.isEngineRunning && io.tapInstalled)
        #expect(manager.registeredDelegateCountForTesting == 1)
        manager.unregister(rejected)
        #expect(manager.isEngineRunning && io.tapInstalled,
            "A rejected old listener must not remove the new listener's tap.")
        manager.unregister(current)
        #expect(!manager.isEngineRunning && !io.tapInstalled)
        #expect(manager.registeredDelegateCountForTesting == 0)
    }

    @Test
    func failedNewRegistrationNotifiesExistingListenersAndRejectsOnlyTheNewListener() throws {
        let io = SyntheticMicrophoneEngine(startFailures: 0)
        let manager = AudioEngineManager(testingOperations: io.operations)
        let existing = MicrophoneStartupReceiver(), rejected = MicrophoneStartupReceiver()
        defer {
            manager.unregister(existing)
            manager.unregister(rejected)
            io.releaseSyntheticTap()
        }
        try manager.register(existing).get()
        io.stopEngineKeepingTap()
        io.failNextStart()
        #expect(throws: MicrophoneStartupFailure.engineStart) { try manager.register(rejected).get() }
        #expect(existing.failures == [.engineStart],
            "Rollback of the shared microphone tap must report its actual cause to its existing listener.")
        #expect(rejected.failures.isEmpty, "The rejected listener receives startup failure through Result.")
        #expect(manager.registeredDelegateCountForTesting == 1)
        #expect(!io.tapInstalled && !manager.isEngineRunning)
        manager.unregister(rejected)
        #expect(manager.registeredDelegateCountForTesting == 1)
    }

    @Test
    func failedRouteRebuildRemovesItsNewTapAndReportsTheOriginalCause() throws {
        let io = SyntheticMicrophoneEngine(startFailures: 0)
        let manager = AudioEngineManager(testingOperations: io.operations)
        let receiver = MicrophoneStartupReceiver()
        defer { manager.unregister(receiver); io.releaseSyntheticTap() }
        try manager.register(receiver).get()
        io.failNextStart()
        manager.rebuildInputTap()
        #expect(receiver.failures == [.engineStart])
        #expect(manager.audioRecoveryState == "Failed")
        #expect(!io.tapInstalled && !manager.isEngineRunning)
        manager.unregister(receiver)
        #expect(!io.tapInstalled, "Recovery failure must not strand the replacement tap.")
    }
}

private enum MicrophoneStartupFailure: Error, Equatable { case engineStart, duplicateTap }

private final class SyntheticMicrophoneEngine: Sendable {
    private struct State { var running = false; var tap = false; var startFailures: Int }
    private let state: OSAllocatedUnfairLock<State>
    init(startFailures: Int) { state = OSAllocatedUnfairLock(initialState: State(startFailures: startFailures)) }
    var tapInstalled: Bool { state.withLock { $0.tap } }
    func failNextStart() { state.withLock { $0.startFailures += 1 } }
    func stopEngineKeepingTap() { state.withLock { $0.running = false } }
    func releaseSyntheticTap() { state.withLock { $0.running = false; $0.tap = false } }
    var operations: AudioEngineStartupTestingOperations {
        .init(installAndPrepareTap: { [self] in
            try state.withLock { value in
                guard !value.tap else { throw MicrophoneStartupFailure.duplicateTap }
                value.tap = true
            }
        }, start: { [self] in
            try state.withLock { value in
                if value.startFailures > 0 {
                    value.startFailures -= 1
                    throw MicrophoneStartupFailure.engineStart
                }
                value.running = true
            }
        }, stop: { [self] in state.withLock { $0.running = false } },
        removeTap: { [self] in state.withLock { $0.tap = false } },
        reset: {}, isRunning: { [self] in state.withLock { $0.running } })
    }
}

private final class MicrophoneStartupReceiver: AudioEngineBufferDelegate, Sendable {
    private let errors = OSAllocatedUnfairLock(initialState: [MicrophoneStartupFailure]())
    var failures: [MicrophoneStartupFailure] { errors.withLock { $0 } }
    func audioEngineManager(_ manager: AudioEngineManager, didFailWith error: Error) {
        if let failure = error as? MicrophoneStartupFailure { errors.withLock { $0.append(failure) } }
    }
}
