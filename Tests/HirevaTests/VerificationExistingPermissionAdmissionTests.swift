import Foundation
import Testing
import os
@testable import Hireva

/// Calls the real service/one-shot APIs; SDK issuance is replaced, never TCC.
@Suite
@MainActor
struct VerificationExistingPermissionAdmissionTests {
    @Test(.timeLimit(.minutes(1)), arguments: PermissionAdmissionScenario.allCases)
    func verificationRequestsNeverIssueTCCAndOrdinaryRequestsStillDo(scenario: PermissionAdmissionScenario) async throws {
        let fixture = try PermissionAdmissionInputFixture()
        defer { fixture.remove() }
        let admission = fixture.admission(for: scenario)
        #expect(admission == scenario.expected)
        let requests = PermissionAdmissionRequests()
        let service = PermissionAdmissionStatusFixture(admission: admission, requests: requests)

        let microphone = await service.requestMicrophonePermission()
        let speech = await service.requestSpeechRecognition()
        service.requestScreenRecording()

        let allowed = scenario == .ordinary
        #expect(requests.counts.microphone == (allowed ? 1 : 0))
        #expect(requests.counts.speech == (allowed ? 1 : 0))
        #expect(requests.counts.screen == (allowed ? 1 : 0))
        #expect(microphone == (allowed ? .authorized : .notDetermined))
        #expect(speech == (allowed ? .granted : .notDetermined))
    }

    @Test(.timeLimit(.minutes(1)), arguments: PermissionAdmissionScenario.allCases)
    func realShareableContentEntryRejectsMissingOrInvalidVerificationBeforeFetch(scenario: PermissionAdmissionScenario) async throws {
        let fixture = try PermissionAdmissionInputFixture()
        defer { fixture.remove() }
        let admission = fixture.admission(for: scenario)
        for granted in [false, true] {
            let calls = PermissionAdmissionRequests()
            var failure: Error?
            do {
                _ = try await NativeSystemAudioCaptureStream.shareableContent(
                    permissionAdmission: admission,
                    preflightAccess: { calls.recordPreflight(); return granted },
                    fetch: { completion in
                        calls.recordFetch()
                        // No SDK object is built or retained, and no callback is held.
                        completion(nil, PermissionAdmissionFetchSentinel.issued)
                    })
            } catch { failure = error }
            let shouldFetch = scenario == .ordinary || (scenario == .validVerification && granted)
            #expect(calls.counts.fetch == (shouldFetch ? 1 : 0))
            #expect(calls.counts.preflight == (scenario == .validVerification ? 1 : 0))
            if shouldFetch {
                #expect(failure is PermissionAdmissionFetchSentinel)
            } else {
                #expect(failure is VerificationPermissionAdmissionError)
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func revokedExistingAuthorizationBlocksTheNextRealEnumeration() async throws {
        let fixture = try PermissionAdmissionInputFixture()
        defer { fixture.remove() }
        let admission = fixture.admission(for: .validVerification)
        let calls = PermissionAdmissionRequests()
        // Fresh permission observation belongs to each actual issuance. This is
        // a deterministic observation change, not an OS permission mutation.
        for granted in [true, false] {
            do {
                _ = try await NativeSystemAudioCaptureStream.shareableContent(
                    permissionAdmission: admission, preflightAccess: { granted },
                    fetch: { completion in
                        calls.recordFetch()
                        completion(nil, PermissionAdmissionFetchSentinel.issued)
                    })
            } catch { }
        }
        #expect(calls.counts.fetch == 1)
    }
}

enum PermissionAdmissionScenario: CaseIterable, Equatable, Sendable {
    case ordinary, validVerification, invalidExplicitVerification
    case verificationOnlyMissingEnvironment, verificationOnlyWrongMode, verificationOnlyMalformedInput

    var expected: VerificationPermissionAdmission {
        switch self {
        case .ordinary: .production
        case .validVerification: .existingAuthorizationOnly
        default: .invalidVerification
        }
    }
}

private enum PermissionAdmissionFetchSentinel: Error { case issued }

private final class PermissionAdmissionRequests: Sendable {
    struct Counts: Sendable { var microphone = 0; var speech = 0; var screen = 0; var fetch = 0; var preflight = 0 }
    private let storage = OSAllocatedUnfairLock(initialState: Counts())
    var counts: Counts { storage.withLock { $0 } }
    func recordMicrophone() { storage.withLock { $0.microphone += 1 } }
    func recordSpeech() { storage.withLock { $0.speech += 1 } }
    func recordScreen() { storage.withLock { $0.screen += 1 } }
    func recordFetch() { storage.withLock { $0.fetch += 1 } }
    func recordPreflight() { storage.withLock { $0.preflight += 1 } }
}

/// Overrides observations only; request methods and continuation bridge stay real.
private final class PermissionAdmissionStatusFixture: PermissionService {
    init(admission: VerificationPermissionAdmission, requests: PermissionAdmissionRequests) {
        super.init(speechAuthorizationRequest: { completion in
            requests.recordSpeech(); completion(.granted)
        }, permissionAdmission: admission, microphoneAuthorizationRequest: { completion in
            requests.recordMicrophone(); completion(true)
        }, screenCaptureAuthorizationRequest: { requests.recordScreen() })
    }
    override func checkMicrophonePermission() -> MicrophonePermissionState { .notDetermined }
    override func speechStatus() -> PermissionState { .notDetermined }
}

private struct PermissionAdmissionInputFixture {
    let root: URL
    let environment: [String: String]
    let configuration: HirevaVerificationConfiguration

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HirevaPermissionAdmission-\(UUID().uuidString)")
        self.root = root
        do {
            let support = root.appendingPathComponent("support", isDirectory: true)
            let output = root.appendingPathComponent("output", isDirectory: true)
            for directory in [support, output] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            }
            let scenario = root.appendingPathComponent("scenario.json")
            try #"{"synthetic":true,"runID":"permission-admission-test","controlledAudioProcessID":42,"controlledAudioBundleIdentifier":"synthetic.owned.player"}"#.write(
                to: scenario, atomically: true, encoding: .utf8)
            environment = ["HIREVA_VERIFICATION_MODE": "1",
                "HIREVA_VERIFICATION_SCENARIO_PATH": scenario.path,
                "HIREVA_VERIFICATION_APP_SUPPORT_DIR": support.path,
                "HIREVA_VERIFICATION_OUTPUT_ROOT": output.path]
            configuration = try #require(HirevaVerificationConfiguration.load(environment: environment, bundleSourceRoot: nil))
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func admission(for scenario: PermissionAdmissionScenario) -> VerificationPermissionAdmission {
        switch scenario {
        case .ordinary:
            .resolve(verification: nil, environment: [:], verificationOnlyBundle: false)
        case .validVerification:
            .resolve(verification: configuration, environment: environment, verificationOnlyBundle: false)
        case .invalidExplicitVerification:
            .resolve(verification: nil, environment: ["HIREVA_VERIFICATION_MODE": "1"], verificationOnlyBundle: false)
        case .verificationOnlyMissingEnvironment:
            .resolve(verification: nil, environment: [:], verificationOnlyBundle: true)
        case .verificationOnlyWrongMode:
            .resolve(verification: nil, environment: ["HIREVA_VERIFICATION_MODE": "true"], verificationOnlyBundle: true)
        case .verificationOnlyMalformedInput:
            .resolve(verification: nil, environment: ["HIREVA_VERIFICATION_MODE": "1"], verificationOnlyBundle: true)
        }
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
