// MainActor compatibility entry for the macOS interview workflow.
// History and diagnostics own their feature state; Practice receives narrow
// dependencies. GenerationCoordinator owns request/generation identities and
// task handles; live UI publication and persistence still pass through here.
// Invariants: UI mutation stays on MainActor, capture/generation IDs bind async
// callbacks to the current question, and technical diagnostics must not become
// the default product flow.

import AppKit
import AVFoundation
import Combine
import Foundation
import SwiftUI

/// Transitional owner of live UI, capture policy and provider settings.
/// Feature compatibility properties forward to their sole state owners.
/// Async callbacks must validate identity at UI and persistence boundaries.
@MainActor
final class AppState: ObservableObject {
    @Published var selectedSection: AppSection = .home
    let persistenceConsent: PersistenceConsent
    lazy var settingsState = AppComposition.makeSettingsState(app: self)
    private var localModelsOwner: LocalModelsSetupViewModel?
    private let localModelsSetupFactory: (@MainActor () -> LocalModelsSetupViewModel)?
    var localModelsSetupState: LocalModelsSetupViewModel {
        if let localModelsOwner { return localModelsOwner }
        let owner = localModelsSetupFactory?() ?? AppComposition.makeLocalModelsSetupState()
        owner.selectedQwenModelDidChange(to: selectedQwenModelName)
        if isShuttingDown { owner.closeAdmission() }
        localModelsOwner = owner
        return owner
    }
    var settings: AppSettings {
        get { settingsState.settings }
        set { settingsState.settings = newValue }
    }
    lazy var documentsState = AppComposition.makeDocumentsState(app: self)
    var documents: [DocumentRecord] { documentsState.documents }
    lazy var interviewContextState = AppComposition.makeInterviewContextState(app: self)
    var candidateProfiles: [CandidateProfile] {
        get { interviewContextState.candidateProfiles }
        set { interviewContextState.candidateProfiles = newValue }
    }
    var opportunityContexts: [OpportunityContext] {
        get { interviewContextState.opportunityContexts }
        set { interviewContextState.opportunityContexts = newValue }
    }
    var activeCandidateProfileID: String? {
        get { interviewContextState.activeCandidateProfileID }
        set { interviewContextState.activeCandidateProfileID = newValue }
    }
    var activeOpportunityContextID: String? {
        get { interviewContextState.activeOpportunityContextID }
        set { interviewContextState.activeOpportunityContextID = newValue }
    }
    var activeInterviewDomainID: InterviewDomainID {
        get { interviewContextState.activeInterviewDomainID }
        set { interviewContextState.activeInterviewDomainID = newValue }
    }
    var activeContextSnapshot: InterviewContextSnapshot? {
        get { interviewContextState.activeContextSnapshot }
        set { interviewContextState.activeContextSnapshot = newValue }
    }
    var automaticContextBuildResult: InterviewContextBuildResult? {
        get { interviewContextState.automaticContextBuildResult }
        set { interviewContextState.automaticContextBuildResult = newValue }
    }
    var automaticContextReadiness: AutomaticContextReadiness {
        get { interviewContextState.automaticContextReadiness }
        set { interviewContextState.automaticContextReadiness = newValue }
    }
    var contextConfigurationOrigin: ContextConfigurationOrigin? {
        get { interviewContextState.contextConfigurationOrigin }
        set { interviewContextState.contextConfigurationOrigin = newValue }
    }
    let historyState: HistoryState
    var sessions: [InterviewSession] {
        get { historyState.sessions }
        set { historyState.sessions = newValue }
    }
    var providerConfigurations: [LLMProviderConfiguration] {
        get { settingsState.providerConfigurations }
        set { settingsState.providerConfigurations = newValue }
    }
    var activeRealtimeProvider: LLMProviderConfiguration? {
        get { settingsState.activeRealtimeProvider }
        set { settingsState.activeRealtimeProvider = newValue }
    }
    var activeRecapProvider: LLMProviderConfiguration? {
        get { settingsState.activeRecapProvider }
        set { settingsState.activeRecapProvider = newValue }
    }
    var providerConnectionResults: [UUID: String] { settingsState.providerConnectionResults }
    var selectedSessionID: String? {
        get { historyState.selectedSessionID }
        set { historyState.selectedSessionID = newValue }
    }
    var selectedSessionTranscript: [TranscriptSegment] {
        get { historyState.selectedSessionTranscript }
        set { historyState.selectedSessionTranscript = newValue }
    }
    var selectedSessionSuggestions: [SuggestionCard] {
        get { historyState.selectedSessionSuggestions }
        set { historyState.selectedSessionSuggestions = newValue }
    }
    var selectedSessionRecap: RecapReport? {
        get { historyState.selectedSessionRecap }
        set { historyState.selectedSessionRecap = newValue }
    }
    var hasCV: Bool { documentsState.hasCV }
    var hasJD: Bool { documentsState.hasJD }
    var hasAPIKey: Bool { settingsState.hasAPIKey }
    let liveInterview = LiveInterviewFeature()
    var liveState: LiveInterviewState {
        get { liveInterview.liveState }
        set { liveInterview.liveState = newValue }
    }
    var currentSession: InterviewSession? {
        get { liveInterview.currentSession }
        set { liveInterview.currentSession = newValue }
    }
    var transcriptSegments: [TranscriptSegment] {
        get { liveInterview.transcriptSegments }
        set { liveInterview.transcriptSegments = newValue }
    }
    var currentSuggestion: SuggestionCard? {
        get { liveInterview.currentSuggestion }
        set { liveInterview.currentSuggestion = newValue }
    }
    var liveSuggestionHistory: [SuggestionCard] {
        get { liveInterview.liveSuggestionHistory }
        set { liveInterview.liveSuggestionHistory = newValue }
    }
    var lastDetectedQuestion: DetectedQuestion? {
        get { liveInterview.lastDetectedQuestion }
        set { liveInterview.lastDetectedQuestion = newValue }
    }
    var possibleQuestion: DetectedQuestion? {
        get { liveInterview.possibleQuestion }
        set { liveInterview.possibleQuestion = newValue }
    }
    var lastTranscriptSnippet: String {
        get { liveInterview.lastTranscriptSnippet }
        set { liveInterview.lastTranscriptSnippet = newValue }
    }
    var rawTranscriptText: String {
        get { liveInterview.rawTranscriptText }
        set { liveInterview.rawTranscriptText = newValue }
    }
    var partialTranscriptText: String {
        get { liveInterview.partialTranscriptText }
        set { liveInterview.partialTranscriptText = newValue }
    }
    var finalTranscriptText: String {
        get { liveInterview.finalTranscriptText }
        set { liveInterview.finalTranscriptText = newValue }
    }
    var displayTranscriptText: String {
        get { liveInterview.displayTranscriptText }
        set { liveInterview.displayTranscriptText = newValue }
    }
    var lastAcceptedQuestionText: String {
        get { liveInterview.lastAcceptedQuestionText }
        set { liveInterview.lastAcceptedQuestionText = newValue }
    }
    // Audio-buffer callbacks update this diagnostic on every PCM buffer. Keep
    // the counter in memory without invalidating every AppState-observing view.
    let diagnosticsState: DiagnosticsState
    var transcriptRuntimeDiagnostics: TranscriptRuntimeDiagnostics {
        get { diagnosticsState.runtime }
        set { diagnosticsState.runtime = newValue }
    }
    var recentTranscriptRuntimeEvents: [TranscriptRuntimeEventRecord] { diagnosticsState.recentEvents }
    var runtimeTranscriptTraceLogURL: URL {
        get { diagnosticsState.traceLogURL }
        set { diagnosticsState.traceLogURL = newValue }
    }
    @Published var isFloatingAssistantVisible = false
    @Published var errorMessage: String?
    private let activeActionFeedbacksSource = CurrentValueSubject<[ActionFeedback], Never>([])
    var activeActionFeedbacks: [ActionFeedback] {
        get { activeActionFeedbacksSource.value }
        set { activeActionFeedbacksSource.send(newValue); objectWillChange.send() }
    }
    var activeActionFeedbacksUpdates: AnyPublisher<[ActionFeedback], Never> {
        activeActionFeedbacksSource.eraseToAnyPublisher()
    }
    private let actionLoadingStatesSource = CurrentValueSubject<[String: Bool], Never>([:])
    var actionLoadingStates: [String: Bool] {
        get { actionLoadingStatesSource.value }
        set { actionLoadingStatesSource.send(newValue); objectWillChange.send() }
    }
    var actionLoadingStatesUpdates: AnyPublisher<[String: Bool], Never> {
        actionLoadingStatesSource.eraseToAnyPublisher()
    }
    
    @Published var lastQuestionDetectionProvider: String? = nil
    @Published var lastQuestionDetectionModel: String? = nil
    @Published var lastSuggestionGenerationProvider: String? = nil
    @Published var lastSuggestionGenerationModel: String? = nil
    var lastProviderSwitchTimestamp: Date? { settingsState.lastProviderSwitchTimestamp }
    var lastProviderSwitchError: String? { settingsState.lastProviderSwitchError }
    @Published var cloudWarningAcceptedThisSession: Bool = false
    

    var connectionResult: String? {
        get { settingsState.connectionResult }
        set { settingsState.setConnectionResult(newValue) }
    }
    var isTestingConnection: Bool { settingsState.isTestingConnection }
    var isGeneratingRecap: Bool { historyState.isGeneratingRecap }
    let systemAudioPermissions: SystemAudioPermissionController
    var permissionSnapshot: PermissionSnapshot { systemAudioPermissions.permissionSnapshot }
    var microphonePermissionState: MicrophonePermissionState { systemAudioPermissions.microphonePermissionState }
    public var systemAudioPermissionState: ScreenSystemAudioPermissionState { systemAudioPermissions.systemAudioPermissionState }
    public var systemAudioProbeResult: ScreenSystemAudioPermissionProbeResult? { systemAudioPermissions.probeResult }
    var diagnostics: DeveloperDiagnostics {
        get { diagnosticsState.developer }
        set { diagnosticsState.developer = newValue }
    }
    var lastRetrievalTrace: RetrievalTrace? {
        get { diagnosticsState.developer.lastRetrievalTrace }
        set { diagnosticsState.setRetrievalTrace(newValue) }
    }
    var currentSuggestionRetrievedChunks: [RetrievedChunk] {
        get { liveInterview.currentSuggestionRetrievedChunks }
        set { liveInterview.currentSuggestionRetrievedChunks = newValue }
    }
    @Published var latexPollutedChunkCount: Int = 0
    @Published var buildIdentity = BuildIdentity.current()

    var staleBundleWarning: String? {
        buildIdentity.staleWarning
    }

    var currentQABinding: QABindingSnapshot {
        let questionID = lastDetectedQuestion?.id
        let questionText = lastDetectedQuestion?.questionText ?? ""
        let suggestion = currentSuggestion

        let status: QABindingStatus
        if let suggestion {
            let suggestionQuestionID = suggestion.detectedQuestionID
            let questionIDMatches = questionID != nil && suggestionQuestionID == questionID
            let suggestionText = suggestion.questionText ?? ""
            let textMatches = suggestionText.isEmpty || questionText.isEmpty || normalizedBindingText(suggestionText) == normalizedBindingText(questionText)
            let semanticMatches = suggestion.alignmentVerdict != .mismatched
            status = questionIDMatches && textMatches && semanticMatches ? .matched : .mismatched
        } else if !lastAlignmentError.isEmpty {
            status = .mismatched
        } else if questionID == nil {
            status = .missingQuestion
        } else {
            status = .missingSuggestion
        }

        return QABindingSnapshot(
            currentQuestionID: questionID,
            currentQuestionText: questionText,
            currentSuggestionID: suggestion?.id,
            currentSuggestionDetectedQuestionID: suggestion?.detectedQuestionID,
            currentSuggestionQuestionText: suggestion?.questionText ?? "",
            activeGenerationID: activeGenerationID,
            activeGenerationQuestionID: activeQuestionID,
            bindingStatus: status,
            lastAlignmentError: lastAlignmentError
        )
    }
    
    // RAG Phase 3 Embedding properties
    var embeddingCoverage: EmbeddingCoverage? { documentsState.embeddings.coverage }
    var rebuildProgress: Double { documentsState.embeddings.progress }
    var isRebuildingEmbeddings: Bool { documentsState.embeddings.isRebuilding }
    var lastEmbeddingTestStatus: String {
        get { settingsState.lastEmbeddingTestStatus }
        set { settingsState.setEmbeddingTestStatus(newValue) }
    }
    var lastEmbeddingError: String? {
        get { settingsState.lastEmbeddingError }
        set { settingsState.setEmbeddingError(newValue) }
    }
    // internal for AppState extension access only
    var activeEmbeddingRebuildTask: Task<Void, Never>? { documentsState.embeddings.rebuildTask }
    let embeddingProviderResolverOverride: ((AppSettings) -> (any EmbeddingProvider)?)?
    // internal for AppState extension access only
    var actionFeedbackDismissTasks: [String: Task<Void, Never>] = [:]
    // The action owner retains live launches separately from current roles.
    // Replaced/cancelled workers retire themselves after their real exit.
    var actionFeedbackDismissalTasksToDrain: [UUID: Task<Void, Never>] = [:]
    var historicalSuggestionChunks: [String: [RetrievedChunk]] {
        get { historyState.historicalSuggestionChunks }
        set { historyState.historicalSuggestionChunks = newValue }
    }

    // MARK: - Manual Capture Push-to-Ask state
    @Published public var hirevaMode: HirevaMode = .autoDetect {
        didSet {
            if hirevaMode == .manualCapture {
                stopAllContinuousPipelines(reason: .userRequested)
            }
        }
    }
    let manualCaptureCapabilities: ManualCaptureCapabilities
    lazy var manualCaptureController: ManualCaptureController = {
        let owner = AppComposition.makeManualCaptureController(app: self)
        // Remaining global action/readiness policies use forwarding properties;
        // Home, Manual workspace and floating card observe this owner directly.
        owner.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        if isShuttingDown { owner.closeAdmission() }
        return owner
    }()
    public var manualCaptureState: ManualCaptureState {
        get { manualCaptureController.state }
        set { manualCaptureController.state = newValue }
    }
    public var manualCaptureTranscript: String {
        get { manualCaptureController.transcript }
        set { manualCaptureController.transcript = newValue }
    }
    public var manualCaptureSuggestion: SuggestionCard? {
        get { manualCaptureController.suggestion }
        set { manualCaptureController.suggestion = newValue }
    }
    public var manualCaptureDuration: Double { manualCaptureController.duration }
    public var manualCaptureLevel: Double { manualCaptureController.level }
    public var manualCaptureError: String? { manualCaptureController.error }
    public var manualCaptureBufferCount: Int { manualCaptureController.bufferCount }
    var manualCaptureRevision: Int { manualCaptureController.revision }
    public var manualCaptureLastBufferTimestamp: Date? { manualCaptureController.lastBufferTimestamp }
    public var manualCaptureSource: String { manualCaptureController.source }

    // Route facts remain in the exact monitor; compatibility reads never mirror them.
    var currentInputDeviceName: String { audioDeviceRouteMonitor?.currentInputDeviceName ?? "Default Input" }
    @Published var selectedMockSpeaker: SpeakerRole = .interviewer {
        didSet {
            mockTranscriptionService.selectedMockSpeaker = selectedMockSpeaker
        }
    }
    var isRecoveringAudioRoute: Bool { audioDeviceRouteMonitor?.isRecoveringAudioRoute ?? false }
    @Published var audioRouteError: String?
    var lastAudioBufferAt: Date?
    @Published var noAudioWarningVisible: Bool = false

    @Published public var lastSystemAudioTranscript: String = ""
    @Published public var lastSystemAudioASRError: String? = nil
    @Published public var lastQuestionDetectionResult: String = "No question detected yet."
    @Published public var lastDetectedQuestionText: String = ""
    @Published public var lastDetectedQuestionSource: String = ""
    @Published public var lastDetectedQuestionSpeaker: String = ""
    @Published var lastDetectionConfidence: Double = 0.0
    @Published public var lastQuestionConfidence: Double = 0.0
    @Published public var lastDetectionShouldTrigger: Bool = false
    @Published public var lastDetectionReason: String = ""
    @Published public var lastDetectionRawJSON: String = ""
    @Published public var lastDetectionSkipReason: String = ""
    @Published public var ignoredCandidateQuestionCount: Int = 0
    @Published public var ignoredSmallTalkCount: Int = 0
    @Published public var lastTranscriptIngestionMs: Int = 0
    @Published public var lastQuestionClassificationMs: Int = 0
    @Published public var lastIgnoredSystemAudioReason: String = ""
    @Published public var ignoredSystemAudioAnswerLikeCount: Int = 0
    @Published public var detectedQuestionsInSessionCount: Int = 0
    @Published public var lastTranscriptQuestionGenerationTrace: TranscriptQuestionGenerationTrace = .empty
    var interviewContextMode: InterviewContextMode {
        get { settingsState.interviewContextMode }
        set { settingsState.interviewContextMode = newValue }
    }
    var interviewSessionMode: InterviewSessionMode {
        get { settingsState.interviewSessionMode }
        set { settingsState.interviewSessionMode = newValue }
    }
    public var resolvedInterviewSessionPhase: DialogueSessionPhase {
        get { liveInterview.resolvedInterviewSessionPhase }
        set { liveInterview.resolvedInterviewSessionPhase = newValue }
    }
    @Published public var interviewListeningMode: InterviewListeningMode = .panelQuestionsOnly
    var candidatePresentationMode: CandidateSpeechMode {
        get { settingsState.candidatePresentationMode }
        set { settingsState.candidatePresentationMode = newValue }
    }
    var candidateAsksPanelMode: CandidateSpeechMode {
        get { settingsState.candidateAsksPanelMode }
        set { settingsState.candidateAsksPanelMode = newValue }
    }
    var answerPanelQuestionsEnabled: Bool {
        get { settingsState.answerPanelQuestionsEnabled }
        set { settingsState.answerPanelQuestionsEnabled = newValue }
    }
    public var interviewPhase: InterviewPhase {
        get { liveInterview.interviewPhase }
        set { liveInterview.interviewPhase = newValue }
    }
    public var detectedDialogueSpeakerRole: DialogueTurnRole {
        get { liveInterview.detectedDialogueSpeakerRole }
        set { liveInterview.detectedDialogueSpeakerRole = newValue }
    }
    public var detectedDialogueTurnType: DialogueTurnType {
        get { liveInterview.detectedDialogueTurnType }
        set { liveInterview.detectedDialogueTurnType = newValue }
    }
    public var lastDialogueSourceChannel: String {
        get { liveInterview.lastDialogueSourceChannel }
        set { liveInterview.lastDialogueSourceChannel = newValue }
    }
    public var lastModeTransition: String {
        get { liveInterview.lastModeTransition }
        set { liveInterview.lastModeTransition = newValue }
    }
    public var lastModeTransitionReason: String {
        get { liveInterview.lastModeTransitionReason }
        set { liveInterview.lastModeTransitionReason = newValue }
    }
    @Published public var lastSpeakerRole: String = SpeakerRole.unknown.rawValue
    @Published public var lastTriggerDecision: String = ""
    @Published public var lastTriggerReason: String = ""
    @Published public var lastSuppressionReason: String = ""
    @Published public var candidateQuestionsToPanelCount: Int = 0

