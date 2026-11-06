import AVFoundation
import CoreMedia
import Combine
import Foundation
import os
import ScreenCaptureKit
import Testing
@testable import Hireva

/// Current production stop/finish API; synthetic streams and PCM only. No
/// SCStream, TCC, microphone, player, helper, or model is constructed.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct SystemAudioStopRetryOwnershipTests {
    @Test
    func explicitStopRetriesTheRetainedStreamAfterCompletedFailure() async throws {
        try await withStopRetryFixture { service, old, replacement, control in
            try await service.startSystemAudioCapture()
            service.receiveAudioSampleBuffer(try stopRetrySample(), from: old)
            let failed = service.stopSystemAudioCapture()
            control.own(failed)
            #expect(await failed.result.isFailure)
            #expect(old.running)
            #expect(old.stopCalls == 1)
            var replacementRejected = false
            do { try await service.startSystemAudioCapture() }
            catch { replacementRejected = true }
            #expect(replacementRejected, "A replacement start does not authorize an implicit cleanup retry")
            #expect(old.stopCalls == 1)
            #expect(replacement.startCalls == 0)

            let retry = service.stopSystemAudioCapture()
            control.own(retry)
            try #require(retry != failed, "An explicit retry must not return the completed failed attempt")
            try await service.finishStoppingSystemAudioCapture(capturedStop: retry)
            #expect(old.stopCalls == 2)
            #expect(!old.running)
            #expect(service.lastError == nil)
            try await service.startSystemAudioCapture()
            service.receiveAudioSampleBuffer(try stopRetrySample(), from: replacement)
            #expect(replacement.startCalls == 1)
            #expect(replacement.running)
        }
    }

    @Test
    func concurrentStopsJoinTheSameRetryAndBorrowerCancellationDoesNotCancelCleanup() async throws {
        try await withStopRetryFixture(holdSecondStop: true) { service, old, _, control in
            var events = control.events.makeAsyncIterator()
            try await service.startSystemAudioCapture()
            service.receiveAudioSampleBuffer(try stopRetrySample(), from: old)
            let failed = service.stopSystemAudioCapture()
            control.own(failed)
            #expect(await failed.result.isFailure)
            #expect(await events.next() == .nativeStopEntered(stream: 1, attempt: 1))

            let retry = service.stopSystemAudioCapture()
            control.own(retry)
            let borrower = Task { @MainActor in
                do {
                    try await service.finishStoppingSystemAudioCapture(capturedStop: retry)
                    control.waiterFinished(true)
                } catch {
                    control.waiterFinished(false)
                    throw error
                }
            }
            control.own(borrower)
            // A cached failure produces waiterFinished(false) immediately in
            // RED; it cannot strand the test waiting for a nonexistent entry.
            let next = await events.next()
            try #require(next == .nativeStopEntered(stream: 1, attempt: 2))
            let duplicate = service.stopSystemAudioCapture()
            control.own(duplicate)
            #expect(duplicate == retry, "Concurrent explicit stops share one native attempt")
            #expect(old.stopCalls == 2)
            borrower.cancel()
            #expect(!retry.isCancelled, "A joiner's cancellation does not cancel the retained resource owner")
            #expect(old.running)
            control.releaseHeldStops()
            try await borrower.value
            try await service.finishStoppingSystemAudioCapture(capturedStop: duplicate)
            #expect(old.stopCalls == 2)
            #expect(!old.running)
        }
    }

    @Test
    func joiningTheOldFailureCannotOverwriteTheReplacementErrorOrStopItsStream() async throws {
        try await withStopRetryFixture { service, old, replacement, control in
            try await service.startSystemAudioCapture()
            service.receiveAudioSampleBuffer(try stopRetrySample(), from: old)
            let failed = service.stopSystemAudioCapture()
            control.own(failed)
            #expect(await failed.result.isFailure)
            let retry = service.stopSystemAudioCapture()
            control.own(retry)
            try #require(retry != failed)
            try await service.finishStoppingSystemAudioCapture(capturedStop: retry)
            try await service.startSystemAudioCapture()
            service.receiveAudioSampleBuffer(try stopRetrySample(), from: replacement)
            service.lastError = "synthetic current-epoch diagnostic"

            var oldFailureReturned = false
            do { try await service.finishStoppingSystemAudioCapture(capturedStop: failed) }
            catch { oldFailureReturned = true }
            #expect(oldFailureReturned, "The old caller still receives the original failure")
            #expect(service.lastError == "synthetic current-epoch diagnostic")
            #expect(service.isCapturing)
            #expect(replacement.running)
            #expect(replacement.stopCalls == 0)
        }
    }

    @Test
    func stableReceiptFollowsAnotherCallersRetryWithoutAStaleTaskAlias() async throws {
        try await withStopRetryFixture(holdSecondStop: true) { service, old, _, control in
            var events = control.events.makeAsyncIterator()
            try await service.startSystemAudioCapture()
            service.receiveAudioSampleBuffer(try stopRetrySample(), from: old)
            let receipt = service.stopSystemAudioCaptureAndReturnReceipt()
            let failedAttempt = receipt.task
            control.own(failedAttempt)
            #expect(await failedAttempt.result.isFailure)
            #expect(await events.next() == .nativeStopEntered(stream: 1, attempt: 1))

            // A different production caller authorizes retry through the
            // compatibility API. The previously captured receipt stays valid.
            let otherRetry = service.stopSystemAudioCapture()
            control.own(otherRetry)
            try #require(otherRetry != failedAttempt)
            let borrower = Task { @MainActor in
                do {
                    try await service.finishStoppingSystemAudioCapture(capturedReceipt: receipt)
                    control.waiterFinished(true)
                } catch {
                    control.waiterFinished(false)
                    throw error
                }
            }
            control.own(borrower)
            try #require(await events.next() == .nativeStopEntered(stream: 1, attempt: 2))
            let sameReceipt = service.retryStoppingSystemAudioCapture(capturedReceipt: receipt)
            #expect(sameReceipt === receipt)
            #expect(sameReceipt.task == otherRetry)
            #expect(old.stopCalls == 2)
            control.releaseHeldStops()
            try await borrower.value
            #expect(!old.running)
            #expect(await failedAttempt.result.isFailure,
                "The old Task retains its historical result even though the stable resource receipt follows retry")
        }
    }

    @Test
    func releasedReceiptCannotStopOrPublishOverAReplacementCapture() async throws {
        try await withStopRetryFixture { service, old, replacement, control in
            try await service.startSystemAudioCapture()
            service.receiveAudioSampleBuffer(try stopRetrySample(), from: old)
            let receipt = service.stopSystemAudioCaptureAndReturnReceipt()
            let failedAttempt = receipt.task
            control.own(failedAttempt)
            #expect(await failedAttempt.result.isFailure)
            let retry = service.retryStoppingSystemAudioCapture(capturedReceipt: receipt)
            #expect(retry === receipt)
            control.own(retry.task)
            try await service.finishStoppingSystemAudioCapture(capturedReceipt: receipt)
            try await service.startSystemAudioCapture()
            service.receiveAudioSampleBuffer(try stopRetrySample(), from: replacement)
            service.lastError = "synthetic current receipt diagnostic"

            let stale = service.retryStoppingSystemAudioCapture(capturedReceipt: receipt)
            #expect(stale === receipt)
            try await service.finishStoppingSystemAudioCapture(capturedReceipt: stale)
            #expect(service.isCapturing)
            #expect(service.lastError == "synthetic current receipt diagnostic")
            #expect(replacement.running)
            #expect(replacement.stopCalls == 0)
            #expect(old.stopCalls == 2)
        }
    }

    @Test(arguments: StopRetryOutputStage.allCases)
    fileprivate func outputRemovalRetryDoesNotRepeatNativeSuccessOrAnAlreadyRemovedOutput(stage: StopRetryOutputStage) async throws {
        try await withStopRetryFixture(failures: 0, removalFailure: stage) { service, old, _, control in
            try await service.startSystemAudioCapture()
            service.receiveAudioSampleBuffer(try stopRetrySample(), from: old)
            let receipt = service.stopSystemAudioCaptureAndReturnReceipt()
            let rejectedRemoval = receipt.task
            control.own(rejectedRemoval)
            #expect(await rejectedRemoval.result.isFailure)
            #expect(!old.running, "The native stop succeeded before the synthetic output removal failed")
            #expect(old.stopCalls == 1)
            #expect(control.audioRemovals == 1)
            #expect(control.screenRemovals == (stage == .audio ? 0 : 1))

            let retry = service.retryStoppingSystemAudioCapture(capturedReceipt: receipt)
            control.own(retry.task)
            try await service.finishStoppingSystemAudioCapture(capturedReceipt: retry)
            #expect(old.stopCalls == 1,
                "The real stopExactStream path must preserve native acknowledgement across failed output removal")
            #expect(control.audioRemovals == (stage == .audio ? 2 : 1))
            #expect(control.screenRemovals == (stage == .screen ? 2 : 1))
            #expect(control.outputSourceIDs == [old.callbackIdentity])
        }
    }

    @Test
    func nativeFailureDoesNotRemoveOutputsAndASeparateRemovalFailureKeepsItsReceipt() async throws {
        try await withStopRetryFixture(failures: 1, removalFailure: .screen) { service, old, _, control in
            try await service.startSystemAudioCapture()
            service.receiveAudioSampleBuffer(try stopRetrySample(), from: old)
            let receipt = service.stopSystemAudioCaptureAndReturnReceipt()
            let nativeFailure = receipt.task
            control.own(nativeFailure)
            #expect(await nativeFailure.result.isFailure)
            #expect(old.running)
            #expect(control.audioRemovals == 0)
            #expect(control.screenRemovals == 0)

            let firstRetry = service.retryStoppingSystemAudioCapture(capturedReceipt: receipt)
            let outputFailure = firstRetry.task
            control.own(outputFailure)
            #expect(await outputFailure.result.isFailure)
            #expect(firstRetry === receipt)
            #expect(old.stopCalls == 2)
            #expect(!old.running)
            #expect(control.audioRemovals == 1)
            #expect(control.screenRemovals == 1)

            let finalRetry = service.retryStoppingSystemAudioCapture(capturedReceipt: receipt)
            control.own(finalRetry.task)
            try await service.finishStoppingSystemAudioCapture(capturedReceipt: finalRetry)
            #expect(finalRetry === receipt)
            #expect(old.stopCalls == 2)
            #expect(control.audioRemovals == 1)
            #expect(control.screenRemovals == 2)
            #expect(control.outputSourceIDs == [old.callbackIdentity])
        }
    }

    @Test
    func repeatedFailedAttemptsKeepOwnershipUntilOneExplicitRetrySucceeds() async throws {
        try await withStopRetryFixture(failures: 2) { service, old, _, control in
            try await service.startSystemAudioCapture()
            service.receiveAudioSampleBuffer(try stopRetrySample(), from: old)
            let first = service.stopSystemAudioCapture()
            control.own(first)
            #expect(await first.result.isFailure)
            let second = service.stopSystemAudioCapture()
            control.own(second)
            try #require(second != first)
            #expect(await second.result.isFailure)
            #expect(old.running)
            #expect(old.stopCalls == 2)
            let third = service.stopSystemAudioCapture()
            control.own(third)
            try #require(third != second)
            try await service.finishStoppingSystemAudioCapture(capturedStop: third)
            #expect(old.stopCalls == 3)
            #expect(!old.running)
            #expect(service.lastError == nil)
        }
    }
}

/// Current recorder/controller APIs, synthetic system stream and permission
/// capabilities only. These cases exercise the real retained resource caller.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct ManualCaptureStopRetryOwnershipTests {
    @Test
    func oldTaskCompatibilityJoinCannotReadOrClearANewerActiveReceipt() async throws {
        try await withStopRetryFixture(failures: 0) { service, old, replacement, control in
            let recorder = ManualQuestionCaptureService(systemAudioCaptureService: service)
            do {
                try await recorder.startCapture(source: .systemAudio, onTimeout: {})
                let oldStop = try #require(recorder.cancelCaptureAndReturnOwnedStop())
                control.own(oldStop)
                try await service.finishStoppingSystemAudioCapture(capturedStop: oldStop)
                try await recorder.startCapture(source: .systemAudio, onTimeout: {})
                for task in recorder.ownedDisplayTasksForTesting { control.own(task) }
                // The new native receipt has no issued stop attempt. Reading an
                // old compatibility Task must not assume the new one has one.
                try await recorder.finishStopping(capturedStop: oldStop)
                #expect(recorder.isRecording)
                #expect(replacement.running)
                #expect(replacement.stopCalls == 0)
                try await recorder.shutdown()
                #expect(!old.running)
                #expect(!replacement.running)
                #expect(replacement.stopCalls == 1, "The new active receipt remains available to its actual owner")
            } catch { try? await recorder.shutdown(); throw error }
        }
    }

    @Test
    func oldStableReceiptJoinExcludesTheNewRecordingsOpenDisplayStream() async throws {
        try await withStopRetryFixture(failures: 0) { service, _, replacement, control in
            let recorder = ManualQuestionCaptureService(systemAudioCaptureService: service)
            do {
                try await recorder.startCapture(source: .systemAudio, onTimeout: {})
                let oldReceipt = try #require(recorder.cancelCaptureAndReturnOwnedReceipt())
                try await recorder.finishStopping(capturedReceipt: oldReceipt)
                try await recorder.startCapture(source: .systemAudio, onTimeout: {})
                for task in recorder.ownedDisplayTasksForTesting { control.own(task) }
                try await recorder.finishStopping(capturedReceipt: oldReceipt)
                #expect(recorder.isRecording)
                #expect(replacement.running)
                #expect(replacement.stopCalls == 0)
                try await recorder.shutdown()
                #expect(!replacement.running)
                #expect(replacement.stopCalls == 1)
            } catch { try? await recorder.shutdown(); throw error }
        }
    }

    @Test
    func recorderStartupCatchDoesNotImplicitlyRetryItsFailedNativeCleanup() async throws {
        try await withStopRetryFixture(failStartForStream: 1) { service, old, _, _ in
            let recorder = ManualQuestionCaptureService(systemAudioCaptureService: service)
            do {
                var rejected = false
                do { try await recorder.startCapture(source: .systemAudio, onTimeout: {}) }
                catch { rejected = true }
                try #require(rejected)
                #expect(old.running)
                #expect(old.stopCalls == 1)
                #expect(!recorder.isRecording)
                var firstDrainFailed = false
                do { try await recorder.shutdown() } catch { firstDrainFailed = true }
                #expect(firstDrainFailed)
                #expect(old.stopCalls == 1, "Joining the first failure is not permission to retry it")
                try await recorder.shutdown()
                #expect(!old.running)
                #expect(old.stopCalls == 2)
            } catch { try? await recorder.shutdown(); throw error }
        }
    }

    @Test
    func activeRecorderCannotStopAnotherCallersReplacement() async throws {
        try await withStopRetryFixture(failures: 0) { service, old, replacement, control in
            let recorder = ManualQuestionCaptureService(systemAudioCaptureService: service)
            do {
                try await recorder.startCapture(source: .systemAudio, onTimeout: {})
                service.receiveAudioSampleBuffer(try stopRetrySample(), from: old)
                // This independent owner stops the still-active recorder's epoch.
                // The recorder has not called cancel or captured a stop yet.
                let external = service.stopSystemAudioCapture()
                control.own(external)
                try await service.finishStoppingSystemAudioCapture(capturedStop: external)
                try await service.startSystemAudioCapture()
                service.receiveAudioSampleBuffer(try stopRetrySample(), from: replacement)
                service.lastError = "synthetic replacement must retain its owner"
                try await recorder.shutdown()
                #expect(!old.running)
                #expect(old.stopCalls == 1)
                #expect(replacement.running)
                #expect(replacement.stopCalls == 0)
                #expect(service.isCapturing)
                #expect(service.lastError == "synthetic replacement must retain its owner")
            } catch { try? await recorder.shutdown(); throw error }
        }
    }

    @Test
    func recorderShutdownRetriesTheSameFailedResource() async throws {
        try await withStopRetryFixture { service, old, _, control in
            let recorder = ManualQuestionCaptureService(systemAudioCaptureService: service)
            try await recorder.startCapture(source: .systemAudio, onTimeout: {})
            service.receiveAudioSampleBuffer(try stopRetrySample(), from: old)
            var failed = false
            do { try await recorder.shutdown() } catch { failed = true }
            try #require(failed)
            #expect(old.running)
            #expect(old.stopCalls == 1)
            try await recorder.shutdown()
            #expect(!old.running)
            #expect(old.stopCalls == 2)
            #expect(!recorder.isRecording)
            #expect(recorder.activeBufferReceiver == nil)
            #expect(control.startCalls(2) == 0)
        }
    }

    @Test
    func recorderCanDrainAnotherCallersRetryWithoutStoppingItsReplacement() async throws {
        try await withStopRetryFixture { service, old, replacement, control in
            let recorder = ManualQuestionCaptureService(systemAudioCaptureService: service)
            try await recorder.startCapture(source: .systemAudio, onTimeout: {})
            service.receiveAudioSampleBuffer(try stopRetrySample(), from: old)
            let failed = try #require(recorder.cancelCaptureAndReturnOwnedStop())
            control.own(failed)
            #expect(await failed.result.isFailure)
            let retry = service.stopSystemAudioCapture()
            control.own(retry)
            try await service.finishStoppingSystemAudioCapture(capturedStop: retry)
            try await service.startSystemAudioCapture()
            service.receiveAudioSampleBuffer(try stopRetrySample(), from: replacement)
            service.lastError = "synthetic replacement owned by another caller"

            try await recorder.shutdown()
            #expect(await failed.result.isFailure)
            #expect(replacement.running)
            #expect(replacement.stopCalls == 0)
            #expect(service.isCapturing)
            #expect(service.lastError == "synthetic replacement owned by another caller")
        }
    }

    @Test(arguments: [1, 2])
    func controllerRetainsFailureUntilAnExplicitRetryActuallyReleasesIt(failures: Int) async throws {
        try await withStopRetryFixture(failures: failures) { service, old, _, control in
            let recorder = ManualQuestionCaptureService(systemAudioCaptureService: service)
            let controller = manualRetryController(recorder: recorder)
            controller.start(configuration: .init(source: .systemAudio, maxDuration: 60,
                showTranscriptBeforeSending: true, autoSendAfterTranscription: false))
            let startup = try #require(controller.startupTask)
            control.own(startup)
            await startup.value
            try Task.checkCancellation()
            try #require(controller.state == .recording)
            service.receiveAudioSampleBuffer(try stopRetrySample(), from: old)
            do {
                for expectedAttempt in 1...failures {
                    var failed = false
                    do { try await controller.shutdown() } catch { failed = true }
                    #expect(failed)
                    #expect(controller.hasUnreleasedResources,
                        "A failed exact native attempt stays authoritative; error clearing is not cleanup")
                    #expect(old.running)
                    #expect(old.stopCalls == expectedAttempt)
                    #expect(controller.pendingTaskCount == 0,
                        "All recording children retire even while the concrete resource stays retained")
                }
                try await controller.shutdown()
                #expect(!controller.hasUnreleasedResources)
                #expect(old.stopCalls == failures + 1)
                #expect(!old.running)
                #expect(!recorder.isRecording)
                try await controller.shutdown()
                #expect(old.stopCalls == failures + 1, "Successful cleanup is idempotent")
            } catch {
                _ = controller.cancel()
                try? await controller.shutdown()
                throw error
            }
        }
    }

    @Test
    func controllerOldFailureCanDrainAReleasedReceiptWithoutStoppingNewCapture() async throws {
        try await withStopRetryFixture { service, old, replacement, control in
            let recorder = ManualQuestionCaptureService(systemAudioCaptureService: service)
            let controller = manualRetryController(recorder: recorder)
            controller.start(configuration: .init(source: .systemAudio, maxDuration: 60,
                showTranscriptBeforeSending: true, autoSendAfterTranscription: false))
            let startup = try #require(controller.startupTask)
            control.own(startup)
            await startup.value
            try Task.checkCancellation()
            try #require(controller.state == .recording)
            service.receiveAudioSampleBuffer(try stopRetrySample(), from: old)
            do {
                var failed = false
                do { try await controller.shutdown() } catch { failed = true }
                try #require(failed)
                let retry = service.stopSystemAudioCapture()
                control.own(retry)
                try await service.finishStoppingSystemAudioCapture(capturedStop: retry)
                try await service.startSystemAudioCapture()
                service.receiveAudioSampleBuffer(try stopRetrySample(), from: replacement)
                service.lastError = "synthetic new-epoch diagnostic"
                try await controller.shutdown()
                #expect(!controller.hasUnreleasedResources)
                #expect(replacement.running)
                #expect(replacement.stopCalls == 0)
                #expect(service.isCapturing)
                #expect(service.lastError == "synthetic new-epoch diagnostic")
            } catch {
                _ = controller.cancel()
                try? await controller.shutdown()
                throw error
            }
        }
    }
}

