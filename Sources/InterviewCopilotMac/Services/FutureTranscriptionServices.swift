import Foundation

final class OpenAIRealtimeTranscriptionService: TranscriptionProvider {
    let providerName = "OpenAI Realtime"
    var segments: AsyncStream<TranscriptSegment> { AsyncStream { $0.finish() } }
    func start(sessionID: String) async throws { throw TranscriptionError.unavailable("OpenAI Realtime transcription adapter is not configured yet.") }
    func stop() {}
}

final class DeepgramTranscriptionService: TranscriptionProvider {
    let providerName = "Deepgram"
    var segments: AsyncStream<TranscriptSegment> { AsyncStream { $0.finish() } }
    func start(sessionID: String) async throws { throw TranscriptionError.unavailable("Deepgram transcription adapter is not configured yet.") }
    func stop() {}
}

protocol SystemAudioCaptureService {
    func start() async throws
    func stop()
}

final class MicrophoneCaptureService: SystemAudioCaptureService {
    func start() async throws {}
    func stop() {}
}

final class CoreAudioTapCaptureService: SystemAudioCaptureService {
    func start() async throws {
        // macOS 14.4+ Core Audio process taps can support future system audio capture with public APIs and explicit user permission.
        throw TranscriptionError.unavailable("System audio capture is a future module and is not enabled in this MVP.")
    }

    func stop() {}
}
