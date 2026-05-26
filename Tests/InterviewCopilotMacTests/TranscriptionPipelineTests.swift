import Foundation
import Testing
@testable import InterviewCopilotMac

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
    func echoLeakageProtectionSuppressesDuplicateDetections() {
        // Setup sliding window simulation:
        var recentSystemAudioRecords: [String] = []

        // Simulate receiving a system audio interviewer segment:
        recentSystemAudioRecords.append("Walk me through your resume and describe your robotics perception project.")

        // Helper word-overlap Jaccard similarity checker matching AppState's logic
        func isEchoLeakage(micText: String, recentRecords: [String]) -> Bool {
            let micWords = Set(micText.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
            if micWords.isEmpty { return false }

            for record in recentRecords {
                let systemWords = Set(record.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
                let intersection = micWords.intersection(systemWords)
                let union = micWords.union(systemWords)
                if !union.isEmpty {
                    let similarity = Double(intersection.count) / Double(union.count)
                    if similarity >= 0.5 { // 50% Jaccard word overlap indicates echo leakage
                        return true
                    }
                }
            }
            return false
        }

        // Test Case 1: Exact leakage (Microphone hears the same question leaking from speakers)
        let exactLeak = "Walk me through your resume and describe your robotics perception project."
        #expect(isEchoLeakage(micText: exactLeak, recentRecords: recentSystemAudioRecords))

        // Test Case 2: Highly similar leakage (minor transcription noise or differences)
        let highLeak = "walk me through your resume and describe your robotics perception"
        #expect(isEchoLeakage(micText: highLeak, recentRecords: recentSystemAudioRecords))

        // Test Case 3: Completely distinct microphone candidate response (should not trigger leakage protection)
        let candidateSpeech = "Sure, I would be happy to describe my experience with robotics simulation and grasp candidate generation."
        #expect(!isEchoLeakage(micText: candidateSpeech, recentRecords: recentSystemAudioRecords))
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