@MainActor
private func manualRetryController(recorder: ManualQuestionCaptureService) -> ManualCaptureController {
    let permissions = ManualRetryPermissions()
    let system = SystemAudioPermissionController(permissions: permissions,
        initialSnapshot: permissions.snapshot(), probe: {
            .init(preflightGranted: true, shareableContentProbeSucceeded: true,
                streamAudioProbeSucceeded: true, errorDescription: nil, likelyIdentityMismatch: false)
        }, stopProbe: {})
    let audio = ManualCaptureCapabilities.existingAudioAdapter(recorder: recorder)
    let speech = ManualCaptureCapabilities.Speech(start: { _, _, _ in }, append: { _ in },
        finalize: { _ in "Synthetic transcript." }, cancel: {}, startOnDevice: { _, _, _ in })
    return ManualCaptureController(dependencies: .init(permissions: permissions,
        systemPermissions: system, audio: audio, speech: speech, prepareLiveTeardown: { nil },
        feedback: { _ in }, clearFeedback: { _ in }, onReady: { _, _ in }))
}
private final class ManualRetryPermissions: PermissionService {
    override func snapshot() -> PermissionSnapshot {
        .init(microphone: .denied, speechRecognition: .granted,
            screenRecording: .granted, systemAudioCapture: .granted)
    }
    override func refreshPermissions() -> PermissionSnapshot { snapshot() }
    override func requestSpeechRecognition() async -> PermissionState { .granted }
    override func requestMicrophonePermission() async -> MicrophonePermissionState {
        Issue.record("System-only fixture must not request microphone permission")
        return .denied
    }
}

/// Real Parakeet provider/native capture retirement with synthetic runtime,
/// model status and system stream. No helper, model inference or device access.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct ParakeetCaptureStopRetryOwnershipTests {
    @Test
    func providerStartupFailureRetirementDoesNotImplicitlyRetryNativeCleanup() async throws {
        try await withStopRetryFixture(failStartForStream: 1) { service, old, _, _ in
            let runtime = StopRetryParakeetRuntime()
            let provider = stopRetryParakeetProvider(service: service, runtime: runtime)
            do {
                var rejected = false
                do {
                    _ = try await provider.startTranscription(config: .init(sessionID: "synthetic-provider-start-reject",
                        captureMode: .systemAudioOnly))
                } catch { rejected = true }
                try #require(rejected)
                #expect(provider.captureCleanupFailure != nil)
                #expect(provider.hasOwnedTranscriptionWork)
                #expect(old.running)
                #expect(old.stopCalls == 1)
                #expect(!runtime.running)
                await provider.stopTranscription()
                #expect(provider.captureCleanupFailure == nil)
                #expect(!provider.hasOwnedTranscriptionWork)
                #expect(!old.running)
                #expect(old.stopCalls == 2)
            } catch { await provider.stopTranscription(); throw error }
        }
    }

    @Test
    func activeProviderCannotStopAnotherCallersReplacement() async throws {
        try await withStopRetryFixture(failures: 0) { service, old, replacement, control in
            let runtime = StopRetryParakeetRuntime()
            let provider = stopRetryParakeetProvider(service: service, runtime: runtime)
            do {
                _ = try await provider.startTranscription(config: .init(sessionID: "synthetic-active-provider-lease",
                    captureMode: .systemAudioOnly))
                service.receiveAudioSampleBuffer(try stopRetrySample(), from: old)
                let external = service.stopSystemAudioCapture()
                control.own(external)
                try await service.finishStoppingSystemAudioCapture(capturedStop: external)
                try await service.startSystemAudioCapture()
                service.receiveAudioSampleBuffer(try stopRetrySample(), from: replacement)
                service.lastError = "synthetic capture independent of the old provider"
                await provider.stopTranscription()
                #expect(!provider.hasOwnedTranscriptionWork)
                #expect(!runtime.running)
                #expect(!old.running)
                #expect(old.stopCalls == 1)
                #expect(replacement.running)
                #expect(replacement.stopCalls == 0)
                #expect(service.isCapturing)
                #expect(service.lastError == "synthetic capture independent of the old provider")
            } catch { await provider.stopTranscription(); throw error }
        }
    }

    @Test(arguments: [1, 2])
    func explicitProviderRetryReleasesTheCapturedEpochWithoutRestartingHelper(failures: Int) async throws {
        try await withStopRetryFixture(failures: failures) { service, old, _, _ in
            let runtime = StopRetryParakeetRuntime()
            let provider = stopRetryParakeetProvider(service: service, runtime: runtime)
            _ = try await provider.startTranscription(config: .init(sessionID: "synthetic-provider-retry",
                captureMode: .systemAudioOnly))
            service.receiveAudioSampleBuffer(try stopRetrySample(), from: old)
            var firstRuntimeStops: Int?
            for attempt in 1...failures {
                await provider.stopTranscription()
                #expect(provider.captureCleanupFailure != nil)
                #expect(provider.hasOwnedTranscriptionWork,
                    "A retained failed native resource remains owned even after Swift children exit")
                #expect(old.running)
                #expect(old.stopCalls == attempt)
                #expect(!runtime.running)
                if firstRuntimeStops == nil { firstRuntimeStops = runtime.stopCalls }
                #expect(runtime.stopCalls == firstRuntimeStops)
            }
            await provider.stopTranscription()
            #expect(provider.captureCleanupFailure == nil)
            #expect(!provider.hasOwnedTranscriptionWork)
            #expect(!old.running)
            #expect(old.stopCalls == failures + 1)
            #expect(runtime.stopCalls == firstRuntimeStops,
                "Native capture retry does not stop or recreate an already drained helper")
            await provider.stopTranscription()
            #expect(old.stopCalls == failures + 1)
            #expect(runtime.stopCalls == firstRuntimeStops)
        }
    }

    @Test
    func anotherCallersSuccessfulRetryCanDrainBeforeAnUnrelatedReplacement() async throws {
        try await withStopRetryFixture { service, old, replacement, control in
            let runtime = StopRetryParakeetRuntime()
            let provider = stopRetryParakeetProvider(service: service, runtime: runtime)
            _ = try await provider.startTranscription(config: .init(sessionID: "synthetic-provider-old",
                captureMode: .systemAudioOnly))
            service.receiveAudioSampleBuffer(try stopRetrySample(), from: old)
            await provider.stopTranscription()
            try #require(provider.captureCleanupFailure != nil)
            let runtimeStops = runtime.stopCalls
            let otherRetry = service.stopSystemAudioCapture()
            control.own(otherRetry)
            try await service.finishStoppingSystemAudioCapture(capturedStop: otherRetry)
            try await service.startSystemAudioCapture()
            service.receiveAudioSampleBuffer(try stopRetrySample(), from: replacement)
            service.lastError = "synthetic unrelated new capture"

            await provider.stopTranscription()
            #expect(provider.captureCleanupFailure == nil)
            #expect(!provider.hasOwnedTranscriptionWork)
            #expect(runtime.stopCalls == runtimeStops)
            #expect(replacement.running)
            #expect(replacement.stopCalls == 0)
            #expect(service.isCapturing)
            #expect(service.lastError == "synthetic unrelated new capture")
        }
    }

    @Test
    func concurrentProviderStopsJoinOneRetainedNativeRetry() async throws {
        try await withStopRetryFixture(holdSecondStop: true) { service, old, _, control in
            var events = control.events.makeAsyncIterator()
            let runtime = StopRetryParakeetRuntime()
            let provider = stopRetryParakeetProvider(service: service, runtime: runtime)
            _ = try await provider.startTranscription(config: .init(sessionID: "synthetic-provider-concurrent",
                captureMode: .systemAudioOnly))
            service.receiveAudioSampleBuffer(try stopRetrySample(), from: old)
            await provider.stopTranscription()
            try #require(provider.captureCleanupFailure != nil)
            #expect(await events.next() == .nativeStopEntered(stream: 1, attempt: 1))
            let retry = Task { @MainActor in
                await provider.stopTranscription()
                control.waiterFinished(true)
            }
            control.own(retry)
            // A stale failed Task causes provider stop to return before native
            // retry entry in RED; the assertion exits through owned cleanup.
            try #require(await events.next() == .nativeStopEntered(stream: 1, attempt: 2))
            let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
            let borrower = Task { @MainActor in
                entered.continuation.yield(())
                entered.continuation.finish()
                await provider.stopTranscription()
            }
            control.own(borrower)
            var arrivals = entered.stream.makeAsyncIterator()
            try #require(await arrivals.next() != nil)
            #expect(old.stopCalls == 2)
            #expect(old.running)
            control.releaseHeldStops()
            await retry.value
            await borrower.value
            #expect(provider.captureCleanupFailure == nil)
            #expect(!provider.hasOwnedTranscriptionWork)
            #expect(!old.running)
            #expect(old.stopCalls == 2)
        }
    }

    @Test
    func applicationShutdownCanRetryItsFailedProviderResource() async throws {
        try await withStopRetryFixture(failures: 2) { service, old, _, _ in
            let runtime = StopRetryParakeetRuntime()
            let provider = stopRetryParakeetProvider(service: service, runtime: runtime)
            let environment = try await HirevaTestEnvironment(prefix: "ParakeetStableStopRetry")
            do {
                _ = try await provider.startTranscription(config: .init(sessionID: "synthetic-app-stop-retry",
                    captureMode: .systemAudioOnly))
                service.receiveAudioSampleBuffer(try stopRetrySample(), from: old)
                await provider.stopTranscription()
                try #require(provider.captureCleanupFailure != nil)
                let runtimeStops = runtime.stopCalls
                environment.appState.activeASRProviderRuntime = provider
                #expect(await environment.appState.shutdownResources() == false)
                #expect(provider.captureCleanupFailure != nil)
                #expect(old.running)
                #expect(old.stopCalls == 2)
                #expect(await environment.appState.shutdownResources())
                #expect(provider.captureCleanupFailure == nil)
                #expect(!old.running)
                #expect(old.stopCalls == 3)
                #expect(runtime.stopCalls == runtimeStops)
                #expect(await environment.appState.shutdownResources())
                #expect(old.stopCalls == 3)
                try await environment.shutdown()
            } catch {
                try? await environment.shutdown()
                throw error
            }
        }
    }
}

/// New synchronous-begin contract tests. Native calls deliberately ignore
/// Task cancellation until the owning test releases its exact continuation.
/// They are not represented as regressions against an API which did not exist.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct SystemAudioOwnedStartupReceiptTests {
    @Test
    func failedStartupCleanupReportsOneAttemptUntilExplicitRetry() async throws {
        try await withStopRetryFixture(failStartForStream: 1) { service, old, _, control in
            let owned = service.beginSystemAudioCapture()
            control.own(owned.startup)
            var rejected = false
            do {
                try await service.finishStartingSystemAudioCapture(capturedStart: owned.startup, capturedReceipt: owned.receipt)
            } catch { rejected = true }
            try #require(rejected)
            #expect(old.running)
            #expect(old.stopCalls == 1, "Startup cleanup cannot silently authorize a second failed-stop attempt")
            let retry = service.retryStoppingSystemAudioCapture(capturedReceipt: owned.receipt)
            control.own(retry.task)
            try await service.finishStoppingSystemAudioCapture(capturedReceipt: retry)
            #expect(!old.running)
            #expect(old.stopCalls == 2)
        }
    }

    @Test
    func delayedStartupJoinCannotPublishSuccessForAnExternallyReleasedEpoch() async throws {
        try await withStopRetryFixture(failures: 0) { service, old, replacement, control in
            let first = service.beginSystemAudioCapture()
            control.own(first.startup)
            try await first.startup.value
            let external = service.stopSystemAudioCapture()
            control.own(external)
            try await service.finishStoppingSystemAudioCapture(capturedStop: external)
            let newer = service.beginSystemAudioCapture()
            control.own(newer.startup)
            try await service.finishStartingSystemAudioCapture(capturedStart: newer.startup, capturedReceipt: newer.receipt)
            service.receiveAudioSampleBuffer(try stopRetrySample(), from: replacement)
            var rejected = false
            do {
                try await service.finishStartingSystemAudioCapture(capturedStart: first.startup, capturedReceipt: first.receipt)
            } catch is CancellationError { rejected = true }
            try #require(rejected, "A late startup join revalidates authority, not just Task success")
            #expect(!old.running)
            #expect(old.stopCalls == 1)
            #expect(replacement.running)
            #expect(replacement.stopCalls == 0)
            #expect(service.isCapturing)
        }
    }

    @Test
    func noNativeAutomationCaptureKeepsAnActiveReceiptUntilExactStop() async throws {
        try #require(isRunningUnderTestOrAutomation(),
            "This test must never enter a real native capture path")
        let service = ScreenCaptureKitSystemAudioCaptureService()
        let owned = service.beginSystemAudioCapture()
        do {
            try await service.finishStartingSystemAudioCapture(capturedStart: owned.startup, capturedReceipt: owned.receipt)
            #expect(service.isCapturing)
            try await service.finishStoppingSystemAudioCapture()
            #expect(service.isCapturing, "A drain without an issued stop does not revoke the active automation capture")
            let stop = service.stopSystemAudioCapture(capturedReceipt: owned.receipt)
            #expect(stop === owned.receipt)
            try await service.finishStoppingSystemAudioCapture(capturedReceipt: stop)
            #expect(!service.isCapturing)
        } catch {
            let stop = service.stopSystemAudioCapture(capturedReceipt: owned.receipt)
            try? await service.finishStoppingSystemAudioCapture(capturedReceipt: stop)
            throw error
        }
    }

    @Test
    func synchronousStopBeforeTaskRunsUsesAlreadyPublishedPendingReceipt() async throws {
        weak var capturedService: ScreenCaptureKitSystemAudioCaptureService?
        var published: SystemAudioCaptureStopReceipt?
        var stopped: SystemAudioCaptureStopReceipt?
        try await withStopRetryFixture(failures: 0, onStartEntered: {
            if let capturedService, let published {
                stopped = capturedService.stopSystemAudioCapture(capturedReceipt: published)
            }
        }) { service, old, replacement, control in
            capturedService = service
            let owned = service.beginSystemAudioCapture(onOwned: { published = $0 })
            control.own(owned.startup)
            let stop = try #require(stopped)
            control.own(stop.task)
            #expect(stop === owned.receipt)
            #expect(await owned.startup.result.isFailure)
            try await service.finishStoppingSystemAudioCapture(capturedReceipt: stop)
            #expect(old.startCalls == 0)
            #expect(replacement.startCalls == 0)
            #expect(!service.isCapturing)
            #expect(service.stopSystemAudioCapture(capturedReceipt: owned.receipt) === stop)
        }
    }

    @Test
    func cancelledNativeStartupDrainsItsOwnStreamAndCannotInvalidateNewPendingStart() async throws {
        try await withStopRetryFixture(failures: 0, holdStartForStream: 1) { service, old, replacement, control in
            var events = control.events.makeAsyncIterator()
            let first = service.beginSystemAudioCapture()
            control.own(first.startup)
            try #require(await events.next() == .nativeStartEntered(stream: 1))
            let stop = service.stopSystemAudioCapture(capturedReceipt: first.receipt)
            let attempt = stop.task
            control.own(attempt)
            #expect(service.stopSystemAudioCapture(capturedReceipt: first.receipt).task == attempt)
            let newer = service.beginSystemAudioCapture()
            control.own(newer.startup)
            // A delayed old stop during the newer startup must only borrow its
            // old receipt, not invalidate the newer revision or cancel its task.
            #expect(service.stopSystemAudioCapture(capturedReceipt: first.receipt) === first.receipt)
            control.releaseHeldStops()
            #expect(await first.startup.result.isFailure)
            try await service.finishStoppingSystemAudioCapture(capturedReceipt: first.receipt)
            try await service.finishStartingSystemAudioCapture(capturedStart: newer.startup, capturedReceipt: newer.receipt)
            service.receiveAudioSampleBuffer(try stopRetrySample(), from: replacement)
            #expect(!old.running)
            #expect(old.stopCalls == 1)
            #expect(replacement.running)
            #expect(replacement.startCalls == 1)
            #expect(replacement.stopCalls == 0)
            #expect(service.isCapturing)
        }
    }

    @Test
    func intermediatePendingStartCancellationDoesNotSelfJoinOrLoseEarlierDrain() async throws {
        try await withStopRetryFixture(holdSecondStop: true) { service, old, replacement, control in
            var events = control.events.makeAsyncIterator()
            try await service.startSystemAudioCapture()
            let oldReceipt = service.stopSystemAudioCaptureAndReturnReceipt()
            control.own(oldReceipt.task)
            #expect(await oldReceipt.task.result.isFailure)
            try #require(await events.next() == .nativeStopEntered(stream: 1, attempt: 1))
            let retry = service.retryStoppingSystemAudioCapture(capturedReceipt: oldReceipt)
            control.own(retry.task)
            try #require(await events.next() == .nativeStopEntered(stream: 1, attempt: 2))
            let intermediate = service.beginSystemAudioCapture()
            control.own(intermediate.startup)
            let newest = service.beginSystemAudioCapture()
            control.own(newest.startup)
            control.own(intermediate.receipt.task)
            #expect(service.stopSystemAudioCapture(capturedReceipt: oldReceipt) === oldReceipt)
            control.releaseHeldStops()
            #expect(await intermediate.startup.result.isFailure)
            try await service.finishStoppingSystemAudioCapture(capturedReceipt: intermediate.receipt)
            try await service.finishStartingSystemAudioCapture(capturedStart: newest.startup, capturedReceipt: newest.receipt)
            service.receiveAudioSampleBuffer(try stopRetrySample(), from: replacement)
            #expect(old.stopCalls == 2)
            #expect(!old.running)
            #expect(replacement.startCalls == 1)
            #expect(replacement.stopCalls == 0)
            #expect(replacement.running)
            service.lastError = "synthetic newest revision"
            try await service.finishStoppingSystemAudioCapture(capturedReceipt: oldReceipt)
            #expect(service.lastError == "synthetic newest revision")
        }
    }

    @Test(arguments: [false, true])
    func exactOldRetryRetiresACancelledResourceFreeStartupWithoutFollowingItsOwnRetry(waitForStartupExit: Bool) async throws {
        try await withStopRetryFixture { service, old, replacement, control in
            try await service.startSystemAudioCapture()
            let failed = service.stopSystemAudioCaptureAndReturnReceipt()
            let failedAttempt = failed.task
            control.own(failedAttempt)
            #expect(await failedAttempt.result.isFailure)
            let cancelled = service.beginSystemAudioCapture()
            control.own(cancelled.startup)
            cancelled.startup.cancel()
            if waitForStartupExit { #expect(await cancelled.startup.result.isFailure) }
            let retry = service.retryStoppingSystemAudioCapture(capturedReceipt: failed)
            let retryAttempt = retry.task
            control.own(retryAttempt)
            try #require(retryAttempt != failedAttempt,
                "A cancelled resource-free startup must not hide the older failed native owner")
            if let cancelledStop = cancelled.receipt.issuedStopTask { control.own(cancelledStop) }
            try await service.finishStoppingSystemAudioCapture(capturedReceipt: retry)
            #expect(!old.running)
            #expect(old.stopCalls == 2)
            #expect(replacement.startCalls == 0)
            #expect(await cancelled.startup.result.isFailure)
            try await service.finishStoppingSystemAudioCapture(capturedReceipt: cancelled.receipt)
            var rejected = false
            do {
                try await service.finishStartingSystemAudioCapture(capturedStart: cancelled.startup,
                    capturedReceipt: cancelled.receipt)
            } catch { rejected = true }
            try #require(rejected)
            try await service.startSystemAudioCapture()
            #expect(replacement.running)
            #expect(replacement.startCalls == 1)
            #expect(replacement.stopCalls == 0)
        }
    }

    @Test
    func cancelledIntermediateWithoutResourceCannotHideAnEarlierFailedNativeOwner() async throws {
        try await withStopRetryFixture { service, old, replacement, control in
            try await service.startSystemAudioCapture()
            let failed = service.stopSystemAudioCaptureAndReturnReceipt()
            control.own(failed.task)
            #expect(await failed.task.result.isFailure)
            let intermediate = service.beginSystemAudioCapture()
            control.own(intermediate.startup)
            let newest = service.beginSystemAudioCapture()
            control.own(newest.startup)
            control.own(intermediate.receipt.task)
            var rejected = false
            do {
                try await service.finishStartingSystemAudioCapture(capturedStart: newest.startup, capturedReceipt: newest.receipt)
            } catch { rejected = true }
            try #require(rejected)
            #expect(await intermediate.startup.result.isFailure)
            #expect(old.running)
            #expect(old.stopCalls == 1, "Replacement startup never authorizes an implicit failed-stop retry")
            #expect(replacement.startCalls == 0, "The native owner cannot be overwritten by a no-resource intermediate receipt")
            let explicitRetry = service.stopSystemAudioCapture()
            control.own(explicitRetry)
            try await service.finishStoppingSystemAudioCapture(capturedStop: explicitRetry)
            #expect(!old.running)
            #expect(old.stopCalls == 2)
            try await service.startSystemAudioCapture()
            #expect(replacement.running)
            #expect(replacement.startCalls == 1)
        }
    }
}

