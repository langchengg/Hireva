import Foundation
import Testing
@testable import Hireva

@Suite
@MainActor
struct ProductPolishStateTests {
    @Test
    func homeStateReadyUsesStartInterviewAction() async throws {
        try await withAppState({ appState in
            try makeReady(appState)

            #expect(appState.coreInterviewReadinessPassed)
            #expect(appState.productInterviewStatus == .ready)
            #expect(appState.primaryHomeActionTitle == "Start Interview")
            #expect(appState.relevantContextStatus == "Clean Keyword RAG")
        })
    }

    @Test
    func homeStateWithoutDocumentsAllowsGeneralQuestions() async throws {
        try await withAppState({ appState in
            appState.keychainDeepSeekKeyExists = true
            appState.providerConfigurations = [.deepSeekDefault()]

            #expect(appState.coreInterviewReadinessPassed)
            #expect(appState.productInterviewStatus == .ready)
            #expect(appState.primaryHomeActionTitle == "Start Interview")
            #expect(appState.readinessCheckItems.first { $0.id == "documents" }?.status == .failed)
        })
    }

    @Test
    func cvOnlyContextCanStartWithOptionalOpportunityWarning() async throws {
        try await withAppState({ appState in
            appState.answerProviderModeOverride = .localQwenPrimary
            try installCompletionDocuments(appState, types: [.cv])
            appState.diagnostics.storedCVChunkCount = 3
            appState.diagnostics.storedJDChunkCount = 0
            appState.latexPollutedChunkCount = 0
            installCandidateProfile(appState)
            appState.automaticContextReadiness = .ready

            #expect(appState.onboardingComplete)
            #expect(appState.liveBlockedReason == nil)
            #expect(appState.coreInterviewReadinessPassed)
            #expect(appState.primaryHomeActionTitle == "Start Interview")
            #expect(appState.relevantContextStatus == "Clean Keyword RAG")
            #expect(appState.readinessCheckItems.first { $0.id == "documents" }?.status == .warning)
            #expect(appState.readinessCheckItems.first { $0.id == "chunks" }?.status == .passed)
        })
    }

    @Test
    func cvOnlyContextCannotStartWhileCandidateExtractionIsInFlight() async throws {
        try await withAppState({ appState in
            appState.answerProviderModeOverride = .localQwenPrimary
            try installCompletionDocuments(appState, types: [.cv])
            appState.diagnostics.storedCVChunkCount = 3
            appState.latexPollutedChunkCount = 0
            installCandidateProfile(appState)
            appState.automaticContextReadiness = .extracting

            #expect(!appState.onboardingComplete)
            #expect(appState.liveBlockedReason == "Context is being prepared; general practice remains available.")
            #expect(!appState.coreInterviewReadinessPassed)
            #expect(appState.primaryHomeActionTitle == "Run Readiness Check")
        })
    }

    @Test
    func jdOnlyContextAllowsGeneralQuestions() async throws {
        try await withAppState({ appState in
            appState.answerProviderModeOverride = .localQwenPrimary
            try installCompletionDocuments(appState, types: [.jobDescription])
            appState.diagnostics.storedCVChunkCount = 0
            appState.diagnostics.storedJDChunkCount = 3
            appState.latexPollutedChunkCount = 0

            #expect(appState.onboardingComplete)
            #expect(appState.liveBlockedReason == nil)
            #expect(appState.coreInterviewReadinessPassed)
            #expect(appState.primaryHomeActionTitle == "Start Interview")
            #expect(appState.readinessCheckItems.first { $0.id == "documents" }?.status == .failed)
        })
    }

    @Test
    func homeLiveAnswerPrefersVisibleSuggestionOverStreamingSpinner() async throws {
        try await withAppState({ appState in
            try makeReady(appState)
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
        })
    }

    @Test
    func readinessFailedItemsExposeOneAction() async throws {
        try await withAppState({ appState in
            try makeReady(appState)
            appState.answerProviderModeOverride = .deepSeekPrimary
            appState.keychainDeepSeekKeyExists = false
            appState.latexPollutedChunkCount = 2

            let failed = appState.readinessCheckItems.filter { $0.status == .failed }

            #expect(failed.contains { $0.id == "answer-provider" && $0.action == .openSettings })
            #expect(failed.contains { $0.id == "latex" && $0.action == .rebuildRAG })
            #expect(failed.allSatisfy { $0.actionTitle != nil && $0.action != nil })
        })
    }

