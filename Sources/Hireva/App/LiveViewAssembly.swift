import SwiftUI

// These hosts are the transitional application composition boundary. Only the
// host observes remaining global readiness, feedback and runtime phase values;
// the feature views retain their concrete Live/Manual/Settings owners directly.
// No display snapshot is cached and no task is owned by these constructors.
struct HomeApplicationHost: View {
    @ObservedObject var appState: AppState
    var body: some View { HomeView(appState: appState) }
}

struct FloatingAssistantApplicationHost: View {
    @ObservedObject var appState: AppState
    var body: some View { FloatingAssistantView(appState: appState) }
}

struct LiveInterviewApplicationHost: View {
    @ObservedObject var appState: AppState
    var body: some View { LiveInterviewView(appState: appState) }
}

// Preserve the lazy Practice controller initialization: the existing Practice
// view is constructed only when its branch actually mounts. Its remaining
// global UI dependency is explicit and is outside this Live content batch.
struct PracticeApplicationHost: View {
    @ObservedObject var appState: AppState
    var body: some View { PracticeView(appState: appState) }
}

extension HomeView {
    @MainActor
    init(appState app: AppState) {
        self.init(
            live: app.liveInterview,
            manual: app.manualCaptureController,
            settingsState: app.settingsState,
            hirevaMode: Binding(get: { [weak app] in app?.hirevaMode ?? .autoDetect }, set: { [weak app] in app?.hirevaMode = $0 }),
            activeIdentity: app.activeGenerationController?.identity,
            elapsedMS: app.activeGenerationElapsedMs ?? app.currentGenerationTelemetry.elapsedMs ?? 0,
            providerStreamActive: app.providerStreamActive,
            productInterviewStatus: app.productInterviewStatus,
            primaryHomeActionTitle: app.primaryHomeActionTitle,
            primaryHomeActionSystemImage: app.primaryHomeActionSystemImage,
            primaryHomeActionShouldStop: app.primaryHomeActionShouldStop,
            coreInterviewReadinessPassed: app.coreInterviewReadinessPassed,
            liveBlockedReason: app.liveBlockedReason,
            anyCaptureRunning: app.anyCaptureRunning,
            isListening: app.isListening,
            selectedAnswerProviderStatusTitle: app.selectedAnswerProviderStatusTitle,
            selectedAnswerProviderConfigured: app.selectedAnswerProviderConfigured,
            userFacingRelevantContextStatus: app.userFacingRelevantContextStatus,
            candidateDisplayName: app.candidateProfiles.first(where: { $0.id == app.activeCandidateProfileID })?.displayName ?? "Missing",
            opportunityTitle: app.opportunityContexts.first(where: { $0.id == app.activeOpportunityContextID })?.title ?? "General",
            domainDisplayName: app.activeInterviewDomainID.displayName,
            contextReadinessStatus: app.contextReadiness.status,
            permissionSummary: app.permissionSummary,
            isFloatingAssistantVisible: app.isFloatingAssistantVisible,
            manualWorkspace: ManualCaptureWorkspaceView(appState: app),
            cancelManualCapture: { [weak app] in app?.cancelManualCapture() },
            clearManualCapture: { [weak app] in app?.clearManualCapture() },
            refreshPermissions: { [weak app] in app?.refreshPermissions() },
            saveSettings: { [weak app] in app?.saveSettings($0) },
            selectSection: { [weak app] in app?.selectSection($0) },
            showFloatingAssistant: { [weak app] in app?.showFloatingAssistant() },
            answerCurrentQuestionOrTranscriptNow: { [weak app] in app?.answerCurrentQuestionOrTranscriptNow() },
            stopListening: { [weak app] in app?.stopListening() },
            startListening: { [weak app] in app?.startListening(mode: .microphone) },
            feedbacks: app.activeActionFeedbacks,
            loadingStates: app.actionLoadingStates,
            beginFeedback: { [weak app] in app?.beginAction($0, title: $1, message: $2) },
            completeFeedback: { [weak app] in app?.completeAction($0, title: $1, message: $2) },
            infoFeedback: { [weak app] in app?.infoAction($0, title: $1, message: $2, autoDismissAfter: $3) }
        )
    }
}