@MainActor
private func stopRetryParakeetProvider(service: ScreenCaptureKitSystemAudioCaptureService,
    runtime: StopRetryParakeetRuntime) -> LocalParakeetASRProvider {
    LocalParakeetASRProvider(modelManager: StopRetryInstalledModelManager(),
        runtimeClient: runtime, systemAudioCaptureService: service)
}
@MainActor
private final class StopRetryParakeetRuntime: ParakeetRuntimeClient {
    private(set) var running = false
    private(set) var stopCalls = 0
    private nonisolated let receivedPCM = StopRetryPCMCount()
    var appendedBufferCount: Int { receivedPCM.count }
    private var continuation: AsyncThrowingStream<ParakeetTranscriptEvent, Error>.Continuation?
    func isRuntimeAvailable() async -> Bool { true }
    func startTranscription(modelDirectory: URL, config: ASRConfig) async throws -> AsyncThrowingStream<ParakeetTranscriptEvent, Error> {
        running = true
        let pair = AsyncThrowingStream<ParakeetTranscriptEvent, Error>.makeStream()
        continuation = pair.continuation
        return pair.stream
    }
    func stop() async { stopCalls += 1; continuation?.finish(); running = false }
    nonisolated func appendAudioBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) { receivedPCM.record() }
}
private final class StopRetryPCMCount: Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: 0)
    var count: Int { storage.withLock { $0 } }
    func record() { storage.withLock { $0 += 1 } }
}
private final class StopRetryInstalledModelManager: LocalModelManager {
    func modelStatus(_ model: LocalModelDescriptor) async -> LocalModelStatus { .installed }
    func downloadModel(_ model: LocalModelDescriptor) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func deleteModel(_ model: LocalModelDescriptor) async throws {}
    func verifyModel(_ model: LocalModelDescriptor) async throws -> Bool { true }
    func fileURL(for model: LocalModelDescriptor) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-stop-retry-model")
    }
}

/// Actual Apple service/provider and captured App cleanup. Recognition is the
/// existing DEBUG simulation; native capture uses only this controlled stream.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct AppleSpeechCaptureStopRetryOwnershipTests {
    @Test
    func appleStartupCatchRetainsItsFirstFailedNativeCleanupWithoutImplicitRetry() async throws {
        try await withStopRetryFixture(failStartForStream: 1) { native, old, _, _ in
            let speech = stopRetryAppleSpeechService(native: native)
            do {
                var rejected = false
                do { try await speech.start(sessionID: "synthetic-apple-start-reject", captureMode: .systemAudioOnly) }
                catch { rejected = true }
                try #require(rejected)
                await speech.finishStoppingAudioInput()
                #expect(speech.hasUnreleasedAudioInput)
                #expect(old.running)
                #expect(old.stopCalls == 1)
                speech.stop()
                await speech.finishStoppingAudioInput()
                #expect(!speech.hasUnreleasedAudioInput)
                #expect(!old.running)
                #expect(old.stopCalls == 2)
            } catch { speech.stop(); await speech.finishStoppingAudioInput(); throw error }
        }
    }

    @Test
    func diagnosticRecognitionStartCannotImplicitlyRetryFailedNativeCleanup() async throws {
        try await withStopRetryFixture { native, old, _, _ in
            let speech = stopRetryAppleSpeechService(native: native)
            do {
                try await speech.start(sessionID: "synthetic-diagnostic-prior-native", captureMode: .systemAudioOnly)
                speech.stop()
                await speech.finishStoppingAudioInput()
                try #require(speech.hasUnreleasedAudioInput)
                #expect(old.stopCalls == 1)
                speech.startDiagnosticSystemAudioSession(sessionID: "synthetic-diagnostic-new-recognition")
                #expect(old.stopCalls == 1, "Starting recognition is not permission to retry failed native cleanup")
                #expect(speech.systemAudioSession?.isRecognitionActive == true)
                speech.stop()
                await speech.finishStoppingAudioInput()
                #expect(!speech.hasUnreleasedAudioInput)
                #expect(!old.running)
                #expect(old.stopCalls == 2)
            } catch { speech.stop(); await speech.finishStoppingAudioInput(); throw error }
        }
    }

    @Test
    func activeAppleCaptureCannotStopAnotherCallersReplacement() async throws {
        try await withStopRetryFixture(failures: 0) { native, old, replacement, control in
            let speech = stopRetryAppleSpeechService(native: native)
            do {
                try await speech.start(sessionID: "synthetic-active-apple-lease", captureMode: .systemAudioOnly)
                let external = native.stopSystemAudioCapture()
                control.own(external)
                try await native.finishStoppingSystemAudioCapture(capturedStop: external)
                try await native.startSystemAudioCapture()
                native.receiveAudioSampleBuffer(try stopRetrySample(), from: replacement)
                native.lastError = "synthetic replacement unrelated to old Apple recognition"
                speech.stop()
                await speech.finishStoppingAudioInput()
                #expect(!speech.hasUnreleasedAudioInput)
                #expect(!old.running)
                #expect(old.stopCalls == 1)
                #expect(replacement.running)
                #expect(replacement.stopCalls == 0)
                #expect(native.isCapturing)
                #expect(native.lastError == "synthetic replacement unrelated to old Apple recognition")
            } catch { speech.stop(); await speech.finishStoppingAudioInput(); throw error }
        }
    }

    @Test(arguments: [1, 2])
    func serviceRetainsFailedNativeInputUntilAnExplicitStopActuallyReleasesIt(failures: Int) async throws {
        try await withStopRetryFixture(failures: failures) { native, old, _, control in
            var events = control.events.makeAsyncIterator()
            let speech = stopRetryAppleSpeechService(native: native)
            do {
                try await speech.start(sessionID: "synthetic-apple-service-retry", captureMode: .systemAudioOnly)
                for attempt in 1...failures {
                    speech.stop()
                    await speech.finishStoppingAudioInput()
                    try #require(await events.next() == .nativeStopEntered(stream: 1, attempt: attempt))
                    try #require(speech.hasUnreleasedAudioInput,
                        "Failed native input must remain owned after PCM/control workers drain")
                    #expect(old.running)
                    #expect(old.stopCalls == attempt)
                }
                speech.stop()
                await speech.finishStoppingAudioInput()
                #expect(!speech.hasUnreleasedAudioInput)
                #expect(!old.running)
                #expect(old.stopCalls == failures + 1)
                speech.stop()
                await speech.finishStoppingAudioInput()
                #expect(old.stopCalls == failures + 1)
            } catch { speech.stop(); await speech.finishStoppingAudioInput(); throw error }
        }
    }

    @Test
    func aCapturedAppleReceiptFollowsAnotherCallersRetryWithoutStoppingAReplacement() async throws {
        try await withStopRetryFixture { native, old, replacement, control in
            let speech = stopRetryAppleSpeechService(native: native)
            do {
                try await speech.start(sessionID: "synthetic-apple-old-capture", captureMode: .systemAudioOnly)
                speech.stop()
                await speech.finishStoppingAudioInput()
                #expect(speech.hasUnreleasedAudioInput)
                let retry = native.stopSystemAudioCapture()
                control.own(retry)
                try await native.finishStoppingSystemAudioCapture(capturedStop: retry)
                try await native.startSystemAudioCapture()
                native.receiveAudioSampleBuffer(try stopRetrySample(), from: replacement)
                native.lastError = "synthetic independent replacement"
                speech.stop()
                await speech.finishStoppingAudioInput()
                #expect(!speech.hasUnreleasedAudioInput)
                #expect(!old.running)
                #expect(replacement.running)
                #expect(replacement.stopCalls == 0)
                #expect(native.isCapturing)
                #expect(native.lastError == "synthetic independent replacement")
            } catch { speech.stop(); await speech.finishStoppingAudioInput(); throw error }
        }
    }

    @Test
    func concurrentAppleStopsJoinTheSameHeldNativeRetry() async throws {
        try await withStopRetryFixture(holdSecondStop: true) { native, old, _, control in
            var events = control.events.makeAsyncIterator()
            let speech = stopRetryAppleSpeechService(native: native)
            do {
                try await speech.start(sessionID: "synthetic-apple-stop-join", captureMode: .systemAudioOnly)
                speech.stop()
                await speech.finishStoppingAudioInput()
                try #require(await events.next() == .nativeStopEntered(stream: 1, attempt: 1))
                try #require(speech.hasUnreleasedAudioInput,
                    "A failed native attempt must be retained before requesting its explicit retry")
                let retry = Task { @MainActor in
                    speech.stop()
                    await speech.finishStoppingAudioInput()
                    control.waiterFinished(!speech.hasUnreleasedAudioInput)
                }
                control.own(retry)
                try #require(await events.next() == .nativeStopEntered(stream: 1, attempt: 2))
                let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
                let borrower = Task { @MainActor in
                    entered.continuation.yield(())
                    entered.continuation.finish()
                    speech.stop()
                    await speech.finishStoppingAudioInput()
                }
                control.own(borrower)
                var arrivals = entered.stream.makeAsyncIterator()
                try #require(await arrivals.next() != nil)
                #expect(speech.hasUnreleasedAudioInput)
                #expect(old.stopCalls == 2)
                control.releaseHeldStops()
                await retry.value
                await borrower.value
                #expect(!speech.hasUnreleasedAudioInput)
                #expect(!old.running)
                #expect(old.stopCalls == 2)
            } catch { control.releaseHeldStops(); speech.stop(); await speech.finishStoppingAudioInput(); throw error }
        }
    }

    @Test
    func recognitionOnlyDiagnosticCannotStopAnIndependentlyRunningStream() async throws {
        try await withStopRetryFixture(failures: 0) { native, old, _, _ in
            try await native.startSystemAudioCapture()
            native.receiveAudioSampleBuffer(try stopRetrySample(), from: old)
            let speech = stopRetryAppleSpeechService(native: native)
            speech.startDiagnosticSystemAudioSession(sessionID: "synthetic-recognition-unrelated-native")
            speech.stop()
            await speech.finishStoppingAudioInput()
            #expect(old.running)
            #expect(old.stopCalls == 0)
            #expect(native.isCapturing)
            #expect(!speech.hasUnreleasedAudioInput)
        }
    }

    @Test(arguments: [StopReason.asrTaskFailed.rawValue, StopReason.screenCaptureStreamEnded.rawValue])
    func automaticAppCaptureStopCannotRetryAnAlreadyFailedSpeechLease(reason: String) async throws {
        let reason: StopReason = try #require(StopReason(rawValue: reason))
        try await withStopRetryFixture { native, old, _, control in
            let speech = stopRetryAppleSpeechService(native: native)
            let environment = try await HirevaTestEnvironment(prefix: "AppleAppAutomaticStopPolicy",
                systemAudioCaptureService: native)
            do {
                try await speech.start(sessionID: "synthetic-automatic-stop-policy", captureMode: .systemAudioOnly)
                speech.stop()
                await speech.finishStoppingAudioInput()
                try #require(speech.hasUnreleasedAudioInput)
                #expect(old.stopCalls == 1)
                environment.appState.appleSpeechService = speech
                environment.appState.activeTranscriptionProvider = speech
                environment.appState.stopListening(reason: reason)
                await environment.appState.captureLifecycle.drain()
                #expect(old.stopCalls == 1,
                    "Automatic ASR/capture failure is cleanup admission, not explicit retry authorization")
                #expect(old.running)
                #expect(speech.hasUnreleasedAudioInput)
                #expect(environment.appState.captureLifecycle.hasFailedTeardown)
                // The later explicit user request must recover that retained
                // operation even though legacy App service aliases were cleared.
                environment.appState.stopListening()
                await environment.appState.captureLifecycle.drain()
                #expect(!environment.appState.captureLifecycle.hasFailedTeardown)
                #expect(!speech.hasUnreleasedAudioInput)
                #expect(!old.running)
                #expect(old.stopCalls == 2)
                try await environment.shutdown()
            } catch {
                control.allowFutureStopsAndRelease()
                speech.stop(); await speech.finishStoppingAudioInput()
                try? await environment.shutdown()
                throw error
            }
        }
    }

    @Test
    func applicationPreemptionCannotImplicitlyRetryTheFailedSpeechLease() async throws {
        try await withStopRetryFixture { native, old, _, control in
            let speech = stopRetryAppleSpeechService(native: native)
            let environment = try await HirevaTestEnvironment(prefix: "AppleAppPreemptionStopPolicy",
                systemAudioCaptureService: native)
            do {
                try await speech.start(sessionID: "synthetic-preemption-stop-policy", captureMode: .systemAudioOnly)
                speech.stop()
                await speech.finishStoppingAudioInput()
                try #require(speech.hasUnreleasedAudioInput)
                environment.appState.appleSpeechService = speech
                environment.appState.activeTranscriptionProvider = speech
                // This entry is invoked by Live/Manual resource coordination;
                // its legacy reason label does not turn preemption into retry.
                environment.appState.stopAllContinuousPipelines(reason: .userRequested)
                await environment.appState.captureLifecycle.drain()
                #expect(old.stopCalls == 1)
                #expect(old.running)
                #expect(speech.hasUnreleasedAudioInput)
                #expect(environment.appState.captureLifecycle.hasFailedTeardown)
                environment.appState.stopListening()
                await environment.appState.captureLifecycle.drain()
                #expect(!environment.appState.captureLifecycle.hasFailedTeardown)
                #expect(!speech.hasUnreleasedAudioInput)
                #expect(!old.running)
                #expect(old.stopCalls == 2)
                try await environment.shutdown()
            } catch {
                control.allowFutureStopsAndRelease()
                speech.stop(); await speech.finishStoppingAudioInput()
                try? await environment.shutdown()
                throw error
            }
        }
    }

    @Test
    func lateFailedAppRetryKeepsCleanupActionAndPublishesSuccessfulRelease() async throws {
        let trace = TestEventWaitTrace(label: "apple.late_failed_app_retry")
        trace.mark("body.entry")
        defer { trace.mark("fixture.close.after_or_throw") }
        try await withStopRetryFixture(failures: 2, holdSecondStop: true) { native, old, _, control in
            trace.mark("fixture.ready")
            defer { trace.mark("fixture.close.before") }
            var events = control.events.makeAsyncIterator()
            let speech = stopRetryAppleSpeechService(native: native)
            trace.mark("environment.create.before")
            let environment = try await HirevaTestEnvironment(prefix: "AppleAppLateFailedCleanupUI",
                systemAudioCaptureService: native)
            trace.mark("environment.create.after")
            let app = environment.appState
            var cleanupAtPublication: [Bool] = []
            let observer = app.objectWillChange.sink { _ in
                cleanupAtPublication.append(app.captureLifecycle.hasFailedTeardown)
            }
            defer { observer.cancel() }
            do {
                trace.mark("speech.start.before")
                try await speech.start(sessionID: "synthetic-late-failed-cleanup-ui", captureMode: .systemAudioOnly)
                trace.mark("speech.start.after")
                app.appleSpeechService = speech
                app.activeTranscriptionProvider = speech
                trace.mark("stop1.submit.before")
                app.stopListening()
                trace.mark("stop1.submit.after")
                trace.mark("stop1.drain.before")
                await app.captureLifecycle.drain()
                trace.mark("stop1.drain.after")
                try #require(await events.next() == .nativeStopEntered(stream: 1, attempt: 1))
                trace.mark("stop1.native_failure.event_consumed")
                try #require(app.captureLifecycle.hasFailedTeardown)
                #expect(app.canStopCapture)
                #expect(app.primaryHomeActionShouldStop)
                #expect(cleanupAtPublication.contains(true))
                trace.mark("stop1.failed_cleanup.asserted")

                trace.mark("retry2.submit.before")
                app.stopListening()
                trace.mark("retry2.submit.after")
                let heldRetry = try #require(app.captureTeardownTask)
                control.own(heldRetry)
                trace.mark("retry2.registered")
                try #require(await events.next() == .nativeStopEntered(stream: 1, attempt: 2))
                trace.mark("retry2.native.entered")
                // This third request is submitted while the old native retry is
                // still running. It only joins; the late failure stays owned.
                trace.mark("overlap.submit.before")
                app.stopListening()
                trace.mark("overlap.submit.after")
                let overlap = try #require(app.captureTeardownTask)
                control.own(overlap)
                trace.mark("overlap.registered")
                try #require(overlap != heldRetry)
                let publicationsBeforeLateFailure = cleanupAtPublication.count
                trace.mark("release.before")
                control.releaseHeldStops()
                trace.mark("release.after")
                trace.mark("retry2.join.before")
                await heldRetry.value
                trace.mark("retry2.join.after")
                trace.mark("overlap.join.before")
                await overlap.value
                trace.mark("overlap.join.after")
                trace.mark("retry2.drain.before")
                await app.captureLifecycle.drain()
                trace.mark("retry2.drain.after")
                #expect(old.stopCalls == 2,
                    "A pending-retry join cannot issue another native retry for its new failure.")
                #expect(old.running)
                #expect(speech.hasUnreleasedAudioInput)
                #expect(app.captureLifecycle.hasFailedTeardown)
                #expect(app.canStopCapture)
                #expect(app.primaryHomeActionShouldStop,
                    "A newer empty stop operation must not hide an older resource's late failure.")
                #expect(cleanupAtPublication.dropFirst(publicationsBeforeLateFailure).contains(true))
                trace.mark("retry2.failed_cleanup.asserted")

                let publicationsBeforeRelease = cleanupAtPublication.count
                trace.mark("finalstop3.submit.before")
                app.stopListening()
                trace.mark("finalstop3.submit.after")
                trace.mark("finalstop3.drain.before")
                await app.captureLifecycle.drain()
                trace.mark("finalstop3.drain.after")
                #expect(old.stopCalls == 3)
                #expect(!old.running)
                #expect(!speech.hasUnreleasedAudioInput)
                #expect(!app.captureLifecycle.hasFailedTeardown)
                #expect(!app.canStopCapture)
                #expect(!app.primaryHomeActionShouldStop)
                #expect(cleanupAtPublication.dropFirst(publicationsBeforeRelease).contains(false),
                    "The actual App consumer receives the committed successful cleanup state.")
                #expect(app.captureLifecycle.pendingTaskCount == 0)
                #expect(app.captureLifecycle.retiringTaskCount == 0)
                trace.mark("environment.shutdown.before")
                try await environment.shutdown()
                trace.mark("environment.shutdown.after")
            } catch {
                trace.mark("catch.cleanup.before")
                trace.mark("catch.release.before")
                control.allowFutureStopsAndRelease()
                trace.mark("catch.release.after")
                trace.mark("catch.speech_stop.before")
                speech.stop(); await speech.finishStoppingAudioInput()
                trace.mark("catch.speech_stop.after")
                trace.mark("catch.environment_shutdown.before")
                try? await environment.shutdown()
                trace.mark("catch.environment_shutdown.after")
                throw error
            }
        }
    }

    @Test
    func blockedLiveStartResolvesFeedbackWithoutAdmittingAnotherCapture() async throws {
        try await withStopRetryFixture { native, old, _, control in
            let speech = stopRetryAppleSpeechService(native: native)
            let environment = try await HirevaTestEnvironment(prefix: "AppleAppBlockedLiveStart",
                systemAudioCaptureService: native)
            let app = environment.appState
            do {
                try await speech.start(sessionID: "synthetic-blocked-live-start", captureMode: .systemAudioOnly)
                app.appleSpeechService = speech
                app.activeTranscriptionProvider = speech
                app.stopListening()
                await app.captureLifecycle.drain()
                try #require(app.captureLifecycle.hasFailedTeardown)
                try #require(app.onboardingComplete)
                try #require(app.liveState.canStartListening)
                let previousNativeStops = old.stopCalls
                app.startListening(mode: .mock)
                #expect(app.captureStartupTask == nil)
                #expect(!app.isActionLoading(ActionID.startInterview),
                    "Rejected cleanup admission must resolve the real public Start action, not leave loading forever.")
                #expect(app.latestActionFeedback(for: ActionID.startInterview)?.kind == .error)
                #expect(old.running)
                #expect(old.startCalls == 1)
                #expect(old.stopCalls == previousNativeStops,
                    "A rejected Start cannot implicitly retry or replace the failed native capture.")
                app.stopListening()
                await app.captureLifecycle.drain()
                #expect(!old.running)
                #expect(!app.captureLifecycle.hasFailedTeardown)
                try await environment.shutdown()
            } catch {
                control.allowFutureStopsAndRelease()
                speech.stop(); await speech.finishStoppingAudioInput()
                try? await environment.shutdown()
                throw error
            }
        }
    }

    @Test(arguments: [1, 2])
    func actualAppStopRetainsAndExplicitlyRetriesItsStandaloneSpeechOwner(failures: Int) async throws {
        try await withStopRetryFixture(failures: failures) { native, old, _, control in
            let speech = stopRetryAppleSpeechService(native: native)
            let environment = try await HirevaTestEnvironment(prefix: "AppleAppStandaloneStopRetry",
                systemAudioCaptureService: native)
            do {
                try await speech.start(sessionID: "synthetic-app-standalone-stop", captureMode: .systemAudioOnly)
                environment.appState.appleSpeechService = speech
                environment.appState.activeTranscriptionProvider = speech
                environment.appState.markSystemAudioCaptureRuntimeOwnedForTesting(true)
                for attempt in 1...failures {
                    environment.appState.stopListening()
                    await environment.appState.captureLifecycle.drain()
                    #expect(environment.appState.captureLifecycle.hasFailedTeardown)
                    #expect(speech.hasUnreleasedAudioInput)
                    #expect(old.running)
                    #expect(old.stopCalls == attempt,
                        "One explicit App request must not silently authorize a second native stop attempt")
                    #expect(environment.appState.appleSpeechService == nil)
                    #expect(environment.appState.activeTranscriptionProvider == nil)
                }
                environment.appState.stopListening()
                await environment.appState.captureLifecycle.drain()
                #expect(!environment.appState.captureLifecycle.hasFailedTeardown)
                #expect(!speech.hasUnreleasedAudioInput)
                #expect(!old.running)
                #expect(old.stopCalls == failures + 1)
                environment.appState.stopListening()
                await environment.appState.captureLifecycle.drain()
                #expect(old.stopCalls == failures + 1)
                try await environment.shutdown()
            } catch {
                control.allowFutureStopsAndRelease()
                speech.stop(); await speech.finishStoppingAudioInput()
                try? await environment.shutdown()
                throw error
            }
        }
    }

    @Test
    func actualAppRetainedRetryUsesItsAliasedAppleProviderAndSpeechExactlyOnce() async throws {
        try await withStopRetryFixture { native, old, _, control in
            let speech = stopRetryAppleSpeechService(native: native)
            let provider = AppleSpeechASRProvider(service: speech)
            let environment = try await HirevaTestEnvironment(prefix: "AppleAppAliasedStopRetry",
                systemAudioCaptureService: native)
            do {
                let stream = try await provider.startTranscription(config: .init(
                    sessionID: "synthetic-app-aliased-stop", captureMode: .systemAudioOnly))
                environment.appState.appleSpeechService = speech
                environment.appState.activeTranscriptionProvider = speech
                environment.appState.activeASRProviderRuntime = provider
                environment.appState.stopListening()
                await environment.appState.captureLifecycle.drain()
                #expect(environment.appState.captureLifecycle.hasFailedTeardown)
                #expect(provider.hasOwnedTranscriptionWork)
                #expect(speech.hasUnreleasedAudioInput)
                #expect(old.running)
                #expect(old.stopCalls == 1)
                environment.appState.stopListening()
                await environment.appState.captureLifecycle.drain()
                #expect(!environment.appState.captureLifecycle.hasFailedTeardown)
                #expect(!provider.hasOwnedTranscriptionWork)
                #expect(!speech.hasUnreleasedAudioInput)
                #expect(!old.running)
                #expect(old.stopCalls == 2,
                    "The same retained Speech service must not be retried by both captured aliases")
                withExtendedLifetime(stream) {}
                try await environment.shutdown()
            } catch {
                control.allowFutureStopsAndRelease()
                await provider.stopTranscription()
                speech.stop(); await speech.finishStoppingAudioInput()
                try? await environment.shutdown()
                throw error
            }
        }
    }

    @Test
    func actualAppRetainedSpeechReceiptObservesExternalReleaseWithoutStoppingItsReplacement() async throws {
        try await withStopRetryFixture { native, old, replacement, control in
            let speech = stopRetryAppleSpeechService(native: native)
            let environment = try await HirevaTestEnvironment(prefix: "AppleAppRetainedReplacement",
                systemAudioCaptureService: native)
            do {
                try await speech.start(sessionID: "synthetic-app-retained-replacement", captureMode: .systemAudioOnly)
                environment.appState.appleSpeechService = speech
                environment.appState.activeTranscriptionProvider = speech
                environment.appState.stopListening()
                await environment.appState.captureLifecycle.drain()
                try #require(environment.appState.captureLifecycle.hasFailedTeardown)
                #expect(speech.hasUnreleasedAudioInput)
                #expect(old.stopCalls == 1)
                let externalRetry = native.stopSystemAudioCapture()
                control.own(externalRetry)
                try await native.finishStoppingSystemAudioCapture(capturedStop: externalRetry)
                try await native.startSystemAudioCapture()
                native.receiveAudioSampleBuffer(try stopRetrySample(), from: replacement)
                native.lastError = "synthetic unrelated replacement after external retained stop"
                environment.appState.stopListening()
                await environment.appState.captureLifecycle.drain()
                #expect(!environment.appState.captureLifecycle.hasFailedTeardown)
                #expect(!speech.hasUnreleasedAudioInput)
                #expect(!old.running)
                #expect(old.stopCalls == 2)
                #expect(replacement.running)
                #expect(replacement.stopCalls == 0)
                #expect(native.isCapturing)
                #expect(native.lastError == "synthetic unrelated replacement after external retained stop")
                try await environment.shutdown()
            } catch {
                control.allowFutureStopsAndRelease()
                speech.stop(); await speech.finishStoppingAudioInput()
                try? await environment.shutdown()
                throw error
            }
        }
    }

    @Test
    func staleLiveDisplayOwnershipCannotAuthorizeStoppingAForeignNativeLeaseAtShutdown() async throws {
        try await withStopRetryFixture(failures: 0) { native, foreign, _, control in
            let capture = native.beginSystemAudioCapture()
            control.own(capture.startup)
            try await native.finishStartingSystemAudioCapture(
                capturedStart: capture.startup, capturedReceipt: capture.receipt)
            native.receiveAudioSampleBuffer(try stopRetrySample(), from: foreign)
            let environment = try await HirevaTestEnvironment(prefix: "StaleLiveDisplayNativeOwnership",
                systemAudioCaptureService: native)
            do {
                // The legacy flag still serves Live stream-ended display tests.
                // It is not an exact capture receipt or a shutdown capability.
                environment.appState.markSystemAudioCaptureRuntimeOwnedForTesting(true)
                #expect(environment.appState.activeASRProviderRuntime == nil)
                #expect(environment.appState.appleSpeechService == nil)
                #expect(!environment.appState.systemAudioPermissions.hasOwnedDiagnosticCapture)
                #expect(await environment.appState.shutdownResources())
                #expect(foreign.running,
                    "An App with only stale display metadata must preserve an independently owned native capture")
                #expect(foreign.stopCalls == 0)
                #expect(native.isCapturing)
                try await environment.shutdown()
            } catch {
                control.allowFutureStopsAndRelease()
                try? await environment.shutdown()
                throw error
            }
            // The enclosing fixture owns the foreign receipt and drains it
            // after these App-boundary assertions, including on RED or error.
        }
    }

    @Test
    func actualAppShutdownCannotStopAReplacementOwnedByAnotherCaller() async throws {
        try await withStopRetryFixture(failures: 0) { native, old, replacement, control in
            let speech = stopRetryAppleSpeechService(native: native)
            let environment = try await HirevaTestEnvironment(prefix: "AppleAppOldEpochReplacement",
                systemAudioCaptureService: native)
            do {
                try await speech.start(sessionID: "synthetic-app-old-native-epoch", captureMode: .systemAudioOnly)
                environment.appState.appleSpeechService = speech
                environment.appState.activeTranscriptionProvider = speech
                environment.appState.markSystemAudioCaptureRuntimeOwnedForTesting(true)
                let external = native.stopSystemAudioCapture()
                control.own(external)
                try await native.finishStoppingSystemAudioCapture(capturedStop: external)
                try await native.startSystemAudioCapture()
                native.receiveAudioSampleBuffer(try stopRetrySample(), from: replacement)
                #expect(await environment.appState.shutdownResources())
                #expect(!old.running)
                #expect(old.stopCalls == 1)
                #expect(replacement.running,
                    "App cleanup delegates the captured owner; a boolean cannot authorize stopping the current shared stream")
                #expect(replacement.stopCalls == 0)
                #expect(native.isCapturing)
                try await environment.shutdown()
            } catch {
                speech.stop(); await speech.finishStoppingAudioInput()
                try? await environment.shutdown()
                throw error
            }
        }
    }

    @Test
    func actualAppShutdownRetriesTheSameFailedSpeechOwnerOncePerAttempt() async throws {
        try await withStopRetryFixture(failures: 2) { native, old, _, _ in
            let speech = stopRetryAppleSpeechService(native: native)
            let environment = try await HirevaTestEnvironment(prefix: "AppleSpeechStableNativeRetry")
            do {
                try await speech.start(sessionID: "synthetic-app-speech-retry", captureMode: .systemAudioOnly)
                speech.stop()
                await speech.finishStoppingAudioInput()
                #expect(speech.hasUnreleasedAudioInput)
                environment.appState.appleSpeechService = speech
                environment.appState.activeTranscriptionProvider = speech
                #expect(await environment.appState.shutdownResources() == false)
                #expect(speech.hasUnreleasedAudioInput)
                #expect(old.running)
                #expect(old.stopCalls == 2,
                    "Legacy aliases must not retry the same failed native resource twice in one App attempt")
                #expect(await environment.appState.shutdownResources())
                #expect(!speech.hasUnreleasedAudioInput)
                #expect(!old.running)
                #expect(old.stopCalls == 3)
                #expect(await environment.appState.shutdownResources())
                #expect(old.stopCalls == 3)
                try await environment.shutdown()
            } catch {
                speech.stop(); await speech.finishStoppingAudioInput()
                try? await environment.shutdown()
                throw error
            }
        }
    }

    @Test
    func actualAppShutdownDetectsFailureOwnedOnlyByItsAppleASRProvider() async throws {
        try await withStopRetryFixture(failures: 2) { native, old, _, _ in
            let speech = stopRetryAppleSpeechService(native: native)
            let provider = AppleSpeechASRProvider(service: speech)
            let environment = try await HirevaTestEnvironment(prefix: "AppleProviderStableNativeRetry")
            do {
                _ = try await provider.startTranscription(config: .init(sessionID: "synthetic-app-apple-provider",
                    captureMode: .systemAudioOnly))
                await provider.stopTranscription()
                #expect(provider.hasOwnedTranscriptionWork)
                #expect(speech.hasUnreleasedAudioInput)
                environment.appState.activeASRProviderRuntime = provider
                #expect(await environment.appState.shutdownResources() == false)
                #expect(old.running)
                #expect(old.stopCalls == 2)
                #expect(await environment.appState.shutdownResources())
                #expect(!provider.hasOwnedTranscriptionWork)
                #expect(!speech.hasUnreleasedAudioInput)
                #expect(!old.running)
                #expect(old.stopCalls == 3)
                try await environment.shutdown()
            } catch {
                await provider.stopTranscription()
                try? await environment.shutdown()
                throw error
            }
        }
    }
}

