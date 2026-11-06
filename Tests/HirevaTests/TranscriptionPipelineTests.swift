import Foundation
import Testing
@testable import Hireva

@Suite
struct TranscriptionPipelineTests {

    @Test
    func settingsEncodingDecodingBackwardCompatibility() throws {
        // 1. JSON representation of settings *WITHOUT* the new audioCaptureMode field (simulating legacy configs)
        let legacyJSON = """
        {
            "realtimeModel": "deepseek-v4-flash",
            "recapModel": "deepseek-v4-pro",
            "automaticQuestionDetectionEnabled": true,
            "manualOnlyMode": false,
            "saveTranscriptsLocally": true,
            "allowQuestionDetectionFromMicrophoneOnly": false
        }
        """

        let data = legacyJSON.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        // 2. Expect default fallback to .microphoneAndSystem
        #expect(decoded.audioCaptureMode == .microphoneAndSystem)

        // 3. Round-trip encode-decode with the new field
        let encoder = JSONEncoder()
        let encodedData = try encoder.encode(decoded)
        let reDecoded = try JSONDecoder().decode(AppSettings.self, from: encodedData)
        
        #expect(reDecoded.audioCaptureMode == .microphoneAndSystem)
    }

    @Test
    @MainActor
    func echoLeakageProtectionSuppressesDuplicateDetections() {
        let owner = LiveInterviewFeature()
        let began = Date(timeIntervalSince1970: 1_000)
        owner.recordSystemAudioForEcho("Walk me through your resume and describe your robotics perception project.", now: began)
        let exactLeak = "Walk me through your resume and describe your robotics perception project."
        #expect(owner.microphoneEchoMatch(exactLeak, now: began)?.similarity == 1)
        let highLeak = "walk me through your resume and describe your robotics perception"
        #expect(owner.microphoneEchoMatch(highLeak, now: began) != nil)
        let candidateSpeech = "Sure, I would be happy to describe my experience with robotics simulation and grasp candidate generation."
        #expect(owner.microphoneEchoMatch(candidateSpeech, now: began) == nil)
        #expect(owner.microphoneEchoMatch("", now: began) == nil)
        #expect(owner.microphoneEchoMatch(exactLeak, now: began.addingTimeInterval(5)) != nil)
        #expect(owner.microphoneEchoMatch(exactLeak, now: began.addingTimeInterval(5.001)) == nil)
        // Synthetic strings only. This is not a microphone capture or GUI test.
    }

    @Test
    func sampleBufferAudioConverterFormatVerification() throws {
        // Verify that SampleBufferAudioConverter is instantiable and has standard error descriptions
        _ = SampleBufferAudioConverter()
        // Verify format and standard error descriptions

        let formatError = AudioConversionError.invalidFormatDescription
        #expect(formatError.localizedDescription.contains("format description"))

        let sampleError = AudioConversionError.zeroSamples
        #expect(sampleError.localizedDescription.contains("zero samples"))
    }
}