    // --- System Audio ASR Diagnostics ---
    @Published public var systemASRTaskRunning: Bool = false
    public var totalSystemAudioASRBuffersAppended: Int { diagnosticsState.systemAudioASRBufferCount }
    @Published public var lastSystemAudioASRPartialTranscript: String = ""
    @Published public var lastSystemAudioASRFinalTranscript: String = ""
    @Published public var lastSystemTranscript: String = ""
    @Published public var recognitionRequestActive: Bool = false
    @Published public var recognitionTaskActive: Bool = false
    // internal for AppState extension access only
    var partialUtteranceFinalizationTasks: [String: Task<Void, Never>] {
        liveInterview.partialUtteranceFinalizationTasks
    }
#if DEBUG
    // Nil in ordinary debug runs, absent in release. Freeze per submission.
    var partialFinalizationDelayForTesting: (@MainActor (UInt64) async throws -> Void)?
    var partialFinalizationBeforeSnapshotForTesting: (@MainActor (String) async -> Void)?
    // Observes each original ancillary handle immediately before the real join.
    var ancillaryTaskWillAwaitForTesting: (@MainActor (Task<Void, Never>) -> Void)?
#endif
    var partialStabilityWindowMS: Int = 1_200
    var minimumQuestionTokenCount: Int = 4
    var maxUtteranceGapMS: Int = 2_500

    var runtimeTranscriptChainStatus: String {
        if transcriptRuntimeDiagnostics.partialTranscriptCount + transcriptRuntimeDiagnostics.finalTranscriptCount > 0,
           displayTranscriptText.isEmpty {
            return "UI state not updated"
        }
        return transcriptRuntimeDiagnostics.chainStatus()
    }

    // --- Pipeline Helper Diagnostics ---
    var captureMode: AudioCaptureMode { settings.audioCaptureMode }
    public var isListening: Bool {
        liveState == .listening || liveState == .transcribing || liveState == .generatingSuggestion || liveState == .detectingQuestion
    }
    var isAudioEngineRunning: Bool { AudioEngineManager.shared.isEngineRunning }
    var isMicPipelineActive: Bool { appleSpeechService?.microphoneSession != nil }
    var isMicASRTaskActive: Bool {
        if let local = activeASRProviderRuntime as? LocalParakeetASRProvider {
            return local.isTranscriptionActive(source: .microphone, sessionID: currentSession?.id)
        }
        return appleSpeechService?.microphoneSession?.isRecognitionActive == true
    }
    var isSystemAudioASRActive: Bool {
        if let local = activeASRProviderRuntime as? LocalParakeetASRProvider {
            return local.isTranscriptionActive(source: .systemAudio, sessionID: currentSession?.id)
        }
        return appleSpeechService?.systemAudioSession?.isRecognitionActive == true
    }

    // --- Dual Stream Diagnostics ---
    var micCaptureRunning: Bool {
        isMicPipelineActive || microphoneDiagnostics.isRunning
    }
    var micBufferCount: Int { appleSpeechService?.microphoneSession?.totalBuffersAppended ?? 0 }
    var micLastBufferTimestamp: Date? { appleSpeechService?.microphoneSession?.lastBufferReceivedAt }
    var micLevelDBFS: Double { microphoneDiagnostics.decibels }
    var micASRRequestActive: Bool { appleSpeechService?.microphoneSession?.request != nil }
    var micASRTaskActive: Bool { isMicASRTaskActive }
    var micLastPartialTranscript: String { appleSpeechService?.microphoneSession?.partialTranscriptBuffer ?? "" }
    var micLastFinalTranscript: Date? { appleSpeechService?.microphoneSession?.lastFinalTranscriptTimestamp }
    var micLastError: String? {
        (activeASRProviderRuntime as? LocalParakeetASRProvider)?.captureSourceFailures[.microphone]?.localizedDescription
            ?? appleSpeechService?.microphoneSession?.lastError?.localizedDescription
    }
    var micSessionID: String { appleSpeechService?.microphoneSession?.sessionID.source.rawValue ?? "None" }
    
    // ASR quality diagnostics for Microphone
    var micLastPartialTranscriptQuality: String { appleSpeechService?.microphoneSession?.lastPartialTranscript ?? "" }
    var micLastFinalTranscriptQuality: String { appleSpeechService?.microphoneSession?.lastFinalTranscript ?? "" }
    var micBestTranscriptUsed: String { appleSpeechService?.microphoneSession?.bestTranscriptUsed ?? "" }
    var micFinalizationReason: String { appleSpeechService?.microphoneSession?.finalizationReason ?? "" }

    // --- Capture Runtime State Lifecycle ---
    public var currentCaptureRuntimeState: CaptureRuntimeState {
        get { liveInterview.currentCaptureRuntimeState }
        set { liveInterview.currentCaptureRuntimeState = newValue }
    }
    public var stopReason: StopReason? {
        get { liveInterview.stopReason }
        set { liveInterview.stopReason = newValue }
    }
    public var lastCaptureStartedAt: Date? {
        get { liveInterview.lastCaptureStartedAt }
        set { liveInterview.lastCaptureStartedAt = newValue }
    }
    public var lastCaptureStoppedAt: Date? {
        get { liveInterview.lastCaptureStoppedAt }
        set { liveInterview.lastCaptureStoppedAt = newValue }
    }
    
    public var lastSystemAudioBufferAt: Date? { systemAudioCaptureService.lastBufferReceivedAt }
    public var lastSystemAudioError: String? { systemAudioCaptureService.lastError }
    
    public typealias CaptureEvent = LiveCaptureEvent

    public var recent20CaptureEvents: [CaptureEvent] {
        get { liveInterview.recent20CaptureEvents }
        set { liveInterview.recent20CaptureEvents = newValue }
    }
    
    public var systemRecentBufferAlive: Bool {
        guard let last = lastSystemAudioBufferAt else { return false }
        return Date().timeIntervalSince(last) < 3.0
    }
    
    public var micRecentBufferAlive: Bool {
        guard let last = appleSpeechService?.microphoneSession?.lastBufferReceivedAt else { return false }
        return Date().timeIntervalSince(last) < 3.0
    }
    
    public var anyCaptureRunning: Bool { systemCaptureRunning || micCaptureRunning }
    
    public var canStopCapture: Bool {
        captureLifecycle.hasFailedTeardown || anyCaptureRunning || currentCaptureRuntimeState == .starting || currentCaptureRuntimeState == .listening || currentCaptureRuntimeState == .generating
    }

    public var systemCaptureRunning: Bool { systemAudioCaptureService.isCapturing }
    var systemBufferCount: Int { appleSpeechService?.systemAudioSession?.totalBuffersAppended ?? 0 }
    var systemLastBufferTimestamp: Date? { appleSpeechService?.systemAudioSession?.lastBufferReceivedAt }
    var systemLevelDBFS: Double { systemAudioCaptureService.decibels }
    var systemASRRequestActive: Bool { appleSpeechService?.systemAudioSession?.request != nil }
    var systemASRTaskActive: Bool {
        if let local = activeASRProviderRuntime as? LocalParakeetASRProvider {
            return local.isTranscriptionActive(source: .systemAudio, sessionID: currentSession?.id)
        }
        return appleSpeechService?.systemAudioSession?.recognitionTask != nil
    }
    var systemLastPartialTranscript: String { appleSpeechService?.systemAudioSession?.partialTranscriptBuffer ?? "" }
    var systemLastFinalTranscript: Date? { appleSpeechService?.systemAudioSession?.lastFinalTranscriptTimestamp }
    var systemLastError: String? { appleSpeechService?.systemAudioSession?.lastError?.localizedDescription }
    var systemSessionID: String { appleSpeechService?.systemAudioSession?.sessionID.source.rawValue ?? "None" }
    
    // ASR quality diagnostics for System Audio
    var systemLastPartialTranscriptQuality: String { appleSpeechService?.systemAudioSession?.lastPartialTranscript ?? "" }
    var systemLastFinalTranscriptQuality: String { appleSpeechService?.systemAudioSession?.lastFinalTranscript ?? "" }
    var systemBestTranscriptUsed: String { appleSpeechService?.systemAudioSession?.bestTranscriptUsed ?? "" }
    var systemFinalizationReason: String { appleSpeechService?.systemAudioSession?.finalizationReason ?? "" }

    var microphoneRequired: Bool {
        let captureMode = settings.audioCaptureMode
        return captureMode == .microphoneOnly || captureMode == .microphoneAndSystem
    }
    var systemAudioRequired: Bool {
        let captureMode = settings.audioCaptureMode
        return captureMode == .systemAudioOnly || captureMode == .microphoneAndSystem
    }
    var twoSessionsActive: Bool {
        micASRTaskActive && isSystemAudioASRActive
    }
    var audioStreamDiagnostics: [AudioStreamDiagnosticSnapshot] {
        let provider = appleSpeechService != nil ? ASRProviderID.appleSpeech
            : (activeASRProviderRuntime?.id ?? activeASRProviderID ?? selectedASRProviderID)
        let requirements = ASRPermissionRequirements(provider: provider, captureMode: captureMode)
        let speechPermissionFailure = requirements.speechRecognition && permissionSnapshot.speechRecognition != .granted
            ? "Speech Recognition permission required for Apple Speech" : nil
        let microphoneSession = appleSpeechService?.microphoneSession
        let systemSession = appleSpeechService?.systemAudioSession
        let parakeetActive = activeASRProviderRuntime?.id == .localParakeet

        func currentEpochBuffer(_ timestamp: Date?) -> Date? {
            guard let timestamp else { return nil }
            guard let startedAt = lastCaptureStartedAt else { return timestamp }
            return timestamp >= startedAt ? timestamp : nil
        }
        func hasTranscript(source: AudioSourceType) -> Bool {
            guard let sessionID = currentSession?.id else { return false }
            return transcriptSegments.contains {
                $0.sessionID == sessionID && $0.source == source && !$0.text.isEmpty
            }
        }
        // The global capture error may have come from another source. Retain a
        // startup error only when no source-specific error explains it.
        let startupState: CaptureRuntimeState = {
            if case .error = currentCaptureRuntimeState,
               lastSystemAudioError != nil || micLastError != nil {
                return .idle
            }
            return currentCaptureRuntimeState
        }()

        return [
            AudioStreamDiagnosticSnapshot(
                source: .microphone,
                selected: microphoneRequired,
                permissionFailure: microphonePermissionState == .authorized
                    ? speechPermissionFailure : "Permission denied",
                runtimeState: startupState,
                captureRunning: micCaptureRunning || (parakeetActive && isAudioEngineRunning),
                lastCapturedBufferAt: currentEpochBuffer(microphoneSession?.lastBufferReceivedAt
                    ?? (parakeetActive ? AudioEngineManager.shared.lastAudioBufferAt : nil)),
                asrBufferCount: microphoneSession?.totalBuffersAppended,
                recognitionActive: microphoneSession?.isRecognitionActive,
                hasTranscript: !(microphoneSession?.partialTranscriptBuffer ?? "").isEmpty
                    || microphoneSession?.lastFinalTranscriptTimestamp != nil
                    || hasTranscript(source: .microphone),
                sourceError: micLastError
            ),
            AudioStreamDiagnosticSnapshot(
                source: .systemAudio,
                selected: systemAudioRequired,
                permissionFailure: systemAudioPermissionState == .granted
                    ? speechPermissionFailure : "Permission denied",
                runtimeState: startupState,
                captureRunning: systemCaptureRunning,
                lastCapturedBufferAt: currentEpochBuffer(lastSystemAudioBufferAt
                    ?? systemSession?.lastBufferReceivedAt),
                asrBufferCount: systemSession?.totalBuffersAppended,
                recognitionActive: systemSession?.isRecognitionActive,
                hasTranscript: !(systemSession?.partialTranscriptBuffer ?? "").isEmpty
                    || systemSession?.lastFinalTranscriptTimestamp != nil
                    || hasTranscript(source: .systemAudio),
                sourceError: lastSystemAudioError ?? systemLastError
            )
        ]
    }

    var streamNotRunningReason: String? {
        AudioStreamDiagnosticSnapshot.streamNotRunningReason(audioStreamDiagnostics)
    }

    var parakeetAudioWriterSnapshot: ParakeetAudioWriterDiagnostics? {
        (activeASRProviderRuntime as? LocalParakeetASRProvider)?.audioWriterSnapshot
    }


    // --- Segment Attribution Diagnostics ---
    public struct SegmentAttributionDiagnostic: Identifiable, Equatable {
        public let id: String
        public let textPreview: String
        public let source: AudioSourceType
        public let speaker: SpeakerRole
        public let createdAt: Date
        public let inputDeviceName: String?
        public let outputDeviceName: String?
        public let eligibleForAutoDetection: Bool
        public let skipReason: String
        public let triggerDecision: String
        public let triggerReason: String
        public let suppressionReason: String
        public let interviewPhase: String
        public let selectedSessionMode: String
        public let resolvedSessionPhase: String
        public let detectedSpeakerRole: String
        public let detectedTurnType: String
        public let sourceChannel: String
    }
    @Published public var last10SegmentsDiagnostics: [SegmentAttributionDiagnostic] = []

    // --- Question Detection Diagnostics ---
    @Published public var lastDetectionSubmittedSegmentText: String = ""
    @Published public var lastDetectionPromptSource: String = ""
    @Published public var lastDetectionPromptSpeaker: String = ""
    @Published public var lastDetectionQuestionComplete: Bool = false
    @Published public var lastDetectionAnswerStrategy: String = ""

    // --- Suggestion Diagnostics ---
    public var suggestionGenerationStarted: Bool {
        get { liveInterview.suggestionGenerationStarted }
        set { liveInterview.suggestionGenerationStarted = newValue }
    }
    @Published public var suggestionProviderModel: String = ""
    @Published public var lastSuggestionCardJSON: String = ""
    @Published public var floatingPanelUpdated: Bool = false
    public var generationUIState: GenerationUIState {
        get { liveInterview.generationUIState }
        set { liveInterview.generationUIState = newValue }
    }
    public var currentGenerationTelemetry: GenerationTelemetry {
        get { liveInterview.currentGenerationTelemetry }
        set { liveInterview.currentGenerationTelemetry = newValue }
    }
    public var generationTelemetryUpdates: AnyPublisher<GenerationTelemetry, Never> {
        liveInterview.generationTelemetryUpdates
    }
    // Heartbeat diagnostics update twice per second. They remain queryable by
    // Diagnostics without invalidating every AppState-observing product view.
    public var mainThreadHeartbeatAt: Date? = nil
    public var mainThreadHeartbeatDelayMs: Int = 0
    public var lastGenerationStateChangeAt: Date? {
        get { liveInterview.lastGenerationStateChangeAt }
        set { liveInterview.lastGenerationStateChangeAt = newValue }
    }
    public var activeTaskSummary: String {
        get { diagnosticsState.activeTaskSummary }
        set { diagnosticsState.activeTaskSummary = newValue }
    }
    public var activeTaskSummaryUpdates: AnyPublisher<String, Never> {
        diagnosticsState.activeTaskSummaryUpdates
    }
    @Published public var lastLongOperationName: String = "None"
    @Published public var lastLongOperationStartedAt: Date? = nil
    @Published public var lastSQLiteOperation: String = "None"
    @Published public var lastRAGOperation: String = "None"
    @Published public var lastProviderOperation: String = "None"
    @Published public internal(set) var ollamaDiagnostics: OllamaProviderDiagnostics = .empty()
    @Published public internal(set) var ollamaLifecycleEvents: [OllamaLifecycleEvent] = []

    // --- Pipeline Latency Metrics ---
    @Published public var ragRetrievalLatencyMS: Int? = nil
    @Published public var asrFirstPartialMS: Int? = nil
    @Published public var asrFinalMS: Int? = nil
    @Published public var asrBestSelectedMS: Int? = nil
    
    // Floating render timestamps (lightweight, no SwiftUI render measurement)
    private let firstVisibleStateSetAtSource = CurrentValueSubject<Date?, Never>(nil)
    public var firstVisibleStateSetAt: Date? {
        get { firstVisibleStateSetAtSource.value }
        set { firstVisibleStateSetAtSource.send(newValue); objectWillChange.send() }
    }
    public var firstVisibleStateSetAtUpdates: AnyPublisher<Date?, Never> {
        firstVisibleStateSetAtSource.eraseToAnyPublisher()
    }
    public var currentSuggestionSetAt: Date? {
        get { liveInterview.currentSuggestionSetAt }
        set { liveInterview.currentSuggestionSetAt = newValue }
    }
    public var currentSuggestionSetAtUpdates: AnyPublisher<Date?, Never> {
        liveInterview.currentSuggestionSetAtUpdates
    }
    private let streamedSayFirstSetAtSource = CurrentValueSubject<Date?, Never>(nil)
    public var streamedSayFirstSetAt: Date? {
        get { streamedSayFirstSetAtSource.value }
        set { streamedSayFirstSetAtSource.send(newValue); objectWillChange.send() }
    }
    public var streamedSayFirstSetAtUpdates: AnyPublisher<Date?, Never> {
        streamedSayFirstSetAtSource.eraseToAnyPublisher()
    }

