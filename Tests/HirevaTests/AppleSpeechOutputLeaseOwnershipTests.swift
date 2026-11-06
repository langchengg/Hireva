import Foundation
import Testing
@testable import Hireva

/// DEBUG recognition creates only simulated PCM input. Stop callbacks are
/// explicit no-ops; these tests never register a native capture or microphone.
@MainActor
struct AppleSpeechOutputLeaseOwnershipTests {
    @Test(.timeLimit(.minutes(1)))
    func oldActiveWrapperStopCannotCloseDirectReplacementOutput() async throws {
        let speech = makeSpeech()
        let wrapper = AppleSpeechASRProvider(service: speech)
        do {
            let oldOutput = try await wrapper.startTranscription(config: .init(
                sessionID: "synthetic-owned-old", captureMode: .systemAudioOnly))
            speech.startDiagnosticSystemAudioSession(sessionID: "synthetic-direct-replacement")
            let replacement = try #require(speech.systemAudioSession)
            // Same-actor direct replacement finishes the old stream. Explicit
            // wrapper retirement happens before yielding to its EOF bridge.
            await wrapper.stopTranscription(retryFailedResource: false)
            #expect(speech.systemAudioSession === replacement)
            #expect(replacement.isRecognitionActive,
                "The old wrapper owns its old output, not this same-object replacement.")
            speech.stop(retryFailedResource: false)
            await speech.finishStoppingAudioInput()
            await wrapper.waitForCurrentTranscriptionEnd()
            for try await _ in oldOutput {}
            #expect(!speech.hasUnreleasedAudioInput)
        } catch { await cleanup(speech, wrapper); throw error }
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelledPendingWrapperStartupCannotCloseDrainObserverReplacement() async throws {
        let speech = makeSpeech()
        let wrapper = AppleSpeechASRProvider(service: speech)
        var replacement: AppleSpeechTranscriptionSession?
        var didReplace = false
        speech.onAudioInputDrainForTesting = {
            guard !didReplace else { return }
            didReplace = true
            speech.startDiagnosticSystemAudioSession(sessionID: "synthetic-pending-replacement")
            replacement = speech.systemAudioSession
        }
        do {
            do {
                _ = try await wrapper.startTranscription(config: .init(
                    sessionID: "synthetic-obsolete-start", captureMode: .systemAudioOnly))
                Issue.record("The drain observer invalidated this startup before it adopted recognition.")
            } catch { #expect(error is CancellationError) }
            #expect(didReplace)
            let captured = try #require(replacement)
            #expect(speech.systemAudioSession === captured)
            #expect(captured.isRecognitionActive,
                "Late startup retirement must not stop the observer's later output.")
            speech.onAudioInputDrainForTesting = nil
            await cleanup(speech, wrapper)
            #expect(!speech.hasUnreleasedAudioInput)
            #expect(!wrapper.hasOwnedTranscriptionWork)
        } catch {
            speech.onAudioInputDrainForTesting = nil
            await cleanup(speech, wrapper)
            throw error
        }
    }

    private func makeSpeech() -> AppleSpeechTranscriptionService {
        AppleSpeechTranscriptionService(stopTestingOperations: .init(
            unregisterMicrophone: { _ in }, unregisterSystemAudio: { _ in }, stopSystemAudio: {}))
    }
    private func cleanup(_ speech: AppleSpeechTranscriptionService,
        _ wrapper: AppleSpeechASRProvider) async {
        speech.stop(retryFailedResource: false)
        await speech.finishStoppingAudioInput()
        await wrapper.stopTranscription(retryFailedResource: false)
        await wrapper.waitForCurrentTranscriptionEnd()
    }
}
