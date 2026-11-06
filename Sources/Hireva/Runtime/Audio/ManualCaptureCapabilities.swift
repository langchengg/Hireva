import AVFoundation
import Combine
import Foundation

/// Narrow I/O boundary for the existing bounded manual recording path. The
/// default adapter uses the same recorder and Apple Speech backend. Fake
/// instances must not install the shared legacy static hooks.
@MainActor
struct ManualCaptureCapabilities {
    /// Wraps the existing SCK resource identity. The controlled case supports
    /// per-instance non-native adapters without introducing another epoch.
    enum Stop {
        case systemAudio(SystemAudioCaptureStopReceipt)
        case controlled(Task<Void, Error>)
        @MainActor var task: Task<Void, Error> {
            switch self { case .systemAudio(let receipt): receipt.task; case .controlled(let task): task }
        }
    }
    struct StoppedAudio {
        let buffers: [AVAudioPCMBuffer]
        let bufferCount: Int
        let lastBufferTimestamp: Date?
        // Captured synchronously before any await: joining cannot adopt a
        // later recording's teardown.
        let drain: Stop?
    }
    struct Audio {
        let start: @MainActor (ManualCaptureSource, Int,
            @escaping @Sendable (Error) -> Void, @escaping @Sendable () -> Void) async throws -> Void
        let stop: @MainActor () -> StoppedAudio
        let cancel: @MainActor () -> Stop?
        let finishStop: @MainActor (Stop?) async throws -> Void
        let retryStop: @MainActor (Stop) async throws -> Void
        let duration: @MainActor () -> Double
        let level: @MainActor () -> Double
        let decibels: @MainActor () -> Double
        let bufferCount: @MainActor () -> Int
        let lastBufferTimestamp: @MainActor () -> Date?
        // Must publish on MainActor, as the concrete recorder already does.
        let changes: AnyPublisher<Void, Never>
    }
    struct Speech {
        let start: @MainActor (@escaping @Sendable (String) -> Void,
            @escaping @Sendable (String) -> Void, @escaping @Sendable (String) -> Void) async throws -> Void
        let append: @MainActor (AVAudioPCMBuffer) -> Void
        let finalize: @MainActor (Double) async throws -> String
        let cancel: @MainActor () -> Void
        private let startOnDevice: (@MainActor (@escaping @Sendable (String) -> Void,
            @escaping @Sendable (String) -> Void, @escaping @Sendable (String) -> Void) async throws -> Void)?

        init(start: @escaping @MainActor (@escaping @Sendable (String) -> Void,
            @escaping @Sendable (String) -> Void, @escaping @Sendable (String) -> Void) async throws -> Void,
            append: @escaping @MainActor (AVAudioPCMBuffer) -> Void,
            finalize: @escaping @MainActor (Double) async throws -> String,
            cancel: @escaping @MainActor () -> Void,
            startOnDevice: (@MainActor (@escaping @Sendable (String) -> Void,
                @escaping @Sendable (String) -> Void, @escaping @Sendable (String) -> Void) async throws -> Void)? = nil) {
            self.start = start; self.append = append; self.finalize = finalize
            self.cancel = cancel; self.startOnDevice = startOnDevice
        }

        @MainActor
        func startConfigured(requiresOnDeviceRecognition: Bool,
            _ partial: @escaping @Sendable (String) -> Void,
            _ final: @escaping @Sendable (String) -> Void,
            _ error: @escaping @Sendable (String) -> Void) async throws {
            if requiresOnDeviceRecognition {
                guard let startOnDevice else {
                    throw TranscriptionError.unavailable("This manual speech adapter has no on-device recognition contract.")
                }
                try await startOnDevice(partial, final, error)
            } else {
                try await start(partial, final, error)
            }
        }
    }
    let audio: Audio
    let speech: Speech

    static func existingAdapter(
        recorder: ManualQuestionCaptureService? = nil,
        speech: ManualQuestionTranscriptionService? = nil
    ) -> Self {
        let recorder = recorder ?? .shared
        let speech = speech ?? .shared
        return .init(audio: existingAudioAdapter(recorder: recorder),
        speech: .init(start: { partial, final, error in
            try await speech.startTranscription(onPartialResult: partial,
                onFinalResult: final, onError: error)
        }, append: { speech.appendBuffer($0) },
        finalize: { try await speech.endAudioAndFinalize(timeoutSeconds: $0) },
        cancel: { speech.cancel() },
        startOnDevice: { partial, final, error in
            try await speech.startTranscription(requiresOnDeviceRecognition: true,
                onPartialResult: partial, onFinalResult: final, onError: error)
        }))
    }

    static func existingAudioAdapter(recorder: ManualQuestionCaptureService) -> Audio {
        .init(start: { source, duration, onFailure, onTimeout in
            try await recorder.startCapture(source: source, maxDuration: duration,
                onFailure: onFailure, onTimeout: onTimeout)
        }, stop: {
            let stopped = recorder.stopCaptureAndReturnOwnedReceiptAudio()
            return .init(buffers: stopped.buffers, bufferCount: stopped.bufferCount,
                lastBufferTimestamp: stopped.lastBufferTimestamp, drain: stopped.drain)
        }, cancel: { recorder.cancelCaptureAndReturnOwnedReceipt() },
        finishStop: { try await recorder.finishStopping(capturedReceipt: $0) },
        retryStop: { try await recorder.retryStopping(capturedReceipt: $0) },
        duration: { recorder.recordingDuration }, level: { recorder.normalizedLevel },
        decibels: { recorder.decibels },
        bufferCount: { recorder.capturedBufferCount }, lastBufferTimestamp: { recorder.lastBufferTimestamp },
        changes: recorder.objectWillChange.eraseToAnyPublisher())
    }
}
