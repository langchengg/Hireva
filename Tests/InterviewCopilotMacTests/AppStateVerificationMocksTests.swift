import Foundation
import Testing
@testable import InterviewCopilotMac

@Suite
@MainActor
struct AppStateVerificationMocksTests {
    
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
        // Ensure environment variable is NOT "1" for this normal startup check
        let originalEnvVal = ProcessInfo.processInfo.environment["ENABLE_VERIFICATION_MOCKS"]
        
        // Temporarily clear it to simulate standard production run
        setenv("ENABLE_VERIFICATION_MOCKS", "", 1)
        unsetenv("ENABLE_VERIFICATION_MOCKS")
        
        defer {
            // Restore original state
            if let val = originalEnvVal {
                setenv("ENABLE_VERIFICATION_MOCKS", val, 1)
            } else {
                unsetenv("ENABLE_VERIFICATION_MOCKS")
            }
        }
        
        let database = try makeTemporaryDatabase()
        let settings = SettingsRepository(database: database)
        let keychain = InMemoryAPIKeyStore()
        let router = LLMRouter(settingsRepository: settings, apiKeyStore: keychain)
        let permissionService = MockPermissionService()
        
        let appState = AppState(
            database: database,
            llmRouter: router,
            permissionService: permissionService
        )
        
        // Assertions: no mocks should be injected during normal production startup
        #expect(appState.currentSuggestion == nil)
        #expect(appState.lastDetectedQuestion == nil)
        #expect(appState.lastRetrievalTrace == nil)
        #expect(appState.sessions.isEmpty)
    }

    @Test
    func testMockInjectionIsActiveOnlyWhenVariableIsOne() throws {
        let originalEnvVal = ProcessInfo.processInfo.environment["ENABLE_VERIFICATION_MOCKS"]
        
        // Explicitly set it to "1" to enable injection
        setenv("ENABLE_VERIFICATION_MOCKS", "1", 1)
        
        defer {
            // Restore original state
            if let val = originalEnvVal {
                setenv("ENABLE_VERIFICATION_MOCKS", val, 1)
            } else {
                unsetenv("ENABLE_VERIFICATION_MOCKS")
            }
        }
        
        let database = try makeTemporaryDatabase()
        let settings = SettingsRepository(database: database)
        let keychain = InMemoryAPIKeyStore()
        let router = LLMRouter(settingsRepository: settings, apiKeyStore: keychain)
        let permissionService = MockPermissionService()
        
        let appState = AppState(
            database: database,
            llmRouter: router,
            permissionService: permissionService
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
        let originalEnvMocks = ProcessInfo.processInfo.environment["ENABLE_VERIFICATION_MOCKS"]
        let originalEnvSection = ProcessInfo.processInfo.environment["DEFAULT_APP_SECTION"]
        
        unsetenv("ENABLE_VERIFICATION_MOCKS")
        setenv("DEFAULT_APP_SECTION", "sessions", 1)
        
        defer {
            if let val = originalEnvMocks {
                setenv("ENABLE_VERIFICATION_MOCKS", val, 1)
            } else {
                unsetenv("ENABLE_VERIFICATION_MOCKS")
            }
            if let val = originalEnvSection {
                setenv("DEFAULT_APP_SECTION", val, 1)
            } else {
                unsetenv("DEFAULT_APP_SECTION")
            }
        }
        
        let database = try makeTemporaryDatabase()
        let settings = SettingsRepository(database: database)
        let keychain = InMemoryAPIKeyStore()
        let router = LLMRouter(settingsRepository: settings, apiKeyStore: keychain)
        let permissionService = MockPermissionService()
        
        let appState = AppState(
            database: database,
            llmRouter: router,
            permissionService: permissionService
        )
        
        // Assert selectedSection is still default (.home), ignoring DEFAULT_APP_SECTION
        #expect(appState.selectedSection == .home)
    }

    @Test
    func testDefaultAppSectionEffectiveWhenVerificationMocksIsOne() throws {
        let originalEnvMocks = ProcessInfo.processInfo.environment["ENABLE_VERIFICATION_MOCKS"]
        let originalEnvSection = ProcessInfo.processInfo.environment["DEFAULT_APP_SECTION"]
        
        setenv("ENABLE_VERIFICATION_MOCKS", "1", 1)
        setenv("DEFAULT_APP_SECTION", "sessions", 1)
        
        defer {
            if let val = originalEnvMocks {
                setenv("ENABLE_VERIFICATION_MOCKS", val, 1)
            } else {
                unsetenv("ENABLE_VERIFICATION_MOCKS")
            }
            if let val = originalEnvSection {
                setenv("DEFAULT_APP_SECTION", val, 1)
            } else {
                unsetenv("DEFAULT_APP_SECTION")
            }
        }
        
        let database = try makeTemporaryDatabase()
        let settings = SettingsRepository(database: database)
        let keychain = InMemoryAPIKeyStore()
        let router = LLMRouter(settingsRepository: settings, apiKeyStore: keychain)
        let permissionService = MockPermissionService()
        
        let appState = AppState(
            database: database,
            llmRouter: router,
            permissionService: permissionService
        )
        
        // Assert selectedSection matches DEFAULT_APP_SECTION value (.sessions)
        #expect(appState.selectedSection == .sessions)
    }
}