/// New diagnostic-owner contracts. The preexisting UI had an anonymous raw
/// start Task, so these are not claimed as an unchanged old-controller RED.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct PermissionDiagnosticCaptureOwnershipTests {
    @Test
    func synchronousPermissionDeniedPublicationDoesNotReemitTheSameFailure() async throws {
        try await withStopRetryFixture(failures: 0) { native, old, _, control in
            let permissions = HermeticPermissionService()
            permissions.currentSnapshot.screenRecording = .denied
            permissions.currentSnapshot.systemAudioCapture = .denied
            let owner = SystemAudioPermissionController(permissions: permissions,
                initialSnapshot: permissions.currentSnapshot,
                probe: { .init(preflightGranted: false, shareableContentProbeSucceeded: false,
                    streamAudioProbeSucceeded: false, errorDescription: nil, likelyIdentityMismatch: false) },
                stopProbe: {}, diagnosticCaptureService: native)
            do {
                var reentered = false
                var publications = 0
                let subscription = owner.objectWillChange.sink {
                    publications += 1
                    guard !reentered else { return }
                    reentered = true
                    #expect(owner.requestDiagnosticCapture() == nil)
                }
                defer { subscription.cancel() }
                #expect(owner.requestDiagnosticCapture() == nil)
                #expect(reentered)
                #expect(publications == 1,
                    "An observer retry of an unchanged denial must not recursively emit the same failure")
                #expect(owner.diagnosticCaptureError != nil)
                #expect(!owner.hasUnreleasedResources)
                #expect(old.startCalls == 0)
                #expect(old.stopCalls == 0)
                try await owner.shutdown()
            } catch {
                control.allowFutureStopsAndRelease()
                try? await owner.shutdown()
                throw error
            }
        }
    }

    @Test
    func synchronousDiagnosticPublicationRejectsASecondStartBeforeReturning() async throws {
        try await withStopRetryFixture(failures: 0) { native, old, _, control in
            try await withDiagnosticCaptureOwner(native: native, control: control) { owner in
                var reentered = false
                var nested: Task<Void, Error>?
                let subscription = owner.objectWillChange.sink {
                    guard !reentered else { return }
                    reentered = true
                    nested = owner.requestDiagnosticCapture()
                    if let nested { control.own(nested) }
                }
                defer { subscription.cancel() }
                let start = owner.requestDiagnosticCapture()
                if let start { control.own(start) }
                #expect(reentered)
                #expect(nested == nil,
                    "The new diagnostic record must be committed before its first observer can submit another start")
                if let nested { _ = await nested.result }
                try await start?.value
                #expect(old.startCalls == 1)
            }
        }
    }

    @Test
    func synchronousDiagnosticPublicationStopJoinsTheAlreadyRegisteredStartup() async throws {
        try await withStopRetryFixture(failures: 0) { native, old, _, control in
            try await withDiagnosticCaptureOwner(native: native, control: control) { owner in
                var reentered = false
                var stop: Task<Void, Error>?
                let subscription = owner.objectWillChange.sink {
                    guard !reentered else { return }
                    reentered = true
                    stop = owner.stopDiagnosticCapture()
                    if let stop { control.own(stop) }
                }
                defer { subscription.cancel() }
                let start = owner.requestDiagnosticCapture()
                if let start { control.own(start) }
                #expect(start == nil)
                #expect(stop != nil,
                    "A synchronous stop observer must see and retain the submitted startup")
                if let start { _ = await start.result }
                try await stop?.value
                #expect(!owner.hasUnreleasedResources)
                #expect(!old.running)
                #expect(old.startCalls == 0,
                    "No native startup may run after the admitted startup is synchronously stopped")
            }
        }
    }

    @Test
    func synchronousFailedStopPublicationCanSubmitOneExactRetry() async throws {
        try await withStopRetryFixture { native, old, _, control in
            try await withDiagnosticCaptureOwner(native: native, control: control) { owner in
                let start = try #require(owner.requestDiagnosticCapture())
                control.own(start)
                try await start.value
                var reentered = false
                var retry: Task<Void, Error>?
                let subscription = owner.objectWillChange.sink {
                    guard !reentered, owner.diagnosticCaptureError != nil else { return }
                    reentered = true
                    retry = owner.stopDiagnosticCapture()
                    if let retry { control.own(retry) }
                }
                defer { subscription.cancel() }
                let failed = try #require(owner.stopDiagnosticCapture())
                control.own(failed)
                #expect((await failed.result).isFailure)
                #expect(reentered,
                    "The observer must read the committed failure, not the old error value")
                let submittedRetry = try #require(retry)
                try await submittedRetry.value
                #expect(!owner.hasUnreleasedResources)
                #expect(owner.diagnosticCaptureError == nil)
                #expect(!old.running)
                #expect(old.stopCalls == 2,
                    "Committed failed attempt retirement permits one explicit retry from its observer")
            }
        }
    }

    @Test
    func foreignPendingNativeStartupCannotBeReplacedByAVisualTest() async throws {
        try await withStopRetryFixture(failures: 0) { native, old, _, control in
            try await withDiagnosticCaptureOwner(native: native, control: control) { owner in
                let foreign = native.beginSystemAudioCapture()
                control.own(foreign.startup)
                #expect(!native.isCapturing)
                #expect(native.hasOwnedCaptureRuntime)
                #expect(!owner.canStartDiagnosticCapture)
                #expect(owner.requestDiagnosticCapture() == nil)
                try await native.finishStartingSystemAudioCapture(
                    capturedStart: foreign.startup, capturedReceipt: foreign.receipt)
                try await owner.shutdown()
                #expect(old.running)
                #expect(old.stopCalls == 0)
                #expect(!owner.hasUnreleasedResources)
            }
        }
    }

    @Test
    func stoppingPendingNativeStartJoinsItAndDoesNotReacquireAfterReturn() async throws {
        try await withStopRetryFixture(failures: 0, holdStartForStream: 1) { native, old, _, control in
            try await withDiagnosticCaptureOwner(native: native, control: control) { owner in
                var events = control.events.makeAsyncIterator()
                let start = try #require(owner.requestDiagnosticCapture())
                control.own(start)
                try #require(await events.next() == .nativeStartEntered(stream: 1))
                let stop = try #require(owner.stopDiagnosticCapture())
                control.own(stop)
                let borrower = try #require(owner.stopDiagnosticCapture())
                control.own(borrower)
                #expect(owner.hasOwnedDiagnosticCapture)
                #expect(owner.requestDiagnosticCapture() == nil)
                control.releaseHeldStops()
                _ = await start.result
                try await stop.value
                try await borrower.value
                #expect(!owner.hasUnreleasedResources)
                #expect(!old.running)
                #expect(old.startCalls == 1)
                #expect(old.stopCalls == 1)
            }
        }
    }

    @Test(arguments: [1, 2])
    func failedVisualTestStopRetainsItsLeaseAndExplicitRetryIsOncePerRequest(failures: Int) async throws {
        try await withStopRetryFixture(failures: failures) { native, old, _, control in
            try await withDiagnosticCaptureOwner(native: native, control: control) { owner in
                let start = try #require(owner.requestDiagnosticCapture())
                control.own(start)
                try await start.value
                #expect(owner.hasOwnedDiagnosticCapture)
                for attempt in 1...failures {
                    let stop = try #require(owner.stopDiagnosticCapture())
                    control.own(stop)
                    #expect((await stop.result).isFailure)
                    #expect(owner.hasUnreleasedResources)
                    #expect(owner.diagnosticCaptureError != nil)
                    #expect(owner.requestDiagnosticCapture() == nil)
                    #expect(old.running)
                    #expect(old.stopCalls == attempt)
                }
                let retry = try #require(owner.stopDiagnosticCapture())
                control.own(retry)
                try await retry.value
                #expect(!owner.hasUnreleasedResources)
                #expect(owner.diagnosticCaptureError == nil)
                #expect(!old.running)
                #expect(old.stopCalls == failures + 1)
                #expect(owner.stopDiagnosticCapture() == nil)
            }
        }
    }

    @Test
    func releasedDiagnosticLeaseCannotStopAnIndependentReplacement() async throws {
        try await withStopRetryFixture { native, old, replacement, control in
            try await withDiagnosticCaptureOwner(native: native, control: control) { owner in
                let start = try #require(owner.requestDiagnosticCapture())
                control.own(start)
                try await start.value
                let failed = try #require(owner.stopDiagnosticCapture())
                control.own(failed)
                #expect((await failed.result).isFailure)
                let external = native.stopSystemAudioCapture()
                control.own(external)
                try await native.finishStoppingSystemAudioCapture(capturedStop: external)
                try await native.startSystemAudioCapture()
                native.receiveAudioSampleBuffer(try stopRetrySample(), from: replacement)
                native.lastError = "synthetic replacement independent of visual test"
                let retry = try #require(owner.stopDiagnosticCapture())
                control.own(retry)
                try await retry.value
                #expect(!owner.hasUnreleasedResources)
                #expect(!old.running)
                #expect(old.stopCalls == 2)
                #expect(replacement.running)
                #expect(replacement.stopCalls == 0)
                #expect(native.lastError == "synthetic replacement independent of visual test")
            }
        }
    }

    @Test
    func synchronousDiagnosticPublicationCanCloseAdmissionBeforeStartupTaskCreation() async throws {
        try await withStopRetryFixture(failures: 0) { native, old, _, control in
            try await withDiagnosticCaptureOwner(native: native, control: control) { owner in
                var reentered = false
                let subscription = owner.objectWillChange.sink {
                    guard !reentered else { return }
                    reentered = true
                    owner.closeAdmission()
                }
                defer { subscription.cancel() }
                #expect(owner.requestDiagnosticCapture() == nil)
                #expect(reentered)
                try await owner.shutdown()
                #expect(!owner.hasUnreleasedResources)
                #expect(!owner.canStartDiagnosticCapture)
                #expect(old.startCalls == 0)
                #expect(old.stopCalls == 0)
            }
        }
    }

    @Test
    func preparingASRCaptureDrainsTheVisualTestAndPreservesFailedNativeOwnership() async throws {
        try await withStopRetryFixture { native, old, _, control in
            try await withDiagnosticCaptureOwner(native: native, control: control) { owner in
                let start = try #require(owner.requestDiagnosticCapture())
                control.own(start)
                try await start.value
                var rejected = false
                do { try await owner.finishPreparingForCapture() }
                catch { rejected = true }
                #expect(rejected)
                #expect(owner.hasUnreleasedResources)
                #expect(old.running)
                #expect(old.stopCalls == 1)
                // Preparation is a join, never an implicit failed-stop retry.
                do { try await owner.finishPreparingForCapture() }
                catch { rejected = true }
                #expect(old.stopCalls == 1)
                let stop = try #require(owner.stopDiagnosticCapture())
                control.own(stop)
                try await stop.value
                try await owner.finishPreparingForCapture()
                #expect(!owner.hasUnreleasedResources)
                #expect(!old.running)
                #expect(old.stopCalls == 2)
            }
        }
    }

    @Test
    func completedInitialCloseFailureIsJoinedBeforeAnyLaterShutdownRetry() async throws {
        try await withStopRetryFixture { native, old, _, control in
            try await withDiagnosticCaptureOwner(native: native, control: control) { owner in
                let start = try #require(owner.requestDiagnosticCapture())
                control.own(start)
                try await start.value
                owner.closeAdmission()
                let close = try #require(owner.stopDiagnosticCapture())
                control.own(close)
                #expect((await close.result).isFailure)
                #expect(old.stopCalls == 1)
                var firstFailed = false
                do { try await owner.shutdown() }
                catch { firstFailed = true }
                #expect(firstFailed)
                #expect(owner.hasUnreleasedResources)
                #expect(old.running)
                #expect(old.stopCalls == 1,
                    "A stop which failed after admission closed must not be implicitly retried in that first shutdown")
                try await owner.shutdown()
                #expect(!owner.hasUnreleasedResources)
                #expect(!old.running)
                #expect(old.stopCalls == 2)
            }
        }
    }

    @Test
    func failureObservedBeforeCloseCanBeRetriedOnceByThatExplicitShutdown() async throws {
        try await withStopRetryFixture(failures: 2) { native, old, _, control in
            try await withDiagnosticCaptureOwner(native: native, control: control) { owner in
                let start = try #require(owner.requestDiagnosticCapture())
                control.own(start)
                try await start.value
                let stop = try #require(owner.stopDiagnosticCapture())
                control.own(stop)
                #expect((await stop.result).isFailure)
                owner.closeAdmission()
                var rejected = false
                do { try await owner.shutdown() } catch { rejected = true }
                #expect(rejected)
                #expect(owner.hasUnreleasedResources)
                #expect(old.running)
                #expect(old.stopCalls == 2)
                try await owner.shutdown()
                #expect(!owner.hasUnreleasedResources)
                #expect(!old.running)
                #expect(old.stopCalls == 3)
            }
        }
    }

    @Test
    func concurrentShutdownBorrowersJoinTheSameHeldExplicitNativeRetry() async throws {
        try await withStopRetryFixture(holdSecondStop: true) { native, old, _, control in
            try await withDiagnosticCaptureOwner(native: native, control: control) { owner in
                var events = control.events.makeAsyncIterator()
                let start = try #require(owner.requestDiagnosticCapture())
                control.own(start)
                try await start.value
                let stop = try #require(owner.stopDiagnosticCapture())
                control.own(stop)
                #expect((await stop.result).isFailure)
                try #require(await events.next() == .nativeStopEntered(stream: 1, attempt: 1))
                let shutdown = Task { @MainActor in try await owner.shutdown() }
                control.own(shutdown)
                try #require(await events.next() == .nativeStopEntered(stream: 1, attempt: 2))
                let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
                let borrower = Task { @MainActor in
                    entered.continuation.yield(())
                    entered.continuation.finish()
                    try await owner.shutdown()
                }
                control.own(borrower)
                var arrivals = entered.stream.makeAsyncIterator()
                try #require(await arrivals.next() != nil)
                #expect(owner.hasUnreleasedResources)
                #expect(old.stopCalls == 2)
                control.releaseHeldStops()
                try await shutdown.value
                try await borrower.value
                #expect(!owner.hasUnreleasedResources)
                #expect(!old.running)
                #expect(old.stopCalls == 2)
            }
        }
    }

    @Test(arguments: [0, 1])
    func actualAppShutdownJoinsItsInjectedVisualTestAndCanRetryARecordedFailure(failures: Int) async throws {
        try await withStopRetryFixture(failures: failures) { native, old, _, control in
            let environment = try await HirevaTestEnvironment(prefix: "PermissionVisualCaptureAppShutdown",
                systemAudioCaptureService: native)
            do {
                let owner = environment.appState.systemAudioPermissions
                let start = try #require(owner.requestDiagnosticCapture())
                control.own(start)
                try await start.value
                #expect(old.running)
                let released = await environment.appState.shutdownResources()
                #expect(released == (failures == 0))
                #expect(old.stopCalls == 1)
                if failures > 0 {
                    #expect(owner.hasUnreleasedResources)
                    #expect(old.running)
                    #expect(await environment.appState.shutdownResources())
                    #expect(old.stopCalls == 2)
                }
                #expect(!owner.hasUnreleasedResources)
                #expect(!old.running)
                #expect(owner.requestDiagnosticCapture() == nil)
                try await environment.shutdown()
            } catch {
                control.allowFutureStopsAndRelease()
                try? await environment.shutdown()
                throw error
            }
        }
    }
}