extension FloatingAssistantView {
    @MainActor
    init(appState app: AppState) {
        self.init(
            live: app.liveInterview,
            manual: app.manualCaptureController,
            settingsState: app.settingsState,
            diagnosticsState: app.diagnosticsState,
            activeIdentity: app.activeGenerationController?.identity,
            elapsedMS: app.activeGenerationElapsedMs ?? app.currentGenerationTelemetry.elapsedMs ?? 0,
            providerStreamActive: app.providerStreamActive,
            productInterviewStatus: app.productInterviewStatus,
            systemCaptureRunning: app.systemCaptureRunning,
            micCaptureRunning: app.micCaptureRunning,
            canStopCapture: app.canStopCapture,
            selectedAnswerProviderStatusTitle: app.selectedAnswerProviderStatusTitle,
            selectedAnswerProviderConfigured: app.selectedAnswerProviderConfigured,
            userFacingRelevantContextStatus: app.userFacingRelevantContextStatus,
            hasCleanRelevantContext: app.hasCleanRelevantContext,
            diagnosticDisplay: app.settings.floatingAssistantDisplayMode == .diagnostic ? FloatingAssistantDiagnosticsDisplay(
                providerConfigured: app.deepSeekProviderConfigured ? "true" : "false",
                deepSeekConfigured: app.deepSeekConfigured ? "true" : "false",
                credentialSource: app.deepSeekCredentialSource,
                keyExists: app.keychainDeepSeekKeyExists ? "true" : "false",
                keyLengthCategory: app.keychainDeepSeekKeyLengthCategory,
                keychainService: app.keychainServiceName,
                keychainAccount: app.keychainDeepSeekAccount,
                generationConfigSource: app.generationConfigSource,
                settingsConfigSource: app.settingsConfigSource,
                lastProviderConfigError: app.lastProviderConfigError,
                generationStateTitle: app.generationUIState.displayName,
                activeGenerationID: app.activeGenerationID ?? "nil",
                activeQuestionID: app.activeQuestionID ?? "nil",
                activeTriggerPath: app.activeTriggerPath?.rawValue ?? "nil",
                activeElapsedMs: app.activeGenerationElapsedMs.map { "\($0)" } ?? "nil",
                activeTaskSummary: app.activeTaskSummary,
                previousGenerationID: app.previousGenerationID ?? "nil",
                regenerate_questionId: app.lastRegenerateQuestionID ?? "nil",
                regenerate_sourceTextKind: app.lastRegenerateSourceTextKind.isEmpty ? "nil" : app.lastRegenerateSourceTextKind,
                regenerate_oldGenerationId: app.lastRegenerateOldGenerationID ?? "nil",
                regenerate_newGenerationId: app.lastRegenerateNewGenerationID ?? "nil",
                regenerate_rejectionReason: app.lastRegenerateRejectionReason.isEmpty ? "nil" : app.lastRegenerateRejectionReason,
                currentSpinnerVisible: app.currentSpinnerVisible ? "true" : "false",
                fallbackWatchdogActive: app.fallbackWatchdogActive ? "true" : "false",
                stageBTaskActive: app.stageBTaskActive ? "true" : "false",
                lastProviderError: app.currentGenerationTelemetry.providerError ?? "nil",
                lastJSONParseError: app.currentGenerationTelemetry.jsonParseError ?? "nil",
                lastDBError: app.currentGenerationTelemetry.dbError ?? "nil",
                cancelledGenerationCount: "\(app.cancelledGenerationCount)",
                staleCallbackDiscardCount: "\(app.staleCallbackDiscardCount)",
                duplicateSuppressionCount: "\(app.duplicateSuppressionCount)",
                heartbeatDelayMs: "\(app.mainThreadHeartbeatDelayMs)",
                lastSQLiteOperation: app.lastSQLiteOperation,
                lastRAGOperation: app.lastRAGOperation,
                lastProviderOperation: app.lastProviderOperation,
                ragRetrievalLatencyMS: app.ragRetrievalLatencyMS.map { "\($0)" } ?? "nil",
                deepseekFirstVisibleMS: app.deepseekFirstVisibleMS.map { "\($0)" } ?? "nil",
                softFallbackUsed: app.softFallbackUsed ? "true" : "false",
                retrievalMode: app.manualVerificationRAGMode,
                latexPollutedChunkCount: "\(app.latexPollutedChunkCount)",
                captureMode: app.captureMode.rawValue,
                currentCaptureRuntimeState: app.currentCaptureRuntimeState.displayName,
                stopReason: app.stopReason?.rawValue ?? "None",
                recognitionRequestActive: app.recognitionRequestActive ? "true" : "false",
                recognitionTaskActive: app.recognitionTaskActive ? "true" : "false",
                systemASRTaskActive: app.systemASRTaskActive ? "true" : "false",
                micASRTaskActive: app.micASRTaskActive ? "true" : "false"
            ) : nil,
            currentSuspectedMismatchReason: app.currentSuspectedMismatchReason,
            lastAlignmentError: app.lastAlignmentError,
            saveSettings: { [weak app] in app?.saveSettings($0) },
            stopListening: { [weak app] in app?.stopListening() },
            openMainWindow: { [weak app] in app?.openMainWindow() },
            regenerateManualSuggestion: { [weak app] in app?.regenerateManualSuggestion() },
            regenerateVisibleSuggestion: { [weak app] in app?.regenerateVisibleSuggestion() },
            feedbacks: app.activeActionFeedbacks,
            loadingStates: app.actionLoadingStates,
            beginFeedback: { [weak app] in app?.beginAction($0, title: $1, message: $2) },
            completeFeedback: { [weak app] in app?.completeAction($0, title: $1, message: $2) },
            infoFeedback: { [weak app] in app?.infoAction($0, title: $1, message: $2, autoDismissAfter: $3) },
            failFeedback: { [weak app] in app?.failAction($0, title: $1, message: $2) }
        )
    }
}

