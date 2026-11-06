import Foundation
import Testing
@testable import Hireva

/// These current-API paths create recognition sessions only. A session is
/// not authority to stop native input owned elsewhere. No capture is started.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct AppleSpeechRecognitionOnlyCaptureAuthorityTests {
    @Test(arguments: [true, false])
    func recognitionOnlySessionDoesNotStopAnUnregisteredSystemCapture(diagnostic: Bool) async throws {
        var nativeStopCalls = 0
        let service = AppleSpeechTranscriptionService(stopTestingOperations: .init(
            unregisterMicrophone: { _ in }, unregisterSystemAudio: { _ in },
            stopSystemAudio: { nativeStopCalls += 1 }),
            pcmTestingOperations: .init(append: { _ in }, endAudio: {}))
        do {
            if diagnostic {
                service.startDiagnosticSystemAudioSession(sessionID: "synthetic-recognition-only-diagnostic")
            } else {
                // The existing DEBUG test contract simulates recognition and
                // skips actual input registration. It must also skip its stop.
                try await service.start(sessionID: "synthetic-recognition-only-start", captureMode: .systemAudioOnly)
            }
            try #require(service.systemAudioSession?.isRecognitionActive == true)
            service.stop()
            await service.finishStoppingAudioInput()
            #expect(nativeStopCalls == 0)
            #expect(!service.hasUnreleasedAudioInput)
            service.stop()
            await service.finishStoppingAudioInput()
            #expect(nativeStopCalls == 0)
        } catch {
            service.stop()
            await service.finishStoppingAudioInput()
            throw error
        }
    }
}