/// Current native terminal API regression. Only controlled protocol streams
/// are created; the callback is issued on an owned non-UI dispatch queue.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct SystemAudioTerminalCallbackReentryTests {
    @Test(arguments: [false, true])
    func terminalCallbackCannotCancelTheReplacementSubmittedByItsObserver(reenterFromErrorPublisher: Bool) async throws {
        try await withStopRetryFixture(failures: 0) { native, old, replacement, control in
            let callbackQueue = DispatchQueue(label: "Hireva.tests.owned-terminal-callback")
            let delivery = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
            var replacementStart: (receipt: SystemAudioCaptureStopReceipt, startup: Task<Void, Error>)?
            var submitted = false
            @MainActor func submitReplacement() {
                guard !submitted else { return }
                submitted = true
                let owned = native.beginSystemAudioCapture()
                replacementStart = owned
                control.own(owned.startup)
                delivery.continuation.yield(())
                delivery.continuation.finish()
            }
            let receiver = TerminalReentryReceiver { _ in
                if !reenterFromErrorPublisher { submitReplacement() }
            }
            native.register(receiver)
            let observer = native.lastErrorUpdates.dropFirst().sink { error in
                if reenterFromErrorPublisher, error?.contains("synthetic current native terminal") == true {
                    submitReplacement()
                }
            }
            @MainActor func finishOwnedCallback() async {
                await withCheckedContinuation { continuation in
                    callbackQueue.async { continuation.resume() }
                }
            }
            do {
                let original = native.beginSystemAudioCapture()
                control.own(original.startup)
                try await native.finishStartingSystemAudioCapture(
                    capturedStart: original.startup, capturedReceipt: original.receipt)
                callbackQueue.async {
                    native.receiveStreamFailure(NSError(domain: "Hireva.SyntheticTerminalReentry", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "synthetic current native terminal"]), from: old)
                }
                var events = delivery.stream.makeAsyncIterator()
                try #require(await events.next() != nil)
                let newCapture = try #require(replacementStart)
                var succeeded = false
                do {
                    try await native.finishStartingSystemAudioCapture(
                        capturedStart: newCapture.startup, capturedReceipt: newCapture.receipt)
                    succeeded = true
                } catch {}
                #expect(succeeded,
                    "An old failure callback must not cancel the newer pending capture submitted by its synchronous observer")
                #expect(old.stopCalls == 1)
                #expect(!old.running)
                #expect(replacement.startCalls == 1)
                #expect(replacement.stopCalls == 0)
                #expect(replacement.running)
                #expect(native.isCapturing)
                #expect(native.lastError == nil, "A replacement clears the retired terminal diagnostic")
                #expect(receiver.failureCount == (reenterFromErrorPublisher ? 0 : 1),
                    "Old failure delivery must stop once an observer has adopted a new receipt")
                await finishOwnedCallback()
            } catch {
                control.allowFutureStopsAndRelease()
                observer.cancel()
                native.unregister(receiver)
                delivery.continuation.finish()
                await finishOwnedCallback()
                throw error
            }
            observer.cancel()
            native.unregister(receiver)
            delivery.continuation.finish()
        }
    }
}

@MainActor
private final class TerminalReentryReceiver: SystemAudioBufferDelegate {
    private let action: @MainActor (Error) -> Void
    private(set) var failureCount = 0
    init(action: @escaping @MainActor (Error) -> Void) { self.action = action }
    nonisolated func systemAudioCaptureService(_ service: ScreenCaptureKitSystemAudioCaptureService,
        didReceive buffer: AVAudioPCMBuffer, at time: AVAudioTime) {}
    func systemAudioCaptureService(_ service: ScreenCaptureKitSystemAudioCaptureService,
        didFailWithError error: Error) {
        failureCount += 1
        action(error)
    }
}

/// Requests admitted synchronously by callbacks supersede the outer request.
/// Every returned startup/stop handle is retained and joined by the fixture.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct SystemAudioRequestPublicationReentryTests {
    @Test
    func errorClearObserverCannotHaveItsNewerStartupOverwrittenByTheOuterRequest() async throws {
        try await withStopRetryFixture(failures: 0) { native, firstNative, unusedNative, control in
            native.lastError = "synthetic earlier capture error"
            var nested: (receipt: SystemAudioCaptureStopReceipt, startup: Task<Void, Error>)?
            var fired = false
            let observation = native.lastErrorUpdates.dropFirst().sink { value in
                guard !fired, value == nil else { return }
                fired = true
                let submitted = native.beginSystemAudioCapture()
                nested = submitted
                control.own(submitted.startup)
            }
            defer { observation.cancel() }
            let outer = native.beginSystemAudioCapture()
            control.own(outer.startup)
            let newer = try #require(nested)
            var outerSucceeded = false
            var newerSucceeded = false
            do { try await native.finishStartingSystemAudioCapture(capturedStart: outer.startup,
                capturedReceipt: outer.receipt); outerSucceeded = true } catch {}
            do { try await native.finishStartingSystemAudioCapture(capturedStart: newer.startup,
                capturedReceipt: newer.receipt); newerSucceeded = true } catch {}
            #expect(fired)
            #expect(!outerSucceeded, "The superseded request must not acquire or publish native capture")
            #expect(newerSucceeded, "Error-clear callbacks run after the outer startup has a cancellable exact owner")
            #expect(firstNative.startCalls == 1 && firstNative.running)
            #expect(unusedNative.startCalls == 0 && unusedNative.stopCalls == 0)
            #expect(native.isCapturing && native.lastError == nil)
        }
    }

    @Test
    func stopObserverCanSubmitAReplacementWithoutChangingTheReturnedOldStopReceipt() async throws {
        try await withStopRetryFixture(failures: 0) { native, old, replacement, control in
            let original = native.beginSystemAudioCapture()
            control.own(original.startup)
            try await native.finishStartingSystemAudioCapture(capturedStart: original.startup,
                capturedReceipt: original.receipt)
            native.receiveAudioSampleBuffer(try stopRetrySample(), from: old)
            var nested: (receipt: SystemAudioCaptureStopReceipt, startup: Task<Void, Error>)?
            var fired = false
            let observation = native.isCapturingUpdates.dropFirst().sink { capturing in
                guard !fired, !capturing else { return }
                fired = true
                let submitted = native.beginSystemAudioCapture()
                nested = submitted
                control.own(submitted.startup)
            }
            defer { observation.cancel() }
            let capturedStop = native.stopSystemAudioCaptureAndReturnReceipt()
            control.own(capturedStop.task)
            let newer = try #require(nested)
            #expect(capturedStop === original.receipt,
                "Native stop identity/task admission must precede synchronous stopped-state observers")
            #expect(capturedStop !== newer.receipt)
            var oldStopped = false
            var newerSucceeded = false
            do { try await native.finishStoppingSystemAudioCapture(capturedReceipt: capturedStop); oldStopped = true } catch {}
            do { try await native.finishStartingSystemAudioCapture(capturedStart: newer.startup,
                capturedReceipt: newer.receipt); newerSucceeded = true } catch {}
            #expect(oldStopped && newerSucceeded)
            #expect(old.stopCalls == 1 && !old.running)
            #expect(replacement.startCalls == 1 && replacement.stopCalls == 0 && replacement.running)
            #expect(native.isCapturing)
        }
    }
}

/// Actual capture Bool publication: nested submission is held at the native
/// startup seam, so the assertion checks a pending replacement, not a sleep.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct SystemAudioCaptureBoolPublicationTests {
    @Test
    func capturingObserverCannotRestoreTrueOverItsPendingReplacement() async throws {
        try await withStopRetryFixture(failures: 0, holdStartForStream: 2) { native, old, replacement, control in
            var events = control.events.makeAsyncIterator()
            var replacementStart: (receipt: SystemAudioCaptureStopReceipt, startup: Task<Void, Error>)?
            var reentered = false
            var storedTrueAtPublication: Bool?
            let observer = native.isCapturingUpdates.dropFirst().sink { capturing in
                guard capturing, !reentered else { return }
                reentered = true
                storedTrueAtPublication = native.isCapturing
                let owned = native.beginSystemAudioCapture()
                replacementStart = owned
                control.own(owned.startup)
            }
            defer { observer.cancel() }
            let original = native.beginSystemAudioCapture()
            control.own(original.startup)
            _ = await original.startup.result
            try #require(reentered)
            try #require(await events.next() == .nativeStopEntered(stream: 1, attempt: 1))
            try #require(await events.next() == .nativeStartEntered(stream: 2))
            let owned = try #require(replacementStart)
            #expect(storedTrueAtPublication == true,
                "Synchronous observers must read the committed capture value")
            #expect(!native.isCapturing,
                "The retiring true publication cannot overwrite a newer pending capture's false state")
            #expect(!old.running && replacement.running)
            #expect(old.stopCalls == 1 && replacement.stopCalls == 0)
            control.releaseHeldStops()
            try await native.finishStartingSystemAudioCapture(capturedStart: owned.startup, capturedReceipt: owned.receipt)
            #expect(native.isCapturing)
        }
    }
}

/// The timestamp observer synchronously adopts a replacement while the old
/// display callback is publishing. Every captured task uses the fixture owner.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct SystemAudioDisplayTransactionReentryTests {
    @Test
    func oldDisplayCannotContinueWritingMetadataAfterObserverAdoptsAnotherCapture() async throws {
        try await withStopRetryFixture(failures: 0, holdStartForStream: 2) { native, old, replacement, control in
            let delivered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
            var replacementStart: (receipt: SystemAudioCaptureStopReceipt, startup: Task<Void, Error>)?
            var committedCountAtTimestamp: Int?
            var valuesAfterReplacementSubmission: [Double]?
            let observer = native.lastBufferReceivedAtUpdates.dropFirst().sink { receivedAt in
                guard receivedAt != nil, replacementStart == nil else { return }
                committedCountAtTimestamp = native.totalBuffersReceived
                let owned = native.beginSystemAudioCapture()
                replacementStart = owned
                control.own(owned.startup)
                valuesAfterReplacementSubmission = numericDisplayValues(native)
                delivered.continuation.yield(())
                delivered.continuation.finish()
            }
            defer { observer.cancel(); delivered.continuation.finish() }
            let initial = native.beginSystemAudioCapture()
            control.own(initial.startup)
            try await native.finishStartingSystemAudioCapture(capturedStart: initial.startup, capturedReceipt: initial.receipt)
            native.receiveAudioSampleBuffer(try stopRetrySample(), from: old)
            try await withTaskCancellationHandler {
                var events = control.events.makeAsyncIterator()
                var arrivals = delivered.stream.makeAsyncIterator()
                try #require(await arrivals.next() != nil)
                try #require(await events.next() == .nativeStopEntered(stream: 1, attempt: 1))
                try #require(await events.next() == .nativeStartEntered(stream: 2))
                #expect(committedCountAtTimestamp == 1,
                    "Timestamp publication must expose the entire committed numeric snapshot")
                #expect(numericDisplayValues(native) == valuesAfterReplacementSubmission,
                    "No remaining old numeric setter may execute after a new capture was submitted")
                #expect(!old.running && replacement.running)
                let owned = try #require(replacementStart)
                control.releaseHeldStops()
                try await native.finishStartingSystemAudioCapture(capturedStart: owned.startup, capturedReceipt: owned.receipt)
            } onCancel: { delivered.continuation.finish() }
        }
    }
}

@MainActor
private func numericDisplayValues(_ native: ScreenCaptureKitSystemAudioCaptureService) -> [Double] {
    [Double(native.totalBuffersReceived), native.sampleRate, Double(native.channelCount),
     Double(native.lastBufferFrameCapacity), native.rmsLevel, native.decibels]
}

/// Native authority controls this shared-to-Live boundary. The old Boolean
/// intentionally stays true after a separate caller replaces the exact stream.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct AppSystemAudioExactErrorOwnerTests {
    @Test(arguments: [0, 1, 2], [false, true])
    func actualConcreteOwnerControlsSharedErrorAdmission(kind: Int, externallyReplaced: Bool) async throws {
        try await runSharedErrorCase(kind: kind, externallyReplaced: externallyReplaced, nativeCallback: false)
    }

    @Test(arguments: [0, 1, 2])
    func foreignCurrentNativeFailureCannotStopOrFailTheOldLiveRuntime(kind: Int) async throws {
        try await runSharedErrorCase(kind: kind, externallyReplaced: true, nativeCallback: true)
    }

    private func runSharedErrorCase(kind: Int, externallyReplaced: Bool, nativeCallback: Bool) async throws {
        try await withStopRetryFixture(failures: 0) { native, old, replacement, control in
            let environment = try await HirevaTestEnvironment(prefix: "ExactSharedAudioErrorOwner",
                systemAudioCaptureService: native)
            let app = environment.appState
            let speech = stopRetryAppleSpeechService(native: native)
            let parakeet = stopRetryParakeetProvider(service: native, runtime: StopRetryParakeetRuntime())
            let appleProvider = AppleSpeechASRProvider(service: speech)
            var retainedStream: AsyncThrowingStream<TranscriptSegment, Error>?
            let marker = "synthetic exact owner diagnostic"
            let delivered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
            let callbackQueue = DispatchQueue(label: "Hireva.tests.exact-error-owner")
            @MainActor func joinCallbackQueue() async {
                await withCheckedContinuation { continuation in callbackQueue.async { continuation.resume() } }
            }
            do {
                switch kind {
                case 0:
                    try await speech.start(sessionID: "synthetic-owned-Apple-live", captureMode: .systemAudioOnly)
                    app.appleSpeechService = speech
                    app.activeTranscriptionProvider = speech
                case 1:
                    retainedStream = try await parakeet.startTranscription(config: .init(
                        sessionID: "synthetic-owned-Parakeet-live", captureMode: .systemAudioOnly))
                    app.activeASRProviderRuntime = parakeet
                default:
                    retainedStream = try await appleProvider.startTranscription(config: .init(
                        sessionID: "synthetic-owned-Apple-provider-live", captureMode: .systemAudioOnly))
                    app.activeASRProviderRuntime = appleProvider
                }
                native.receiveAudioSampleBuffer(try stopRetrySample(), from: old)
                #expect(old.running)
                // Prevent the deliberately external resource handoff itself
                // from being a user-visible Live stream-end operation. The
                // tested callbacks occur after Live returns to listening.
                app.currentCaptureRuntimeState = .idle
                app.markSystemAudioCaptureRuntimeOwnedForTesting(true)
                if externallyReplaced {
                    let oldStop = native.stopSystemAudioCapture()
                    control.own(oldStop)
                    try await native.finishStoppingSystemAudioCapture(capturedStop: oldStop)
                    let foreign = native.beginSystemAudioCapture()
                    control.own(foreign.startup)
                    try await native.finishStartingSystemAudioCapture(capturedStart: foreign.startup,
                        capturedReceipt: foreign.receipt)
                    native.receiveAudioSampleBuffer(try stopRetrySample(), from: replacement)
                    #expect(replacement.running)
                    #expect(!old.running)
                }
                app.currentCaptureRuntimeState = .listening
                app.systemAudioErrorDidObserve = { incoming in
                    guard incoming?.contains(marker) == true else { return }
                    delivered.continuation.yield(())
                    delivered.continuation.finish()
                }
                try await withTaskCancellationHandler {
                    if nativeCallback {
                        callbackQueue.async {
                            native.receiveStreamFailure(NSError(domain: "Hireva.SyntheticExactErrorOwner", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: marker]), from: replacement)
                        }
                    } else { native.lastError = marker }
                    var delivery = delivered.stream.makeAsyncIterator()
                    try #require(await delivery.next() != nil)
                    #expect(app.currentCaptureRuntimeState == (externallyReplaced ? .listening : .error(reason: marker)),
                        "Only the concrete current receipt may change Live; the old compatibility flag grants no authority")
                    #expect(app.stopReason == nil)
                } onCancel: { delivered.continuation.finish() }
                app.systemAudioErrorDidObserve = nil
                delivered.continuation.finish()
                await joinCallbackQueue()
                try await environment.shutdown()
                withExtendedLifetime(retainedStream) {}
            } catch {
                control.allowFutureStopsAndRelease()
                app.systemAudioErrorDidObserve = nil
                delivered.continuation.finish()
                await joinCallbackQueue()
                await parakeet.stopTranscription()
                await appleProvider.stopTranscription()
                speech.stop(); await speech.finishStoppingAudioInput()
                try? await environment.shutdown()
                throw error
            }
        }
    }
}

