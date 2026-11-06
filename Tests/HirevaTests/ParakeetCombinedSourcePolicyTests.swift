import AVFoundation
import Foundation
import Testing
@testable import Hireva

/// Actual provider source-failure handler and stream bridge. Injected capture
/// closures suppress both devices; runtime/model values are synthetic only.
@MainActor
struct ParakeetCombinedSourcePolicyTests {
    @Test(.timeLimit(.minutes(1)))
    func failedSystemChannelKeepsHealthyCombinedMicrophoneStreamUsable() async throws {
        let runtime = CombinedPolicyRuntime()
        let capture = ScreenCaptureKitSystemAudioCaptureService()
        let provider = LocalParakeetASRProvider(modelManager: CombinedInstalledModel(),
            runtimeClient: runtime, systemAudioCaptureService: capture,
            startCapture: { mode in #expect(mode == .microphoneAndSystem) }, stopCapture: {})
        var consumer: Task<[TranscriptSegment], Error>?
        do {
            let stream = try await provider.startTranscription(config: .init(
                sessionID: "synthetic-combined-survivor", captureMode: .microphoneAndSystem))
            consumer = Task {
                var received: [TranscriptSegment] = []
                for try await value in stream { received.append(value) }
                return received
            }
            provider.systemAudioCaptureService(capture, didFailWithError: CombinedPolicyFailure.systemSource)
            #expect(provider.hasOwnedTranscriptionWork,
                "A failed system channel must not revoke a still-usable Combined microphone round.")
            #expect(runtime.running)
            runtime.emitMicrophoneFinal()
            runtime.finish()
            switch await consumer?.result {
            case .some(.success(let values)):
                #expect(values.count == 1)
                #expect(values.first?.sessionID == "synthetic-combined-survivor")
                #expect(values.first?.source == .microphone)
                #expect(values.first?.speaker == .unknown,
                    "Healthy microphone provenance does not establish candidate identity.")
                #expect(values.first?.asrSource == .localParakeetASR)
            case .some(.failure):
                Issue.record("One failed source terminated the healthy Combined source output.")
            case .none: Issue.record("Lost the exact owned consumer.")
            }
            await provider.stopTranscription()
            #expect(!runtime.running)
            #expect(!provider.hasOwnedTranscriptionWork)
        } catch {
            runtime.finish()
            consumer?.cancel()
            await provider.stopTranscription()
            _ = await consumer?.result
            throw error
        }
        runtime.finish()
        consumer?.cancel()
        await provider.stopTranscription()
        _ = await consumer?.result
    }
}
private enum CombinedPolicyFailure: Error { case systemSource }
@MainActor
private final class CombinedPolicyRuntime: ParakeetRuntimeClient {
    private(set) var running = false
    private var continuation: AsyncThrowingStream<ParakeetTranscriptEvent, Error>.Continuation?
    func isRuntimeAvailable() async -> Bool { true }
    func probeModel(at modelDirectory: URL) async -> Bool { true }
    func startTranscription(modelDirectory: URL, config: ASRConfig) async throws
        -> AsyncThrowingStream<ParakeetTranscriptEvent, Error> {
        let pair = AsyncThrowingStream<ParakeetTranscriptEvent, Error>.makeStream()
        continuation = pair.continuation; running = true
        return pair.stream
    }
    func emitMicrophoneFinal() {
        continuation?.yield(.init(segmentId: "synthetic-surviving-source-final",
            text: "Synthetic speech from the healthy selected source.", isFinal: true,
            startTime: nil, endTime: nil, audioSource: AudioSourceType.microphone.rawValue))
    }
    func finish() { continuation?.finish() }
    func stop() async { continuation?.finish(); continuation = nil; running = false }
    nonisolated func appendAudioBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) { }
}
private final class CombinedInstalledModel: LocalModelManager {
    func modelStatus(_ model: LocalModelDescriptor) async -> LocalModelStatus { .installed }
    func downloadModel(_ model: LocalModelDescriptor) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func deleteModel(_ model: LocalModelDescriptor) async throws { }
    func verifyModel(_ model: LocalModelDescriptor) async throws -> Bool { true }
    func fileURL(for model: LocalModelDescriptor) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-combined-no-model")
    }
}