    // Historical latency averages (cached, refreshed after each suggestion)
    var latencyQueryOverride: DiagnosticsState.LatencyQuery? {
        get { diagnosticsState.latencyQueryOverride }
        set { diagnosticsState.latencyQueryOverride = newValue }
    }
    public var latencyAveragesOverall: LatencyAverages { diagnosticsState.latencyAveragesOverall }
    public var latencyAveragesDeepSeek: LatencyAverages { diagnosticsState.latencyAveragesDeepSeek }


    // --- Streaming & Provenance ---
    public var isStreamingSayFirst: Bool {
        get { liveInterview.isStreamingSayFirst }
        set { liveInterview.isStreamingSayFirst = newValue }
    }
    public var streamedSayFirst: String {
        get { liveInterview.streamedSayFirst }
        set { liveInterview.streamedSayFirst = newValue }
    }
    public var isExpandingSuggestionCard: Bool {
        get { liveInterview.isExpandingSuggestionCard }
        set { liveInterview.isExpandingSuggestionCard = newValue }
    }
    
    @Published public var streamRequestStartAt: Date? = nil
    private let streamFirstTokenAtSource = CurrentValueSubject<Date?, Never>(nil)
    public var streamFirstTokenAt: Date? {
        get { streamFirstTokenAtSource.value }
        set { streamFirstTokenAtSource.send(newValue); objectWillChange.send() }
    }
    public var streamFirstTokenAtUpdates: AnyPublisher<Date?, Never> {
        streamFirstTokenAtSource.eraseToAnyPublisher()
    }
    private let streamFirstVisibleTextAtSource = CurrentValueSubject<Date?, Never>(nil)
    public var streamFirstVisibleTextAt: Date? {
        get { streamFirstVisibleTextAtSource.value }
        set { streamFirstVisibleTextAtSource.send(newValue); objectWillChange.send() }
    }
    public var streamFirstVisibleTextAtUpdates: AnyPublisher<Date?, Never> {
        streamFirstVisibleTextAtSource.eraseToAnyPublisher()
    }
    private let streamFirstSentenceAtSource = CurrentValueSubject<Date?, Never>(nil)
    public var streamFirstSentenceAt: Date? {
        get { streamFirstSentenceAtSource.value }
        set { streamFirstSentenceAtSource.send(newValue); objectWillChange.send() }
    }
    public var streamFirstSentenceAtUpdates: AnyPublisher<Date?, Never> {
        streamFirstSentenceAtSource.eraseToAnyPublisher()
    }
    private let streamFullResponseAtSource = CurrentValueSubject<Date?, Never>(nil)
    public var streamFullResponseAt: Date? {
        get { streamFullResponseAtSource.value }
        set { streamFullResponseAtSource.send(newValue); objectWillChange.send() }
    }
    public var streamFullResponseAtUpdates: AnyPublisher<Date?, Never> {
        streamFullResponseAtSource.eraseToAnyPublisher()
    }
    @Published public var streamJSONParsedAt: Date? = nil
    @Published public var streamPersistedAt: Date? = nil
    
    // Delay Provider for mock time unit testing
    public var delayProvider: DelayProvider = RealDelayProvider()
    // Provider deadlines and the full-card watchdog share a clock separate
    // from debounce/fallback delays. Tests of answer content can hold this
    // clock without changing product deadlines.
    var generationWatchdogDelayProvider: any DelayProvider = RealDelayProvider()
    public var generationFullCardWatchdogNanoseconds: UInt64 = 8_000_000_000
    var stageATimeoutSeconds: TimeInterval = 6.0
    var lateDeepSeekReplacementWindowSeconds: TimeInterval = 6.0

    // Soft Fallback & Advanced Provenance
    public var softFallbackUsed: Bool {
        get { liveInterview.softFallbackUsed }
        set { liveInterview.softFallbackUsed = newValue }
    }
    public var softFallbackUsedUpdates: AnyPublisher<Bool, Never> {
        liveInterview.softFallbackUsedUpdates
    }
    public var softFallbackLatencyMS: Int? {
        get { liveInterview.softFallbackLatencyMS }
        set { liveInterview.softFallbackLatencyMS = newValue }
    }
    public var softFallbackLatencyMSUpdates: AnyPublisher<Int?, Never> {
        liveInterview.softFallbackLatencyMSUpdates
    }
    public var softFallbackShownAt: Date? {
        get { liveInterview.softFallbackShownAt }
        set { liveInterview.softFallbackShownAt = newValue }
    }
    public var softFallbackShownAtUpdates: AnyPublisher<Date?, Never> {
        liveInterview.softFallbackShownAtUpdates
    }
    private let deepseekFirstTokenMSSource = CurrentValueSubject<Int?, Never>(nil)
    public var deepseekFirstTokenMS: Int? {
        get { deepseekFirstTokenMSSource.value }
        set { deepseekFirstTokenMSSource.send(newValue); objectWillChange.send() }
    }
    public var deepseekFirstTokenMSUpdates: AnyPublisher<Int?, Never> {
        deepseekFirstTokenMSSource.eraseToAnyPublisher()
    }
    private let deepseekFirstVisibleMSSource = CurrentValueSubject<Int?, Never>(nil)
    public var deepseekFirstVisibleMS: Int? {
        get { deepseekFirstVisibleMSSource.value }
        set { deepseekFirstVisibleMSSource.send(newValue); objectWillChange.send() }
    }
    public var deepseekFirstVisibleMSUpdates: AnyPublisher<Int?, Never> {
        deepseekFirstVisibleMSSource.eraseToAnyPublisher()
    }
    public var finalVisibleSource: String? {
        get { liveInterview.finalVisibleSource }
        set { liveInterview.finalVisibleSource = newValue }
    }
    public var finalVisibleSourceUpdates: AnyPublisher<String?, Never> {
        liveInterview.finalVisibleSourceUpdates
    }
    @Published public var lastRegenerateQuestionID: String? = nil
    @Published public var lastRegenerateSourceTextKind: String = ""
    @Published public var lastRegenerateOldGenerationID: String? = nil
    @Published public var lastRegenerateNewGenerationID: String? = nil
    @Published public var lastRegenerateRejectionReason: String = ""
    // Read-only compatibility projections. The coordinator owns identity changes.
    public var currentGenerationID: String? { generationCoordinator.activeGeneration?.generationID }
    public var activeGenerationID: String? { currentGenerationID }
    public var activeQuestionID: String? { generationCoordinator.activeGeneration?.questionID }
    public var activeTriggerPath: GenerationTriggerPath? { generationCoordinator.activeGeneration?.triggerPath }
    public var activeGenerationStartedAt: Date? { generationCoordinator.activeGeneration?.startedAt }
    // internal for AppState extension access only
    @Published public internal(set) var previousGenerationID: String? = nil
    // internal for AppState extension access only
    @Published public internal(set) var cancelledGenerationCount: Int = 0
    // internal for AppState extension access only
    @Published public internal(set) var staleCallbackDiscardCount: Int = 0
    // internal for AppState extension access only
    @Published public internal(set) var staleAnswerDiscardCount: Int = 0
    // internal for AppState extension access only
    @Published public internal(set) var answerQuestionMismatchCount: Int = 0
    // internal for AppState extension access only
    @Published public internal(set) var lastAlignmentError: String = ""
    // internal for AppState extension access only
    @Published public internal(set) var recentSuggestionAlignments: [SuggestionAlignmentRecord] = []
    // internal for AppState extension access only
    @Published public internal(set) var currentAnswerQuestionIntent: AnswerRelevanceIntent? = nil
    // internal for AppState extension access only
    @Published public internal(set) var currentPromptQuestionText: String = ""
    // internal for AppState extension access only
    @Published public internal(set) var currentPromptPrimaryQuestion: String = ""
    // internal for AppState extension access only
    @Published public internal(set) var currentPromptContainsPreviousQuestion: Bool = false
    // internal for AppState extension access only
    @Published public internal(set) var currentPreviousQuestionIncluded: Bool = false
    // internal for AppState extension access only
    @Published public internal(set) var currentPreviousQuestionText: String = ""
    // internal for AppState extension access only
    @Published public internal(set) var currentContextBleedRisk: ContextBleedRisk = .low
    // internal for AppState extension access only
    @Published public internal(set) var currentRAGChunkIDs: [String] = []
    // internal for AppState extension access only
    @Published public internal(set) var currentRAGChunkIntents: [AnswerRelevanceIntent] = []
    // internal for AppState extension access only
    @Published public internal(set) var currentFirstQuestionSuppressedReason: String = ""
    // internal for AppState extension access only
    @Published public internal(set) var currentPromptTokenEstimate: Int? = nil
    // internal for AppState extension access only
    @Published public internal(set) var currentPromptContextPreviews: [String] = []
    // internal for AppState extension access only
    @Published public internal(set) var currentAnswerIntent: AnswerRelevanceIntent? = nil
    // internal for AppState extension access only
    @Published public internal(set) var currentExpectedThemesMatched: [String] = []
    // internal for AppState extension access only
    @Published public internal(set) var currentSuspectedMismatchReason: String = ""
    // internal for AppState extension access only
    @Published public internal(set) var duplicateSuppressionCount: Int = 0
    // internal for AppState extension access only
    public var fallbackWatchdogActive: Bool { generationCoordinator.fallbackWatchdogTask != nil }
    // Current-generation registration is owned by the coordinator. A terminal
    // UI or cancellation request does not certify task exit; retired cleanup
    // is separately visible through the coordinator's pending-cleanup counts.
    public var stageBTaskActive: Bool { generationCoordinator.stageBTask != nil }
    // internal for AppState extension access only
    public internal(set) var providerStreamActive: Bool {
        get { liveInterview.providerStreamActive }
        set { liveInterview.providerStreamActive = newValue }
    }
    public var providerStreamActiveUpdates: AnyPublisher<Bool, Never> {
        liveInterview.providerStreamActiveUpdates
    }
    @Published public var userInteractedWithCard: Bool = false
    
    // Keychain Diagnostics properties
    var keychainServiceName: String { settingsState.keychainServiceName }
    var keychainDeepSeekAccount: String { settingsState.keychainDeepSeekAccount }
    var keychainDeepSeekKeyExists: Bool {
        get { settingsState.keychainDeepSeekKeyExists }
        set { settingsState.keychainDeepSeekKeyExists = newValue }
    }
    var keychainDeepSeekKeyLengthCategory: String { settingsState.keychainDeepSeekKeyLengthCategory }
    var keychainMaskedKey: String { settingsState.keychainMaskedKey }
    var keychainLastReadStatus: String { settingsState.keychainLastReadStatus }
    var keychainLastWriteStatus: String { settingsState.keychainLastWriteStatus }
    var keychainMigrationPerformed: Bool { settingsState.keychainMigrationPerformed }
    var keychainLegacyItemFound: Bool { settingsState.keychainLegacyItemFound }
    var keychainLegacyItemCount: Int { settingsState.keychainLegacyItemCount }
    var keychainMismatchStatus: String { settingsState.keychainMismatchStatus }
    var keychainAuthorizationWarning: String? { settingsState.keychainAuthorizationWarning }
    
    // Read-only task projections retained for diagnostics and existing test waits.
    var stageBTask: Task<Void, Never>? { generationCoordinator.stageBTask }
    var softFallbackTask: Task<Void, Never>? { generationCoordinator.fallbackWatchdogTask }
    var fullCardWatchdogTask: Task<Void, Never>? { generationCoordinator.fullCardWatchdogTask }
    public var simulateSuggestionPersistenceFailure: Bool = false
    public var simulatedSuggestionPersistenceDelayNanoseconds: UInt64 = 0

    typealias ActiveGenerationController = GenerationCoordinator.ActiveGeneration
    var activeGenerationController: ActiveGenerationController? { generationCoordinator.activeGeneration }
    // internal for AppState extension access only
    var pendingIgnoredSystemAudioFallback: (questionID: String, reason: String)?
    // Existing mixed replay fixtures keep their type and write boundary; Live
    // owns the only queue value and commits before notifying its observers.
    typealias PendingAcceptedQuestion = LiveInterviewFeature.PendingAcceptedQuestion
    var pendingAcceptedQuestions: [PendingAcceptedQuestion] {
        get { liveInterview.pendingAcceptedQuestions }
        set { liveInterview.replaceAcceptedQuestions(newValue) }
    }
    // internal for AppState extension access only
    var queuedQuestionHandoffTask: Task<Void, Never>? { generationCoordinator.queuedQuestionHandoffTask }
#if DEBUG
    var queuedQuestionHandoffDelayProviderForTesting: (any DelayProvider)?
#endif
    // internal for AppState extension access only
    var autoSuggestionLaunchPending: Bool { generationCoordinator.autoLaunchPending }
    // internal for AppState extension access only
    var mainThreadHeartbeatTask: Task<Void, Never>?
    // internal for AppState extension access only
    var lastHeartbeatTickAt: Date?
    
    // Read-only compatibility; prefetch work and cache have one Live owner.
    let liveRAGPrefetch = LiveRAGPrefetch()
    var precomputeDebounceTask: Task<Void, Never>? { liveRAGPrefetch.currentTask }
    var precomputedRAGCache: [String: LiveRAGPrefetch.CacheItem] { liveRAGPrefetch.cachedItems }

    var materialImportStatus: String { documentsState.importStatus }
    var materialImportTask: Task<Void, Never>? { documentsState.importTask }
    var materialImportID: UUID { documentsState.importID }
    typealias MaterialURLExtraction = DocumentsState.URLExtraction
    typealias MaterialDataExtraction = DocumentsState.DataExtraction
    let materialURLExtraction: MaterialURLExtraction
    let materialDataExtraction: MaterialDataExtraction
    var pendingMaterialImportTaskCount: Int { documentsState.pendingImportTaskCount }

    lazy var preparationState = AppComposition.makePreparationState(app: self)
    lazy var practiceController = AppComposition.makePracticeController(app: self)
    let database: AppDatabase
    let documentRepository: DocumentRepository
    let interviewContextRepository: InterviewContextRepository
    let sessionRepository: SessionRepository
    let transcriptRepository: TranscriptRepository
    let suggestionRepository: SuggestionRepository
    let recapRepository: RecapRepository
    let settingsRepository: SettingsRepository
    let keychainService: KeychainService
    let audioDeviceRouteMonitor: AudioDeviceRouteMonitor?
    let permissionService: PermissionService
    let systemAudioCaptureService: ScreenCaptureKitSystemAudioCaptureService
    let microphoneDiagnostics: MicrophoneDiagnosticsService
    let mockTranscriptionService: MockTranscriptionService

    // internal for AppState extension access only
    let localDataService: LocalDataService
    // internal for AppState extension access only
    var contextRetrievalService: ContextRetrievalService!
    // internal for AppState extension access only
    let llmRouter: LLMRouter
    // internal for AppState extension access only
    let questionDetectionService: QuestionDetectionService
    // internal for AppState extension access only
    let suggestionGenerationService: SuggestionGenerationService
    // internal for AppState extension access only
    let generationCoordinator: GenerationCoordinator
    // internal for AppState extension access only
    var appleSpeechService: AppleSpeechTranscriptionService?
    // internal for AppState extension access only
    var activeTranscriptionProvider: TranscriptionProvider?
    // Retains local ASR providers whose audio delegates are weakly held by the
    // capture services.
    var activeASRProviderRuntime: (any ASRProvider)?
    // One owner schedules, invalidates, retires and joins Live capture controls.
    // Compatibility consumers observe exact handles without writing a second list.
    let captureLifecycle = LiveCaptureLifecycle()
    var captureStartupTask: Task<Void, Never>? { captureLifecycle.startupTask }
    var captureStartupID: UUID? { captureLifecycle.startupID }
    var captureTeardownTask: Task<Void, Never>? { captureLifecycle.teardownTask }
    var captureTeardownID: UUID? { captureLifecycle.teardownID }
    // internal for AppState extension access only
    var ownsSystemAudioCaptureRuntime = false
    // Concrete Live owners expose their existing receipt. This derived view
    // does not adopt a foreign native capture because a legacy Boolean is true.
    var ownsCurrentSystemAudioCaptureRuntime: Bool {
        if let provider = activeASRProviderRuntime as? LocalParakeetASRProvider {
            return provider.ownsCurrentSystemAudioCapture(systemAudioCaptureService)
        }
        if let provider = activeASRProviderRuntime as? AppleSpeechASRProvider {
            return provider.ownsCurrentSystemAudioCapture(systemAudioCaptureService)
        }
        let speech = appleSpeechService ?? (activeTranscriptionProvider as? AppleSpeechTranscriptionService)
        return speech?.ownsCurrentSystemAudioCapture(systemAudioCaptureService) == true
    }
    // Terminal delivery may follow exact native release. This projection
    // never grants active/native/PCM authority or adopts another owner's epoch.
    var hasMostRecentSystemAudioCaptureReceipt: Bool {
        if let provider = activeASRProviderRuntime as? LocalParakeetASRProvider {
            return provider.hasMostRecentSystemAudioCaptureReceipt(systemAudioCaptureService)
        }
        if let provider = activeASRProviderRuntime as? AppleSpeechASRProvider {
            return provider.hasMostRecentSystemAudioCaptureReceipt(systemAudioCaptureService)
        }
        let speech = appleSpeechService ?? (activeTranscriptionProvider as? AppleSpeechTranscriptionService)
        return speech?.hasMostRecentSystemAudioCaptureReceipt(systemAudioCaptureService) == true
    }
    // internal for AppState extension access only
    var transcriptionTask: Task<Void, Never>? { captureLifecycle.transcriptionTask }
    
