import Foundation
import Testing
@testable import InterviewCopilotMac

@Suite(.serialized)
@MainActor
struct AppStateVerificationMocksTests {

    @Test
    func swiftPMTestingHelperIsDetectedAsTestEnvironment() {
        #expect(
            isRunningUnderTestOrAutomation(),
            "Undetected test host: \(ProcessInfo.processInfo.processName)"
        )
    }
    
    private func makeTemporaryDatabase() throws -> AppDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppStateVerificationMocksTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AppDatabase(path: directory.appendingPathComponent("test.sqlite"))
    }

    class MockPermissionService: PermissionService {
        override func checkMicrophonePermission() -> MicrophonePermissionState {
            return .authorized
        }
        override func snapshot() -> PermissionSnapshot {
            return PermissionSnapshot(
                microphone: .granted,
                speechRecognition: .granted,
                screenRecording: .granted,
                systemAudioCapture: .granted
            )
        }
        override func refreshPermissions() -> PermissionSnapshot {
            return snapshot()
        }
    }

    @Test
    func testNormalStartupDoesNotInjectMockData() throws {
        let database = try makeTemporaryDatabase()
        let settings = SettingsRepository(database: database)
        let keychain = InMemoryAPIKeyStore()
        let router = LLMRouter(settingsRepository: settings, apiKeyStore: keychain)
        let permissionService = MockPermissionService()
        
        let appState = AppState(
            database: database,
            llmRouter: router,
            permissionService: permissionService,
            verificationMocksEnabled: false
        )
        
        // Assertions: no mocks should be injected during normal production startup
        #expect(appState.currentSuggestion == nil)
        #expect(appState.lastDetectedQuestion == nil)
        #expect(appState.lastRetrievalTrace == nil)
        #expect(appState.sessions.isEmpty)
    }

    @Test
    func testMockInjectionIsActiveOnlyWhenVariableIsOne() throws {
        let database = try makeTemporaryDatabase()
        let settings = SettingsRepository(database: database)
        let keychain = InMemoryAPIKeyStore()
        let router = LLMRouter(settingsRepository: settings, apiKeyStore: keychain)
        let permissionService = MockPermissionService()
        
        let appState = AppState(
            database: database,
            llmRouter: router,
            permissionService: permissionService,
            verificationMocksEnabled: true
        )
        
        // Assertions: mocks MUST be successfully injected
        #expect(appState.currentSuggestion != nil)
        #expect(appState.lastDetectedQuestion != nil)
        #expect(appState.lastRetrievalTrace != nil)
        #expect(!appState.sessions.isEmpty)
        
        let suggestion = appState.currentSuggestion
        #expect(suggestion?.strategy == "Project Walkthrough")
        #expect(suggestion?.confidence == 0.95)
    }

    @Test
    func testDefaultAppSectionIgnoredWhenVerificationMocksNotOne() throws {
        let database = try makeTemporaryDatabase()
        let settings = SettingsRepository(database: database)
        let keychain = InMemoryAPIKeyStore()
        let router = LLMRouter(settingsRepository: settings, apiKeyStore: keychain)
        let permissionService = MockPermissionService()
        
        let appState = AppState(
            database: database,
            llmRouter: router,
            permissionService: permissionService,
            verificationMocksEnabled: false,
            defaultAppSection: .sessions
        )
        
        // Assert selectedSection is still default (.home), ignoring DEFAULT_APP_SECTION
        #expect(appState.selectedSection == .home)
    }

    @Test
    func testDefaultAppSectionEffectiveWhenVerificationMocksIsOne() throws {
        let database = try makeTemporaryDatabase()
        let settings = SettingsRepository(database: database)
        let keychain = InMemoryAPIKeyStore()
        let router = LLMRouter(settingsRepository: settings, apiKeyStore: keychain)
        let permissionService = MockPermissionService()
        
        let appState = AppState(
            database: database,
            llmRouter: router,
            permissionService: permissionService,
            verificationMocksEnabled: true,
            defaultAppSection: .sessions
        )
        
        // Assert selectedSection matches DEFAULT_APP_SECTION value (.sessions)
        #expect(appState.selectedSection == .sessions)
    }
}
