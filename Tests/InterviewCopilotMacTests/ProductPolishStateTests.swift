import Foundation
import Testing
@testable import InterviewCopilotMac

@Suite
@MainActor
struct ProductPolishStateTests {
    @Test
    func homeStateReadyUsesStartInterviewAction() throws {
        let appState = try makeAppState()
        makeReady(appState)

        #expect(appState.coreInterviewReadinessPassed)
        #expect(appState.productInterviewStatus == .ready)
        #expect(appState.primaryHomeActionTitle == "Start Interview")
        #expect(appState.relevantContextStatus == "Clean Keyword RAG")
    }

    @Test
    func homeStateMissingDocumentsRoutesToReadiness() throws {
        let appState = try makeAppState()
        appState.keychainDeepSeekKeyExists = true
        appState.providerConfigurations = [.deepSeekDefault()]
        grantPermissions(appState)

        #expect(!appState.coreInterviewReadinessPassed)
        #expect(appState.productInterviewStatus == .needsAttention)
        #expect(appState.primaryHomeActionTitle == "Run Readiness Check")
        #expect(appState.readinessCheckItems.first { $0.id == "documents" }?.status == .failed)
    }

    @Test
    func readinessFailedItemsExposeOneAction() throws {
        let appState = try makeAppState()
        makeReady(appState)
        appState.keychainDeepSeekKeyExists = false
        appState.latexPollutedChunkCount = 2

        let failed = appState.readinessCheckItems.filter { $0.status == .failed }

        #expect(failed.contains { $0.id == "deepseek" && $0.action == .openSettings })
        #expect(failed.contains { $0.id == "latex" && $0.action == .rebuildRAG })
        #expect(failed.allSatisfy { $0.actionTitle != nil && $0.action != nil })
    }

    @Test
    func floatingDisplayModeDecodesLegacyCompactSetting() throws {
        let json = """
        {
          "realtimeModel": "deepseek-v4-flash",
          "recapModel": "deepseek-v4-pro",
          "automaticQuestionDetectionEnabled": true,
          "manualOnlyMode": false,
          "saveTranscriptsLocally": true,
          "allowQuestionDetectionFromMicrophoneOnly": false,
          "audioCaptureMode": "microphoneAndSystem",
          "floatingWindowOpacity": 0.82,
          "compactMode": true,
          "highContrastFloatingPanel": false
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(AppSettings.self, from: json)

        #expect(settings.floatingAssistantDisplayMode == .compact)
    }

    @Test
    func documentsLatexWarningAndAdditionalNotesFeedContext() async throws {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "ProductPolishDocuments")
        let repository = DocumentRepository(database: database)
        let settings = AppSettings.default
        let retrieval = HybridContextRetrievalService(
            documentRepository: repository,
            settingsProvider: { settings },
            embeddingProviderResolver: { nil }
        )

        _ = try repository.saveDocument(type: .cv, title: "CV", content: longText("Robotics CV project with Swift and ScreenCaptureKit experience."))
        _ = try repository.saveDocument(type: .jobDescription, title: "JD", content: longText("Job requires macOS audio capture and thoughtful product engineering."))
        let notes = try repository.saveDocument(
            type: .additionalNotes,
            title: "Additional Notes",
            content: longText("\\documentclass{article}\\begin{document}\\section{Preference} Mention calm interview pacing and concise first answers.\\end{document}")
        )

        let context = try await retrieval.retrieveContext(question: "How do you pace concise interview answers?", intent: .behavioral)

        #expect(notes.sanitizationWarnings?.isEmpty == false)
        #expect(context.promptText.contains("Additional notes context"))
        #expect(!context.promptText.contains("documentclass"))
    }

    private func makeAppState() throws -> AppState {
        let database = try TestSupport.makeTemporaryDatabase(prefix: "ProductPolishState")
        let settings = SettingsRepository(database: database)
        let keychain = InMemoryAPIKeyStore()
        let router = LLMRouter(settingsRepository: settings, apiKeyStore: keychain)
        return AppState(database: database, llmRouter: router)
    }

    private func makeReady(_ appState: AppState) {
        appState.hasCV = true
        appState.hasJD = true
        appState.keychainDeepSeekKeyExists = true
        appState.providerConfigurations = [.deepSeekDefault()]
        appState.diagnostics.storedCVChunkCount = 3
        appState.diagnostics.storedJDChunkCount = 2
        appState.latexPollutedChunkCount = 0
        grantPermissions(appState)
    }

    private func grantPermissions(_ appState: AppState) {
        appState.microphonePermissionState = .authorized
        appState.systemAudioPermissionState = .granted
        appState.permissionSnapshot = PermissionSnapshot(
            microphone: .granted,
            speechRecognition: .granted,
            screenRecording: .granted,
            systemAudioCapture: .granted
        )
    }

    private func longText(_ seed: String) -> String {
        Array(repeating: seed, count: 8).joined(separator: " ")
    }
}