extension ManualCaptureWorkspaceView {
    @MainActor
    init(appState app: AppState) {
        self.init(
            live: app.liveInterview,
            manual: app.manualCaptureController,
            settingsState: app.settingsState,
            startManualCapture: { [weak app] in app?.startManualCapture() },
            stopAndTranscribeManualCapture: { [weak app] in app?.stopAndTranscribeManualCapture() },
            cancelManualCapture: { [weak app] in app?.cancelManualCapture() },
            sendManualCaptureToAI: { [weak app] in app?.sendManualCaptureToAI(forceDeepSeek: $0) },
            retryManualCapture: { [weak app] in app?.retryManualCapture() },
            clearManualCapture: { [weak app] in app?.clearManualCapture() },
            selectSection: { [weak app] in app?.selectSection($0) },
            feedbacks: app.activeActionFeedbacks,
            loadingStates: app.actionLoadingStates,
            beginFeedback: { [weak app] in app?.beginAction($0, title: $1, message: $2) },
            completeFeedback: { [weak app] in app?.completeAction($0, title: $1, message: $2) },
            infoFeedback: { [weak app] in app?.infoAction($0, title: $1, message: $2, autoDismissAfter: $3) }
        )
    }
}

extension LiveInterviewView where PracticeContent == PracticeApplicationHost {
    @MainActor
    init(appState app: AppState) {
        self.init(
            live: app.liveInterview,
            settingsState: app.settingsState,
            permissions: app.systemAudioPermissions,
            micDiagnostics: app.microphoneDiagnostics,
            systemAudio: app.systemAudioCaptureService,
            hirevaMode: Binding(get: { [weak app] in app?.hirevaMode ?? .autoDetect }, set: { [weak app] in app?.hirevaMode = $0 }),
            manualWorkspace: ManualCaptureWorkspaceView(appState: app),
            practiceContent: PracticeApplicationHost(appState: app),
            liveBlockedReason: app.liveBlockedReason,
            anyCaptureRunning: app.anyCaptureRunning,
            canStopCapture: app.canStopCapture,
            isFloatingAssistantVisible: app.isFloatingAssistantVisible,
            onboardingComplete: app.onboardingComplete,
            noAudioWarningVisible: app.noAudioWarningVisible,
            audioRouteError: app.audioRouteError,
            errorMessage: app.errorMessage,
            saveSettings: { [weak app] in app?.saveSettings($0) },
            startListening: { [weak app] in app?.startListening(mode: .microphone) },
            stopListening: { [weak app] in app?.stopListening() },
            showFloatingAssistant: { [weak app] in app?.showFloatingAssistant() },
            answerCurrentQuestionOrTranscriptNow: { [weak app] in app?.answerCurrentQuestionOrTranscriptNow() },
            clearLiveSession: { [weak app] in app?.clearLiveSession() },
            restartAudioInput: { [weak app] in app?.restartAudioInput() },
            refreshPermissions: { [weak app] in app?.refreshPermissions() },
            requestMicrophonePermission: { [weak app] in app?.requestMicrophonePermission() },
            requestScreenRecordingPermission: { [weak app] in app?.requestScreenRecordingPermission() },
            openMicrophonePrivacySettings: { [weak app] in app?.openMicrophonePrivacySettings() },
            selectSection: { [weak app] in app?.selectSection($0) },
            feedbacks: app.activeActionFeedbacks,
            loadingStates: app.actionLoadingStates,
            beginFeedback: { [weak app] in app?.beginAction($0, title: $1, message: $2) },
            completeFeedback: { [weak app] in app?.completeAction($0, title: $1, message: $2) },
            infoFeedback: { [weak app] in app?.infoAction($0, title: $1, message: $2, autoDismissAfter: $3) }
        )
    }
}


struct LiveInterviewView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            LiveInterviewApplicationHost(appState: AppState.bootstrap())
                .frame(width: 1600, height: 900)
                .previewDisplayName("1600x900 - Light")
            
            LiveInterviewApplicationHost(appState: AppState.bootstrap())
                .frame(width: 1280, height: 800)
                .preferredColorScheme(.dark)
                .previewDisplayName("1280x800 - Dark")
            
            LiveInterviewApplicationHost(appState: AppState.bootstrap())
                .frame(width: 1120, height: 720)
                .previewDisplayName("1120x720 - Compact")
        }
    }
}
