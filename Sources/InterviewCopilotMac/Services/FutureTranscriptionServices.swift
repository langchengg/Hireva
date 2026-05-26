import Foundation
import AVFoundation

final class OpenAIRealtimeTranscriptionService: TranscriptionProvider {
    let providerName = "OpenAI Realtime"
    var segments: AsyncStream<TranscriptSegment> { AsyncStream { $0.finish() } }
    func start(sessionID: String) async throws {
        throw TranscriptionError.unavailable("OpenAI Realtime transcription adapter is not configured yet.")
    }
    func stop() {}
}

final class DeepgramTranscriptionService: TranscriptionProvider {
    let providerName = "Deepgram"
    var segments: AsyncStream<TranscriptSegment> { AsyncStream { $0.finish() } }
    func start(sessionID: String) async throws {
        throw TranscriptionError.unavailable("Deepgram transcription adapter is not configured yet.")
    }
    func stop() {}
}

protocol SystemAudioCaptureService: AnyObject {
    var isAvailable: Bool { get }
    var currentCapturedAppName: String? { get }
    var currentOutputDeviceName: String? { get }
    func startSystemAudioCapture() async throws
    func stopSystemAudioCapture()
}

final class PlaceholderSystemAudioCaptureService: SystemAudioCaptureService {
    var isAvailable: Bool { false }
    var currentCapturedAppName: String? { nil }
    var currentOutputDeviceName: String? { nil }

    func startSystemAudioCapture() async throws {
        throw TranscriptionError.unavailable("System audio capture is not implemented yet. In microphone-only mode, interviewer detection may be unreliable.")
    }

    func stopSystemAudioCapture() {}
}

final class FutureSystemAudioTranscriptionService: TranscriptionProvider {
    let providerName = "System Audio Capture"
    var segments: AsyncStream<TranscriptSegment> { AsyncStream { $0.finish() } }
    
    func start(sessionID: String) async throws {
        throw TranscriptionError.unavailable("System audio transcription is not implemented yet. Microphone-only mode is active.")
    }
    
    func stop() {}
}

protocol SpeakerDiarizationService: AnyObject {
    var isEnabled: Bool { get }
    func enrollSpeaker(id: String, audioData: Data) async throws
    func diarize(buffer: AVAudioPCMBuffer) async throws -> SpeakerRole
}

final class PlaceholderSpeakerDiarizationService: SpeakerDiarizationService {
    var isEnabled: Bool { false }
    func enrollSpeaker(id: String, audioData: Data) async throws {}
    func diarize(buffer: AVAudioPCMBuffer) async throws -> SpeakerRole {
        return .unknown
    }
}