/// The actual Parakeet provider remains active while another caller replaces
/// its native capture. Runtime counters observe real receiver append calls.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct SystemAudioDelegateReceiptAdmissionTests {
    @Test(arguments: [false, true])
    func externalReplacementCannotDeliverPCMOrTerminalFailureToTheOldProvider(includeTerminal: Bool) async throws {
        try await withStopRetryFixture(failures: 0) { native, old, replacement, control in
            let runtime = StopRetryParakeetRuntime()
            let provider = stopRetryParakeetProvider(service: native, runtime: runtime)
            let terminalPublished = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
            let observer = native.lastErrorUpdates.dropFirst().sink { error in
                guard error?.contains("synthetic foreign delegate admission") == true else { return }
                terminalPublished.continuation.yield(())
                terminalPublished.continuation.finish()
            }
            defer { observer.cancel(); terminalPublished.continuation.finish() }
            do {
                try await withTaskCancellationHandler {
                    _ = try await provider.startTranscription(config: .init(sessionID: "synthetic-owned-delegate",
                        captureMode: .systemAudioOnly))
                    native.receiveAudioSampleBuffer(try stopRetrySample(), from: old)
                    #expect(runtime.appendedBufferCount == 1,
                        "The controlled sample must actually reach this provider before replacement")
                    let retired = native.stopSystemAudioCaptureAndReturnReceipt()
                    control.own(retired.task)
                    try await native.finishStoppingSystemAudioCapture(capturedReceipt: retired)
                    let newer = native.beginSystemAudioCapture()
                    control.own(newer.startup)
                    try await native.finishStartingSystemAudioCapture(capturedStart: newer.startup, capturedReceipt: newer.receipt)
                    native.receiveAudioSampleBuffer(try stopRetrySample(), from: replacement)
                    #expect(runtime.appendedBufferCount == 1,
                        "Same service identity is not authority to append a foreign capture epoch to the old ASR round")
                    #expect(provider.hasHealthyCaptureSource)
                    #expect(provider.captureSourceFailures.isEmpty)
                    if includeTerminal {
                        native.receiveStreamFailure(NSError(domain: "Hireva.SyntheticDelegateAdmission", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "synthetic foreign delegate admission"]), from: replacement)
                        var events = terminalPublished.stream.makeAsyncIterator()
                        try #require(await events.next() != nil)
                        try await native.finishStoppingSystemAudioCapture(capturedReceipt: newer.receipt)
                        #expect(provider.captureSourceFailures.isEmpty,
                            "A foreign terminal event must not revoke the retained old provider's source")
                        #expect(provider.hasHealthyCaptureSource)
                    } else {
                        #expect(replacement.running && replacement.stopCalls == 0)
                    }
                    await provider.stopTranscription()
                    #expect(!provider.hasOwnedTranscriptionWork)
                    #expect(!runtime.running)
                } onCancel: { terminalPublished.continuation.finish() }
            } catch { await provider.stopTranscription(); throw error }
        }
    }
}

/// Actual helper stop policy. Native start/stop uses the existing exact
/// controlled streams; parent cancellation owns every blocked fixture handle.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct PermissionProbeRetainedRetryOwnershipTests {
    @Test(arguments: [false, true])
    func stopSubmittedDuringStartupMustReportItsFirstFailedCleanupWithoutRetry(concurrentBorrower: Bool) async throws {
        try await withStopRetryFixture(failures: 1, holdStartForStream: 1) { _, old, _, control in
            let helper = StreamAudioProbeHelper()
            var probeResult: Bool?
            let probe: Task<Void, Error> = Task { @MainActor in
                probeResult = await helper.runProbe(makeStream: { old })
            }
            control.own(probe)
            let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(2))
            var stoppers: [Task<Void, Error>] = []
            @MainActor func cleanup() async {
                control.allowFutureStopsAndRelease()
                entered.continuation.finish()
                probe.cancel()
                _ = await probe.result
                for stopper in stoppers { _ = await stopper.result }
                try? await helper.stop()
            }
            do {
                try await withTaskCancellationHandler {
                    var events = control.events.makeAsyncIterator()
                    try #require(await events.next() == .nativeStartEntered(stream: 1))
                    let callers = concurrentBorrower ? 2 : 1
                    for _ in 0..<callers {
                        let stop = Task { @MainActor in
                            entered.continuation.yield(())
                            try await helper.stop()
                        }
                        control.own(stop)
                        stoppers.append(stop)
                    }
                    var arrivals = entered.stream.makeAsyncIterator()
                    for _ in 0..<callers { try #require(await arrivals.next() != nil) }
                    control.releaseHeldStops()
                    for stopper in stoppers {
                        #expect((await stopper.result).isFailure,
                            "This submission joins the cleanup which first failed during its startup await")
                    }
                    try await probe.value
                    #expect(probeResult == false)
                    #expect(helper.hasUnreleasedStream)
                    #expect(old.running)
                    #expect(old.stopCalls == 1,
                        "Neither the original waiting Stop nor its concurrent borrower may implicitly issue native attempt two")
                    try await helper.stop()
                    #expect(!helper.hasUnreleasedStream)
                    #expect(!old.running && old.stopCalls == 2)
                } onCancel: { entered.continuation.finish() }
            } catch { await cleanup(); throw error }
            await cleanup()
        }
    }

    @Test
    func borrowersOfOneObservedFailureJoinTheSameRetryAndCannotAuthorizeAnotherAttempt() async throws {
        try await withStopRetryFixture(failures: 2, holdSecondStop: true) { _, old, _, control in
            let helper = StreamAudioProbeHelper()
            #expect(!(await helper.runProbe(makeStream: { old })))
            var retry: Task<Void, Error>?
            let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
            var borrower: Task<Void, Error>?
            @MainActor func cleanup() async {
                control.allowFutureStopsAndRelease()
                entered.continuation.finish()
                _ = await retry?.result
                _ = await borrower?.result
                try? await helper.stop()
            }
            do {
                try await withTaskCancellationHandler {
                    var events = control.events.makeAsyncIterator()
                    try #require(await events.next() == .nativeStopEntered(stream: 1, attempt: 1))
                    let submittedRetry = Task { @MainActor in try await helper.stop() }
                    retry = submittedRetry
                    control.own(submittedRetry)
                    try #require(await events.next() == .nativeStopEntered(stream: 1, attempt: 2))
                    let join = Task { @MainActor in
                        entered.continuation.yield(())
                        try await helper.stop()
                    }
                    borrower = join
                    control.own(join)
                    var arrivals = entered.stream.makeAsyncIterator()
                    try #require(await arrivals.next() != nil)
                    #expect(old.stopCalls == 2)
                    control.releaseHeldStops()
                    #expect((await submittedRetry.result).isFailure)
                    #expect((await join.result).isFailure)
                    #expect(helper.hasUnreleasedStream && old.running)
                    #expect(old.stopCalls == 2)
                    try await helper.stop()
                    #expect(old.stopCalls == 3 && !old.running)
                    #expect(!helper.hasUnreleasedStream)
                    try await helper.stop()
                    #expect(old.stopCalls == 3, "Released capture is idempotent")
                } onCancel: { entered.continuation.finish() }
            } catch { await cleanup(); throw error }
            await cleanup()
        }
    }

    // Mixed seam regression: root stages only output-removal injection first.
    // Native stop and releaseOwnedStream are the real production methods.
    @Test(arguments: [false, true])
    func acknowledgedNativeStopIsNotRepeatedWhenOnlyOutputRemovalNeedsRetry(failedScreenOutput: Bool) async throws {
        let failedOutput: SCStreamOutputType = failedScreenOutput ? .screen : .audio
        try await withStopRetryFixture(failures: 0) { _, old, _, _ in
            var failedOnce = false
            var audioRemovals = 0
            var screenRemovals = 0
            let helper = StreamAudioProbeHelper(registeredOutputsForTesting: [.audio, .screen],
                removeOutputForTesting: { source, type in
                    #expect(source.callbackIdentity == old.callbackIdentity)
                    if type == .audio { audioRemovals += 1 } else { screenRemovals += 1 }
                    if type == failedOutput, !failedOnce {
                        failedOnce = true
                        throw StopRetryFailure.outputRemovalRejected
                    }
                })
            do {
                #expect(!(await helper.runProbe(makeStream: { old })))
                #expect(helper.hasUnreleasedStream)
                #expect(!old.running && old.stopCalls == 1)
                try await helper.stop()
                #expect(!helper.hasUnreleasedStream)
                #expect(old.stopCalls == 1,
                    "A successful native stop remains acknowledged while output removal is retried")
                #expect(audioRemovals == (failedOutput == .audio ? 2 : 1))
                #expect(screenRemovals == (failedOutput == .screen ? 2 : 1))
            } catch {
                try? await helper.stop()
                throw error
            }
            try await helper.stop()
        }
    }
}

/// Real wrapper/controller methods; only native I/O and helper construction
/// are injected. The wrapper constructor is the sole mixed seam in this group.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct PermissionProbeUpperCurrentAPITests {
    @Test
    func sharedWrapperDefaultDrainCannotRetryAnObservedNativeFailure() async throws {
        try await withStopRetryFixture { _, old, _, control in
            let helper = StreamAudioProbeHelper()
            let wrapper = ScreenSystemAudioPermissionProbe(streamProbeForTesting: helper)
            #expect(!(await helper.runProbe(makeStream: { old })))
            #expect(helper.hasUnreleasedStream && old.running && old.stopCalls == 1)
            let drain = Task { @MainActor in try await wrapper.finishStoppingProbe() }
            control.own(drain)
            #expect((await drain.result).isFailure,
                "A handoff joins the first failure rather than authorizing native attempt two")
            #expect(helper.hasUnreleasedStream && old.running)
            #expect(old.stopCalls == 1)
            control.allowFutureStopsAndRelease()
            try await helper.stop()
            try await wrapper.finishStoppingProbe()
            #expect(!helper.hasUnreleasedStream)
        }
    }

    @Test
    func controllerCancellationWorkerAndRetirementCannotRetryTheirLateFirstNativeFailure() async throws {
        try await withStopRetryFixture(failures: 1, holdStartForStream: 1) { _, old, _, control in
            let helper = StreamAudioProbeHelper()
            let wrapper = ScreenSystemAudioPermissionProbe(streamProbeForTesting: helper)
            let permissions = HermeticPermissionService()
            let owner = SystemAudioPermissionController(permissions: permissions, probe: {
                let succeeded = await helper.runProbe(makeStream: { old })
                return .init(preflightGranted: true, shareableContentProbeSucceeded: true,
                    streamAudioProbeSucceeded: succeeded, errorDescription: helper.lastFailureDescription,
                    likelyIdentityMismatch: false)
            }, stopProbe: { try await wrapper.finishStoppingProbe() })
            let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
            let probe: Task<Void, Error> = Task { @MainActor in
                let pending = try #require(owner.requestExplicitProbe())
                _ = try await pending.value
            }
            control.own(probe)
            var handoff: Task<Void, Error>?
            @MainActor func cleanup() async {
                control.allowFutureStopsAndRelease()
                entered.continuation.finish()
                owner.cancelProbe()
                _ = await probe.result
                _ = await handoff?.result
                // Test cleanup explicitly owns this exact helper. It is not an
                // automatic controller retry or native hardware evidence.
                try? await helper.stop()
                try? await owner.shutdown()
            }
            do {
                try await withTaskCancellationHandler {
                    var events = control.events.makeAsyncIterator()
                    try #require(await events.next() == .nativeStartEntered(stream: 1))
                    owner.cancelProbe()
                    let drain = Task { @MainActor in
                        entered.continuation.yield(())
                        try await owner.finishPreparingForCapture()
                    }
                    handoff = drain
                    control.own(drain)
                    var arrivals = entered.stream.makeAsyncIterator()
                    try #require(await arrivals.next() != nil)
                    control.releaseHeldStops()
                    #expect((await probe.result).isFailure)
                    #expect((await drain.result).isFailure)
                    #expect(owner.probeResult == nil)
                    #expect(owner.hasUnreleasedProbeResources)
                    #expect(helper.hasUnreleasedStream && old.running)
                    #expect(old.stopCalls == 1,
                        "Watcher, worker and retirement all join the same failed attempt")
                } onCancel: { entered.continuation.finish() }
            } catch { await cleanup(); throw error }
            await cleanup()
        }
    }

    // Current source-compatible callback contract; no native resource exists
    // here. This isolates the controller's permanent metadata latch defect.
    @Test
    func successfulExplicitShutdownRetiresThePreviouslyObservedProbeCleanupError() async throws {
        try await withStopRetryFixture(failures: 0) { _, _, _, control in
            let permissions = HermeticPermissionService()
            var stopMustFail = true
            var stops = 0
            let owner = SystemAudioPermissionController(permissions: permissions, probe: {
                .init(preflightGranted: true, shareableContentProbeSucceeded: true,
                    streamAudioProbeSucceeded: true, errorDescription: nil, likelyIdentityMismatch: false)
            }, stopProbe: {
                stops += 1
                if stopMustFail { throw StopRetryFailure.nativeStopRejected }
            })
            do {
                do { _ = try await owner.probeNow(); Issue.record("Observed cleanup must fail") }
                catch is StopRetryFailure {}
                #expect(stops == 1 && owner.hasUnreleasedProbeResources)
                stopMustFail = false
                let shutdown = Task { @MainActor in try await owner.shutdown() }
                control.own(shutdown)
                #expect(!(await shutdown.result).isFailure)
                #expect(stops == 2)
                #expect(owner.cleanupFailureDescription == nil)
                #expect(!owner.hasUnreleasedProbeResources)
                #expect(owner.requestExplicitProbe() == nil, "Successful cleanup does not reopen admission")
            } catch {
                stopMustFail = false
                try? await owner.shutdown()
                throw error
            }
            stopMustFail = false
            try? await owner.shutdown()
        }
    }
}

/// New typed retry-capability contract. These call the same production wrapper
/// and controller, with one controlled stream and exact helper per case.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct PermissionProbeExplicitShutdownOwnershipTests {
    @Test(arguments: [1, 2])
    func explicitShutdownAndItsBorrowerJoinOneRetryOfTheObservedProbeFailure(failures: Int) async throws {
        try await withStopRetryFixture(failures: failures, holdSecondStop: true) { _, old, _, control in
            let helper = StreamAudioProbeHelper()
            let wrapper = ScreenSystemAudioPermissionProbe(streamProbeForTesting: helper)
            let permissions = HermeticPermissionService()
            var retrySubmissions = 0
            let owner = SystemAudioPermissionController(permissions: permissions, probe: {
                let succeeded = await helper.runProbe(makeStream: { old })
                return .init(preflightGranted: true, shareableContentProbeSucceeded: true,
                    streamAudioProbeSucceeded: succeeded, errorDescription: helper.lastFailureDescription,
                    likelyIdentityMismatch: false)
            }, stopProbe: { retryFailedResource in
                if retryFailedResource { retrySubmissions += 1 }
                try await wrapper.finishStoppingProbe(retryFailedResource: retryFailedResource)
            })
            let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
            var callers: [Task<Void, Error>] = []
            @MainActor func cleanup() async {
                control.allowFutureStopsAndRelease()
                entered.continuation.finish()
                owner.closeAdmission()
                for task in callers { _ = await task.result }
                try? await helper.stop()
                try? await owner.shutdown()
            }
            do {
                try await withTaskCancellationHandler {
                    var events = control.events.makeAsyncIterator()
                    let probe: Task<Void, Error> = Task { @MainActor in _ = try await owner.probeNow() }
                    callers.append(probe)
                    control.own(probe)
                    #expect((await probe.result).isFailure)
                    try #require(await events.next() == .nativeStopEntered(stream: 1, attempt: 1))
                    #expect(helper.hasUnreleasedStream && old.running)
                    #expect(owner.cleanupFailureDescription != nil && owner.hasUnreleasedProbeResources)
                    #expect(old.stopCalls == 1 && retrySubmissions == 0)
                    let retry = Task { @MainActor in try await owner.shutdown() }
                    callers.append(retry)
                    control.own(retry)
                    try #require(await events.next() == .nativeStopEntered(stream: 1, attempt: 2))
                    let borrower = Task { @MainActor in
                        entered.continuation.yield(())
                        try await owner.shutdown()
                    }
                    callers.append(borrower)
                    control.own(borrower)
                    var arrivals = entered.stream.makeAsyncIterator()
                    try #require(await arrivals.next() != nil)
                    #expect(old.stopCalls == 2 && retrySubmissions == 1)
                    control.releaseHeldStops()
                    let retryResult = await retry.result
                    let borrowerResult = await borrower.result
                    #expect(retryResult.isFailure == (failures == 2))
                    #expect(borrowerResult.isFailure == (failures == 2))
                    #expect(old.stopCalls == 2 && retrySubmissions == 1,
                        "An in-flight shutdown borrower cannot authorize a third attempt")
                    if failures == 2 {
                        #expect(helper.hasUnreleasedStream && old.running)
                        #expect(owner.hasUnreleasedProbeResources && owner.cleanupFailureDescription != nil)
                        try await owner.shutdown()
                        #expect(old.stopCalls == 3 && retrySubmissions == 2)
                    }
                    #expect(!helper.hasUnreleasedStream && !old.running)
                    #expect(!owner.hasUnreleasedProbeResources && owner.cleanupFailureDescription == nil)
                    #expect(owner.requestExplicitProbe() == nil)
                    let nativeAttempts = old.stopCalls
                    try await owner.shutdown()
                    #expect(old.stopCalls == nativeAttempts, "Released native cleanup remains idempotent")
                } onCancel: { entered.continuation.finish() }
            } catch { await cleanup(); throw error }
            await cleanup()
        }
    }

    @Test
    func firstShutdownDuringStartupCannotReauthorizeTheFailureItLearnsWhileJoining() async throws {
        try await withStopRetryFixture(failures: 1, holdStartForStream: 1) { _, old, _, control in
            let helper = StreamAudioProbeHelper()
            let wrapper = ScreenSystemAudioPermissionProbe(streamProbeForTesting: helper)
            let permissions = HermeticPermissionService()
            var retrySubmissions = 0
            let owner = SystemAudioPermissionController(permissions: permissions, probe: {
                let succeeded = await helper.runProbe(makeStream: { old })
                return .init(preflightGranted: true, shareableContentProbeSucceeded: true,
                    streamAudioProbeSucceeded: succeeded, errorDescription: helper.lastFailureDescription,
                    likelyIdentityMismatch: false)
            }, stopProbe: { retryFailedResource in
                if retryFailedResource { retrySubmissions += 1 }
                try await wrapper.finishStoppingProbe(retryFailedResource: retryFailedResource)
            })
            let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(2))
            var callers: [Task<Void, Error>] = []
            @MainActor func cleanup() async {
                control.allowFutureStopsAndRelease()
                entered.continuation.finish()
                owner.closeAdmission()
                for task in callers { _ = await task.result }
                try? await helper.stop()
                try? await owner.shutdown()
            }
            do {
                try await withTaskCancellationHandler {
                    var events = control.events.makeAsyncIterator()
                    let probe: Task<Void, Error> = Task { @MainActor in _ = try await owner.probeNow() }
                    callers.append(probe)
                    control.own(probe)
                    try #require(await events.next() == .nativeStartEntered(stream: 1))
                    for _ in 0..<2 {
                        let shutdown = Task { @MainActor in
                            entered.continuation.yield(())
                            try await owner.shutdown()
                        }
                        callers.append(shutdown)
                        control.own(shutdown)
                    }
                    var arrivals = entered.stream.makeAsyncIterator()
                    for _ in 0..<2 { try #require(await arrivals.next() != nil) }
                    #expect(old.stopCalls == 0 && retrySubmissions == 0)
                    control.releaseHeldStops()
                    for task in callers { #expect((await task.result).isFailure) }
                    #expect(helper.hasUnreleasedStream && old.running)
                    #expect(owner.cleanupFailureDescription != nil && owner.hasUnreleasedProbeResources)
                    #expect(old.stopCalls == 1 && retrySubmissions == 0,
                        "Learning a first stop failure during shutdown is not an explicit retry submission")
                    try await owner.shutdown()
                    #expect(old.stopCalls == 2 && retrySubmissions == 1)
                    #expect(!helper.hasUnreleasedStream && !old.running)
                    #expect(!owner.hasUnreleasedProbeResources && owner.cleanupFailureDescription == nil)
                } onCancel: { entered.continuation.finish() }
            } catch { await cleanup(); throw error }
            await cleanup()
        }
    }

    @Test(arguments: [false, true])
    func explicitShutdownPreservesNativeStopAcknowledgementWhileRetryingOutputRemoval(failedScreenOutput: Bool) async throws {
        let failedOutput: SCStreamOutputType = failedScreenOutput ? .screen : .audio
        try await withStopRetryFixture(failures: 0) { _, old, _, control in
            var rejectedOutput = false
            var audioRemovals = 0
            var screenRemovals = 0
            let helper = StreamAudioProbeHelper(registeredOutputsForTesting: [.audio, .screen],
                removeOutputForTesting: { source, type in
                    #expect(source.callbackIdentity == old.callbackIdentity)
                    if type == .audio { audioRemovals += 1 } else { screenRemovals += 1 }
                    if type == failedOutput, !rejectedOutput {
                        rejectedOutput = true
                        throw StopRetryFailure.outputRemovalRejected
                    }
                })
            let wrapper = ScreenSystemAudioPermissionProbe(streamProbeForTesting: helper)
            let permissions = HermeticPermissionService()
            let owner = SystemAudioPermissionController(permissions: permissions, probe: {
                let succeeded = await helper.runProbe(makeStream: { old })
                return .init(preflightGranted: true, shareableContentProbeSucceeded: true,
                    streamAudioProbeSucceeded: succeeded, errorDescription: helper.lastFailureDescription,
                    likelyIdentityMismatch: false)
            }, stopProbe: { retryFailedResource in
                try await wrapper.finishStoppingProbe(retryFailedResource: retryFailedResource)
            })
            @MainActor func cleanup() async {
                control.allowFutureStopsAndRelease()
                owner.closeAdmission()
                try? await helper.stop()
                try? await owner.shutdown()
            }
            do {
                let probe: Task<Void, Error> = Task { @MainActor in _ = try await owner.probeNow() }
                control.own(probe)
                #expect((await probe.result).isFailure)
                #expect(helper.hasUnreleasedStream && !old.running && old.stopCalls == 1)
                #expect(owner.cleanupFailureDescription != nil && owner.hasUnreleasedProbeResources)
                try await owner.shutdown()
                #expect(!helper.hasUnreleasedStream && !owner.hasUnreleasedProbeResources)
                #expect(owner.cleanupFailureDescription == nil)
                #expect(old.stopCalls == 1,
                    "Controller retry releases remaining outputs rather than stopping an acknowledged native stream again")
                #expect(audioRemovals == (failedOutput == .audio ? 2 : 1))
                #expect(screenRemovals == (failedOutput == .screen ? 2 : 1))
            } catch { await cleanup(); throw error }
            await cleanup()
        }
    }
}