    // internal for AppState extension access only
    var detectionDebounceTask: Task<Void, Never>? { liveInterview.detectionDebounceTask }
    // internal for AppState extension access only
    var activeDetectionTask: Task<Void, Never>? { liveInterview.activeDetectionTask }
    // internal for AppState extension access only
    var activeAITask: Task<Void, Never>? { generationCoordinator.requestTask }
    var providerTestTask: Task<Void, Never>? { settingsState.providerTestTask }
    var recapTask: Task<Void, Never>? { historyState.recapTask }
    var recapSessionID: String? { historyState.recapSessionID }
    var answerProviderModeOverride: AnswerProviderMode?
    var localLLMProviderOverride: (any LocalLLMProvider)?
    let questionRoutingProvider: (any LocalLLMProvider)?
    var automaticContextBuildTask: Task<Void, Never>? { interviewContextState.worker }
    var automaticContextBuildID: UUID { interviewContextState.buildID }
    var automaticContextBuilderOverride: (any InterviewContextBuilding)? {
        get { interviewContextState.builderOverride }
        set { interviewContextState.builderOverride = newValue }
    }
    // internal for AppState extension access only
    var lastDetectionAt: Date?
    // internal for AppState extension access only
    var intentionalRepeatQuestionIDs: Set<String> { liveInterview.intentionalRepeatQuestionIDs }
#if DEBUG
    // Compatibility for existing synthetic replay fixtures. These setters
    // forward to the sole Live owner; no application-level copy is stored.
    var recentQuestionTimestamps: [String: Date] {
        get { liveInterview.recentQuestionTimestampsForTesting }
        set { liveInterview.recentQuestionTimestampsForTesting = newValue }
    }
    var transcriptReconciler: TranscriptReconciler {
        get { liveInterview.transcriptReconcilerForTesting }
        set { liveInterview.transcriptReconcilerForTesting = newValue }
    }
#endif
    var cancelledPersistenceGenerationIDs = Set<String>()
    var terminalGenerationIDs: Set<String> { generationCoordinator.terminalGenerationIDs }
    struct SuggestionPersistenceClaim {
        let cardID: String
        let identity: GenerationIdentity
    }
    var suggestionPersistenceClaims = [String: SuggestionPersistenceClaim]()
    var successfulSuggestionPersistenceOwners = Set<String>()

    private var activeObserverToken: AnyCancellable?
    private var terminationObserverToken: AnyCancellable?
    var liveSystemAudioDiagnosticObserverToken: AnyCancellable?
    private var resourceShutdownTask: (id: UUID, task: Task<Bool, Never>)?
    private lazy var ownedVerificationCoordinator = HirevaVerificationCoordinator()
    var verificationCoordinator: HirevaVerificationCoordinator {
#if DEBUG
        if let verificationCoordinatorOverrideForTesting { return verificationCoordinatorOverrideForTesting }
#endif
        return ownedVerificationCoordinator
    }
    // Admission stays closed between failed cleanup attempts. The frozen
    // operation retains the original owners after active capture fields clear.
    private var resourceShutdownOperation: (@MainActor () async -> Bool)?
    private var resourceShutdownSucceeded = false
#if DEBUG
    // Controlled scheduler seam; nil in ordinary debug runs and absent in release.
    var shutdownResultDidAwaitForTesting: (@MainActor () async -> Void)?
    // Mixed-path test seam before any Speech object or floating panel is created.
    var liveSystemAudioDiagnosticWillCreateServiceForTesting: (@MainActor () async throws -> Void)?
    // Counts exact captured prefetch handles; no scheduling or I/O override.
    var ragPrefetchShutdownSnapshotForTesting: (@MainActor (Int) -> Void)?
    // Observe the actual generation drain entry. Counts describe ownership;
    // they do not certify that an underlying resource has stopped.
    var generationShutdownWillDrainForTesting: (@MainActor (Int, Int) -> Void)?
    // Test-owned instance, never the production verification singleton.
    var verificationCoordinatorOverrideForTesting: HirevaVerificationCoordinator?
    // Read-only actual App entry observation, never a cleanup override.
    var verificationShutdownScopeDidObserveForTesting: (@MainActor (Bool) -> Void)?
    // Read-only receipt observation: nil in ordinary debug runs, absent in release.
    var speechPermissionTaskDidRegisterForTesting: (@MainActor (Task<Void, Never>) -> Void)?
#endif
    var isShuttingDown: Bool { resourceShutdownOperation != nil || resourceShutdownSucceeded }

    private enum ResourceShutdownStep: CaseIterable {
        case verification, signalMonitor, manual, routeMonitor, practice, documents, context, diagnostics
        case preparation, generation, history, settings, localModels, signing
        case systemPermissions, captureControls, provider, speech, ancillary
    }
    @MainActor
    private final class ResourceShutdownProgress {
        private var completed = Set<ResourceShutdownStep>()
        var isComplete: Bool { completed.count == ResourceShutdownStep.allCases.count }
        // This bounded application receipt set owns no task or service. A
        // successful stop/save boundary is never invoked again on quit retry.
        func run(_ step: ResourceShutdownStep,
            operation: @MainActor () async -> Bool) async {
            guard !completed.contains(step) else { return }
            if await operation() { completed.insert(step) }
        }
    }
    // Tests can stop at the actual backend dispatch before opening any device.
    var liveASRWillStart: (@MainActor (ASRProviderID, AudioCaptureMode) throws -> Void)?
    var systemAudioErrorDidObserve: (@MainActor (String?) -> Void)?
    private let verificationMocksEnabledOverride: Bool?
    private let defaultAppSectionOverride: AppSection?
    private let ownedPreferenceDefaultsSuiteName: String?
    var dialogueDefaults: UserDefaults?
    // internal for AppState extension access only
    var recentQuestionsFingerprints = [String]()
    private var cancellables = Set<AnyCancellable>()
    // internal for AppState extension access only
    lazy var audioSignalMonitor = AudioSignalMonitor { [weak self] in
        guard let self, !self.isShuttingDown else { return }
        self.monitorAudioSignal()
    }
    // Read-only compatibility for existing diagnostics and native Timer tests.
    var audioSignalMonitoringTimer: Timer? { audioSignalMonitor.currentTimer }

    var detectionDebounceSeconds: TimeInterval = 2
    // internal for AppState extension access only
    let autoSuggestionConfidenceThreshold = 0.75
    // internal for AppState extension access only
    let possibleQuestionConfidenceRange = 0.55..<0.75

    static func bootstrap() -> AppState {
        AppComposition.bootstrap()
    }

    init(
        database: AppDatabase,
        questionRoutingProvider: (any LocalLLMProvider)? = nil,
        llmRouter: LLMRouter? = nil,
        permissionService: PermissionService? = nil,
        audioDeviceRouteMonitor: AudioDeviceRouteMonitor? = nil,
        systemAudioPermissions: SystemAudioPermissionController? = nil,
        keychainService: KeychainService? = nil,
        contextRetrievalService: ContextRetrievalService? = nil,
        systemAudioCaptureService: ScreenCaptureKitSystemAudioCaptureService? = nil,
        verificationMocksEnabled: Bool? = nil,
        defaultAppSection: AppSection? = nil,
        dialogueDefaults: UserDefaults? = nil,
        materialURLExtraction: MaterialURLExtraction? = nil,
        materialDataExtraction: MaterialDataExtraction? = nil,
        localModelsSetupFactory: (@MainActor () -> LocalModelsSetupViewModel)? = nil,
        manualCaptureCapabilities: ManualCaptureCapabilities? = nil,
        embeddingProviderResolverOverride: ((AppSettings) -> (any EmbeddingProvider)?)? = nil,
        diagnosticsTraceStore: RuntimeTranscriptTraceStore = .shared
    ) {
        self.localModelsSetupFactory = localModelsSetupFactory
        self.embeddingProviderResolverOverride = embeddingProviderResolverOverride
        self.questionRoutingProvider = questionRoutingProvider
        let testProcess = isRunningUnderTestOrAutomation()
        let routeMonitor = audioDeviceRouteMonitor ?? AppComposition.makeAudioRouteMonitor(isTestProcess: testProcess)
        self.audioDeviceRouteMonitor = routeMonitor
        let dialogue = AppComposition.resolveDialoguePreferences(override: dialogueDefaults, isTestProcess: testProcess)
        let resolvedDialogueDefaults = dialogue.defaults
        let ownedPreferenceDefaultsSuiteName = dialogue.ownedSuiteName
        let dialogueMigration = dialogue.migration
        let repositories = AppComposition.Repositories(database: database)
        let documents = repositories.documents
        let interviewContexts = repositories.interviewContexts
        let sessions = repositories.sessions
        let transcripts = repositories.transcripts
        let suggestions = repositories.suggestions
        let recaps = repositories.recaps
        let settings = repositories.settings
        let keychain = AppComposition.makeKeychain(override: keychainService, isTestProcess: testProcess)
        let language = AppComposition.LanguageServices(settings: settings, keychain: keychain, routerOverride: llmRouter)
        let consent = PersistenceConsent()


        self.database = database
        self.persistenceConsent = consent
        self.materialURLExtraction = materialURLExtraction ?? { try await MaterialExtractionService.extractCancellable(url: $0) }
        self.materialDataExtraction = materialDataExtraction ?? { try await MaterialExtractionService.extractCancellable(data: $0, filename: $1) }
        self.diagnosticsState = DiagnosticsState(traceLogURL: AppPaths.runtimeTranscriptTraceURL(for: database.databaseURL), traceStore: diagnosticsTraceStore, latencyQuery: suggestions.makeLatencyQuery())
        self.documentRepository = documents
        self.interviewContextRepository = interviewContexts
        self.sessionRepository = sessions
        self.historyState = AppComposition.makeHistoryState(database: database, repositories: repositories,
            recapService: language.recaps, consent: consent)
        self.transcriptRepository = transcripts
        self.suggestionRepository = suggestions
        self.recapRepository = recaps
        self.settingsRepository = settings
        self.keychainService = keychain
        let permissions = permissionService ?? PermissionService()
        self.permissionService = permissions
        self.manualCaptureCapabilities = manualCaptureCapabilities ?? .existingAdapter()
        let resolvedSystemAudioCapture = systemAudioCaptureService ?? (
            testProcess ? ScreenCaptureKitSystemAudioCaptureService() : .shared
        )
        self.systemAudioCaptureService = resolvedSystemAudioCapture
        self.systemAudioPermissions = systemAudioPermissions ?? AppComposition.makeSystemAudioPermissions(
            permissions: permissions, isTestProcess: testProcess,
            diagnosticCaptureService: resolvedSystemAudioCapture)
        self.verificationMocksEnabledOverride = verificationMocksEnabled
        self.defaultAppSectionOverride = defaultAppSection
        self.ownedPreferenceDefaultsSuiteName = ownedPreferenceDefaultsSuiteName
        self.dialogueDefaults = resolvedDialogueDefaults
        self.microphoneDiagnostics = MicrophoneDiagnosticsService(inputDeviceName: { [weak routeMonitor] in
            routeMonitor?.currentInputDeviceName ?? "Default Input"
        })
        self.mockTranscriptionService = MockTranscriptionService()
        self.localDataService = AppComposition.makeLocalDataService(repositories: repositories, keychain: keychain)
        self.llmRouter = language.router
        self.questionDetectionService = language.questions
        self.suggestionGenerationService = language.suggestions
        self.generationCoordinator = language.generations
        self.resolvedInterviewSessionPhase = dialogueMigration.resolvedPhase
        self.detectedDialogueTurnType = dialogueMigration.legacyTurnType ?? .unknown
        
        self.contextRetrievalService = AppComposition.makeContextRetrievalService(
            repository: documents, override: contextRetrievalService,
            configuration: { [weak self] in
                guard let self else { return (AppSettings.default, nil) }
                let snapshot = self.settings
                return (snapshot, self.resolveEmbeddingProvider(settings: snapshot))
            }
        )
        
        cancellables.formUnion(AppComposition.connectFeatureObservations(app: self))

        AppComposition.startInitialRuntimeWork(app: self,
            loadKeychain: !(keychain.store is RealKeychainStore), isTestProcess: testProcess)
        cancellables.formUnion(AppComposition.connectRuntimeObservations(app: self))
        let applicationObservers = AppComposition.connectApplicationNotifications(
            app: self, isTestProcess: testProcess)
        activeObserverToken = applicationObservers.active
        terminationObserverToken = applicationObservers.termination
    }

    // Runtime observations enter existing application policy synchronously on MainActor.
    // The composition root owns no capture or presentation fact.
    func initializeAudioRouteRecoveryPresentation() {
        if self.isRecoveringAudioRoute {
            self.audioRouteError = "Audio device changed. Reconnecting..."
            self.noAudioWarningVisible = true
            self.microphoneDiagnostics.markAsRecovering()
        }
    }

    func audioRouteRecoveryDidUpdate(_ isRecovering: Bool, monitor audioDeviceRouteMonitor: AudioDeviceRouteMonitor) {
        self.objectWillChange.send()
        if isRecovering {
            self.audioRouteError = "Audio device changed. Reconnecting..."
            self.noAudioWarningVisible = true
            self.microphoneDiagnostics.markAsRecovering()
        } else {
            let state = audioDeviceRouteMonitor.engineRecoveryState
            if state == "Active" {
                self.audioRouteError = "Audio input restored."
                self.noAudioWarningVisible = false
            } else if state == "Failed" {
                self.audioRouteError = "Could not restore audio input. Try Stop Listening and Start Listening again."
                self.noAudioWarningVisible = true
            }
        }
    }

    func systemAudioCaptureStateDidUpdate(_ capturing: Bool) {
        self.objectWillChange.send()
        // Propagate capture stream end only for the AppState that actually
        // started the shared ScreenCaptureKit system-audio runtime.
        let ownsTerminalCapture = self.hasMostRecentSystemAudioCaptureReceipt
        let wasActivelyCapturingOrStoppedWithoutReason =
            self.currentCaptureRuntimeState == .listening ||
            self.currentCaptureRuntimeState == .generating ||
            self.currentCaptureRuntimeState == .stopped(reason: nil)
        if !capturing,
           ownsTerminalCapture,
           wasActivelyCapturingOrStoppedWithoutReason,
           !self.systemAudioCaptureService.isCapturing,
           !self.hasHealthyParakeetAfterSystemFailure {
            if self.stopReason == nil {
                self.stopListening(reason: .screenCaptureStreamEnded)
            }
        }
    }

    func systemAudioCaptureErrorDidUpdate(_ err: String?) {
        self.objectWillChange.send()
        if self.hasMostRecentSystemAudioCaptureReceipt {
            if self.hasHealthyParakeetAfterSystemFailure,
               let sourceError = (self.activeASRProviderRuntime as? LocalParakeetASRProvider)?.captureSourceFailures[.systemAudio] {
                self.reportParakeetSourceFailure(source: .systemAudio, error: sourceError)
            } else if let currentError = self.systemAudioCaptureService.lastError {
                // A queued signal reads only the current exact owner's
                // committed diagnostic; foreign capture remains separate.
                self.currentCaptureRuntimeState = .error(reason: currentError)
            }
        }
        self.systemAudioErrorDidObserve?(err)
    }

    // ARC can invoke this closure away from MainActor. It owns only the exact
    // Foundation token and its center, and never reads UI or AppState.
    nonisolated static func makeNotificationCancellation(
        observer: NSObjectProtocol, center: NotificationCenter
    ) -> AnyCancellable {
        AnyCancellable { center.removeObserver(observer) }
    }

    func markSystemAudioCaptureRuntimeOwnedForTesting(_ owned: Bool) {
        ownsSystemAudioCaptureRuntime = owned
    }

    deinit {
        actionFeedbackDismissalTasksToDrain.values.forEach { $0.cancel() }
        mainThreadHeartbeatTask?.cancel()
        if let ownedPreferenceDefaultsSuiteName {
            // Only the UUID suite created by this instance is owned here.
            // Reopen by immutable identity rather than access mutable actor state.
            UserDefaults(suiteName: ownedPreferenceDefaultsSuiteName)?
                .removePersistentDomain(forName: ownedPreferenceDefaultsSuiteName)
        }
    }

    /// Application termination and test fixtures share one cleanup operation.
    /// Admission closes synchronously; the retained task finishes only after
    /// the feature owners and captured runtime handles have actually exited.
    /// The caller owns any UI deadline; cancellation cannot force a resource out.
    @discardableResult
    func shutdownResources() async -> Bool {
        // Check before borrowing an existing shutdown task: an external drain
        // can already be waiting for this detector or its inherited child.
        guard liveInterview.canDrainAutomaticDetectionFromCurrentTask else { return false }
#if DEBUG
        verificationShutdownScopeDidObserveForTesting?(verificationCoordinator.canDrainFromCurrentTask)
#endif
        guard verificationCoordinator.canDrainFromCurrentTask else { return false }
        // A dismissal worker or its inherited child cannot borrow a drain
        // which already waits for that exact still-live launch.
        guard canDrainActionFeedbackDismissalsFromCurrentTask else { return false }
        guard generationCoordinator.canDrainFromCurrentTask else { return false }
        if let owned = resourceShutdownTask { return await owned.task.value }
        if resourceShutdownSucceeded { return true }
        let firstAttempt = resourceShutdownOperation == nil
        let operation = resourceShutdownOperation ?? makeResourceShutdownOperation()
        resourceShutdownOperation = operation
        let id = UUID()
        let cleanup = Task { @MainActor in
            let released = await operation()
            // The exact owner retires before any waiter can observe its Bool.
            // Retry admission cannot depend on which waiter resumes first.
            if self.resourceShutdownTask?.id == id {
                self.resourceShutdownTask = nil
                if released {
                    self.resourceShutdownSucceeded = true
                    self.resourceShutdownOperation = nil
                }
            }
            return released
        }
        resourceShutdownTask = (id, cleanup)
        if firstAttempt { cancelOwnedWorkForShutdown() }
        let released = await cleanup.value
#if DEBUG
        await shutdownResultDidAwaitForTesting?()
#endif
        return released
    }

