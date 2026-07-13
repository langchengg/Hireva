import Foundation
import Testing
import GRDB
@testable import Hireva

@Suite @MainActor
struct PermissionProbeTests {

    private func makeTemporaryDatabase() throws -> AppDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HirevaPermissionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AppDatabase(path: directory.appendingPathComponent("test.sqlite"))
    }

    @Test
    func testScreenSystemAudioPermissionStateDisplayNames() {
        let grantedState = ScreenSystemAudioPermissionState.granted
        #expect(grantedState.displayName == "Granted")

        let missingState = ScreenSystemAudioPermissionState.permissionMissing
        #expect(missingState.displayName == "Permission Missing")

        let restartState = ScreenSystemAudioPermissionState.restartLikely
        #expect(restartState.displayName == "Restart Required")

        let mismatchState = ScreenSystemAudioPermissionState.identityMismatch
        #expect(mismatchState.displayName == "Identity Mismatch")

        let shareableErrorState = ScreenSystemAudioPermissionState.shareableContentProbeFailed("Demo Error")
        #expect(shareableErrorState.displayName == "Shareable Content Probe Failed: Demo Error")

        let streamErrorState = ScreenSystemAudioPermissionState.streamAudioProbeFailed("Timeout")
        #expect(streamErrorState.displayName == "Stream Audio Probe Failed: Timeout")
    }

    @Test
    func testScreenSystemAudioPermissionProbeResultMapping() throws {
        let database = try makeTemporaryDatabase()
        let appState = AppState(database: database)

        // Test mapping rules to state:
        // 1. Success case: everything succeeded
        let successResult = ScreenSystemAudioPermissionProbeResult(
            preflightGranted: true,
            shareableContentProbeSucceeded: true,
            streamAudioProbeSucceeded: true,
            errorDescription: nil,
            likelyIdentityMismatch: false
        )
        
        var state = appState.determineProbeState(result: successResult)
        #expect(state == .granted)

        // 2. Missing permission case: preflight denied and probes failed
        let missingResult = ScreenSystemAudioPermissionProbeResult(
            preflightGranted: false,
            shareableContentProbeSucceeded: false,
            streamAudioProbeSucceeded: false,
            errorDescription: "Access Denied",
            likelyIdentityMismatch: false
        )
        state = appState.determineProbeState(result: missingResult)
        #expect(state == .permissionMissing)

        // 3. Restart likely case: preflight granted but shareable failed with no identity mismatch
        let restartResult = ScreenSystemAudioPermissionProbeResult(
            preflightGranted: true,
            shareableContentProbeSucceeded: false,
            streamAudioProbeSucceeded: false,
            errorDescription: "Service denied",
            likelyIdentityMismatch: false
        )
        state = appState.determineProbeState(result: restartResult)
        #expect(state == .restartLikely)

        // 4. Mismatch case: likelyIdentityMismatch is true
        let mismatchResult = ScreenSystemAudioPermissionProbeResult(
            preflightGranted: true,
            shareableContentProbeSucceeded: false,
            streamAudioProbeSucceeded: false,
            errorDescription: "Wrong Bundle ID",
            likelyIdentityMismatch: true
        )
        state = appState.determineProbeState(result: mismatchResult)
        #expect(state == .identityMismatch)

        // 5. Stream audio failed
        let streamFailResult = ScreenSystemAudioPermissionProbeResult(
            preflightGranted: true,
            shareableContentProbeSucceeded: true,
            streamAudioProbeSucceeded: false,
            errorDescription: "Timeout receiving buffers",
            likelyIdentityMismatch: false
        )
        state = appState.determineProbeState(result: streamFailResult)
        #expect(state == .streamAudioProbeFailed("Timeout receiving buffers"))
    }
}