/// Projection regression with real receipt/start/stop/callback methods. The
/// read-only method is the only seam and delegates to the old owner rule for
/// RED. This is not a complete App receive(on:) or hardware/GUI reproduction.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct SystemAudioReleasedTerminalAttributionTests {
    @Test(arguments: [false, true])
    func releasedMostRecentReceiptRemainsAttributableAfterEitherActualJoin(compatibilityJoin: Bool) async throws {
        try await withStopRetryFixture(failures: 0) { service, old, _, control in
            let start = service.beginSystemAudioCapture()
            control.own(start.startup)
            try await service.finishStartingSystemAudioCapture(capturedStart: start.startup, capturedReceipt: start.receipt)
            #expect(service.isCurrentCaptureOwner(start.receipt))
            #expect(service.isMostRecentCaptureReceipt(start.receipt))
            let stop = service.stopSystemAudioCapture(capturedReceipt: start.receipt, retryFailed: false)
            control.own(stop.task)
            try await stop.task.value
            #expect(!old.running && old.stopCalls == 1)
            #expect(!service.hasOwnedCaptureRuntime && !service.isCurrentCaptureOwner(start.receipt))
            #expect(service.isMostRecentCaptureReceipt(start.receipt),
                "Native release ends resource authority, not attribution of this exact terminal signal")
            if compatibilityJoin {
                try await service.finishStoppingSystemAudioCapture(capturedStop: stop.task)
            } else {
                try await service.finishStoppingSystemAudioCapture(capturedReceipt: start.receipt)
            }
            #expect(service.isMostRecentCaptureReceipt(start.receipt),
                "Joining cleanup must not discard the most-recent epoch before queued terminal delivery")
            #expect(!service.hasOwnedCaptureRuntime && !service.isCurrentCaptureOwner(start.receipt))
            let buffers = service.totalBuffersReceived
            service.receiveAudioSampleBuffer(try stopRetrySample(), from: old)
            #expect(service.totalBuffersReceived == buffers && service.pendingDiagnosticUpdates == 0,
                "Terminal attribution never reopens PCM admission")
        }
    }

    @Test
    func pendingReplacementImmediatelyExcludesTheReleasedReceiptTerminalAttribution() async throws {
        try await withStopRetryFixture(failures: 0, holdStartForStream: 2) { service, old, replacement, control in
            var events = control.events.makeAsyncIterator()
            let first = service.beginSystemAudioCapture()
            control.own(first.startup)
            try await service.finishStartingSystemAudioCapture(capturedStart: first.startup, capturedReceipt: first.receipt)
            let stopped = service.stopSystemAudioCapture(capturedReceipt: first.receipt, retryFailed: false)
            control.own(stopped.task)
            try await service.finishStoppingSystemAudioCapture(capturedReceipt: first.receipt)
            try #require(await events.next() == .nativeStopEntered(stream: 1, attempt: 1))
            #expect(service.isMostRecentCaptureReceipt(first.receipt))
            let second = service.beginSystemAudioCapture()
            control.own(second.startup)
            // Submission, rather than native start completion, replaces the
            // one most-recent receipt. No compatibility Bool grants ownership.
            #expect(!service.isMostRecentCaptureReceipt(first.receipt))
            #expect(!service.isCurrentCaptureOwner(first.receipt))
            #expect(service.isMostRecentCaptureReceipt(second.receipt))
            try #require(await events.next() == .nativeStartEntered(stream: 2))
            #expect(replacement.running && service.hasOwnedCaptureRuntime)
            let before = service.lastError
            service.receiveStreamFailure(StopRetryFailure.nativeStopRejected, from: old)
            service.receiveAudioSampleBuffer(try stopRetrySample(), from: old)
            #expect(service.lastError == before && service.pendingDiagnosticUpdates == 0)
            #expect(!service.isMostRecentCaptureReceipt(first.receipt))
            control.releaseHeldStops()
            try await service.finishStartingSystemAudioCapture(capturedStart: second.startup, capturedReceipt: second.receipt)
            #expect(service.isCurrentCaptureOwner(second.receipt))
            #expect(old.stopCalls == 1 && replacement.stopCalls == 0)
        }
    }

    @Test
    func actualLeafErrorAndStoppedSignalsKeepTheirExactReceiptAfterNativeDrain() async throws {
        try await withStopRetryFixture(failures: 0) { service, old, _, control in
            let start = service.beginSystemAudioCapture()
            control.own(start.startup)
            try await service.finishStartingSystemAudioCapture(capturedStart: start.startup, capturedReceipt: start.receipt)
            let observed = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
            var order: [String] = []
            let errors = service.lastErrorUpdates.dropFirst().sink { message in
                guard message?.hasPrefix("System audio stream stopped: ") == true else { return }
                order.append("error")
                observed.continuation.yield(())
            }
            let states = service.isCapturingUpdates.dropFirst().sink { capturing in
                if !capturing { order.append("stopped") }
            }
            let delegate = TerminalAttributionObserver { order.append("sourceFailure") }
            service.register(delegate, capturedReceipt: start.receipt)
            defer {
                service.unregister(delegate)
                errors.cancel(); states.cancel(); observed.continuation.finish()
            }
            try await withTaskCancellationHandler {
                // Identical source identity/callback admission is used by the
                // native SCStreamDelegate method; no SDK object is fabricated.
                service.receiveStreamFailure(StopRetryFailure.nativeStopRejected, from: old)
                var arrivals = observed.stream.makeAsyncIterator()
                try #require(await arrivals.next() != nil)
                let issued = try #require(start.receipt.issuedStopTask)
                control.own(issued)
                #expect(order == ["error", "sourceFailure", "stopped"],
                    "Leaf emits error, synchronously notifies source failure, then submits stopped state")
                try await service.finishStoppingSystemAudioCapture(capturedReceipt: start.receipt)
                #expect(!old.running && old.stopCalls == 1)
                #expect(!service.hasOwnedCaptureRuntime && !service.isCurrentCaptureOwner(start.receipt))
                #expect(service.isMostRecentCaptureReceipt(start.receipt))
                let message = service.lastError
                service.receiveStreamFailure(StopRetryFailure.nativeStopRejected, from: old)
                #expect(service.lastError == message && old.stopCalls == 1,
                    "A late stopped SDK source cannot create another control event")
            } onCancel: { observed.continuation.finish() }
        }
    }
}

@MainActor
private final class TerminalAttributionObserver: SystemAudioBufferDelegate {
    private let failure: @MainActor () -> Void
    init(failure: @escaping @MainActor () -> Void) { self.failure = failure }
    nonisolated func systemAudioCaptureService(_ service: ScreenCaptureKitSystemAudioCaptureService,
        didReceive buffer: AVAudioPCMBuffer, at time: AVAudioTime) {}
    func systemAudioCaptureService(_ service: ScreenCaptureKitSystemAudioCaptureService,
        didFailWithError error: Error) { failure() }
}

/// Actual Speech/ASR owner with DEBUG recognition and controlled native streams.
/// The only seam for RED is a read-only terminal query forwarding to the old
/// active owner rule. No microphone/SCK permission or native model is used.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct AppleReleasedTerminalReceiptTests {
    @Test(arguments: [false, true])
    func exactTerminalReceiptSurvivesActualDirectAndWrappedNativeJoin(wrapped: Bool) async throws {
        try await withStopRetryFixture(failures: 0) { native, old, _, _ in
            let speech = stopRetryAppleSpeechService(native: native)
            let provider = AppleSpeechASRProvider(service: speech)
            let output: AsyncThrowingStream<TranscriptSegment, Error>?
            do {
                if wrapped {
                    output = try await provider.startTranscription(config: .init(sessionID: "synthetic-terminal-wrapped",
                        captureMode: .systemAudioOnly))
                } else {
                    output = nil
                    try await speech.start(sessionID: "synthetic-terminal-direct", captureMode: .systemAudioOnly)
                }
                #expect(speech.ownsCurrentSystemAudioCapture(native))
                if wrapped { await provider.stopTranscription(retryFailedResource: false) }
                else { speech.stop(retryFailedResource: false); await speech.finishStoppingAudioInput() }
                #expect(!old.running && old.stopCalls == 1)
                #expect(!speech.hasUnreleasedAudioInput && speech.captureCleanupFailure == nil)
                #expect(!speech.ownsCurrentSystemAudioCapture(native))
                #expect(speech.hasMostRecentSystemAudioCaptureReceipt(native),
                    "Exact native release and input join retain terminal attribution, not resource admission")
                speech.stop(retryFailedResource: false)
                await speech.finishStoppingAudioInput()
                #expect(old.stopCalls == 1 && !speech.hasUnreleasedAudioInput)
                #expect(speech.hasMostRecentSystemAudioCaptureReceipt(native))
                withExtendedLifetime(output) {}
            } catch {
                await provider.stopTranscription(retryFailedResource: false)
                speech.stop(); await speech.finishStoppingAudioInput()
                throw error
            }
        }
    }

    @Test(arguments: [false, true])
    func newRecognitionWithoutSystemCaptureRevokesOldTerminalAttribution(diagnostic: Bool) async throws {
        try await withStopRetryFixture(failures: 0) { native, old, _, _ in
            let speech = stopRetryAppleSpeechService(native: native)
            do {
                try await speech.start(sessionID: "synthetic-terminal-old-native", captureMode: .systemAudioOnly)
                speech.stop(retryFailedResource: false)
                await speech.finishStoppingAudioInput()
                try #require(!speech.hasUnreleasedAudioInput)
                #expect(speech.hasMostRecentSystemAudioCaptureReceipt(native))
                if diagnostic {
                    speech.startDiagnosticSystemAudioSession(sessionID: "synthetic-terminal-new-diagnostic")
                    #expect(speech.systemAudioSession?.isRecognitionActive == true)
                } else {
                    // Existing DEBUG recognition branch skips microphone I/O;
                    // this is not real microphone acceptance or permission.
                    try await speech.start(sessionID: "synthetic-terminal-new-mic-simulation", captureMode: .microphoneOnly)
                    #expect(speech.microphoneSession?.isRecognitionActive == true)
                }
                #expect(!speech.hasMostRecentSystemAudioCaptureReceipt(native),
                    "A later recognition-only request does not adopt the old native receipt")
                #expect(!speech.ownsCurrentSystemAudioCapture(native))
                #expect(old.stopCalls == 1 && !old.running)
                speech.stop(retryFailedResource: false)
                await speech.finishStoppingAudioInput()
                #expect(!speech.hasUnreleasedAudioInput)
                #expect(!speech.hasMostRecentSystemAudioCaptureReceipt(native),
                    "Stopping the new recognition round cannot revive old terminal attribution")
                #expect(old.stopCalls == 1)
            } catch { speech.stop(); await speech.finishStoppingAudioInput(); throw error }
        }
    }

    @Test
    func oldCapturedNativeJoinCannotRestoreAttributionOrCloseANewDiagnosticSession() async throws {
        try await withStopRetryFixture(failures: 0) { native, old, _, _ in
            let speech = stopRetryAppleSpeechService(native: native)
            do {
                try await speech.start(sessionID: "synthetic-terminal-prior-join", captureMode: .systemAudioOnly)
                speech.stop(retryFailedResource: false)
                var replacement: AppleSpeechTranscriptionSession?
                speech.onAudioInputDrainForTesting = {
                    speech.onAudioInputDrainForTesting = nil
                    speech.startDiagnosticSystemAudioSession(sessionID: "synthetic-terminal-reentrant-diagnostic")
                    replacement = speech.systemAudioSession
                }
                await speech.finishStoppingAudioInput()
                let fresh = try #require(replacement)
                #expect(speech.systemAudioSession === fresh && fresh.isRecognitionActive)
                #expect(speech.hasUnreleasedAudioInput)
                #expect(!speech.hasMostRecentSystemAudioCaptureReceipt(native),
                    "The old join updates only native failure; it cannot restore revoked terminal revision")
                #expect(!speech.ownsCurrentSystemAudioCapture(native))
                #expect(!old.running && old.stopCalls == 1)
                speech.stop(retryFailedResource: false)
                await speech.finishStoppingAudioInput()
                #expect(!speech.hasUnreleasedAudioInput)
                #expect(!speech.hasMostRecentSystemAudioCaptureReceipt(native))
                #expect(old.stopCalls == 1)
            } catch {
                speech.onAudioInputDrainForTesting = nil
                speech.stop(); await speech.finishStoppingAudioInput()
                throw error
            }
        }
    }

    @Test
    func revokingOldTerminalAttributionNeverDropsItsFailedNativeCleanup() async throws {
        try await withStopRetryFixture { native, old, _, control in
            let speech = stopRetryAppleSpeechService(native: native)
            do {
                try await speech.start(sessionID: "synthetic-terminal-failed-native", captureMode: .systemAudioOnly)
                speech.stop(retryFailedResource: false)
                await speech.finishStoppingAudioInput()
                try #require(speech.captureCleanupFailure != nil && speech.hasUnreleasedAudioInput)
                #expect(speech.hasMostRecentSystemAudioCaptureReceipt(native))
                speech.startDiagnosticSystemAudioSession(sessionID: "synthetic-terminal-new-diagnostic-after-failure")
                #expect(old.running && old.stopCalls == 1)
                #expect(speech.captureCleanupFailure != nil && speech.hasUnreleasedAudioInput)
                #expect(!speech.hasMostRecentSystemAudioCaptureReceipt(native))
                speech.stop()
                await speech.finishStoppingAudioInput()
                #expect(!old.running && old.stopCalls == 2)
                #expect(speech.captureCleanupFailure == nil && !speech.hasUnreleasedAudioInput)
                #expect(!speech.hasMostRecentSystemAudioCaptureReceipt(native))
            } catch {
                control.allowFutureStopsAndRelease()
                speech.stop(); await speech.finishStoppingAudioInput()
                throw error
            }
        }
    }
}