    private func makeResourceShutdownOperation() -> @MainActor () async -> Bool {
        let endingSession = currentSession.map { (id: $0.id, endedAt: $0.endedAt ?? Date()) }
        let sessions = sessionRepository
        let verification = verificationCoordinator
        let capture = captureLifecycle
        let provider = activeASRProviderRuntime
        let speech = appleSpeechService ?? activeTranscriptionProvider as? AppleSpeechTranscriptionService
        let practice = practiceController
        let documents = documentsState
        let preparation = preparationState
        let context = interviewContextState
        let generation = generationCoordinator
#if DEBUG
        let generationWillDrain = generationShutdownWillDrainForTesting
#endif
        let history = historyState
        let settingsOwner = settingsState
        let localModels = localModelsOwner
        let permissionOwner = systemAudioPermissions
        let permissionDiagnostics = permissionService
        let manual = manualCaptureController
        let routeMonitor = audioDeviceRouteMonitor
        let diagnostics = diagnosticsState
        let microphoneMetering = microphoneDiagnostics
        let signalMonitor = audioSignalMonitor
        let prefetch = liveRAGPrefetch
        let live = liveInterview
        let prefetchTasks = prefetch.tasksToDrain
#if DEBUG
        ragPrefetchShutdownSnapshotForTesting?(prefetchTasks.count)
#endif
        let ancillary = [
            mainThreadHeartbeatTask].compactMap { $0 } +
            Array(actionFeedbackDismissalTasksToDrain.values)
#if DEBUG
        let ancillaryWillAwait = ancillaryTaskWillAwaitForTesting
#endif
        let progress = ResourceShutdownProgress()
        return { [weak self] in
            await progress.run(.verification) {
                await verification.shutdown()
            }
            await progress.run(.signalMonitor) {
                await signalMonitor.shutdown()
                return !signalMonitor.hasPendingWork
            }
            await progress.run(.manual) {
                do { try await manual.shutdown() }
                catch { return false }
                return !manual.hasUnreleasedResources
            }
            await progress.run(.routeMonitor) {
                await routeMonitor?.shutdown()
                return !(routeMonitor?.hasOwnedRecoveryWork ?? false)
            }
            await progress.run(.practice) {
                await practice.shutdown()
                return true
            }
            await progress.run(.documents) {
                await documents.shutdown()
                return documents.pendingImportTaskCount == 0 && documents.embeddings.pendingTaskCount == 0
            }
            await progress.run(.context) {
                await context.shutdown()
                return context.pendingTaskCount == 0
            }
            await progress.run(.diagnostics) {
                await diagnostics.shutdown()
                await microphoneMetering.shutdown()
                return diagnostics.pendingLatencyTaskCount == 0 &&
                    diagnostics.pendingSystemAudioDiagnosticTaskCount == 0 &&
                    !microphoneMetering.hasOwnedCallbackWork
            }
            await progress.run(.preparation) {
                await preparation.shutdown()
                return preparation.pendingTaskCount == 0
            }
            await progress.run(.generation) {
#if DEBUG
                generationWillDrain?(generation.pendingCleanupTaskCount, generation.retiringTaskCount)
#endif
                await generation.drainRetiredTasks()
                return generation.pendingCleanupTaskCount == 0
            }
            await progress.run(.history) {
                let stopped = await history.shutdownAndDrain()
                return stopped && history.pendingRecapTaskCount == 0
            }
            await progress.run(.settings) {
                await settingsOwner.shutdown()
                return settingsOwner.pendingTaskCount == 0
            }
            await progress.run(.localModels) {
                let stopped = await localModels?.shutdown() ?? true
                return stopped && (localModels?.pendingOperationTaskCount ?? 0) == 0
            }
            await progress.run(.signing) {
                await permissionDiagnostics.shutdownCodeSigningDiagnostics()
            }
            await progress.run(.systemPermissions) {
                do { try await permissionOwner.shutdown() }
                catch { return false }
                return !permissionOwner.hasUnreleasedResources
            }
            await progress.run(.captureControls) {
                // This explicit shutdown attempt may retry captured failed
                // operations. Drain alone never authorizes native retry.
                await capture.retryFailedTeardowns()
                await capture.drain()
                return capture.pendingTaskCount == 0 && !capture.hasFailedTeardown
            }
            await progress.run(.provider) {
                await provider?.stopTranscription()
                return (provider as? LocalParakeetASRProvider)?.captureCleanupFailure == nil &&
                    (provider as? AppleSpeechASRProvider)?.captureCleanupFailure == nil
            }
            await progress.run(.speech) {
                if let speech, (provider as? AppleSpeechASRProvider)?.ownsSpeechService(speech) != true {
                    speech.retryStoppingAudioInput()
                }
                await speech?.finishStoppingAudioInput()
                return speech?.hasUnreleasedAudioInput != true
            }
            await progress.run(.ancillary) {
                await prefetch.shutdown()
                let detectionReleased = await live.drainAutomaticDetection()
                for task in ancillary {
#if DEBUG
                    ancillaryWillAwait?(task)
#endif
                    await task.value
                }
                return detectionReleased && live.pendingAutomaticDetectionTaskCount == 0 &&
                    live.pendingPartialFinalizationTaskCount == 0
            }
            guard progress.isComplete else { return false }
            // Keep the original session/time through quit retries; all admitted
            // content writers have drained before this metadata-only finalization.
            if let endingSession {
                do {
                    let endedAt = try sessions.endSession(id: endingSession.id, at: endingSession.endedAt)
                    if let endedAt, self?.currentSession?.id == endingSession.id {
                        self?.currentSession?.endedAt = endedAt
                    }
                } catch { return false }
            }
            // The earlier Diagnostics step cannot seal later legitimate native,
            // Generation or History cleanup audit. Finish only this App's writer
            // after all producers have exited; the shared store remains usable.
            await diagnostics.finalizeTraceWritesForShutdown()
            return true
        }
    }

    /// Fixtures own their database; cleanup never closes or removes it.
    func shutdownForTesting() async { _ = await shutdownResources() }

    private func cancelOwnedWorkForShutdown() {
        verificationCoordinator.closeAdmission()
        audioDeviceRouteMonitor?.closeAdmission()
        diagnosticsState.closeAdmission()
        manualCaptureController.closeAdmission()
        preparationState.closeAdmission()
        documentsState.closeAdmission()
        interviewContextState.closeAdmission()
        liveRAGPrefetch.closeAdmission()
        liveInterview.closeAutomaticDetectionAdmission()
        settingsState.closeAdmission()
        localModelsOwner?.closeAdmission()
        systemAudioPermissions.closeAdmission()
        historyState.closeAdmission()
        captureLifecycle.closeAdmission()
        cancelActiveGenerationForStop()
        generationCoordinator.closeAdmission()

        actionFeedbackDismissalTasksToDrain.values.forEach { $0.cancel() }
        actionFeedbackDismissTasks.removeAll()
        mainThreadHeartbeatTask?.cancel()
        mainThreadHeartbeatTask = nil
        audioSignalMonitor.closeAdmission()

        // Failed Apple capture is retried once by its awaited owner step, not
        // also by synchronous admission closure and each legacy alias.
        if let speech = activeTranscriptionProvider as? AppleSpeechTranscriptionService {
            if speech.captureCleanupFailure == nil { speech.stop() }
        } else { activeTranscriptionProvider?.stop() }
        activeTranscriptionProvider = nil
        activeASRProviderRuntime = nil
        if appleSpeechService?.captureCleanupFailure == nil { appleSpeechService?.stop() }
        appleSpeechService = nil
        ownsSystemAudioCaptureRuntime = false
        microphoneDiagnostics.closeAdmission()

        activeObserverToken?.cancel()
        activeObserverToken = nil
        terminationObserverToken?.cancel()
        terminationObserverToken = nil
        liveSystemAudioDiagnosticObserverToken?.cancel()
        liveSystemAudioDiagnosticObserverToken = nil
        cancellables.removeAll()
        if let ownedPreferenceDefaultsSuiteName {
            dialogueDefaults?.removePersistentDomain(forName: ownedPreferenceDefaultsSuiteName)
        }
    }

    // MARK: - Action Feedback (moved to AppState+Actions.swift)

    // MARK: - Diagnostics Helpers (moved to AppState+Diagnostics.swift)

    // MARK: - Background Persistence (moved to AppState+Transcript.swift)

    var onboardingComplete: Bool {
        automaticContextReadiness != .extracting
    }

    var liveBlockedReason: String? {
        if automaticContextReadiness == .extracting { return "Context is being prepared; general practice remains available." }
        return nil
    }

    var activeRealtimeProviderBadge: String { settingsState.activeRealtimeProviderBadge }
    var activeRealtimeProviderPrivacyNote: String { settingsState.activeRealtimeProviderPrivacyNote }

    var manualVerificationRAGMode: String {
        if let mode = lastRetrievalTrace?.retrievalMode, !mode.isEmpty {
            return mode
        }
        guard settings.enableVectorRAG else {
            return "keywordOnly (vector RAG disabled)"
        }
        guard let coverage = embeddingCoverage else {
            return "keywordOnly (embedding coverage unknown)"
        }
        if settings.forceHybridRAG || coverage.coveragePercent >= 80 {
            return "hybrid eligible (\(Int(coverage.coveragePercent))% coverage)"
        }
        return "keywordOnly (\(Int(coverage.coveragePercent))% embedding coverage)"
    }

    func refreshAll(loadKeychain: Bool? = nil) {
        do {
            try settingsState.reload()
            diagnosticsState.prepareForMode(settings.effectiveDiagnosticTraceMode)
            try documentsState.reload()
            try interviewContextState.reload(sessionSnapshotID: currentSession?.contextSnapshotID)
            try historyState.refreshSessions()
            settingsState.refreshKeychainStatus(
                loadImmediately: loadKeychain ?? !(keychainService.store is RealKeychainStore),
                isTestProcess: isRunningUnderTestOrAutomation(),
                answerMode: selectedAnswerProviderMode)
            let cvCount = (try? documentRepository.chunks(type: .cv).count) ?? 0
            let jdCount = (try? documentRepository.chunks(type: .jobDescription).count) ?? 0
            latexPollutedChunkCount = (try? documentRepository.latexPollutedChunkCount()) ?? 0
            refreshPermissions()
            updateDiagnostics {
                $0.storedCVChunkCount = cvCount
                $0.storedJDChunkCount = jdCount
                $0.apiCallCount = (try? self.settingsRepository.apiCallCount()) ?? 0
            }
            
            let verificationMocksEnabled = ProductionContextPolicy.verificationMocksEnabled(
                explicitOverride: verificationMocksEnabledOverride,
                environmentValue: ProcessInfo.processInfo.environment["ENABLE_VERIFICATION_MOCKS"]
            )
            injectVerificationMockData(enabled: verificationMocksEnabled)
            if verificationMocksEnabled {
                if let defaultAppSectionOverride {
                    self.selectedSection = defaultAppSectionOverride
                } else if let sectionStr = ProcessInfo.processInfo.environment["DEFAULT_APP_SECTION"],
                          let sec = AppSection(rawValue: sectionStr) {
                    self.selectedSection = sec
                }
            }
            refreshLatencyAverages()
        } catch {
            showError(error.localizedDescription)
        }
    }

    // MARK: - Documents (moved to AppState+Documents.swift)

    // MARK: - Providers & Settings (moved to AppState+Providers.swift)

    func submitMockQuestion(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !primaryHomeActionShouldStop || currentSession?.mode == .mock else {
            showError("Stop real capture before injecting a synthetic transcript.")
            return
        }
        practiceController.pause()


        if activeTranscriptionProvider === mockTranscriptionService {
            mockTranscriptionService.submit(trimmed)
        } else {
            Task { [weak self] in
                guard let self else { return }
                do {
                    let session: InterviewSession
                    if let currentSession = self.currentSession, currentSession.mode == .mock {
                        session = currentSession
                    } else {
                        session = try self.createContextBoundSession(mode: .mock, title: "Synthetic Diagnostic")
                    }
                    self.currentSession = session
                    if self.transcriptSegments.isEmpty {
                        self.transcriptSegments.append(.system("Practice transcript injected for testing automatic detection.", sessionID: session.id))
                    }
                    self.liveState = .transcribing
                    self.showFloatingAssistant()
                    let segment = TranscriptSegment(
                        id: UUID().uuidString,
                        sessionID: session.id,
                        source: .mock,
                        speaker: self.selectedMockSpeaker,
                        text: trimmed,
                        startTime: nil,
                        endTime: nil,
                        createdAt: Date(),
                        inputDeviceName: "Manual Inject",
                        outputDeviceName: nil,
                        deviceID: nil,
                        confidence: 1.0
                    )
                    await self.handleTranscriptSegment(segment)
                } catch {
                    let message = self.userFacing(error)
                    self.liveState = .error(message)
                    self.showError(message)
                }
            }
        }
    }