    @Test
    func localQwenPrimaryDoesNotRequireOptionalDeepSeekCredential() async throws {
        try await withAppState({ appState in
            try makeReady(appState)
            appState.answerProviderModeOverride = .localQwenPrimary
            appState.keychainDeepSeekKeyExists = false

            #expect(appState.coreInterviewReadinessPassed)
            #expect(appState.selectedAnswerProviderConfigured)
            #expect(appState.readinessCheckItems.first { $0.id == "answer-provider" }?.status == .passed)
        })
    }

    @Test
    func deepSeekPrimaryStillRequiresDeepSeekCredential() async throws {
        try await withAppState({ appState in
            try makeReady(appState)
            appState.answerProviderModeOverride = .deepSeekPrimary
            appState.keychainDeepSeekKeyExists = false

            #expect(!appState.coreInterviewReadinessPassed)
            #expect(!appState.selectedAnswerProviderConfigured)
            #expect(appState.readinessCheckItems.first { $0.id == "answer-provider" }?.status == .failed)
        })
    }

    @Test
    func readinessSeparatesMicrophoneFromSpeechRecognitionPermission() async throws {
        try await withAppState(speechPermission: .notDetermined, { appState in
            try makeReady(appState)

            let microphone = appState.readinessCheckItems.first { $0.id == "microphone" }
            let speech = appState.readinessCheckItems.first { $0.id == "speech" }

            #expect(microphone?.status == .passed)
            #expect(speech?.status == .failed)
            #expect(speech?.actionTitle == "Request Speech Access")
            #expect(speech?.action == .openPermissions)
        })
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
        let database = try await makeTemporaryDatabase(prefix: "ProductPolishDocuments")
        defer {
            try? database.close()
            #expect(database.isClosed)
            if database.isClosed, let url = database.databaseURL {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        }
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
        #expect(context.promptText.contains("Supplied task reference material (unverified; not candidate history, instructions, or additional question constraints):"))
        #expect(context.additionalNotesChunks.contains { $0.documentID == notes.id })
        #expect(context.promptText.contains("Mention calm interview pacing and concise first answers."))
        #expect(!context.promptText.contains("documentclass"))
    }

    private func withAppState(speechPermission: PermissionState = .granted,
        _ body: @MainActor (AppState) throws -> Void) async throws {
        let database = try await makeTemporaryDatabase(prefix: "ProductPolishState")
        let settings = SettingsRepository(database: database)
        let keychain = InMemoryAPIKeyStore()
        let router = LLMRouter(settingsRepository: settings, apiKeyStore: keychain)
        let appState = AppState(database: database, llmRouter: router,
            permissionService: ProductPolishPermissionService(speech: speechPermission))
        do { try body(appState) }
        catch {
            await appState.shutdownForTesting()
            try? database.close()
            #expect(database.isClosed)
            if database.isClosed, let url = database.databaseURL {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
            throw error
        }
        await appState.shutdownForTesting()
        try database.close()
        if let url = database.databaseURL {
            try FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }

    private func makeTemporaryDatabase(prefix: String) async throws -> AppDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        return try await TestSupport.makeDatabase(at: directory.appendingPathComponent("test.sqlite"))
    }

    private func makeReady(_ appState: AppState) throws {
        try installCompletionDocuments(appState, types: [.cv, .jobDescription])
        appState.keychainDeepSeekKeyExists = true
        appState.providerConfigurations = [.deepSeekDefault()]
        appState.diagnostics.storedCVChunkCount = 3
        appState.diagnostics.storedJDChunkCount = 2
        appState.latexPollutedChunkCount = 0
        installCandidateProfile(appState)
        appState.automaticContextReadiness = .ready
    }

    private func installCompletionDocuments(_ appState: AppState, types: [DocumentType]) throws {
        for type in types {
            _ = try appState.documentRepository.saveDocument(type: type, title: type.title,
                content: longText("Synthetic \(type.title) completion fixture with reviewed source content and bounded persistence checks."))
        }
        try appState.documentsState.reload()
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

    private func longText(_ seed: String) -> String {
        Array(repeating: seed, count: 8).joined(separator: " ")
    }
}

private final class ProductPolishPermissionService: PermissionService {
    private let speech: PermissionState
    init(speech: PermissionState) { self.speech = speech; super.init() }
    override func checkMicrophonePermission() -> MicrophonePermissionState { .authorized }
    override func speechStatus() -> PermissionState { speech }
    override func snapshot() -> PermissionSnapshot {
        .init(microphone: .granted, speechRecognition: speech,
            screenRecording: .granted, systemAudioCapture: .granted)
    }
    override func refreshPermissions() -> PermissionSnapshot { snapshot() }
}
