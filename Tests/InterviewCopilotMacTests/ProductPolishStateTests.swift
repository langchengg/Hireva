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
    func cvOnlyContextCanStartWithOptionalOpportunityWarning() throws {
        let appState = try makeAppState()
        appState.answerProviderModeOverride = .localQwenPrimary
        appState.hasCV = true
        appState.hasJD = false
        appState.diagnostics.storedCVChunkCount = 3
        appState.diagnostics.storedJDChunkCount = 0
        appState.latexPollutedChunkCount = 0
        installCandidateProfile(appState)
        appState.automaticContextReadiness = .ready
        grantPermissions(appState)

        #expect(appState.onboardingComplete)
        #expect(appState.liveBlockedReason == nil)
        #expect(appState.coreInterviewReadinessPassed)
        #expect(appState.primaryHomeActionTitle == "Start Interview")
        #expect(appState.relevantContextStatus == "Clean Keyword RAG")
        #expect(appState.readinessCheckItems.first { $0.id == "documents" }?.status == .warning)
        #expect(appState.readinessCheckItems.first { $0.id == "chunks" }?.status == .passed)
    }

    @Test
    func cvOnlyContextCannotStartWhileCandidateExtractionIsInFlight() throws {
        let appState = try makeAppState()
        appState.answerProviderModeOverride = .localQwenPrimary
        appState.hasCV = true
        appState.hasJD = false
        appState.diagnostics.storedCVChunkCount = 3
        appState.latexPollutedChunkCount = 0
        installCandidateProfile(appState)
        appState.automaticContextReadiness = .extracting
        grantPermissions(appState)

        #expect(!appState.onboardingComplete)
        #expect(appState.liveBlockedReason == "Candidate context is still being prepared.")
        #expect(!appState.coreInterviewReadinessPassed)
        #expect(appState.primaryHomeActionTitle == "Run Readiness Check")
    }

    @Test
    func jdOnlyContextRemainsBlockedWithoutCandidateEvidence() throws {
        let appState = try makeAppState()
        appState.answerProviderModeOverride = .localQwenPrimary
        appState.hasCV = false
        appState.hasJD = true
        appState.diagnostics.storedCVChunkCount = 0
        appState.diagnostics.storedJDChunkCount = 3
        appState.latexPollutedChunkCount = 0
        grantPermissions(appState)

        #expect(!appState.onboardingComplete)
        #expect(appState.liveBlockedReason == "Add your CV before starting an interview.")
        #expect(!appState.coreInterviewReadinessPassed)
        #expect(appState.primaryHomeActionTitle == "Run Readiness Check")
        #expect(appState.readinessCheckItems.first { $0.id == "documents" }?.status == .failed)
    }

    @Test
    func homeLiveAnswerPrefersVisibleSuggestionOverStreamingSpinner() throws {
        let appState = try makeAppState()
        makeReady(appState)
        appState.isStreamingSayFirst = true
        appState.streamedSayFirst = ""
        appState.currentSuggestion = SuggestionCard(
            id: "card-1",
            sessionID: "session-1",
            questionID: "question-1",
            strategy: "Local First Answer Fallback",
            sayFirst: "I can walk through one project by explaining the problem, my implementation choices, and the result.",
            keyPoints: ["Problem and constraints.", "Implementation choices.", "Result."],
            followUpReady: [],
            confidence: 0.45,
            caution: nil,
            evidenceUsed: [],
            riskLevel: .medium,
            modelName: "local-first-answer-fallback",
            promptVersion: "local-first-answer-v1",
            providerName: "Local First Answer Fallback",
            providerBaseURL: "",
            isLocal: true,
            createdAt: Date(),
            sayFirstSource: "local_first_answer_fallback"
        )

        #expect(appState.homeLiveAnswerPreviewText == appState.currentSuggestion?.sayFirst)
        #expect(appState.homeLiveAnswerPreviewText != "Generating first answer...")
    }

    @Test
    func readinessFailedItemsExposeOneAction() throws {
        let appState = try makeAppState()
        makeReady(appState)
        appState.answerProviderModeOverride = .deepSeekPrimary
        appState.keychainDeepSeekKeyExists = false
        appState.latexPollutedChunkCount = 2

        let failed = appState.readinessCheckItems.filter { $0.status == .failed }

        #expect(failed.contains { $0.id == "answer-provider" && $0.action == .openSettings })
        #expect(failed.contains { $0.id == "latex" && $0.action == .rebuildRAG })
        #expect(failed.allSatisfy { $0.actionTitle != nil && $0.action != nil })
    }

    @Test
    func localQwenPrimaryDoesNotRequireOptionalDeepSeekCredential() throws {
        let appState = try makeAppState()
        makeReady(appState)
        appState.answerProviderModeOverride = .localQwenPrimary
        appState.keychainDeepSeekKeyExists = false

        #expect(appState.coreInterviewReadinessPassed)
        #expect(appState.selectedAnswerProviderConfigured)
        #expect(appState.readinessCheckItems.first { $0.id == "answer-provider" }?.status == .passed)
    }

    @Test
    func deepSeekPrimaryStillRequiresDeepSeekCredential() throws {
        let appState = try makeAppState()
        makeReady(appState)
        appState.answerProviderModeOverride = .deepSeekPrimary
        appState.keychainDeepSeekKeyExists = false

        #expect(!appState.coreInterviewReadinessPassed)
        #expect(!appState.selectedAnswerProviderConfigured)
        #expect(appState.readinessCheckItems.first { $0.id == "answer-provider" }?.status == .failed)
    }

    @Test
    func readinessSeparatesMicrophoneFromSpeechRecognitionPermission() throws {
        let appState = try makeAppState()
        makeReady(appState)
        appState.microphonePermissionState = .authorized
        appState.permissionSnapshot.speechRecognition = .notDetermined

        let microphone = appState.readinessCheckItems.first { $0.id == "microphone" }
        let speech = appState.readinessCheckItems.first { $0.id == "speech" }

        #expect(microphone?.status == .passed)
        #expect(speech?.status == .failed)
        #expect(speech?.actionTitle == "Request Speech Access")
        #expect(speech?.action == .openPermissions)
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
        installCandidateProfile(appState)
        appState.automaticContextReadiness = .ready
        grantPermissions(appState)
    }

    private func installCandidateProfile(_ appState: AppState) {
        let evidence = ProfileEvidence(
            id: "product-polish-candidate-evidence",
            statement: "Built and operated a documented synthetic service.",
            sourceDocumentID: "product-polish-cv",
            sourceChunkID: "product-polish-cv-chunk",
            sourceSpan: "Built and operated a documented synthetic service.",
            confidence: 1,
            evidenceType: .experience,
            explicitness: .explicit
        )
        let profile = CandidateProfile(
            id: "product-polish-candidate",
            displayName: "Product Polish Candidate",
            sourceDocumentIDs: ["product-polish-cv"],
            education: [],
            experience: [evidence],
            projects: [],
            skills: [],
            publications: [],
            achievements: [],
            declaredGaps: [],
            goals: [],
            generatedSummary: nil,
            version: 1,
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        appState.candidateProfiles = [profile]
        appState.activeCandidateProfileID = profile.id
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