    /// Coordinates one suggestion-generation attempt from accepted question to
    /// visible first answer, Stage B expansion, persistence, and diagnostics.
    ///
    /// The caller has accepted one clean question. GenerationCoordinator owns
    /// the root and provider children; this application boundary applies frozen
    /// evidence, UI and persistence policy. Async returns must validate the full
    /// generation identity before publishing to the current question.
    ///
    /// Stage B timeout is not automatically a product failure: an aligned,
    /// complete first answer or local fallback may remain the correct visible
    /// result while full-card expansion is retried or optimized later.
    func generateSuggestion(
        for question: DetectedQuestion,
        session: InterviewSession,
        transcript: String,
        autoGenerated: Bool,
        triggerPath explicitTriggerPath: GenerationTriggerPath? = nil,
        source explicitSource: AudioSourceType? = nil,
        speaker explicitSpeaker: SpeakerRole? = nil,
        requestID owningRequestID: String? = nil,
        localProvider frozenLocalProvider: (any LocalLLMProvider)? = nil,
        localModelName frozenLocalModelName: String? = nil,
        answerMode frozenAnswerMode: AnswerProviderMode? = nil,
        providerConfiguration frozenProviderConfiguration: LLMProviderConfiguration? = nil,
        retrievalService submittedRetrievalService: (any ContextRetrievalService)? = nil,
        prefetchAdmission submittedPrefetchAdmission: LiveRAGPrefetch.CacheAdmission? = nil,
        consentTicket submittedTicket: Int? = nil
    ) async throws {
        try Task.checkCancellation()
        let triggerPath = explicitTriggerPath ?? (autoGenerated ? .autoDetect : .manualGenerate)
        let requestID: String
        if let owningRequestID {
            guard generationCoordinator.isCurrentRequest(owningRequestID) else { return }
            requestID = owningRequestID
        } else {
            requestID = beginGenerationRequest(triggerPath: triggerPath)
        }
        // Preliminary invalidation can synchronously submit a newer request.
        // An obsolete entry must stop before writing question/UI diagnostics.
        guard generationCoordinator.isCurrentRequest(requestID) else { return }
        defer {
            if owningRequestID == nil { generationCoordinator.finishRequest(requestID: requestID) }
        }
        // Configuration edits apply to the next request. The existing public
        // answer-mode setter instead cancels work and revokes its consent.
        let answerProviderMode = frozenAnswerMode ?? selectedAnswerProviderMode
        // A submitted mode also marks an explicitly captured configuration,
        // including absence. Do not revive a missing provider from later settings.
        let answerProviderConfiguration = frozenAnswerMode != nil
            ? frozenProviderConfiguration
            : activeRealtimeProvider ?? (try? llmRouter.realtimeConfiguration())
        guard answerProviderMode == .localQwenPrimary || answerProviderConfiguration != nil else {
            throw LLMProviderError.notConfigured("Realtime LLM provider")
        }
        let localModelName = frozenLocalModelName ?? selectedQwenModelName
        let localAnswerProvider = frozenLocalProvider ?? localLLMProviderOverride ?? OllamaQwenProvider()
        let routingProvider = questionRoutingProvider ?? localAnswerProvider
        // Settings/provider edits apply to the next RAG request, including
        // changes during routing before the retriever itself starts.
        let prefetchAdmission = submittedPrefetchAdmission ?? (
            frozenAnswerMode == nil && submittedRetrievalService == nil
                ? liveRAGPrefetch.cacheAdmission : nil)
        let retrievalService = frozenAnswerMode != nil
            ? submittedRetrievalService
            : submittedRetrievalService ?? contextRetrievalService?.freezeConfiguration()
        var question = question
        let routingTicket = submittedTicket ?? persistenceConsent.ticket()
        // Submitted manual actions already captured their parent and mode.
        // Current UI mode changes apply to the next request; session/context
        // revocation remains guarded by the request and generation owners.
        if frozenAnswerMode == nil || question.taskDescriptor?.conversationContextCaptured != true {
            freezeConversationContext(for: &question)
        }
        let routingParent = question.taskDescriptor?.conversationContext
        #if DEBUG
        let guardBeganNS = DispatchTime.now().uptimeNanoseconds
        #endif
        let preGenerationGuard = QuestionRuntimeAcceptanceGuard.validateDetectedQuestionForGeneration(question)
        #if DEBUG
        diagnosticsState.onPipelineTimingForTesting?("generation.pre_guard_sync",
            session.id, question.id, nil, guardBeganNS,
            DispatchTime.now().uptimeNanoseconds, question.questionText.utf16.count)
        #endif
        guard preGenerationGuard.accepted else {
            let reason = preGenerationGuard.reason ?? .pipelineRejected
            if lastRegenerateQuestionID == question.id {
                lastRegenerateRejectionReason = reason.rawValue
                recordLifecycleTrace(
                    "regenerate.rejected",
                    sessionID: session.id,
                    questionID: question.id,
                    generationID: lastRegenerateOldGenerationID,
                    text: question.questionText,
                    reason: "sourceTextKind=\(lastRegenerateSourceTextKind.isEmpty ? "unknown" : lastRegenerateSourceTextKind) rejectionReason=\(reason.rawValue)"
                )
            }
            recordTranscriptRuntimeEvent(.generationRejected(
                sessionID: session.id,
                question: question.questionText,
                reason: reason,
                timestamp: Date()
            ))
            lastDetectionSkipReason = reason.rawValue
            lastQuestionDetectionResult = "Pre-generation guard rejected question: \(preGenerationGuard.diagnostic)"
            lastTranscriptQuestionGenerationTrace.generationTriggered = false
            lastTranscriptQuestionGenerationTrace.generationBlockedReason = reason.rawValue
            liveState = anyCaptureRunning ? .listening : .ready
            currentCaptureRuntimeState = anyCaptureRunning ? .listening : .stopped(reason: stopReason)
            throw RuntimeQuestionRejectedError(reason: reason, diagnostic: preGenerationGuard.diagnostic)
        }
        #if DEBUG
        let contextBindBeganNS = DispatchTime.now().uptimeNanoseconds
        #endif
        let generationSession = try ensureContextSnapshot(for: session)
        #if DEBUG
        diagnosticsState.onPipelineTimingForTesting?("generation.context_bind_sync",
            session.id, question.id, nil, contextBindBeganNS,
            DispatchTime.now().uptimeNanoseconds, question.questionText.utf16.count)
        let contextReadBeganNS = DispatchTime.now().uptimeNanoseconds
        #endif
        let generationSnapshot = generationSession.contextSnapshotID.flatMap { try? interviewContextRepository.snapshot(id: $0) }
        #if DEBUG
        diagnosticsState.onPipelineTimingForTesting?("generation.context_read_sync",
            session.id, question.id, nil, contextReadBeganNS,
            DispatchTime.now().uptimeNanoseconds, question.questionText.utf16.count)
        #endif
        let attributedSegment = question.transcriptSegmentID.flatMap { segmentID in
            transcriptSegments.first(where: { $0.id == segmentID })
        }
        let telemetrySource = explicitSource ?? attributedSegment?.source
        let telemetrySpeaker = explicitSpeaker ?? attributedSegment?.speaker
        lastDetectedQuestion = question
        guard generationCoordinator.isCurrentRequest(requestID), !Task.isCancelled else { return }
        lastDetectedQuestionText = question.questionText
        guard generationCoordinator.isCurrentRequest(requestID), !Task.isCancelled else { return }
        lastDetectedQuestionSource = telemetrySource?.rawValue ?? lastDetectedQuestionSource
        guard generationCoordinator.isCurrentRequest(requestID), !Task.isCancelled else { return }
        lastDetectedQuestionSpeaker = telemetrySpeaker?.rawValue ?? lastDetectedQuestionSpeaker
        guard generationCoordinator.isCurrentRequest(requestID), !Task.isCancelled else { return }
        if !isActionLoading(ActionID.generateAnswer) {
            beginAction(
                ActionID.generateAnswer,
                title: autoGenerated ? "Question detected" : "Generating first answer",
                message: autoGenerated ? "Generating answer..." : "Preparing a speakable first answer..."
            )
        }

        guard generationCoordinator.isCurrentRequest(requestID), !Task.isCancelled else { return }
        liveState = .generatingSuggestion
        guard generationCoordinator.isCurrentRequest(requestID), !Task.isCancelled else { return }
        let stateBefore = currentCaptureRuntimeState.displayName
        currentCaptureRuntimeState = .generating
        guard generationCoordinator.isCurrentRequest(requestID), !Task.isCancelled else { return }
        addCaptureEvent(name: "suggestionGenerationStarted", stateBefore: stateBefore, stateAfter: "generating", reason: "questionDetected")
        guard generationCoordinator.isCurrentRequest(requestID), !Task.isCancelled else { return }
        self.suggestionGenerationStarted = true
        guard generationCoordinator.isCurrentRequest(requestID), !Task.isCancelled else { return }
        self.floatingPanelUpdated = false
        guard generationCoordinator.isCurrentRequest(requestID), !Task.isCancelled else { return }

        let requestStart = Date()
        let isAcceptedQuestionRegenerate = lastRegenerateQuestionID == question.id &&
            lastRegenerateSourceTextKind == "accepted_question"
        let cardID = isAcceptedQuestionRegenerate ? (currentSuggestion?.id ?? UUID().uuidString) : UUID().uuidString
        let generationID = UUID().uuidString
        if isAcceptedQuestionRegenerate {
            liveInterview.markIntentionalQuestionRepeat(question.id)
            lastRegenerateNewGenerationID = generationID
            guard generationCoordinator.isCurrentRequest(requestID), !Task.isCancelled else { return }
            lastRegenerateRejectionReason = ""
            guard generationCoordinator.isCurrentRequest(requestID), !Task.isCancelled else { return }
            recordLifecycleTrace(
                "regenerate.generation.started",
                sessionID: session.id,
                questionID: question.id,
                generationID: generationID,
                text: question.questionText,
                reason: "sourceTextKind=accepted_question oldGenerationId=\(lastRegenerateOldGenerationID ?? "nil") newGenerationId=\(generationID)"
            )
        }
        recordTranscriptRuntimeEvent(.generationStarted(
            sessionID: session.id,
            questionID: question.id,
            generationID: generationID,
            question: question.questionText,
            timestamp: Date()
        ))
        recordLifecycleTrace(
            "answer.request.started",
            sessionID: session.id,
            questionID: question.id,
            generationID: generationID,
            text: question.questionText
        )
        guard generationCoordinator.isCurrentRequest(requestID), !Task.isCancelled else { return }
        let traceSegmentID = lastTranscriptQuestionGenerationTrace.transcriptSegmentID
        if !traceSegmentID.isEmpty,
           question.transcriptSegmentID == traceSegmentID {
            lastTriggerDecision = InterviewTriggerDecision.triggerAnswer.rawValue
            guard generationCoordinator.isCurrentRequest(requestID), !Task.isCancelled else { return }
            lastTriggerReason = "accepted substantive interviewer question"
            guard generationCoordinator.isCurrentRequest(requestID), !Task.isCancelled else { return }
            lastSuppressionReason = ""
            guard generationCoordinator.isCurrentRequest(requestID), !Task.isCancelled else { return }
            lastTranscriptQuestionGenerationTrace.generationTriggered = true
            guard generationCoordinator.isCurrentRequest(requestID), !Task.isCancelled else { return }
            lastTranscriptQuestionGenerationTrace.generationID = generationID
            guard generationCoordinator.isCurrentRequest(requestID), !Task.isCancelled else { return }
            lastTranscriptQuestionGenerationTrace.generationBlockedReason = ""
            guard generationCoordinator.isCurrentRequest(requestID), !Task.isCancelled else { return }
            lastTranscriptQuestionGenerationTrace.providerStatus = activeRealtimeProviderBadge
            guard generationCoordinator.isCurrentRequest(requestID), !Task.isCancelled else { return }
            lastTranscriptQuestionGenerationTrace.triggerDecision = InterviewTriggerDecision.triggerAnswer.rawValue
            guard generationCoordinator.isCurrentRequest(requestID), !Task.isCancelled else { return }
            lastTranscriptQuestionGenerationTrace.triggerReason = "accepted substantive interviewer question"
            guard generationCoordinator.isCurrentRequest(requestID), !Task.isCancelled else { return }
            lastTranscriptQuestionGenerationTrace.suppressionReason = ""
            guard generationCoordinator.isCurrentRequest(requestID), !Task.isCancelled else { return }
        }
        guard generationCoordinator.isCurrentRequest(requestID), !Task.isCancelled else { return }
        activateGeneration(
            question: question,
            generationID: generationID,
            triggerPath: triggerPath,
            requestStart: requestStart,
            source: telemetrySource,
            speaker: telemetrySpeaker,
            requestID: requestID,
            providerConfiguration: answerProviderConfiguration,
            answerProviderMode: answerProviderMode,
            persistenceTicket: routingTicket
        )
        guard let generationIdentity = activeGenerationController?.identity,
              generationIdentity.generationID == generationID,
              generationCoordinator.isCurrentRequest(requestID) else { return }
        @MainActor func acceptsInitialPresentation() -> Bool {
            !Task.isCancelled && generationCoordinator.isCurrentRequest(requestID) &&
                generationCoordinator.canPublish(generationIdentity)
        }
        guard acceptsInitialPresentation() else { return }
        setGenerationUIState(.generatingFirstAnswer(questionID: question.id, generationID: generationID, triggerPath: triggerPath), generationID: generationID, whileCurrent: acceptsInitialPresentation)
        guard acceptsInitialPresentation() else { return }
        let useFirstAnswerFallbackWatchdogs = answerProviderMode != .localQwenPrimary


        self.streamRequestStartAt = requestStart
        guard acceptsInitialPresentation() else { return }
        self.streamFirstTokenAt = nil
        guard acceptsInitialPresentation() else { return }
        self.streamFirstVisibleTextAt = nil
        guard acceptsInitialPresentation() else { return }
        self.streamFirstSentenceAt = nil
        guard acceptsInitialPresentation() else { return }
        self.streamFullResponseAt = nil
        guard acceptsInitialPresentation() else { return }
        self.streamJSONParsedAt = nil
        guard acceptsInitialPresentation() else { return }
        self.streamPersistedAt = nil
        guard acceptsInitialPresentation() else { return }

        self.isStreamingSayFirst = true
        guard acceptsInitialPresentation() else { return }
        self.streamedSayFirst = ""
        guard acceptsInitialPresentation() else { return }
        self.isExpandingSuggestionCard = false
        guard acceptsInitialPresentation() else { return }

        self.softFallbackUsed = false
        guard acceptsInitialPresentation() else { return }
        self.softFallbackLatencyMS = nil
        guard acceptsInitialPresentation() else { return }
        self.softFallbackShownAt = nil
        guard acceptsInitialPresentation() else { return }
        self.deepseekFirstTokenMS = nil
        guard acceptsInitialPresentation() else { return }
        self.deepseekFirstVisibleMS = nil
        guard acceptsInitialPresentation() else { return }
        self.finalVisibleSource = nil
        guard acceptsInitialPresentation() else { return }
        self.userInteractedWithCard = false
        guard acceptsInitialPresentation() else { return }
        self.ragRetrievalLatencyMS = nil
        guard acceptsInitialPresentation() else { return }
        self.firstVisibleStateSetAt = nil
        guard acceptsInitialPresentation() else { return }
        self.currentSuggestionSetAt = nil
        guard acceptsInitialPresentation() else { return }
        self.streamedSayFirstSetAt = nil
        guard acceptsInitialPresentation() else { return }

        recordVerificationBoundary("verification.generation_snapshot_frozen",
            at: VerificationTiming.hostTicks(), sessionID: generationIdentity.sessionID,
            segmentID: question.transcriptSegmentID, questionID: generationIdentity.acceptedQuestionID,
            generationID: generationIdentity.generationID, contextSnapshotID: generationIdentity.contextSnapshotID)

        if answerProviderMode == .localQwenPrimary {
            startFullCardWatchdog(generationID: generationID, cardID: cardID,
                question: question, session: session, requestStart: requestStart, triggerPath: triggerPath)
        }

        let routingInput = InterviewRoutingInput(
            question: question.questionText, questionID: question.id,
            contextSnapshotID: generationSnapshot?.id,
            parentQuestionID: routingParent?.questionID,
            previousQuestion: routingParent?.questionText,
            previousAnswer: routingParent?.answerText
        )
        var descriptor = question.taskDescriptor ?? InterviewTaskDescriptor(question: question.questionText)
        if descriptor.decision == nil || descriptor.question != question.questionText || descriptor.decision?.contextSnapshotID != generationSnapshot?.id || descriptor.decision?.model != localModelName || descriptor.decision?.routerVersion != InterviewQuestionRouter.version {
            let decision = try await generationCoordinator.routeQuestion(identity: generationIdentity,
                input: routingInput, provider: routingProvider, model: localModelName)
            guard !Task.isCancelled, isActiveGeneration(generationID, questionID: question.id) else { return }
            recordVerificationBoundary("verification.route_producer_completed",
                at: decision.verificationCompletedHostTicks, sessionID: generationIdentity.sessionID,
                segmentID: question.transcriptSegmentID, questionID: decision.questionID,
                generationID: generationIdentity.generationID, contextSnapshotID: decision.contextSnapshotID,
                questionRevision: decision.questionRevision, artifactRevision: decision.artifactRevision,
                producerFailure: decision.failure != nil)
            descriptor.question = question.questionText
            descriptor.apply(decision)
            question.taskDescriptor = descriptor
            lastDetectedQuestion = question
            if settings.saveTranscriptsLocally {
                try? persistenceConsent.write(ticket: routingTicket) {
                    try suggestionRepository.resolveQuestionTask(question)
                }
            }
        }
        if useFirstAnswerFallbackWatchdogs {
            startFullCardWatchdog(
                generationID: generationID,
                cardID: cardID,
                question: question,
                session: session,
                requestStart: requestStart,
                triggerPath: triggerPath
            )
        }
        let localQuestion = question
        let localSession = generationSession
        let localTranscript = transcript

        // This watchdog covers the remote answer pipeline, including RAG
        // retrieval. Local Qwen primary must either produce ollama_qwen or fail;
        // it must not publish template fallback as the default local path.
        let initialFallbackTask = generationCoordinator.launchInitialFirstAnswerFallbackDeadline(
            identity: generationIdentity, startedAt: requestStart, delayProvider: delayProvider,
            presentation: { [weak self] identity in
                guard let self, !Task.isCancelled,
                      self.generationCoordinator.canPublish(identity),
                      !self.generationUIState.isTerminal,
                      self.currentSession?.id == identity.sessionID else { return nil }
                return (self.currentSuggestion, self.streamFirstVisibleTextAt)
            }
        ) { [weak self] identity, elapsed in
            guard let self else { return }
            let acceptsPublication = {
                !Task.isCancelled && self.generationCoordinator.canPublish(identity) &&
                    !self.generationUIState.isTerminal && self.currentSession?.id == identity.sessionID
            }
            guard acceptsPublication() else { return }
            self.softFallbackUsed = true
            guard acceptsPublication() else { return }
            self.softFallbackLatencyMS = elapsed
            guard acceptsPublication() else { return }
            self.softFallbackShownAt = Date()
            guard acceptsPublication() else { return }
            self.finalVisibleSource = "local_first_answer_fallback"
            guard acceptsPublication() else { return }
            var fallbackCard = self.makeInitialFirstAnswerFallbackCard(
                cardID: cardID,
                question: localQuestion,
                session: localSession,
                requestStart: requestStart
            )
            fallbackCard.firstVisibleAnswerMS = elapsed
            if !fallbackCard.keyPoints.isEmpty {
                fallbackCard.firstKeyPointVisibleMS = elapsed
                fallbackCard.allKeyPointsVisibleMS = elapsed
            }
            if !fallbackCard.followUpReady.isEmpty {
                fallbackCard.followUpVisibleMS = elapsed
            }
            guard self.displaySuggestionIfAligned(
                fallbackCard,
                question: localQuestion,
                generationID: generationID,
                triggerPath: triggerPath,
                source: telemetrySource,
                speaker: telemetrySpeaker,
                whileCurrent: acceptsPublication
            ) else { return }
            guard acceptsPublication() else { return }
            self.currentSuggestionSetAt = Date()
            guard acceptsPublication() else { return }
            self.isStreamingSayFirst = false
            guard acceptsPublication() else { return }
            self.isExpandingSuggestionCard = true
            guard acceptsPublication() else { return }
            self.markFirstVisibleAnswer(generationID: generationID, fallback: true, whileCurrent: acceptsPublication)
            guard acceptsPublication() else { return }
            self.setGenerationUIState(.showingFallback(questionID: localQuestion.id, generationID: generationID, triggerPath: triggerPath), generationID: generationID, whileCurrent: acceptsPublication)
            guard acceptsPublication() else { return }
            self.infoAction(ActionID.generateAnswer, title: "First answer visible", message: "Local first answer is visible while the full answer expands.", autoDismissAfter: 3.0, whileCurrent: acceptsPublication)
            guard acceptsPublication() else { return }
            print("[StreamingASR] Initial first-answer fallback triggered at \(elapsed)ms before provider text was visible.")
            if self.finishVisibleFirstAnswerForQueuedQuestionIfNeeded(
                generationID: generationID,
                question: localQuestion,
                session: localSession,
                requestStart: requestStart,
                triggerPath: triggerPath
            ) {
                return
            }
        }
        if initialFallbackTask != nil {
            updateActiveTaskSummary()
        }
        applyPendingIgnoredSystemAudioFallbackIfNeeded(for: question)
        
        var retrievedContext: RetrievedContext? = nil
        var retrievalTrace: RetrievalTrace? = nil
        
        // 1. Consume speculative context only for the exact accepted question.
        var hitCache = false
        if let segmentID = question.transcriptSegmentID, retrievalService != nil {
            let finalIntent = AnswerRelevancePolicy.intent(for: question.questionText)
            let cacheScope = LiveRAGPrefetch.Scope(sessionID: generationSession.id,
                snapshotID: generationSnapshot?.id,
                cacheContextID: generationSnapshot?.id ?? generationSession.contextSnapshotID ?? "legacy-context")
            switch liveRAGPrefetch.consume(scope: cacheScope, admission: prefetchAdmission, segmentID: segmentID,
                questionText: question.questionText, intent: finalIntent) {
            case .hit(let cached):
                retrievedContext = cached.context
                retrievalTrace = cached.trace
                hitCache = true
                lastRAGOperation = "Relevant context cache hit"
                print("[PrecomputeRAG] Exact cache hit")
            case .mismatch:
                lastRAGOperation = "Relevant context cache miss"
                print("[PrecomputeRAG] Cache miss due to question/intent mismatch. Rerunning retrieval.")
            case .miss(let staleCount):
                if staleCount > 0 {
                    lastRAGOperation = "Relevant context cache miss"
                    print("[PrecomputeRAG] Removed \(staleCount) stale cache item(s) for segmentID: \(segmentID).")
                }
            }
        }

        if !hitCache {
            do {
                markRAGOperation("Relevant context retrieval started")
                guard let retrievalService else {
                    throw LLMProviderError.notConfigured("Context retrieval at submission")
                }
                let (context, trace) = try await generationCoordinator.retrieveContext(
                    identity: generationIdentity, service: retrievalService,
                    question: question.questionText, intent: question.intent,
                    maxCVWords: 300, maxJDWords: 180, strategy: question.answerStrategy)
                guard !Task.isCancelled, generationCoordinator.canPublish(generationIdentity),
                      ownsCurrentGenerationPresentation(generationIdentity, requestID: requestID) else {
                    recordStaleGenerationDiscard()
                    return
                }
                retrievedContext = context
                retrievalTrace = trace
                lastRAGOperation = "Relevant context retrieval completed"
            } catch {
                guard !Task.isCancelled, generationCoordinator.canPublish(generationIdentity),
                      ownsCurrentGenerationPresentation(generationIdentity, requestID: requestID) else {
                    recordStaleGenerationDiscard()
                    return
                }
                lastRAGOperation = "Relevant context retrieval failed: \(error.localizedDescription)"
                guard !Task.isCancelled, generationCoordinator.canPublish(generationIdentity),
                      ownsCurrentGenerationPresentation(generationIdentity, requestID: requestID) else { return }
                markGenerationFailed(
                    generationID: generationID,
                    reason: "Relevant context retrieval failed: \(error.localizedDescription)",
                    providerError: error.localizedDescription
                )
                guard ownsCurrentGenerationPresentation(generationIdentity, requestID: requestID) else { return }
                failAction(ActionID.generateAnswer, title: "Generation failed", message: "Could not prepare relevant context. \(userFacing(error))",
                    whileCurrent: { self.ownsCurrentGenerationPresentation(generationIdentity, requestID: requestID) })
                guard ownsCurrentGenerationPresentation(generationIdentity, requestID: requestID) else { return }
                throw error
            }
        }
        
        guard let legacyContext = retrievedContext, let trace = retrievalTrace else {
            guard !Task.isCancelled, generationCoordinator.canPublish(generationIdentity),
                  ownsCurrentGenerationPresentation(generationIdentity, requestID: requestID) else { return }
            let error = LLMProviderError.invalidResponse("Could not retrieve relevant context.")
            markGenerationFailed(generationID: generationID, reason: error.localizedDescription, providerError: error.localizedDescription)
            guard ownsCurrentGenerationPresentation(generationIdentity, requestID: requestID) else { return }
            failAction(ActionID.generateAnswer, title: "Generation failed", message: "Could not prepare relevant context.",
                whileCurrent: { self.ownsCurrentGenerationPresentation(generationIdentity, requestID: requestID) })
            guard ownsCurrentGenerationPresentation(generationIdentity, requestID: requestID) else { return }
            throw error
        }
        guard !Task.isCancelled, generationCoordinator.canPublish(generationIdentity),
              ownsCurrentGenerationPresentation(generationIdentity, requestID: requestID) else {
            recordStaleGenerationDiscard()
            return
        }
        recordVerificationBoundary(hitCache ? "verification.rag_cached_producer_time" : "verification.rag_producer_completed",
            at: trace.verificationCompletedHostTicks, sessionID: generationIdentity.sessionID,
            segmentID: question.transcriptSegmentID, questionID: generationIdentity.acceptedQuestionID,
            generationID: generationIdentity.generationID, contextSnapshotID: generationIdentity.contextSnapshotID)
        recordVerificationBoundary("verification.rag_result_accepted",
            at: VerificationTiming.hostTicks(), sessionID: generationIdentity.sessionID,
            segmentID: question.transcriptSegmentID, questionID: generationIdentity.acceptedQuestionID,
            generationID: generationIdentity.generationID, contextSnapshotID: generationIdentity.contextSnapshotID)
        self.lastRetrievalTrace = trace
        self.ragRetrievalLatencyMS = Int(trace.retrievalLatencyMS)

        let snapshotRetrieval = generationSnapshot.map {
            DynamicInterviewContextEngine().retrieveContext(question: question.questionText, snapshot: $0)
        }
        let context = SnapshotBoundContextPolicy.retrievedContext(
            snapshot: generationSnapshot,
            snapshotContext: snapshotRetrieval?.context,
            legacyContext: legacyContext
        )
        
        // 2. Realtime Context Budget Optimization
        let optimizedContext = trimContextForRealtime(context, question: question)
        
        // Snapshot summaries already own these inputs. Reading live documents
        // here would add an awaited dependency whose result is discarded.
        let summaries: (cv: String, jd: String)
        if let generationSnapshot {
            guard !Task.isCancelled, generationCoordinator.canPublish(generationIdentity) else {
                recordStaleGenerationDiscard()
                return
            }
            summaries = SnapshotBoundContextPolicy.summaries(
                snapshot: generationSnapshot,
                liveCVSummary: "",
                liveJDSummary: ""
            )
            lastSQLiteOperation = "Using frozen context summaries"
        } else {
            let documentRepository = self.documentRepository
            markSQLiteOperation("Loading document summaries in background")
            let (cvRecord, jdRecord) = await Task.detached(priority: .utility) {
                (
                    try? documentRepository.document(type: .cv),
                    try? documentRepository.document(type: .jobDescription)
                )
            }.value
            guard !Task.isCancelled, generationCoordinator.canPublish(generationIdentity) else {
                recordStaleGenerationDiscard()
                return
            }
            lastSQLiteOperation = "Loaded document summaries"
            summaries = SnapshotBoundContextPolicy.summaries(
                snapshot: nil,
                liveCVSummary: makeCompactSummary(cvRecord),
                liveJDSummary: makeCompactSummary(jdRecord)
            )
        }
        let cvSummary = summaries.cv
        let jdSummary = summaries.jd
        // Freeze the prompt inputs after RAG retrieval and before provider
        // streaming. From here on, transcript changes and later questions must
        // not alter the current prompt: question_text must stay equal to
        // prompt_primary_question for this generation.
        let generationContext = GenerationExecutionContext.make(
            session: localSession,
            question: localQuestion,
            generationID: generationID,
            triggerPath: triggerPath,
            provider: answerProviderConfiguration,
            retrievedContext: optimizedContext,
            transcriptSnapshot: localTranscript,
            cvSummary: cvSummary,
            jdSummary: jdSummary,
            startedAt: requestStart,
            source: telemetrySource,
            speaker: telemetrySpeaker,
            stage: .firstAnswer,
            interviewContextSnapshot: generationSnapshot
        )
        let firstAnswerProviderRequest = GenerationProviderRequest(
            context: generationContext,
            streamingEnabled: true
        )
        let promptSnapshot = generationContext.promptSnapshot
        applyPromptSnapshotDiagnostics(promptSnapshot, providerRequest: firstAnswerProviderRequest)
        
        // Citations and persisted source previews must describe the frozen
        // provider input, not the larger pool returned before evidence policy.
        let promptContext = promptSnapshot.ragContextSnapshot
        let generationRetrievedChunks = promptContext.frozenPromptCitations

        // A definite personal dependency with no confirmed candidate facts is
        // a missing-input state, not a reason to ask a model to invent a story.
        // Mixed tasks still reach generation so their general part can be answered.
        if let decision = localQuestion.taskDescriptor?.decision,
           decision.personalEvidence == .required, decision.basis == .candidateRecord,
           generationSnapshot?.candidateEvidence.contains(where: \.isUsable) != true {
            var notice = SuggestionCard(id: cardID, sessionID: localSession.id, questionID: localQuestion.id,
                strategy: "Personal facts needed / 需要个人事实", sayFirst: InterviewQuestionDecision.missingPersonalEvidenceNotice(language: decision.language),
                keyPoints: [], followUpReady: [], confidence: nil, caution: "Clarification only — not a completed answer or a performance sample.",
                evidenceUsed: [], riskLevel: .medium, modelName: "Evidence policy", promptVersion: InterviewQuestionRouter.version,
                isLocal: true, createdAt: Date())
            notice.questionText = localQuestion.questionText
            notice.questionDecision = decision
            notice.generationID = generationID
            notice.promptPrimaryQuestion = localQuestion.questionText
            notice.contextSnapshotID = generationSnapshot?.id
            notice.stageBCompleted = false
            notice.stageBStatus = "needs_personal_evidence"
            notice.groundingDecision = "missing_personal_evidence"
            if displaySuggestionIfAligned(notice, question: localQuestion, generationID: generationID, triggerPath: triggerPath, source: telemetrySource, speaker: telemetrySpeaker),
               let visible = currentSuggestion {
                _ = finishGenerationWithVisibleCard(visible, generationID: generationID, question: localQuestion, session: localSession,
                    requestStart: requestStart, retrievedChunks: [], triggerPath: triggerPath, timedOut: false)
                guard ownsCurrentGenerationPresentation(generationContext.identity, requestID: requestID) else { return }
                warnAction(ActionID.generateAnswer, title: "Personal facts needed", message: "Add or confirm the relevant facts before generating a personal answer.")
            }
            return
        }

        if answerProviderMode == .localQwenPrimary {
            clearFallbackWatchdogTask(generationID: generationID)
            markProviderOperation("Local Qwen primary generation started")
            do {
                let finished = try await finishWithLocalQwenAnswer(
                    question: localQuestion,
                    session: localSession,
                    transcript: localTranscript,
                    context: optimizedContext,
                    retrievedChunks: generationRetrievedChunks,
                    cvSummary: cvSummary,
                    jdSummary: jdSummary,
                    generationID: generationID,
                    cardID: cardID,
                    requestStart: requestStart,
                    triggerPath: triggerPath,
                    source: telemetrySource,
                    speaker: telemetrySpeaker,
                    localProvider: localAnswerProvider,
                    modelName: localModelName,
                    fallbackReason: nil,
                    interviewContextSnapshot: generationSnapshot
                )
                if finished { return }
                guard generationCoordinator.canPublish(generationContext.identity),
                      ownsCurrentGenerationPresentation(generationContext.identity, requestID: requestID),
                      isActiveGeneration(generationID, questionID: localQuestion.id),
                      !Task.isCancelled else {
                    return
                }
                let category = ollamaDiagnostics.finalErrorCategory ?? .alignmentRejectedNonemptyContent
                throw LocalQwenGenerationError(
                    category: category,
                    diagnostic: lastAlignmentError.isEmpty ? category.rawValue : lastAlignmentError
                )
            } catch {
                guard generationCoordinator.canPublish(generationContext.identity),
                      ownsCurrentGenerationPresentation(generationContext.identity, requestID: requestID),
                      shouldPropagateGenerationFailure(
                    generationID: generationID,
                    questionID: localQuestion.id
                ),
                      !Task.isCancelled else {
                    recordStaleGenerationDiscard()
                    return
                }
                markGenerationFailed(
                    generationID: generationID,
                    reason: error.localizedDescription,
                    providerError: error.localizedDescription
                )
                guard ownsCurrentGenerationPresentation(generationContext.identity, requestID: requestID) else { return }
                failAction(ActionID.generateAnswer, title: "Generation failed", message: "Local Qwen did not produce an answer. \(userFacing(error))",
                    whileCurrent: { self.ownsCurrentGenerationPresentation(generationContext.identity, requestID: requestID) })
                guard ownsCurrentGenerationPresentation(generationContext.identity, requestID: requestID) else { return }
                throw error
            }
        }

        // Also used as a blank card shell for provider text. General tasks must
        // never receive a personal-story template while waiting for that text.
        let trigger = StageBTrigger(delayProvider: generationWatchdogDelayProvider)
        
        let ragFallbackTask = generationCoordinator.launchRAGFirstAnswerFallbackDeadline(
            context: generationContext, delayProvider: delayProvider,
            presentation: { [weak self] identity in
                guard let self, !Task.isCancelled,
                      self.generationCoordinator.canPublish(identity),
                      !self.generationUIState.isTerminal,
                      self.currentSession?.id == identity.sessionID else { return nil }
                return (self.currentSuggestion, self.streamFirstVisibleTextAt)
            }
        ) { [weak self] identity, elapsed in
            guard let self else { return }
            let acceptsPublication = {
                !Task.isCancelled && self.generationCoordinator.canPublish(identity) &&
                    !self.generationUIState.isTerminal && self.currentSession?.id == identity.sessionID
            }
            guard acceptsPublication() else { return }
            self.softFallbackUsed = true
            guard acceptsPublication() else { return }
            self.softFallbackLatencyMS = elapsed
            guard acceptsPublication() else { return }
            self.finalVisibleSource = "rag_template_soft_fallback"
            guard acceptsPublication() else { return }

            let fallbackCard = self.makeRAGFallbackCard(context: generationContext, cardID: cardID, isSoft: true)
            var visibleFallback = fallbackCard
            visibleFallback.firstVisibleAnswerMS = elapsed
            guard self.displaySuggestionIfAligned(
                visibleFallback,
                question: localQuestion,
                generationID: generationID,
                triggerPath: triggerPath,
                source: telemetrySource,
                speaker: telemetrySpeaker,
                whileCurrent: acceptsPublication
            ) else { return }
            guard acceptsPublication() else { return }
            self.currentSuggestionSetAt = self.currentSuggestionSetAt ?? Date()
            guard acceptsPublication() else { return }
            self.isStreamingSayFirst = false
            guard acceptsPublication() else { return }
            self.isExpandingSuggestionCard = true
            guard acceptsPublication() else { return }
            self.markFirstVisibleAnswer(generationID: generationID, fallback: true, whileCurrent: acceptsPublication)
            guard acceptsPublication() else { return }
            self.setGenerationUIState(.showingFallback(questionID: localQuestion.id, generationID: generationID, triggerPath: triggerPath), generationID: generationID, whileCurrent: acceptsPublication)
            guard acceptsPublication() else { return }
            self.infoAction(ActionID.generateAnswer, title: "First answer visible", message: "Fast local answer is visible while DeepSeek continues.", autoDismissAfter: 3.0, whileCurrent: acceptsPublication)
            guard acceptsPublication() else { return }
            print("[StreamingASR] Soft fallback triggered at \(elapsed)ms because no DeepSeek text was visible yet.")
            if self.finishVisibleFirstAnswerForQueuedQuestionIfNeeded(
                generationID: generationID,
                question: localQuestion,
                session: localSession,
                requestStart: requestStart,
                triggerPath: triggerPath
            ) {
                return
            }
        }
        if ragFallbackTask != nil {
            updateActiveTaskSummary()
        }

        // The coordinator owns Stage B creation, its exact trigger and provider workflow.
        guard let configuredExpansion = launchProviderExpansion(context: generationContext, providerQuestion: localQuestion,
            providerContext: optimizedContext, cvSummary: cvSummary, jdSummary: jdSummary,
            providerConfiguration: answerProviderConfiguration, cardID: cardID,
            retrievedChunks: generationRetrievedChunks, trigger: trigger) else {
            throw CancellationError()
        }

        // Provider consumption and its handle are owned by the coordinator.
        guard launchProviderFirstAnswer(
            context: generationContext, providerQuestion: localQuestion,
            providerContext: optimizedContext, cvSummary: cvSummary, jdSummary: jdSummary,
            providerConfiguration: answerProviderConfiguration, trigger: trigger
        ) != nil else { throw CancellationError() }

        // The deadline observer and the cooperative transport race can finish
        // in either order. Publish the deadline outcome once, using answer
        // eligibility and the still-owned expansion task for source metadata.
        let stageATimeoutNanoseconds = UInt64(max(stageATimeoutSeconds, 0) * 1_000_000_000)
        generationCoordinator.launchDeadline(
            identity: generationContext.identity, role: .stageATimeout,
            nanoseconds: stageATimeoutNanoseconds, delayProvider: delayProvider
        ) { [weak self] _, _ in
            guard let self,
                  !self.generationUIState.isTerminal,
                  self.activeGenerationController?.stageATask != nil,
                  self.visibleAnswerExists else { return }
            _ = self.preserveStageAAnswerWhileExpansionContinues(
                    context: generationContext, cardID: cardID,
                    answerProviderConfiguration: answerProviderConfiguration,
                    fallbackProviderModel: firstAnswerProviderRequest.model,
                    generationRetrievedChunks: generationRetrievedChunks
                )
        }
        
        // The owner admits and retires its exact fallback role. This single
        // application bridge publishes only the original stream presentation.
        @MainActor func publishStageAExit(failure: Error? = nil) -> Bool {
            generationCoordinator.applyStageAStreamExit(identity: generationContext.identity) { [weak self] identity in
                guard let self else { return false }
                @MainActor func acceptsPublication() -> Bool {
                    !Task.isCancelled && self.generationCoordinator.canPublish(identity) &&
                        self.currentSession?.id == localSession.id && !self.generationUIState.isTerminal
                }
                guard acceptsPublication() else { return false }
                self.providerStreamActive = false
                guard acceptsPublication() else { return false }
                self.updateActiveTaskSummary()
                guard acceptsPublication() else { return false }
                if let failure {
                    print("[StreamingASR] Stage A Fast Say-First timed out or failed: code=\((failure as NSError).code)")
                }
                self.isStreamingSayFirst = false
                return acceptsPublication()
            }
        }

        // Race Stage A with 6.0s timeout
        var fastSayFirst = ""
        do {
            guard let completed = try await generationCoordinator.awaitStageAFirstAnswer(
                identity: generationContext.identity, timeoutSeconds: stageATimeoutSeconds,
                delayProvider: generationWatchdogDelayProvider) else {
                recordStaleGenerationDiscard(attributedTo: generationContext.identity)
                return
            }
            fastSayFirst = completed
            guard self.currentGenerationID == generationID else {
                recordStaleGenerationDiscard(attributedTo: generationContext.identity)
                return
            }
            guard !self.generationUIState.isTerminal else {
                return
            }
            guard publishStageAExit() else { return }
            
            let elapsed = Date().timeIntervalSince(requestStart)
            let isSoft = self.softFallbackUsed
            
            if isSoft {
                // Apply conservative late DeepSeek replacement checks
                let replace = !self.userInteractedWithCard &&
                    elapsed < self.lateDeepSeekReplacementWindowSeconds &&
                    self.isSpecificAnswer(fastSayFirst)
                if replace {
                    if var current = self.currentSuggestion,
                       current.stageBCompleted == true,
                       self.visibleCardMatchesGeneration(
                            card: current,
                            generationID: generationID,
                            detectedQuestionID: localQuestion.id,
                            promptPrimaryQuestion: localQuestion.questionText
                        ) {
                        current.sayFirst = fastSayFirst
                        self.markProviderStreamOwnership(&current)
                        let validated = await self.validateAndRewriteIfNeeded(current, generationID: generationID)
                        guard self.isActiveGeneration(generationID), !Task.isCancelled else {
                            self.recordStaleGenerationDiscard()
                            return
                        }
                        guard self.displaySuggestionIfAligned(
                            validated,
                            question: localQuestion,
                            generationID: generationID,
                            triggerPath: triggerPath,
                            source: telemetrySource,
                            speaker: telemetrySpeaker
                        ) else { return }
                        self.markFirstVisibleAnswer(generationID: generationID, fallback: false)
                        self.persistSuggestionInBackground(validated, chunks: self.currentSuggestionRetrievedChunks, generationID: generationID, requestStart: requestStart)
                        self.setGenerationUIState(.answerReady(questionID: localQuestion.id, generationID: generationID, triggerPath: triggerPath), generationID: generationID)
                        self.recordTranscriptRuntimeEvent(.generationCompleted(
                            sessionID: localSession.id,
                            questionID: localQuestion.id,
                            generationID: generationID,
                            question: localQuestion.questionText,
                            timestamp: Date()
                        ))
                        self.recordLifecycleTrace(
                            "answer.stream.completed",
                            sessionID: localSession.id,
                            questionID: localQuestion.id,
                            generationID: generationID,
                            text: localQuestion.questionText
                        )
                        self.processNextQueuedAutoQuestionIfIdle()
                    } else {
                        var updated = self.makeRAGFallbackCard(context: generationContext, cardID: cardID, isSoft: true)
                        updated.sayFirst = fastSayFirst
                        self.markProviderStreamOwnership(&updated)
                        updated.caution = "DeepSeek answer updated. Expanding details..."
                        updated.firstVisibleAnswerMS = updated.firstVisibleAnswerMS ?? Int(Date().timeIntervalSince(requestStart) * 1000)
                        self.finalVisibleSource = "deepseek_stream"
                        let validated = await self.validateAndRewriteIfNeeded(updated, generationID: generationID)
                        guard self.isActiveGeneration(generationID), !Task.isCancelled else {
                            self.recordStaleGenerationDiscard()
                            return
                        }
                        guard self.displaySuggestionIfAligned(
                            validated,
                            question: localQuestion,
                            generationID: generationID,
                            triggerPath: triggerPath,
                            source: telemetrySource,
                            speaker: telemetrySpeaker
                        ) else { return }
                        self.currentSuggestionSetAt = self.currentSuggestionSetAt ?? Date()
                        self.markFirstVisibleAnswer(generationID: generationID, fallback: false)
                        self.setGenerationUIState(.expandingFullAnswer(questionID: localQuestion.id, generationID: generationID, triggerPath: triggerPath), generationID: generationID)
                        if self.finishVisibleFirstAnswerForQueuedQuestionIfNeeded(
                            generationID: generationID,
                            question: localQuestion,
                            session: localSession,
                            requestStart: requestStart,
                            triggerPath: triggerPath
                        ) {
                            return
                        }
                    }
                    print("[StreamingASR] Soft fallback replaced with late DeepSeek text at \(Int(elapsed * 1000))ms.")
                } else {
                    print("[StreamingASR] Soft fallback preserved. Late DeepSeek text rejected (elapsed: \(Int(elapsed * 1000))ms, interacted: \(self.userInteractedWithCard)).")
                    if self.finishVisibleFirstAnswerForQueuedQuestionIfNeeded(
                        generationID: generationID,
                        question: localQuestion,
                        session: localSession,
                        requestStart: requestStart,
                        triggerPath: triggerPath
                    ) {
                        return
                    }
                }
            } else {
                // Set temporary suggestion card immediately since DeepSeek was fast!
	                let tempCard = SuggestionCard(
	                    id: cardID,
	                    sessionID: localSession.id,
	                    questionID: localQuestion.id,
                    strategy: "Quick Opener",
                    sayFirst: fastSayFirst,
                    keyPoints: [],
                    followUpReady: [],
                    confidence: 0.8,
                    caution: "Streaming quick opener. Expanding answer...",
                    evidenceUsed: [],
                    riskLevel: .low,
                    modelName: "deepseek-v4-flash",
                    promptVersion: "quick-v1",
                    providerKind: .deepSeek,
                    providerName: "DeepSeek",
                    providerBaseURL: "https://api.deepseek.com",
                    latencyMS: Int(Date().timeIntervalSince(requestStart) * 1000),
                    isLocal: false,
	                    rawJSON: nil,
	                    createdAt: Date(),
	                    questionIntent: promptSnapshot.questionIntent,
	                    promptQuestionText: promptSnapshot.questionTextSnapshot,
	                    promptPrimaryQuestion: promptSnapshot.promptPrimaryQuestion,
	                    promptContainsPreviousQuestion: promptSnapshot.promptContainsPreviousQuestion,
	                    previousQuestionIncluded: promptSnapshot.previousQuestionIncluded,
	                    previousQuestionText: promptSnapshot.previousQuestionText,
	                    contextBleedRisk: promptSnapshot.contextBleedRisk,
	                    ragChunkIDs: promptSnapshot.ragChunkIDs,
	                    ragChunkIntents: promptSnapshot.ragChunkIntents,
	                    promptTokenEstimate: promptSnapshot.promptTokenEstimate,
	                    promptContextPreview: promptSnapshot.ragChunkPreviews.joined(separator: "\n"),
	                    sayFirstSource: "deepseek_stream",
                    stageATimedOut: false,
                    stageBCompleted: false,
                    stageBStatus: "skipped",
                    latencyFirstTokenMS: self.deepseekFirstTokenMS,
                    latencyFirstVisibleMS: self.deepseekFirstVisibleMS,
                    latencyFullCardMS: nil,
                    softFallbackUsed: false,
                    softFallbackLatencyMS: nil,
                    deepseekFirstTokenMS: self.deepseekFirstTokenMS,
                    deepseekFirstVisibleMS: self.deepseekFirstVisibleMS,
                    finalVisibleSource: "deepseek_stream"
                )
                var visibleTempCard = tempCard
                visibleTempCard.firstVisibleAnswerMS = self.deepseekFirstVisibleMS ?? Int(Date().timeIntervalSince(requestStart) * 1000)
                self.finalVisibleSource = "deepseek_stream"
                let validated = await self.validateAndRewriteIfNeeded(visibleTempCard, generationID: generationID)
                guard self.isActiveGeneration(generationID), !Task.isCancelled else {
                    self.recordStaleGenerationDiscard()
                    return
                }
                guard self.displaySuggestionIfAligned(
                    validated,
                    question: localQuestion,
                    generationID: generationID,
                    triggerPath: triggerPath,
                    source: telemetrySource,
                    speaker: telemetrySpeaker
                ) else { return }
                self.currentSuggestionSetAt = self.currentSuggestionSetAt ?? Date()
                self.isExpandingSuggestionCard = true
                self.markFirstVisibleAnswer(generationID: generationID, fallback: false)
                self.setGenerationUIState(.expandingFullAnswer(questionID: localQuestion.id, generationID: generationID, triggerPath: triggerPath), generationID: generationID)
                self.infoAction(ActionID.generateAnswer, title: "First answer visible", message: "Expanding the full answer and key points.", autoDismissAfter: 3.0)
                if self.finishVisibleFirstAnswerForQueuedQuestionIfNeeded(
                    generationID: generationID,
                    question: localQuestion,
                    session: localSession,
                    requestStart: requestStart,
                    triggerPath: triggerPath
                ) {
                    return
                }
            }
        } catch {
            guard !Task.isCancelled, self.currentGenerationID == generationID else {
                recordStaleGenerationDiscard(attributedTo: generationContext.identity)
                return
            }
            guard !self.generationUIState.isTerminal else {
                return
            }
            guard publishStageAExit(failure: error) else { return }

            @MainActor func ownsRecoveryPresentation(_ identity: GenerationIdentity) -> Bool {
                self.generationCoordinator.isCurrent(identity) &&
                    self.currentSession?.id == identity.sessionID &&
                    self.currentSession?.contextSnapshotID == identity.contextSnapshotID
            }
            let recoveryHandled = await self.generationCoordinator.recoverConfiguredProviderBeforeFirstToken(
                context: generationContext, expectedExpansion: configuredExpansion,
                firstTokenObserved: { [weak self] identity in
                    guard let self, ownsRecoveryPresentation(identity) else { return nil }
                    return self.streamFirstTokenAt != nil
                },
                onStarted: { [weak self] identity in
                    guard let self, ownsRecoveryPresentation(identity) else { return false }
                    self.markProviderOperation("Local Qwen fallback generation started")
                    return ownsRecoveryPresentation(identity)
                },
                recover: { [weak self] identity in
                    guard let self, ownsRecoveryPresentation(identity) else { return false }
                    return try await self.finishWithLocalQwenAnswer(
                        question: localQuestion, session: localSession,
                        transcript: localTranscript, context: optimizedContext,
                        retrievedChunks: generationRetrievedChunks, cvSummary: cvSummary, jdSummary: jdSummary,
                        generationID: generationID, cardID: cardID, requestStart: requestStart,
                        triggerPath: triggerPath, source: telemetrySource, speaker: telemetrySpeaker,
                        localProvider: localAnswerProvider, modelName: localModelName,
                        fallbackReason: "deepseek_failed_before_first_token",
                        interviewContextSnapshot: generationSnapshot)
                },
                onRecovered: { [weak self] identity in
                    guard let self, ownsRecoveryPresentation(identity) else { return }
                    self.warnAction(ActionID.generateAnswer, title: "Local Qwen fallback used",
                        message: "DeepSeek did not produce a first token. The local Qwen answer is visible.",
                        whileCurrent: { ownsRecoveryPresentation(identity) })
                },
                onFailure: { [weak self] identity, failure in
                    guard let self, ownsRecoveryPresentation(identity),
                          self.generationCoordinator.canPublish(identity), !Task.isCancelled else { return }
                    self.currentGenerationTelemetry.providerError = failure.localizedDescription
                    guard ownsRecoveryPresentation(identity) else { return }
                    print("[LocalQwen] Fallback failed: code=\((failure as NSError).code)")
                })
            if recoveryHandled { return }

            if self.preserveStageAAnswerWhileExpansionContinues(
                    context: generationContext, cardID: cardID,
                    answerProviderConfiguration: answerProviderConfiguration,
                    fallbackProviderModel: firstAnswerProviderRequest.model,
                    generationRetrievedChunks: generationRetrievedChunks
                ) {
                return
            }
            guard self.generationCoordinator.canPublish(generationContext.identity),
                  !Task.isCancelled else { return }
            self.markGenerationFailed(
                generationID: generationID,
                reason: error.localizedDescription,
                providerError: error.localizedDescription,
                timeout: (error as NSError).domain == "TimeoutDomain"
            )
            guard self.ownsCurrentGenerationPresentation(generationContext.identity, requestID: requestID) else { return }
            self.failAction(ActionID.generateAnswer, title: "Generation failed", message: "Transcript preserved. \(self.userFacing(error))")
        }
    }