/// Mixed-seam request-entry regression. Hooks only expose actual submitted
/// round IDs before retirement/await; all start/stop/query work is production.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct NativeTerminalRequestInvalidationTests {
    @Test(arguments: [0, 1])
    func appleWrapperRevokesOlderTerminalAttributionAtSubmission(failures: Int) async throws {
        try await withStopRetryFixture(failures: failures) { native, old, replacement, control in
            let speech = stopRetryAppleSpeechService(native: native)
            let provider = AppleSpeechASRProvider(service: speech)
            do {
                let first = try await provider.startTranscription(config: .init(sessionID: "synthetic-apple-request-old",
                    captureMode: .systemAudioOnly))
                #expect(provider.hasMostRecentSystemAudioCaptureReceipt(native))
                var submissions = 0
                provider.onRoundRequestedForTesting = { _ in
                    submissions += 1
                    #expect(!provider.hasMostRecentSystemAudioCaptureReceipt(native),
                        "The new request invalidates old terminal attribution before retirement observers or await")
                }
                var second: AsyncThrowingStream<TranscriptSegment, Error>?
                do {
                    second = try await provider.startTranscription(config: .init(sessionID: "synthetic-apple-request-new",
                        captureMode: .systemAudioOnly))
                    #expect(failures == 0)
                } catch {
                    if failures == 0 { throw error }
                    try #require(provider.captureCleanupFailure != nil)
                }
                provider.onRoundRequestedForTesting = nil
                #expect(submissions == 1 && old.stopCalls == 1)
                if failures == 1 {
                    #expect(old.running && provider.captureCleanupFailure != nil)
                    #expect(!provider.hasMostRecentSystemAudioCaptureReceipt(native))
                } else { #expect(!old.running && replacement.running) }
                await provider.stopTranscription()
                #expect(provider.captureCleanupFailure == nil && !provider.hasOwnedTranscriptionWork)
                #expect(provider.hasMostRecentSystemAudioCaptureReceipt(native) == (failures == 0),
                    "Explicit nil stop preserves the latest valid ticket, never the revoked older ticket")
                #expect(!old.running && !replacement.running)
                withExtendedLifetime((first, second)) {}
            } catch {
                provider.onRoundRequestedForTesting = nil
                control.allowFutureStopsAndRelease()
                await provider.stopTranscription()
                throw error
            }
        }
    }

    @Test(arguments: [0, 1])
    func parakeetOutcomeRevokesOlderTerminalAttributionAtSubmission(failures: Int) async throws {
        try await withStopRetryFixture(failures: failures) { native, old, replacement, control in
            let provider = stopRetryParakeetProvider(service: native, runtime: StopRetryParakeetRuntime())
            do {
                let first = try await provider.startTranscription(config: .init(sessionID: "synthetic-parakeet-request-old",
                    captureMode: .systemAudioOnly))
                #expect(provider.hasMostRecentSystemAudioCaptureReceipt(native))
                var submissions = 0
                provider.onRoundRequestedForTesting = { _ in
                    submissions += 1
                    #expect(!provider.hasMostRecentSystemAudioCaptureReceipt(native),
                        "The old outcome's immutable request ticket must be revoked before retirement and await")
                }
                var second: AsyncThrowingStream<TranscriptSegment, Error>?
                do {
                    second = try await provider.startTranscription(config: .init(sessionID: "synthetic-parakeet-request-new",
                        captureMode: .systemAudioOnly))
                    #expect(failures == 0)
                } catch {
                    if failures == 0 { throw error }
                    try #require(provider.captureCleanupFailure != nil)
                }
                provider.onRoundRequestedForTesting = nil
                #expect(submissions == 1 && old.stopCalls == 1)
                if failures == 1 {
                    #expect(old.running && provider.captureCleanupFailure != nil)
                    #expect(!provider.hasMostRecentSystemAudioCaptureReceipt(native))
                } else { #expect(!old.running && replacement.running) }
                await provider.stopTranscription()
                #expect(provider.captureCleanupFailure == nil && !provider.hasOwnedTranscriptionWork)
                #expect(provider.hasMostRecentSystemAudioCaptureReceipt(native) == (failures == 0),
                    "Clearing requestedRoundID for stop cannot restore the old outcome's revoked ticket")
                #expect(!old.running && !replacement.running)
                withExtendedLifetime((first, second)) {}
            } catch {
                provider.onRoundRequestedForTesting = nil
                control.allowFutureStopsAndRelease()
                await provider.stopTranscription()
                throw error
            }
        }
    }

    @Test
    func cancelledAppleSubmissionDoesNotRestoreItsOlderTicketAfterExplicitStop() async throws {
        try await withStopRetryFixture(failures: 0) { native, old, replacement, control in
            let speech = stopRetryAppleSpeechService(native: native)
            let provider = AppleSpeechASRProvider(service: speech)
            do {
                let first = try await provider.startTranscription(config: .init(sessionID: "synthetic-apple-before-cancel",
                    captureMode: .systemAudioOnly))
                var request: Task<Void, Error>?
                var submitted = false
                provider.onRoundRequestedForTesting = { _ in
                    submitted = true
                    #expect(!provider.hasMostRecentSystemAudioCaptureReceipt(native))
                    #expect(request != nil)
                    request?.cancel()
                }
                let owned = Task { @MainActor in
                    _ = try await provider.startTranscription(config: .init(sessionID: "synthetic-apple-cancel-new",
                        captureMode: .systemAudioOnly))
                }
                request = owned; control.own(owned)
                let result = await owned.result
                if case .failure(let error) = result { #expect(error is CancellationError) }
                else { #expect(Bool(false), "The request canceled at submission must fail before replacement capture") }
                provider.onRoundRequestedForTesting = nil
                #expect(submitted && old.stopCalls == 1 && !old.running)
                #expect(replacement.startCalls == 0)
                await provider.stopTranscription()
                #expect(!provider.hasMostRecentSystemAudioCaptureReceipt(native))
                #expect(!provider.hasOwnedTranscriptionWork && !speech.hasUnreleasedAudioInput)
                withExtendedLifetime(first) {}
            } catch {
                provider.onRoundRequestedForTesting = nil
                control.allowFutureStopsAndRelease()
                await provider.stopTranscription()
                throw error
            }
        }
    }

    @Test
    func cancelledParakeetSubmissionDoesNotRestoreItsOlderTicketAfterExplicitStop() async throws {
        try await withStopRetryFixture(failures: 0) { native, old, replacement, control in
            let provider = stopRetryParakeetProvider(service: native, runtime: StopRetryParakeetRuntime())
            do {
                let first = try await provider.startTranscription(config: .init(sessionID: "synthetic-parakeet-before-cancel",
                    captureMode: .systemAudioOnly))
                var request: Task<Void, Error>?
                var submitted = false
                provider.onRoundRequestedForTesting = { _ in
                    submitted = true
                    #expect(!provider.hasMostRecentSystemAudioCaptureReceipt(native))
                    #expect(request != nil)
                    request?.cancel()
                }
                let owned = Task { @MainActor in
                    _ = try await provider.startTranscription(config: .init(sessionID: "synthetic-parakeet-cancel-new",
                        captureMode: .systemAudioOnly))
                }
                request = owned; control.own(owned)
                let result = await owned.result
                if case .failure(let error) = result { #expect(error is CancellationError) }
                else { #expect(Bool(false), "The request canceled at submission must fail before replacement capture") }
                provider.onRoundRequestedForTesting = nil
                #expect(submitted && old.stopCalls == 1 && !old.running)
                #expect(replacement.startCalls == 0)
                await provider.stopTranscription()
                #expect(!provider.hasMostRecentSystemAudioCaptureReceipt(native))
                #expect(!provider.hasOwnedTranscriptionWork && provider.captureCleanupFailure == nil)
                withExtendedLifetime(first) {}
            } catch {
                provider.onRoundRequestedForTesting = nil
                control.allowFutureStopsAndRelease()
                await provider.stopTranscription()
                throw error
            }
        }
    }
}

/// Existing App publisher/error-observation API after controlled native release.
/// Injecting a diagnostic with the real setter tests consumer admission; this
/// deliberately does not claim delayed SDK callback, GUI, or hardware proof.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct AppReleasedSystemAudioTerminalAdmissionTests {
    @Test(arguments: [false, true])
    func postDrainErrorBelongsOnlyToTheAppsExactMostRecentReceipt(foreignReplacement: Bool) async throws {
        try await withStopRetryFixture(failures: 0) { native, old, replacement, control in
            let speech = stopRetryAppleSpeechService(native: native)
            let environment = try await HirevaTestEnvironment(prefix: "PostDrainExactTerminalError",
                systemAudioCaptureService: native)
            let app = environment.appState
            let arrived = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
            let message = "synthetic terminal diagnostic after exact native drain"
            let previous = "synthetic prior capture error"
            app.systemAudioErrorDidObserve = { error in
                if error == message { arrived.continuation.yield(()) }
            }
            defer { app.systemAudioErrorDidObserve = nil; arrived.continuation.finish() }
            try await withTaskCancellationHandler {
                do {
                    try await speech.start(sessionID: "synthetic-post-drain-app-owned", captureMode: .systemAudioOnly)
                    app.appleSpeechService = speech
                    app.activeTranscriptionProvider = speech
                    // Bool reconciliation excludes prior .error; this isolates
                    // the existing error consumer instead of selecting a race.
                    app.currentCaptureRuntimeState = .error(reason: previous)
                    speech.stop(retryFailedResource: false)
                    await speech.finishStoppingAudioInput()
                    #expect(!speech.hasUnreleasedAudioInput && !old.running)
                    if foreignReplacement {
                        let start = native.beginSystemAudioCapture()
                        control.own(start.startup)
                        try await native.finishStartingSystemAudioCapture(capturedStart: start.startup, capturedReceipt: start.receipt)
                        #expect(replacement.running)
                    }
                    native.lastError = message
                    var events = arrived.stream.makeAsyncIterator()
                    try #require(await events.next() != nil)
                    #expect(app.currentCaptureRuntimeState == .error(reason: foreignReplacement ? previous : message),
                        "Only the exact most-recent receipt admits a post-drain terminal diagnostic")
                    #expect(old.stopCalls == 1)
                    if foreignReplacement { #expect(replacement.running && replacement.stopCalls == 0) }
                    try await environment.shutdown()
                    if foreignReplacement { #expect(replacement.running && replacement.stopCalls == 0) }
                } catch {
                    control.allowFutureStopsAndRelease()
                    speech.stop(); await speech.finishStoppingAudioInput()
                    try? await environment.shutdown()
                    throw error
                }
            } onCancel: { arrived.continuation.finish() }
        }
    }
}

@MainActor
private func withDiagnosticCaptureOwner(native: ScreenCaptureKitSystemAudioCaptureService, control: StopRetryControl,
    body: @MainActor (SystemAudioPermissionController) async throws -> Void) async throws {
    let permissions = HermeticPermissionService()
    let owner = SystemAudioPermissionController(permissions: permissions, initialSnapshot: permissions.currentSnapshot,
        probe: { .init(preflightGranted: true, shareableContentProbeSucceeded: true,
            streamAudioProbeSucceeded: true, errorDescription: nil, likelyIdentityMismatch: false) },
        stopProbe: {}, diagnosticCaptureService: native)
    do { try await body(owner) }
    catch {
        control.allowFutureStopsAndRelease()
        try? await owner.shutdown()
        throw error
    }
    try await owner.shutdown()
}

@MainActor
private func stopRetryAppleSpeechService(native: ScreenCaptureKitSystemAudioCaptureService) -> AppleSpeechTranscriptionService {
    AppleSpeechTranscriptionService(stopTestingOperations: nil,
        pcmTestingOperations: .init(append: { _ in }, endAudio: {}), systemAudioCaptureService: native)
}

@MainActor
private func withStopRetryFixture(failures: Int = 1, holdSecondStop: Bool = false, holdStartForStream: Int? = nil,
    failStartForStream: Int? = nil, onStartEntered: (() -> Void)? = nil, removalFailure: StopRetryOutputStage? = nil,
    body: @MainActor (ScreenCaptureKitSystemAudioCaptureService, StopRetryStream,
        StopRetryStream, StopRetryControl) async throws -> Void) async throws {
    let control = StopRetryControl(failures: failures, holdSecondStop: holdSecondStop,
        holdStartForStream: holdStartForStream, failStartForStream: failStartForStream, removalFailure: removalFailure)
    let old = StopRetryStream(id: 1, control: control)
    let replacement = StopRetryStream(id: 2, control: control)
    var creations = 0
    let removeOutput: (@MainActor (any SystemAudioCaptureStream, SCStreamOutputType) throws -> Void)?
    if removalFailure != nil {
        removeOutput = { stream, type in
            try control.removeOutput(source: stream.callbackIdentity, type: type)
        }
    } else { removeOutput = nil }
    let service = ScreenCaptureKitSystemAudioCaptureService(streamFactory: {
        creations += 1
        return creations == 1 ? old : replacement
    }, onStartEntered: onStartEntered, registeredOutputsForTesting: removalFailure == nil ? [] : [.audio, .screen],
        removeOutputForTesting: removeOutput)
    @MainActor func cleanup() async -> Bool {
        // Synchronously release every owned fixture continuation before joining
        // any task, including after the test's one-minute cancellation budget.
        control.allowFutureStopsAndRelease()
        let stop = service.stopSystemAudioCapture()
        control.own(stop)
        var stopped: Bool
        do { try await service.finishStoppingSystemAudioCapture(capturedStop: stop); stopped = true }
        catch { stopped = false }
        for task in control.ownedTasks { _ = await task.result }
        for task in control.ownedNeverTasks { await task.value }
        var noRetainedNative = !old.running && !replacement.running
        if stopped, !noRetainedNative {
            let retained = service.stopSystemAudioCapture()
            control.own(retained)
            do { try await service.finishStoppingSystemAudioCapture(capturedStop: retained) }
            catch { stopped = false }
            noRetainedNative = !old.running && !replacement.running
        }
        // RED can retain the immutable failed receipt. This disposes only the
        // synthetic fixture's value state after all tasks have joined; it is
        // never an SDK stop or evidence of successful production recovery.
        control.disposeFixtureAfterJoin()
        return stopped && noRetainedNative
    }
    try await withTaskCancellationHandler {
        do { try await body(service, old, replacement, control) }
        catch { _ = await cleanup(); throw error }
        #expect(await cleanup(), "Successful cases must exit through the production stop owner")
    } onCancel: { control.cancelOwningTest() }
}

@MainActor
private final class StopRetryStream: SystemAudioCaptureStream {
    nonisolated let callbackIdentity: ObjectIdentifier
    private let identity = StopRetryIdentity()
    private let id: Int
    private let control: StopRetryControl
    var running: Bool { control.running(id) }
    var startCalls: Int { control.startCalls(id) }
    var stopCalls: Int { control.stopCalls(id) }
    init(id: Int, control: StopRetryControl) {
        self.id = id
        self.control = control
        callbackIdentity = ObjectIdentifier(identity)
    }
    func startCapture() async throws { try await control.started(id) }
    func stopCapture() async throws { try await control.stopped(id) }
}

private final class StopRetryIdentity {}
private enum StopRetryFailure: Error, Sendable { case nativeStartRejected, nativeStopRejected, nativeAlreadyStopped, outputRemovalRejected }
private enum StopRetryOutputStage: CaseIterable, Equatable, Sendable { case audio, screen }
private enum StopRetryEvent: Equatable, Sendable {
    case nativeStartEntered(stream: Int)
    case nativeStopEntered(stream: Int, attempt: Int)
    case waiterFinished(Bool)
}

/// Test cancellation owns the exact tasks and the held native-stop latch.
/// Continuations resume and task cancellation run after unlocking.
private final class StopRetryControl: Sendable {
    private struct State: Sendable {
        var failures: Int
        var removalFailure: StopRetryOutputStage?
        var audioRemovals = 0
        var screenRemovals = 0
        var outputSourceIDs: Set<ObjectIdentifier> = []
        let holdSecondStop: Bool
        let holdStartForStream: Int?
        let failStartForStream: Int?
        var starts: [Int: Int] = [:]
        var stops: [Int: Int] = [:]
        var running: Set<Int> = []
        var released = false
        var cancelled = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        var tasks: [Task<Void, Error>] = []
        var neverTasks: [Task<Void, Never>] = []
    }
    private let state: OSAllocatedUnfairLock<State>
    private let channel = AsyncStream<StopRetryEvent>.makeStream()
    var events: AsyncStream<StopRetryEvent> { channel.stream }
    var ownedTasks: [Task<Void, Error>] { state.withLock { $0.tasks } }
    var ownedNeverTasks: [Task<Void, Never>] { state.withLock { $0.neverTasks } }
    init(failures: Int, holdSecondStop: Bool, holdStartForStream: Int?, failStartForStream: Int?, removalFailure: StopRetryOutputStage?) {
        state = OSAllocatedUnfairLock(initialState: State(failures: failures,
            removalFailure: removalFailure, holdSecondStop: holdSecondStop, holdStartForStream: holdStartForStream, failStartForStream: failStartForStream))
    }
    var audioRemovals: Int { state.withLock { $0.audioRemovals } }
    var screenRemovals: Int { state.withLock { $0.screenRemovals } }
    var outputSourceIDs: Set<ObjectIdentifier> { state.withLock { $0.outputSourceIDs } }
    func startCalls(_ id: Int) -> Int { state.withLock { $0.starts[id, default: 0] } }
    func stopCalls(_ id: Int) -> Int { state.withLock { $0.stops[id, default: 0] } }
    func running(_ id: Int) -> Bool { state.withLock { $0.running.contains(id) } }
    func started(_ id: Int) async throws {
        let action = state.withLock { value in
            value.starts[id, default: 0] += 1
            value.running.insert(id)
            return (hold: value.holdStartForStream == id, reject: value.failStartForStream == id)
        }
        if action.hold {
            channel.continuation.yield(.nativeStartEntered(stream: id))
            await withCheckedContinuation { continuation in
                let released = state.withLock { value in
                    if value.released { return true }
                    value.waiters.append(continuation)
                    return false
                }
                if released { continuation.resume() }
            }
        }
        if action.reject { throw StopRetryFailure.nativeStartRejected }
    }
    func stopped(_ id: Int) async throws {
        let attempt = state.withLock { value -> (number: Int, reject: Bool, hold: Bool, alreadyStopped: Bool) in
            value.stops[id, default: 0] += 1
            let number = value.stops[id, default: 0]
            let reject = id == 1 && value.failures > 0
            if reject { value.failures -= 1 }
            return (number, reject, id == 1 && number == 2 && value.holdSecondStop, !value.running.contains(id))
        }
        channel.continuation.yield(.nativeStopEntered(stream: id, attempt: attempt.number))
        if attempt.hold {
            await withCheckedContinuation { continuation in
                let released = state.withLock { value in
                    if value.released { return true }
                    value.waiters.append(continuation)
                    return false
                }
                if released { continuation.resume() }
            }
        }
        if attempt.reject { throw StopRetryFailure.nativeStopRejected }
        if attempt.alreadyStopped { throw StopRetryFailure.nativeAlreadyStopped }
        _ = state.withLock { $0.running.remove(id) }
    }
    func removeOutput(source: ObjectIdentifier, type: SCStreamOutputType) throws {
        let reject = state.withLock { value in
            value.outputSourceIDs.insert(source)
            let stage: StopRetryOutputStage
            if type == .audio { value.audioRemovals += 1; stage = .audio }
            else { value.screenRemovals += 1; stage = .screen }
            if value.removalFailure == stage {
                value.removalFailure = nil
                return true
            }
            return false
        }
        if reject { throw StopRetryFailure.outputRemovalRejected }
    }
    func own(_ task: Task<Void, Error>) {
        let cancel = state.withLock { value in value.tasks.append(task); return value.cancelled }
        if cancel { task.cancel() }
    }
    func own(_ task: Task<Void, Never>) {
        let cancel = state.withLock { value in value.neverTasks.append(task); return value.cancelled }
        if cancel { task.cancel() }
    }
    func waiterFinished(_ success: Bool) { channel.continuation.yield(.waiterFinished(success)) }
    func releaseHeldStops() {
        let waiters = state.withLock { value in
            value.released = true
            let waiters = value.waiters
            value.waiters.removeAll()
            return waiters
        }
        waiters.forEach { $0.resume() }
    }
    func allowFutureStopsAndRelease() {
        state.withLock { $0.failures = 0; $0.removalFailure = nil }
        releaseHeldStops()
    }
    func cancelOwningTest() {
        let tasks = state.withLock { value in value.cancelled = true; return value.tasks }
        releaseHeldStops()
        channel.continuation.finish()
        tasks.forEach { $0.cancel() }
        ownedNeverTasks.forEach { $0.cancel() }
    }
    func disposeFixtureAfterJoin() {
        state.withLock { $0.running.removeAll(); $0.tasks.removeAll(); $0.neverTasks.removeAll() }
        channel.continuation.finish()
    }
}

private extension Result where Success == Void, Failure == Error {
    var isFailure: Bool { if case .failure = self { return true }; return false }
}

@MainActor
func stopRetrySample() throws -> CMSampleBuffer {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
    pcm.frameLength = 16
    for index in 0..<16 { pcm.floatChannelData?[0][index] = 0.1 }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
        presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    try #require(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil,
        dataReady: false, makeDataReadyCallback: nil, refcon: nil,
        formatDescription: format.formatDescription, sampleCount: 16,
        sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr)
    let created = try #require(sample)
    try #require(CMSampleBufferSetDataBufferFromAudioBufferList(created,
        blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
        flags: 0, bufferList: pcm.audioBufferList) == noErr)
    try #require(CMSampleBufferSetDataReady(created) == noErr)
    return created
}

/// Existing controlled native owner; no SDK stream, permission, model or mic.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct AppleOutputNativeLeaseOwnershipTests {
    @Test
    func failedOldWrapperRetryPreservesTheSameServicesDiagnosticReplacement() async throws {
        try await withStopRetryFixture { native, old, _, control in
            let speech = stopRetryAppleSpeechService(native: native)
            let wrapper = AppleSpeechASRProvider(service: speech)
            do {
                let stream = try await wrapper.startTranscription(config: .init(
                    sessionID: "synthetic-owned-failed-output", captureMode: .systemAudioOnly))
                await wrapper.stopTranscription(retryFailedResource: false)
                try #require(wrapper.captureCleanupFailure != nil)
                #expect(old.running && old.stopCalls == 1)
                speech.startDiagnosticSystemAudioSession(sessionID: "synthetic-failed-output-replacement")
                let replacement = try #require(speech.systemAudioSession)
                await wrapper.stopTranscription(retryFailedResource: true)
                #expect(speech.systemAudioSession === replacement && replacement.isRecognitionActive,
                    "Explicit old native retry does not grant control over this newer recognition output")
                #expect(!old.running && old.stopCalls == 2)
                #expect(wrapper.captureCleanupFailure == nil && !wrapper.hasOwnedTranscriptionWork)
                speech.stop(retryFailedResource: false)
                await speech.finishStoppingAudioInput()
                #expect(!speech.hasUnreleasedAudioInput)
                withExtendedLifetime(stream) {}
            } catch {
                control.allowFutureStopsAndRelease()
                await wrapper.stopTranscription()
                speech.stop(); await speech.finishStoppingAudioInput()
                throw error
            }
        }
    }

    @Test
    func pendingOldWrapperNativeStartupRetirementPreservesDiagnosticReplacement() async throws {
        try await withStopRetryFixture(failures: 0, holdStartForStream: 1) { native, old, other, control in
            let speech = stopRetryAppleSpeechService(native: native)
            let wrapper = AppleSpeechASRProvider(service: speech)
            let startup = Task<Void, Error> { @MainActor in
                _ = try await wrapper.startTranscription(config: .init(
                    sessionID: "synthetic-pending-owned-output", captureMode: .systemAudioOnly))
            }
            control.own(startup)
            do {
                let trace = TestEventWaitTrace(label: #function)
                let entered = try await trace.nextEvent(in: control.events, event: "old_native_start_held")
                #expect(entered == .nativeStartEntered(stream: 1))
                speech.startDiagnosticSystemAudioSession(sessionID: "synthetic-pending-native-replacement")
                let replacement = try #require(speech.systemAudioSession)
                startup.cancel()
                let stop = Task { @MainActor in await wrapper.stopTranscription(retryFailedResource: false) }
                control.own(stop)
                // The owning fixture registered cancellation before start. It
                // releases this exact synthetic gate before joining any task.
                control.releaseHeldStops()
                let result = await startup.result
                if case .failure(let error) = result { #expect(error is CancellationError) }
                else { Issue.record("Replacement invalidated the older native startup") }
                await stop.value
                #expect(speech.systemAudioSession === replacement && replacement.isRecognitionActive)
                #expect(!old.running && old.stopCalls == 1)
                #expect(other.startCalls == 0 && other.stopCalls == 0)
                #expect(!wrapper.hasOwnedTranscriptionWork)
                speech.stop(retryFailedResource: false)
                await speech.finishStoppingAudioInput()
                #expect(!speech.hasUnreleasedAudioInput)
            } catch {
                control.allowFutureStopsAndRelease()
                _ = await startup.result
                await wrapper.stopTranscription()
                speech.stop(); await speech.finishStoppingAudioInput()
                throw error
            }
        }
    }
}
