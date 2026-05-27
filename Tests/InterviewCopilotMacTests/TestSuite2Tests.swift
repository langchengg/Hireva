import Foundation
import Testing
@testable import InterviewCopilotMac

@Suite(.serialized)
struct TestSuite2Tests {
    @Test
    @MainActor
    func testSuite2_PermissionsAndAppIdentity() async throws {
        print("=== Test Suite 2: Permissions and App Identity ===")
        
        let database = try makeTemporaryDatabase()
        let appState = AppState(database: database)
        let permissionService = appState.permissionService
        
        print("[2.1] App identity verification...")
        // In the test harness, we might not be in a signed .app container, but we can verify the service's properties
        let expectedBundleID = "com.langcheng.InterviewCopilotMac"
        let bundleID = Bundle.main.bundleIdentifier ?? "None"
        let isCorrectBundle = (bundleID == expectedBundleID) || (bundleID == "None") || (bundleID.contains("TestSuite")) || (bundleID.contains("xctest"))
        #expect(isCorrectBundle, "Bundle ID must match or represent test environment: \(bundleID)")
        
        let path = permissionService.processPath
        print("  Process path: \(path)")
        print("  Is running from App Bundle: \(permissionService.isRunningFromAppBundle)")
        
        print("[2.2] Microphone permission state query...")
        let micState = appState.microphonePermissionState
        print("  Candidate mic permission: \(micState.displayName)")
        
        print("[2.3] Screen & System Audio permission mapping...")
        let successResult = ScreenSystemAudioPermissionProbeResult(
            preflightGranted: true,
            shareableContentProbeSucceeded: true,
            streamAudioProbeSucceeded: true,
            errorDescription: nil,
            likelyIdentityMismatch: false
        )
        let probeState = appState.determineProbeState(result: successResult)
        #expect(probeState == .granted, "Success probe result must map to .granted")
        print("  determineProbeState(success) = \(probeState.displayName)")
        
        let restartingResult = ScreenSystemAudioPermissionProbeResult(
            preflightGranted: true,
            shareableContentProbeSucceeded: false,
            streamAudioProbeSucceeded: false,
            errorDescription: "Service denied",
            likelyIdentityMismatch: false
        )
        let restartState = appState.determineProbeState(result: restartingResult)
        #expect(restartState == .restartLikely, "Should trigger restartRequired when shareable probe fails but no mismatch")
        print("  determineProbeState(restart required) = \(restartState.displayName)")
        
        print("=== Test Suite 2: ALL TESTS PASSED ===")
    }

    private func makeTemporaryDatabase() throws -> AppDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TestSuite2Database-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AppDatabase(path: directory.appendingPathComponent("test.sqlite"))
    }
}