    @MainActor
    func injectVerificationMockData(enabled: Bool? = nil) {
        let enabled = enabled ?? (ProcessInfo.processInfo.environment["ENABLE_VERIFICATION_MOCKS"] == "1")
        guard enabled else { return }
        
        let cvChunks = [
            RetrievedChunk(
                id: "cv-chunk-1",
                documentID: "doc-cv-1",
                documentType: .cv,
                chunkIndex: 0,
                contentPreview: "Led development of a distributed service reliability project...",
                fullContent: "Led development of a distributed service reliability project using Kotlin and PostgreSQL. Reduced API latency through measured query and cache changes.",
                keywords: ["Kotlin", "PostgreSQL", "API", "reliability", "latency"],
                score: 8.5,
                keywordOverlapCount: 3,
                contentOverlapCount: 5,
                rank: 1,
                isIncludedInPrompt: true,
                sectionTitle: "PLATFORM PROJECT",
                wordCount: 22
            ),
            RetrievedChunk(
                id: "cv-chunk-2",
                documentID: "doc-cv-1",
                documentType: .cv,
                chunkIndex: 1,
                contentPreview: "Implemented event processing and operational recovery for a service...",
                fullContent: "Implemented event processing and operational recovery for a backend service using Kafka. Tested retries, idempotency, and failure handling.",
                keywords: ["Kafka", "event processing", "retries", "idempotency"],
                score: 6.0,
                keywordOverlapCount: 2,
                contentOverlapCount: 3,
                rank: 2,
                isIncludedInPrompt: true,
                sectionTitle: "PLATFORM PROJECT",
                wordCount: 20
            ),
            RetrievedChunk(
                id: "cv-chunk-3",
                documentID: "doc-cv-1",
                documentType: .cv,
                chunkIndex: 2,
                contentPreview: "Documented internal reporting workflows and operational handoffs...",
                fullContent: "Documented internal reporting workflows and operational handoffs for a cross-functional project.",
                keywords: ["documentation", "workflow", "handoff"],
                score: 1.5,
                keywordOverlapCount: 0,
                contentOverlapCount: 1,
                rank: 3,
                isIncludedInPrompt: false,
                sectionTitle: "OPERATIONS",
                wordCount: 18
            )
        ]
        
        let jdChunks = [
            RetrievedChunk(
                id: "jd-chunk-1",
                documentID: "doc-jd-1",
                documentType: .jobDescription,
                chunkIndex: 0,
                contentPreview: "We are seeking a Backend Engineer experienced in reliable distributed services...",
                fullContent: "We are seeking a Backend Engineer experienced in distributed systems, API performance, and production operations.",
                keywords: ["Backend Engineer", "distributed systems", "API", "operations"],
                score: 9.0,
                keywordOverlapCount: 4,
                contentOverlapCount: 6,
                rank: 1,
                isIncludedInPrompt: true,
                sectionTitle: "ROLE OVERVIEW",
                wordCount: 23
            )
        ]
        
        let trace = RetrievalTrace(
            id: UUID(),
            query: "Could you walk me through your most relevant platform project?",
            intent: "technical",
            createdAt: Date(),
            rankedCVChunks: cvChunks,
            rankedJDChunks: jdChunks,
            includedCVChunks: [cvChunks[0], cvChunks[1]],
            includedJDChunks: [jdChunks[0]],
            excludedCVChunks: [cvChunks[2]],
            excludedJDChunks: [],
            cvWordsUsed: 42,
            jdWordsUsed: 23,
            cvWordBudget: 350,
            jdWordBudget: 350,
            retrievalLatencyMS: 12.45,
            emptyQueryFallbackUsed: false,
            zeroScoreFallbackUsed: false
        )
        
        self.lastRetrievalTrace = trace
        
        var mockCard = SuggestionCard(
            id: "mock-suggestion-card-id",
            sessionID: "mock-session-id",
            questionID: nil,
            strategy: "Project Walkthrough",
            sayFirst: "My most relevant platform project improved a distributed API by isolating latency bottlenecks, changing the data path, and validating reliability under failure.",
            keyPoints: [
                "Measured the API bottleneck before changing the design.",
                "Redesigned the distributed data path.",
                "Validated latency and failure recovery."
            ],
            followUpReady: [
                "How did you isolate the latency bottleneck?",
                "How did you validate failure recovery?"
            ],
            confidence: 0.95,
            caution: "Keep ownership and measured outcomes tied to the fixture evidence.",
            evidenceUsed: [
                "Distributed API latency investigation",
                "Kafka retry and idempotency validation"
            ],
            riskLevel: .low,
            modelName: "deepseek-v4-flash",
            promptVersion: "v1.0",
            providerKind: .deepSeek,
            providerName: "DeepSeek",
            providerBaseURL: "https://api.deepseek.com",
            latencyMS: 1250,
            isLocal: false,
            rawJSON: nil,
            createdAt: Date()
        )
        
        let mockQuestion = DetectedQuestion(
            id: "mock-question-id",
            sessionID: "mock-session-id",
            transcriptSegmentID: "mock-segment-id",
            questionText: "Could you walk me through your most relevant platform project?",
            intent: .technical,
            answerStrategy: .projectWalkthrough,
            confidence: 0.95,
            reason: "Verifying relevant project experience",
            shouldTrigger: true,
            questionComplete: true,
            modelName: "deepseek-v4-flash",
            promptVersion: "v1.0",
            providerKind: .deepSeek,
            providerName: "DeepSeek",
            providerBaseURL: "https://api.deepseek.com",
            latencyMS: 1250,
            isLocal: false,
            rawJSON: nil,
            createdAt: Date()
        )
        self.lastDetectedQuestion = mockQuestion
        self.lastDetectedQuestionText = mockQuestion.questionText
        self.currentSuggestionRetrievedChunks = cvChunks.filter { $0.isIncludedInPrompt } + jdChunks.filter { $0.isIncludedInPrompt }
        self.manualCaptureSuggestion = self.currentSuggestion
        self.manualCaptureState = .suggestionReady
        
        do {
            try? self.sessionRepository.deleteSession(id: "mock-session-id")
            
            let mockSession = InterviewSession(
                id: "mock-session-id",
                title: "Mock Interview - Backend",
                company: "Example Company",
                role: "Backend Engineer",
                startedAt: Date().addingTimeInterval(-3600),
                endedAt: Date(),
                mode: .mock,
                createdAt: Date()
            )
            
            try self.database.dbQueue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO interview_sessions (id, title, company, role, started_at, ended_at, mode, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        mockSession.id,
                        mockSession.title,
                        mockSession.company,
                        mockSession.role,
                        DateCoding.string(from: mockSession.startedAt),
                        mockSession.endedAt.map(DateCoding.string),
                        mockSession.mode.rawValue,
                        DateCoding.string(from: mockSession.createdAt)
                    ]
                )
            }
            // Verification fixtures use the same evidence gate as real cards.
            // Synthetic source facts are scoped to this explicit mock mode.
            let profile = try interviewContextRepository.upsertCandidateDocument(documentID: "verification-synthetic-cv", title: "Synthetic verification candidate", content: cvChunks.map(\.fullContent).joined(separator: "\n"), profileID: nil, persistedChunks: [])
            let snapshot = try interviewContextRepository.createSnapshot(sessionID: mockSession.id, candidateProfileID: profile.id, opportunityContextID: nil, domainProfileID: InterviewDomainID.softwareEngineering.rawValue)
            try sessionRepository.attachContextSnapshot(sessionID: mockSession.id, snapshotID: snapshot.id)
            mockCard.contextSnapshotID = snapshot.id
        _ = displaySuggestionIfAligned(
            mockCard,
            question: mockQuestion,
            generationID: nil,
            triggerPath: .manualGenerate,
            source: .mock,
            speaker: .interviewer,
            allowInactiveGeneration: true
        )
            self.manualCaptureSuggestion = self.currentSuggestion
            self.sessions = try self.sessionRepository.listSessions()
            
            let mockSegment = TranscriptSegment(
                id: "mock-segment-id",
                sessionID: "mock-session-id",
                source: .mock,
                speaker: .interviewer,
                text: "Could you walk me through your most relevant platform project?",
                startTime: 0,
                endTime: 5,
                createdAt: Date()
            )
            try self.transcriptRepository.saveSegment(mockSegment)
            try self.suggestionRepository.saveSuggestionCard(mockCard, retrievedChunks: cvChunks + jdChunks)
            
            if defaultAppSectionOverride == .sessions ||
                ProcessInfo.processInfo.environment["DEFAULT_APP_SECTION"] == "sessions" {
                self.selectedSessionID = "mock-session-id"
                loadSessionDetails(sessionID: "mock-session-id")
            } else if ProcessInfo.processInfo.environment["DEFAULT_APP_SECTION"] == "floating" {
                self.showFloatingAssistant()
            }
        } catch {
            print("Failed to save mock database elements: code=\((error as NSError).code)")
        }
    }

}
