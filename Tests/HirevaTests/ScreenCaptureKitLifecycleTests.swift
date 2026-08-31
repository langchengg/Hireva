import Foundation
import Testing
@testable import Hireva

@Suite(.serialized, .sharedRuntimeResources)
@MainActor
struct ScreenCaptureKitLifecycleTests {
    private enum SyntheticError: Error, Equatable {
        case start
        case stop
    }

    private final class Identity: NSObject {}

    @MainActor
    private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var isWaiting = false

        func wait() async {
            isWaiting = true
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            isWaiting = false
            continuation?.resume()
            continuation = nil
        }
    }

    @Test
    func rapidStopStartWaitsForStopCompletion() async throws {
        let operations = SystemAudioAsyncOperationQueue()
        let stopGate = Gate()
        var events: [String] = []

        let stop = operations.enqueue {
            events.append("stop.begin")
            await stopGate.wait()
            events.append("stop.end")
        }
        let start = operations.enqueue {
            events.append("start")
        }

        while !stopGate.isWaiting { await Task.yield() }
        #expect(events == ["stop.begin"])
        stopGate.open()
        try await stop.value
        try await start.value
        #expect(events == ["stop.begin", "stop.end", "start"])
    }

    @Test
    func oldSamplesWatchdogsAndErrorsCannotAffectReplacementSession() {
        let lifecycle = SystemAudioStreamSessionGate()
        let oldStream = Identity()
        let newStream = Identity()
        let old = lifecycle.beginCandidate(identity: ObjectIdentifier(oldStream))
        #expect(lifecycle.accepts(old))
        #expect(lifecycle.beginRequestedStop() == old)

        let replacement = lifecycle.beginCandidate(identity: ObjectIdentifier(newStream))
        #expect(!lifecycle.accepts(old))
        #expect(!lifecycle.accepts(identity: ObjectIdentifier(oldStream)))
        #expect(lifecycle.accepts(replacement))
        #expect(lifecycle.didStop(identity: ObjectIdentifier(oldStream)) == .expected)
        #expect(lifecycle.didStop(identity: ObjectIdentifier(oldStream)) == .stale)
        #expect(lifecycle.accepts(replacement))
    }

    @Test
    func unexpectedStopIsDeliveredExactlyOnce() {
        let lifecycle = SystemAudioStreamSessionGate()
        let stream = Identity()
        let token = lifecycle.beginCandidate(identity: ObjectIdentifier(stream))

        #expect(lifecycle.didStop(identity: token.identity) == .unexpected(token))
        #expect(lifecycle.didStop(identity: token.identity) == .stale)
        #expect(!lifecycle.accepts(token))
    }

    @Test
    func delayedOldUnexpectedStopCleanupCannotMutateReplacementSession() {
        let oldStream = Identity()
        let replacementStream = Identity()
        var isCapturing = true
        var watchdogIsActive = true
        var rmsLevel = 0.75
        var notificationCount = 0

        let applied = SystemAudioUnexpectedStopCleanupPolicy.applyIfCurrent(
            stoppedIdentity: ObjectIdentifier(oldStream),
            currentIdentity: ObjectIdentifier(replacementStream)
        ) {
            isCapturing = false
            watchdogIsActive = false
            rmsLevel = 0
            notificationCount += 1
        }

        #expect(!applied)
        #expect(isCapturing)
        #expect(watchdogIsActive)
        #expect(rmsLevel == 0.75)
        #expect(notificationCount == 0)
    }

    @Test
    func repeatedRequestedStopIsIdempotent() {
        let lifecycle = SystemAudioStreamSessionGate()
        let stream = Identity()
        let token = lifecycle.beginCandidate(identity: ObjectIdentifier(stream))

        #expect(lifecycle.beginRequestedStop() == token)
        #expect(lifecycle.beginRequestedStop() == nil)
        #expect(lifecycle.didStop(identity: token.identity) == .expected)
        #expect(lifecycle.didStop(identity: token.identity) == .stale)
    }

    @Test
    func stopFailureIsObservableAndRestoresRetryableIdentity() async throws {
        let operations = SystemAudioAsyncOperationQueue()
        let lifecycle = SystemAudioStreamSessionGate()
        let stream = Identity()
        let token = lifecycle.beginCandidate(identity: ObjectIdentifier(stream))
        #expect(lifecycle.beginRequestedStop() == token)

        let stop = operations.enqueue { throw SyntheticError.stop }
        do {
            try await stop.value
            Issue.record("Expected stop failure")
        } catch let error as SyntheticError {
            #expect(error == .stop)
        }

        let restored = lifecycle.restoreAfterStopFailure(token)
        #expect(restored != nil)
        #expect(SystemAudioStopFailurePolicy.isCapturingWhenRetryable)
        #expect(lifecycle.accepts(identity: token.identity))
        #expect(lifecycle.beginRequestedStop() != nil)
    }

    @Test
    func publicStopFailureContractDoesNotExposeUnderlyingDescription() {
        let sensitiveDescription = "stop failed for /Users/private/interview.wav in SecretApp"
        let underlying = NSError(
            domain: "SCStreamErrorDomain",
            code: 999,
            userInfo: [NSLocalizedDescriptionKey: sensitiveDescription]
        )
        let publicError = SystemAudioStopFailurePolicy.publicError()

        #expect(underlying.localizedDescription == sensitiveDescription)
        #expect(publicError.domain == "ScreenCaptureKitSystemAudioCaptureService")
        #expect(publicError.code == -7)
        #expect(publicError.localizedDescription == "System audio capture could not stop cleanly. Restart the app before starting another capture.")
        #expect(!publicError.localizedDescription.contains(sensitiveDescription))
        #expect(!publicError.localizedDescription.contains("/Users/private"))
        #expect(!publicError.localizedDescription.contains("SecretApp"))
    }

    @Test
    func expectedDelegateCompletionWinsRaceWithStopThrow() {
        let lifecycle = SystemAudioStreamSessionGate()
        let stream = Identity()
        let token = lifecycle.beginCandidate(identity: ObjectIdentifier(stream))
        #expect(lifecycle.beginRequestedStop() == token)
        #expect(lifecycle.didStop(identity: token.identity) == .expected)
        #expect(lifecycle.restoreAfterStopFailure(token) == nil)
        #expect(!lifecycle.accepts(identity: token.identity))
    }

    @Test
    func startFailureRollsBackCandidateExactlyOnce() async throws {
        var startCount = 0
        var rollbackCount = 0
        do {
            try await SystemAudioCandidateTransaction.start(
                start: {
                    startCount += 1
                    throw SyntheticError.start
                },
                rollback: {
                    rollbackCount += 1
                }
            )
            Issue.record("Expected start failure")
        } catch let error as SyntheticError {
            #expect(error == .start)
        }
        #expect(startCount == 1)
        #expect(rollbackCount == 1)
    }
}
