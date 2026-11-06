import Foundation
import Speech
import Testing
@testable import Hireva

/// Request allocation only: no recognizer, recognition task, device, permission
/// request or PCM is created. This characterizes the new explicit ASR contract.
struct AppleSpeechRequestPolicyTests {
    enum MatrixCase: CaseIterable, Equatable, Sendable {
        case defaultUnsupported, defaultSupported, requiredUnsupported, requiredSupported
        var required: Bool { self == .requiredUnsupported || self == .requiredSupported }
        var supported: Bool { self == .defaultSupported || self == .requiredSupported }
    }

    @Test(arguments: MatrixCase.allCases)
    func actualFactoryPreservesDefaultAndFailsClosedWhenRequired(_ sample: MatrixCase) throws {
        var allocations = 0
        do {
            let request = try AppleSpeechRequestFactory.make(
                requiresOnDeviceRecognition: sample.required,
                supportsOnDeviceRecognition: sample.supported,
                verificationMode: false,
                allocate: {
                    allocations += 1
                    return SFSpeechAudioBufferRecognitionRequest()
                })
            #expect(sample != .requiredUnsupported)
            #expect(allocations == 1)
            #expect(request.shouldReportPartialResults)
            #expect(request.requiresOnDeviceRecognition == sample.required)
        } catch {
            #expect(sample == .requiredUnsupported)
            #expect(error is TranscriptionError)
            #expect(allocations == 0)
        }
    }

    @Test(arguments: [false, true])
    func verificationCannotRelaxNativeRequestPrivacy(supported: Bool) throws {
        var allocations = 0
        do {
            let request = try AppleSpeechRequestFactory.make(
                requiresOnDeviceRecognition: false,
                supportsOnDeviceRecognition: supported,
                verificationMode: true,
                allocate: {
                    allocations += 1
                    return SFSpeechAudioBufferRecognitionRequest()
                })
            #expect(supported)
            #expect(allocations == 1)
            #expect(request.requiresOnDeviceRecognition)
        } catch {
            #expect(!supported)
            #expect(error is TranscriptionError)
            #expect(allocations == 0)
        }
    }

    @Test
    func existingConfigDefaultAndExplicitRequirementHaveDistinctFrozenIdentity() {
        let legacy = ASRConfig(sessionID: "synthetic-same", captureMode: .systemAudioOnly)
        let local = ASRConfig(sessionID: "synthetic-same", captureMode: .systemAudioOnly,
            requiresOnDeviceRecognition: true)
        #expect(!legacy.requiresOnDeviceRecognition)
        #expect(local.requiresOnDeviceRecognition)
        #expect(legacy.captureMode == local.captureMode)
        #expect(legacy.sessionID == local.sessionID)
        #expect(legacy != local)
    }
}
