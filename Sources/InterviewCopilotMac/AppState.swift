// Central MainActor state container for the macOS interview workflow.
// AppState owns UI-observable state and coordinates repositories/services, but
// feature-specific behavior should live in focused AppState extensions.
// Invariants: UI mutation stays on MainActor, capture/generation IDs bind async
// callbacks to the current question, and technical diagnostics must not become
// the default product flow.

import AppKit
import AVFoundation
import Combine
import Foundation
import SwiftUI

/// MainActor source of truth for live interview UI, capture state, detected
/// questions, generation state, provider settings, and diagnostics.
///
/// AppState deliberately keeps observable UI mutation centralized while the
/// modular extensions own domain-specific workflows. Async callbacks must check
/// the active generation/question identity before changing visible answer state.
@MainActor
final class AppState: ObservableObject {
    @Published var selectedSection: AppSection = .home
    @Published var settings: AppSettings = .default
    @Published var documents: [DocumentRecord] = []
    @Published var sessions: [InterviewSession] = []
    @Published var providerConfigurations: [LLMProviderConfiguration] = []
    @Published var activeRealtimeProvider: LLMProviderConfiguration?
    @Published var activeRecapProvider: LLMProviderConfiguration?
    @Published var providerConnectionResults: [UUID: String] = [:]
    @Published var selectedSessionID: String?
    @Published var selectedSessionTranscript: [TranscriptSegment] = []
    @Published var selectedSessionSuggestions: [SuggestionCard] = []
    @Published var selectedSessionRecap: RecapReport?
    @Published var hasCV = false
    @Published var hasJD = false
    @Published var hasAPIKey = false
    @Published var liveState: LiveInterviewState = .idle {
        didSet { updateDiagnostics { $0.liveState = liveState } }
    }
    @Published var currentSession: InterviewSession?
    @Published var transcriptSegments: [TranscriptSegment] = []
    @Published var currentSuggestion: SuggestionCard?
    @Published var lastDetectedQuestion: DetectedQuestion?
    @Published var possibleQuestion: DetectedQuestion?
    @Published var lastTranscriptSnippet: String = ""
    @Published var isFloatingAssistantVisible = false
    @Published var errorMessage: String?
    @Published var activeActionFeedbacks: [ActionFeedback] = []
    @Published var actionLoadingStates: [String: Bool] = [:]
    
    @Published var lastQuestionDetectionProvider: String? = nil
    @Published var lastQuestionDetectionModel: String? = nil
    @Published var lastSuggestionGenerationProvider: String? = nil
    @Published var lastSuggestionGenerationModel: String? = nil
    @Published var lastProviderSwitchTimestamp: Date? = nil
    @Published var lastProviderSwitchError: String? = nil
    @Published var cloudWarningAcceptedThisSession: Bool = false
    
    public enum FailedAITaskType: String, Codable {
        case questionDetection
        case suggestionGeneration
    }
    @Published public var lastFailedTaskType: FailedAITaskType? = nil
    @Published public var lastFailedQuestion: DetectedQuestion? = nil
    @Published public var lastFailedTranscriptContext: String = ""
    @Published public var lastFailedCVJDContext: RetrievedContext? = nil
    @Published public var lastFailedProviderConfig: LLMProviderConfiguration? = nil

    @Published var connectionResult: String?
    @Published var isTestingConnection = false
    @Published var isGeneratingRecap = false
    @Published var permissionSnapshot = PermissionSnapshot(
        microphone: .unknown,
        speechRecognition: .unknown,
        screenRecording: .unknown,
        systemAudioCapture: .notDetermined
    )
    @Published var microphonePermissionState: MicrophonePermissionState = .unknown
    @Published public var systemAudioPermissionState: ScreenSystemAudioPermissionState = .permissionMissing
    @Published public var systemAudioProbeResult: ScreenSystemAudioPermissionProbeResult? = nil
    @Published var diagnostics = DeveloperDiagnostics.empty
    @Published var lastRetrievalTrace: RetrievalTrace?
    @Published var currentSuggestionRetrievedChunks: [RetrievedChunk] = []
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
    @Published var embeddingCoverage: EmbeddingCoverage? = nil
    @Published var rebuildProgress: Double = 0.0
    @Published var isRebuildingEmbeddings: Bool = false
    @Published var lastEmbeddingTestStatus: String = "Not tested"
    @Published var lastEmbeddingError: String?
    // internal for AppState extension access only
    var activeEmbeddingRebuildTask: Task<Void, Never>? = nil
    // internal for AppState extension access only
    var actionFeedbackDismissTasks: [String: Task<Void, Never>] = [:]
    @Published var historicalSuggestionChunks: [String: [RetrievedChunk]] = [:]

    // MARK: - Manual Capture Push-to-Ask state
    @Published public var interviewCopilotMode: InterviewCopilotMode = .autoDetect {
        didSet {
            if interviewCopilotMode == .manualCapture {
                stopAllContinuousPipelines(reason: .userRequested)
            }
        }
    }
    @Published public var manualCaptureState: ManualCaptureState = .idle
    @Published public var manualCaptureTranscript: String = ""
    @Published public var manualCaptureSuggestion: SuggestionCard? = nil
    @Published public var manualCaptureDuration: Double = 0.0
    @Published public var manualCaptureLevel: Double = 0.0
    @Published public var manualCaptureError: String? = nil
    @Published public var manualCaptureBufferCount: Int = 0
    @Published public var manualCaptureLastBufferTimestamp: Date? = nil
    @Published public var manualCaptureSource: String = ""

    @Published var currentInputDeviceName: String = "Default Input"
    @Published var selectedMockSpeaker: SpeakerRole = .interviewer {
        didSet {
            mockTranscriptionService.selectedMockSpeaker = selectedMockSpeaker
        }
    }
    @Published var isRecoveringAudioRoute: Bool = false
    @Published var audioRouteError: String?
    @Published var lastAudioBufferAt: Date?
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

    // --- System Audio ASR Diagnostics ---
    @Published public var systemASRTaskRunning: Bool = false
    @Published public var totalSystemAudioASRBuffersAppended: Int = 0
    @Published public var lastSystemAudioASRPartialTranscript: String = ""
    @Published public var lastSystemAudioASRFinalTranscript: String = ""
    @Published public var lastSystemTranscript: String = ""
    @Published public var recognitionRequestActive: Bool = false
    @Published public var recognitionTaskActive: Bool = false

    // --- Pipeline Helper Diagnostics ---
    var captureMode: AudioCaptureMode { settings.audioCaptureMode }
    public var isListening: Bool {
        liveState == .listening || liveState == .transcribing || liveState == .generatingSuggestion || liveState == .detectingQuestion
    }
    var isAudioEngineRunning: Bool { AudioEngineManager.shared.isEngineRunning }
    var isMicPipelineActive: Bool { appleSpeechService?.microphoneSession != nil }
    var isMicASRTaskActive: Bool { appleSpeechService?.microphoneSession?.recognitionTask != nil }
    var isSystemAudioASRActive: Bool { appleSpeechService?.systemAudioSession?.recognitionTask != nil }

    // --- Dual Stream Diagnostics ---
    var micCaptureRunning: Bool {
        isMicPipelineActive || microphoneDiagnostics.isRunning
    }
    var micBufferCount: Int { appleSpeechService?.microphoneSession?.totalBuffersAppended ?? 0 }
    var micLastBufferTimestamp: Date? { appleSpeechService?.microphoneSession?.lastBufferReceivedAt }
    var micLevelDBFS: Double { microphoneDiagnostics.decibels }
    var micASRRequestActive: Bool { appleSpeechService?.microphoneSession?.request != nil }
    var micASRTaskActive: Bool { appleSpeechService?.microphoneSession?.recognitionTask != nil }
    var micLastPartialTranscript: String { appleSpeechService?.microphoneSession?.partialTranscriptBuffer ?? "" }
    var micLastFinalTranscript: Date? { appleSpeechService?.microphoneSession?.lastFinalTranscriptTimestamp }
    var micLastError: String? { appleSpeechService?.microphoneSession?.lastError?.localizedDescription }
    var micSessionID: String { appleSpeechService?.microphoneSession?.sessionID.source.rawValue ?? "None" }
    
    // ASR quality diagnostics for Microphone
    var micLastPartialTranscriptQuality: String { appleSpeechService?.microphoneSession?.lastPartialTranscript ?? "" }
    var micLastFinalTranscriptQuality: String { appleSpeechService?.microphoneSession?.lastFinalTranscript ?? "" }
    var micBestTranscriptUsed: String { appleSpeechService?.microphoneSession?.bestTranscriptUsed ?? "" }
    var micFinalizationReason: String { appleSpeechService?.microphoneSession?.finalizationReason ?? "" }

    // --- Capture Runtime State Lifecycle ---
    @Published public var currentCaptureRuntimeState: CaptureRuntimeState = .idle
    @Published public var stopReason: StopReason? = nil
    @Published public var lastCaptureStartedAt: Date? = nil
    @Published public var lastCaptureStoppedAt: Date? = nil
    
    public var lastSystemAudioBufferAt: Date? { ScreenCaptureKitSystemAudioCaptureService.shared.lastBufferReceivedAt }
    public var lastSystemAudioError: String? { ScreenCaptureKitSystemAudioCaptureService.shared.lastError }
    
    public struct CaptureEvent: Identifiable, Codable, Hashable {
        public let id: String
        public let timestamp: Date
        public let eventName: String
        public let stateBefore: String
        public let stateAfter: String
        public let reason: String
        public let file: String
        public let function: String
        public let line: Int
        public let systemCaptureRunning: Bool
        public let micCaptureRunning: Bool
        public let lastSystemAudioBufferAt: Date?
    }
    
    @Published public var recent20CaptureEvents: [CaptureEvent] = []
    
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
        anyCaptureRunning || currentCaptureRuntimeState == .starting || currentCaptureRuntimeState == .listening || currentCaptureRuntimeState == .generating
    }

    public var systemCaptureRunning: Bool { ScreenCaptureKitSystemAudioCaptureService.shared.isCapturing }
    var systemBufferCount: Int { appleSpeechService?.systemAudioSession?.totalBuffersAppended ?? 0 }
    var systemLastBufferTimestamp: Date? { appleSpeechService?.systemAudioSession?.lastBufferReceivedAt }
    var systemLevelDBFS: Double { ScreenCaptureKitSystemAudioCaptureService.shared.decibels }
    var systemASRRequestActive: Bool { appleSpeechService?.systemAudioSession?.request != nil }
    var systemASRTaskActive: Bool { appleSpeechService?.systemAudioSession?.recognitionTask != nil }
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
    var streamNotRunningReason: String? {
        let captureMode = settings.audioCaptureMode
        if captureMode == .microphoneOnly && systemAudioRequired {
            return "System audio not running: Capture Mode is Microphone Only"
        }
        if captureMode == .systemAudioOnly && microphoneRequired {
            return "Microphone not running: Capture Mode is System Audio Only"
        }
        if microphoneRequired && microphonePermissionState != .authorized {
            return "Microphone not running: Permission denied"
        }
        if systemAudioRequired && systemAudioPermissionState != .granted {
            return "System audio not running: Permission denied"
        }
        return nil
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
    }
    @Published public var last10SegmentsDiagnostics: [SegmentAttributionDiagnostic] = []

    // --- Question Detection Diagnostics ---
    @Published public var lastDetectionSubmittedSegmentText: String = ""
    @Published public var lastDetectionPromptSource: String = ""
    @Published public var lastDetectionPromptSpeaker: String = ""
    @Published public var lastDetectionQuestionComplete: Bool = false
    @Published public var lastDetectionAnswerStrategy: String = ""

    // --- Suggestion Diagnostics ---
    @Published public var suggestionGenerationStarted: Bool = false
    @Published public var suggestionProviderModel: String = ""
    @Published public var lastSuggestionCardJSON: String = ""
    @Published public var floatingPanelUpdated: Bool = false
    @Published public var generationUIState: GenerationUIState = .idle
    @Published public var currentGenerationTelemetry: GenerationTelemetry = .idle
    @Published public var mainThreadHeartbeatAt: Date? = nil
    @Published public var mainThreadHeartbeatDelayMs: Int = 0
    @Published public var lastGenerationStateChangeAt: Date? = nil
    @Published public var activeTaskSummary: String = "Idle"
    @Published public var lastLongOperationName: String = "None"
    @Published public var lastLongOperationStartedAt: Date? = nil
    @Published public var lastSQLiteOperation: String = "None"
    @Published public var lastRAGOperation: String = "None"
    @Published public var lastProviderOperation: String = "None"

    // --- Pipeline Latency Metrics ---
    @Published public var ragRetrievalLatencyMS: Int? = nil
    @Published public var asrFirstPartialMS: Int? = nil
    @Published public var asrFinalMS: Int? = nil
    @Published public var asrBestSelectedMS: Int? = nil
    
    // Floating render timestamps (lightweight, no SwiftUI render measurement)
    @Published public var firstVisibleStateSetAt: Date? = nil
    @Published public var currentSuggestionSetAt: Date? = nil
    @Published public var streamedSayFirstSetAt: Date? = nil

    // Historical latency averages (cached, refreshed after each suggestion)
    @Published public var latencyAveragesOverall: LatencyAverages = .empty
    @Published public var latencyAveragesDeepSeek: LatencyAverages = .empty


    // --- Streaming & Provenance ---
    @Published public var isStreamingSayFirst: Bool = false
    @Published public var streamedSayFirst: String = ""
    @Published public var isExpandingSuggestionCard: Bool = false
    
    @Published public var streamRequestStartAt: Date? = nil
    @Published public var streamFirstTokenAt: Date? = nil
    @Published public var streamFirstVisibleTextAt: Date? = nil
    @Published public var streamFirstSentenceAt: Date? = nil
    @Published public var streamFullResponseAt: Date? = nil
    @Published public var streamJSONParsedAt: Date? = nil
    @Published public var streamPersistedAt: Date? = nil
    
    // Delay Provider for mock time unit testing
    public var delayProvider: DelayProvider = RealDelayProvider()
    public var generationFullCardWatchdogNanoseconds: UInt64 = 8_000_000_000
    var stageATimeoutSeconds: TimeInterval = 6.0
    var lateDeepSeekReplacementWindowSeconds: TimeInterval = 6.0

    // Soft Fallback & Advanced Provenance
    @Published public var softFallbackUsed: Bool = false
    @Published public var softFallbackLatencyMS: Int? = nil
    @Published public var softFallbackShownAt: Date? = nil
    @Published public var deepseekFirstTokenMS: Int? = nil
    @Published public var deepseekFirstVisibleMS: Int? = nil
    @Published public var finalVisibleSource: String? = nil
    @Published public var currentGenerationID: String? = nil
    // internal for AppState extension access only
    @Published public internal(set) var activeGenerationID: String? = nil
    // internal for AppState extension access only
    @Published public internal(set) var activeQuestionID: String? = nil
    // internal for AppState extension access only
    @Published public internal(set) var activeTriggerPath: GenerationTriggerPath? = nil
    // internal for AppState extension access only
    @Published public internal(set) var activeGenerationStartedAt: Date? = nil
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
    @Published public internal(set) var fallbackWatchdogActive: Bool = false
    // internal for AppState extension access only
    @Published public internal(set) var stageBTaskActive: Bool = false
    // internal for AppState extension access only
    @Published public internal(set) var providerStreamActive: Bool = false
    @Published public var userInteractedWithCard: Bool = false
    
    // Keychain Diagnostics properties
    @Published public var keychainServiceName: String = KeychainConstants.service
    @Published public var keychainDeepSeekAccount: String = KeychainConstants.deepSeekAccount
    @Published public var keychainDeepSeekKeyExists: Bool = false
    @Published public var keychainMaskedKey: String = "None"
    @Published public var keychainLastReadStatus: String = "Not Checked"
    @Published public var keychainLastWriteStatus: String = "Not Checked"
    @Published public var keychainMigrationPerformed: Bool = false
    @Published public var keychainLegacyItemFound: Bool = false
    @Published public var keychainLegacyItemCount: Int = 0
    @Published public var keychainMismatchStatus: String = "No key found"
    @Published public var keychainAuthorizationWarning: String? = nil
    
    // Stage B lifecycle task reference for cost control / cancellation
    // internal for AppState extension access only
    var stageBTask: Task<Void, Never>? = nil
    // internal for AppState extension access only
    var softFallbackTask: Task<Void, Never>? = nil
    // internal for AppState extension access only
    var fullCardWatchdogTask: Task<Void, Never>? = nil
    public var simulateSuggestionPersistenceFailure: Bool = false
    public var simulatedSuggestionPersistenceDelayNanoseconds: UInt64 = 0

    // internal for AppState extension access only
    /// Tracks the single generation attempt that is allowed to control the
    /// current answer UI.
    ///
    /// When a newer interviewer question is accepted, all tasks in this
    /// controller are cancelled and late callbacks must be treated as stale.
    struct ActiveGenerationController {
        let generationID: String
        let questionID: String?
        let questionTextSnapshot: String
        let questionIntent: AnswerRelevanceIntent
        let triggerPath: GenerationTriggerPath
        let startedAt: Date
        var stageATask: Task<String, Error>?
        var stageBTask: Task<Void, Never>?
        var fallbackWatchdogTask: Task<Void, Never>?
        var fullCardWatchdogTask: Task<Void, Never>?

        mutating func cancelAll() {
            stageATask?.cancel()
            stageATask = nil
            stageBTask?.cancel()
            stageBTask = nil
            fallbackWatchdogTask?.cancel()
            fallbackWatchdogTask = nil
            fullCardWatchdogTask?.cancel()
            fullCardWatchdogTask = nil
        }
    }

    // internal for AppState extension access only
    var activeGenerationController: ActiveGenerationController?
    // internal for AppState extension access only
    var pendingIgnoredSystemAudioFallback: (questionID: String, reason: String)?
    // internal for AppState extension access only
    var mainThreadHeartbeatTask: Task<Void, Never>?
    // internal for AppState extension access only
    var lastHeartbeatTickAt: Date?
    
    // Background RAG precompute cache and debounce
    // internal for AppState extension access only
    struct RAGPrecomputeCacheItem {
        let context: RetrievedContext
        let trace: RetrievalTrace
        let rawText: String
        let normalizedQuestionText: String
        let questionIntent: AnswerRelevanceIntent
    }
    // internal for AppState extension access only
    var precomputedRAGCache: [String: RAGPrecomputeCacheItem] = [:]
    // internal for AppState extension access only
    var precomputeDebounceTask: Task<Void, Never>? = nil

    let database: AppDatabase
    let documentRepository: DocumentRepository
    let sessionRepository: SessionRepository
    let transcriptRepository: TranscriptRepository
    let suggestionRepository: SuggestionRepository
    let recapRepository: RecapRepository
    let settingsRepository: SettingsRepository
    let keychainService: KeychainService
    let permissionService: PermissionService
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
    let recapGenerationService: RecapGenerationService
    // internal for AppState extension access only
    var appleSpeechService: AppleSpeechTranscriptionService?
    // internal for AppState extension access only
    var activeTranscriptionProvider: TranscriptionProvider?
    // internal for AppState extension access only
    var ownsSystemAudioCaptureRuntime = false
    // internal for AppState extension access only
    var transcriptionTask: Task<Void, Never>?
    
    // internal for AppState extension access only
    struct RecentSystemAudioRecord {
        let text: String
        let timestamp: Date
    }
    // internal for AppState extension access only
    var recentSystemAudioRecords: [RecentSystemAudioRecord] = []
    // internal for AppState extension access only
    var detectionDebounceTask: Task<Void, Never>?
    // internal for AppState extension access only
    var activeDetectionTask: Task<Void, Never>?
    // internal for AppState extension access only
    var activeAITask: Task<Void, Never>?
    // internal for AppState extension access only
    var lastDetectionAt: Date?
    // internal for AppState extension access only
    var lastAutoSuggestionAt: Date?
    // internal for AppState extension access only
    var lastAutoQuestionText: String?
    // internal for AppState extension access only
    var recentQuestionTimestamps = [String: Date]()
    // internal for AppState extension access only
    let autoQuestionDuplicateCooldownSeconds: TimeInterval = 60

    private var activeObserverToken: NSObjectProtocol?
    private let verificationMocksEnabledOverride: Bool?
    private let defaultAppSectionOverride: AppSection?
    // internal for AppState extension access only
    var recentQuestionsFingerprints = [String]()
    private var cancellables = Set<AnyCancellable>()
    // internal for AppState extension access only
    var audioSignalMonitoringTimer: Timer?

    var detectionDebounceSeconds: TimeInterval = 2
    // internal for AppState extension access only
    let autoSuggestionCooldownSeconds: TimeInterval = 5
    // internal for AppState extension access only
    let autoSuggestionConfidenceThreshold = 0.75
    // internal for AppState extension access only
    let possibleQuestionConfidenceRange = 0.55..<0.75

    static func bootstrap() -> AppState {
        do {
            let database = try AppDatabase()
            let state = AppState(database: database)
            state.startMainThreadHeartbeat()
            return state
        } catch {
            let fallbackURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("InterviewCopilotMac-\(UUID().uuidString).sqlite")
            let fallback = (try? AppDatabase(path: fallbackURL)) ?? (try? AppDatabase(inMemory: true))
            guard let fallback else {
                preconditionFailure("Unable to initialize SQLite or in-memory database.")
            }
            let state = AppState(database: fallback)
            state.startMainThreadHeartbeat()
            state.showError("Could not open the application database at the normal path. Using a temporary database for this run. \(error.localizedDescription)")
            return state
        }
    }

    init(
        database: AppDatabase,
        llmRouter: LLMRouter? = nil,
        permissionService: PermissionService? = nil,
        keychainService: KeychainService = KeychainService(),
        contextRetrievalService: ContextRetrievalService? = nil,
        verificationMocksEnabled: Bool? = nil,
        defaultAppSection: AppSection? = nil
    ) {
        let documents = DocumentRepository(database: database)
        let sessions = SessionRepository(database: database)
        let transcripts = TranscriptRepository(database: database)
        let suggestions = SuggestionRepository(database: database)
        let recaps = RecapRepository(database: database)
        let settings = SettingsRepository(database: database)
        let keychain = keychainService
        keychain.performMigrationIfNeeded()
        let router = llmRouter ?? LLMRouter(settingsRepository: settings, apiKeyStore: keychain)


        self.database = database
        self.documentRepository = documents
        self.sessionRepository = sessions
        self.transcriptRepository = transcripts
        self.suggestionRepository = suggestions
        self.recapRepository = recaps
        self.settingsRepository = settings
        self.keychainService = keychain
        self.permissionService = permissionService ?? PermissionService()
        self.verificationMocksEnabledOverride = verificationMocksEnabled
        self.defaultAppSectionOverride = defaultAppSection
        self.microphoneDiagnostics = MicrophoneDiagnosticsService()
        self.mockTranscriptionService = MockTranscriptionService()
        self.localDataService = LocalDataService(
            documents: documents,
            sessions: sessions,
            transcripts: transcripts,
            suggestions: suggestions,
            recaps: recaps,
            settings: settings,
            keychainService: keychain
        )
        self.llmRouter = router
        let suggestionService = SuggestionGenerationService(llmRouter: router)
        self.questionDetectionService = QuestionDetectionService(llmRouter: router)
        self.suggestionGenerationService = suggestionService
        self.generationCoordinator = GenerationCoordinator(
            dependencies: GenerationCoordinator.Dependencies(
                suggestionGenerationService: suggestionService
            )
        )
        self.recapGenerationService = RecapGenerationService(llmRouter: router)
        
        self.contextRetrievalService = contextRetrievalService ?? HybridContextRetrievalService(
            documentRepository: documents,
            settingsProvider: { [weak self] in self?.settings ?? AppSettings.default },
            embeddingProviderResolver: { [weak self] in self?.resolveEmbeddingProvider() }
        )
        
        // Initialize notifications and refresh permissions on startup and when application didBecomeActive
        refreshAll()

        AudioDeviceRouteMonitor.shared.$currentInputDeviceName
            .receive(on: DispatchQueue.main)
            .sink { [weak self] name in
                self?.currentInputDeviceName = name
            }
            .store(in: &cancellables)

        AudioDeviceRouteMonitor.shared.$isRecoveringAudioRoute
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecovering in
                guard let self else { return }
                self.isRecoveringAudioRoute = isRecovering
                if isRecovering {
                    self.audioRouteError = "Audio device changed. Reconnecting..."
                    self.noAudioWarningVisible = true
                    self.microphoneDiagnostics.markAsRecovering()
                } else {
                    let state = AudioEngineManager.shared.audioRecoveryState
                    if state == "Active" {
                        self.audioRouteError = "Audio input restored."
                        self.noAudioWarningVisible = false
                    } else if state == "Failed" {
                        self.audioRouteError = "Could not restore audio input. Try Stop Listening and Start Listening again."
                        self.noAudioWarningVisible = true
                    }
                }
            }
            .store(in: &cancellables)

        ScreenCaptureKitSystemAudioCaptureService.shared.$isCapturing
            .receive(on: DispatchQueue.main)
            .sink { [weak self] capturing in
                guard let self = self else { return }
                self.objectWillChange.send()
                // Propagate capture stream end only for the AppState that actually
                // started the shared ScreenCaptureKit system-audio runtime.
                let ownsActiveCapture = self.ownsSystemAudioCaptureRuntime
                if !capturing,
                   ownsActiveCapture,
                   (self.currentCaptureRuntimeState == .listening || self.currentCaptureRuntimeState == .generating) {
                    if self.stopReason == nil {
                        self.stopListening(reason: .screenCaptureStreamEnded)
                    }
                }
            }
            .store(in: &cancellables)

        ScreenCaptureKitSystemAudioCaptureService.shared.$lastBufferReceivedAt
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        ScreenCaptureKitSystemAudioCaptureService.shared.$lastError
            .receive(on: DispatchQueue.main)
            .sink { [weak self] err in
                guard let self = self else { return }
                self.objectWillChange.send()
                if let err = err {
                    self.currentCaptureRuntimeState = .error(reason: err)
                }
            }
            .store(in: &cancellables)

        ManualQuestionCaptureService.shared.$recordingDuration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] duration in
                self?.manualCaptureDuration = duration
            }
            .store(in: &cancellables)

        ManualQuestionCaptureService.shared.$decibels
            .receive(on: DispatchQueue.main)
            .sink { [weak self] db in
                self?.manualCaptureLevel = min(max((db + 60) / 60, 0), 1)
            }
            .store(in: &cancellables)

        ManualQuestionCaptureService.shared.$capturedBufferCount
            .receive(on: DispatchQueue.main)
            .sink { [weak self] count in
                if self?.manualCaptureState == .recording {
                    self?.manualCaptureBufferCount = count
                }
            }
            .store(in: &cancellables)

        ManualQuestionCaptureService.shared.$lastBufferTimestamp
            .receive(on: DispatchQueue.main)
            .sink { [weak self] timestamp in
                if self?.manualCaptureState == .recording {
                    self?.manualCaptureLastBufferTimestamp = timestamp
                }
            }
            .store(in: &cancellables)

        self.activeObserverToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPermissions()
            }
        }
    }

    func markSystemAudioCaptureRuntimeOwnedForTesting(_ owned: Bool) {
        ownsSystemAudioCaptureRuntime = owned
    }

    deinit {
        if let token = activeObserverToken {
            NotificationCenter.default.removeObserver(token)
        }
        actionFeedbackDismissTasks.values.forEach { $0.cancel() }
        mainThreadHeartbeatTask?.cancel()
    }

    // MARK: - Action Feedback (moved to AppState+Actions.swift)

    // MARK: - Diagnostics Helpers (moved to AppState+Diagnostics.swift)

    // MARK: - Background Persistence (moved to AppState+Transcript.swift)

    var onboardingComplete: Bool {
        hasCV && hasJD
    }

    var liveBlockedReason: String? {
        if !hasCV && !hasJD { return "Add your CV and job description before starting an interview." }
        if !hasCV { return "Add your CV before starting an interview." }
        if !hasJD { return "Add the job description before starting an interview." }
        return nil
    }

    var activeRealtimeProviderBadge: String {
        guard let provider = activeRealtimeProvider else { return "No realtime provider" }
        return "\(provider.name): \(provider.model)"
    }

    var activeRealtimeProviderPrivacyNote: String {
        guard let provider = activeRealtimeProvider else {
            return "No AI provider is selected."
        }
        return "Cloud mode: selected transcript and CV/JD snippets are sent to \(provider.name)."
    }

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

    func refreshAll() {
        do {
            settings = try settingsRepository.loadSettings()
            providerConfigurations = try settingsRepository.ensureDefaultProviderConfigurations()
            activeRealtimeProvider = try settingsRepository.activeRealtimeProvider()
            activeRecapProvider = try settingsRepository.activeRecapProvider()
            documents = try documentRepository.documents()
            sessions = try sessionRepository.listSessions()
            let completion = try documentRepository.onboardingCompletion()
            hasCV = completion.hasCV
            hasJD = completion.hasJD
            let keychainAccounts = Set(providerConfigurations.compactMap(\.apiKeyAccount))
            var keychainStates: [String: KeychainAPIKeyAccessState] = [:]
            for account in keychainAccounts {
                keychainStates[account] = keychainService.apiKeyAccessState(account: account)
            }
            let deepSeekState = keychainStates[KeychainConstants.deepSeekAccount] ??
                keychainService.apiKeyAccessState(account: KeychainConstants.deepSeekAccount)
            keychainStates[KeychainConstants.deepSeekAccount] = deepSeekState

            hasAPIKey = keychainStates.values.contains { $0.hasReadableKey }

            // Hydrate Keychain Diagnostics & Mismatch Detection without repeated reads.
            self.keychainDeepSeekKeyExists = deepSeekState.hasReadableKey
            self.keychainMaskedKey = deepSeekState.maskedDisplay
            self.keychainLastReadStatus = keychainService.lastReadStatus
            self.keychainLastWriteStatus = keychainService.lastWriteStatus
            self.keychainMigrationPerformed = keychainService.migrationPerformed
            self.keychainLegacyItemFound = keychainService.legacyItemFound
            self.keychainLegacyItemCount = keychainService.legacyItemCount

            if case .authorizationRequired(let message) = deepSeekState {
                self.keychainAuthorizationWarning = message
            } else {
                self.keychainAuthorizationWarning = nil
            }

            if self.keychainDeepSeekKeyExists {
                self.keychainMismatchStatus = "✅ DeepSeek API Key loaded successfully"
            } else if let warning = self.keychainAuthorizationWarning {
                self.keychainMismatchStatus = "⚠️ \(warning)"
            } else if keychainService.legacyItemFound || keychainService.legacyItemCount > 0 {
                let count = keychainService.legacyItemCount
                if count > 1 {
                    self.keychainMismatchStatus = "⚠️ Legacy keys found (\(count) items), migration available"
                } else {
                    self.keychainMismatchStatus = "⚠️ Legacy key found, migration available"
                }
            } else {
                self.keychainMismatchStatus = "❌ No DeepSeek API key found in Keychain"
            }
            let cvCount = (try? documentRepository.chunks(type: .cv).count) ?? 0
            let jdCount = (try? documentRepository.chunks(type: .jobDescription).count) ?? 0
            latexPollutedChunkCount = (try? documentRepository.latexPollutedChunkCount()) ?? 0
            refreshPermissions()
            updateDiagnostics {
                $0.storedCVChunkCount = cvCount
                $0.storedJDChunkCount = jdCount
                $0.apiCallCount = (try? self.settingsRepository.apiCallCount()) ?? 0
            }
            
            let currentProvStr = currentEmbeddingProviderID(for: settings)
            let currentModelStr = settings.embeddingModelName
            if let cov = try? documentRepository.embeddingCoverage(currentProvider: currentProvStr, currentModel: currentModelStr) {
                self.embeddingCoverage = cov
            }
            let verificationMocksEnabled = verificationMocksEnabledOverride ??
                (ProcessInfo.processInfo.environment["ENABLE_VERIFICATION_MOCKS"] == "1")
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

        if activeTranscriptionProvider === mockTranscriptionService {
            mockTranscriptionService.submit(trimmed)
        } else {
            Task { [weak self] in
                guard let self else { return }
                do {
                    let session: InterviewSession
                    if let currentSession = self.currentSession {
                        session = currentSession
                    } else {
                        session = try self.sessionRepository.createSession(mode: .mock, title: "Practice Test")
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
    /// This method still owns the task lifecycle in Phase 2D. It assumes the
    /// caller has already accepted exactly one clean question. All async paths
    /// must guard `generationID` against the active generation before mutating
    /// current UI state, because older Stage A/Stage B/provider callbacks may
    /// finish after a newer interviewer question starts.
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
        speaker explicitSpeaker: SpeakerRole? = nil
    ) async throws {
        let triggerPath = explicitTriggerPath ?? (autoGenerated ? .autoDetect : .manualGenerate)
        let attributedSegment = question.transcriptSegmentID.flatMap { segmentID in
            transcriptSegments.first(where: { $0.id == segmentID })
        }
        let telemetrySource = explicitSource ?? attributedSegment?.source
        let telemetrySpeaker = explicitSpeaker ?? attributedSegment?.speaker
        lastDetectedQuestion = question
        lastDetectedQuestionText = question.questionText
        lastDetectedQuestionSource = telemetrySource?.rawValue ?? lastDetectedQuestionSource
        lastDetectedQuestionSpeaker = telemetrySpeaker?.rawValue ?? lastDetectedQuestionSpeaker
        if !isActionLoading(ActionID.generateAnswer) {
            beginAction(
                ActionID.generateAnswer,
                title: autoGenerated ? "Question detected" : "Generating first answer",
                message: autoGenerated ? "Generating answer..." : "Preparing a speakable first answer..."
            )
        }

        liveState = .generatingSuggestion
        let stateBefore = currentCaptureRuntimeState.displayName
        currentCaptureRuntimeState = .generating
        addCaptureEvent(name: "suggestionGenerationStarted", stateBefore: stateBefore, stateAfter: "generating", reason: "questionDetected")
        self.suggestionGenerationStarted = true
        self.floatingPanelUpdated = false

        let requestStart = Date()
        let cardID = UUID().uuidString
        let generationID = UUID().uuidString
        if question.transcriptSegmentID == lastTranscriptQuestionGenerationTrace.transcriptSegmentID {
            lastTranscriptQuestionGenerationTrace.generationTriggered = true
            lastTranscriptQuestionGenerationTrace.generationID = generationID
            lastTranscriptQuestionGenerationTrace.generationBlockedReason = ""
            lastTranscriptQuestionGenerationTrace.providerStatus = activeRealtimeProviderBadge
        }
        activateGeneration(
            question: question,
            generationID: generationID,
            triggerPath: triggerPath,
            requestStart: requestStart,
            source: telemetrySource,
            speaker: telemetrySpeaker
        )
        setGenerationUIState(.generatingFirstAnswer(questionID: question.id, generationID: generationID, triggerPath: triggerPath), generationID: generationID)
        startFullCardWatchdog(
            generationID: generationID,
            cardID: cardID,
            question: question,
            session: session,
            requestStart: requestStart,
            triggerPath: triggerPath
        )

        self.streamRequestStartAt = requestStart
        self.streamFirstTokenAt = nil
        self.streamFirstVisibleTextAt = nil
        self.streamFirstSentenceAt = nil
        self.streamFullResponseAt = nil
        self.streamJSONParsedAt = nil
        self.streamPersistedAt = nil

        self.isStreamingSayFirst = true
        self.streamedSayFirst = ""
        self.isExpandingSuggestionCard = false

        self.softFallbackUsed = false
        self.softFallbackLatencyMS = nil
        self.softFallbackShownAt = nil
        self.deepseekFirstTokenMS = nil
        self.deepseekFirstVisibleMS = nil
        self.finalVisibleSource = nil
        self.userInteractedWithCard = false
        self.ragRetrievalLatencyMS = nil
        self.firstVisibleStateSetAt = nil
        self.currentSuggestionSetAt = nil
        self.streamedSayFirstSetAt = nil

        let localQuestion = question
        let localSession = session
        let localTranscript = transcript

        // This watchdog covers the whole answer pipeline, including RAG retrieval.
        // The later RAG/DeepSeek paths replace it with more specific content.
        let initialFallbackTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                try await self.delayProvider.sleep(nanoseconds: 1_500_000_000)
            } catch {
                return
            }
            guard self.currentGenerationID == generationID else { return }
            guard self.currentSuggestion == nil, self.streamFirstVisibleTextAt == nil else { return }
            let elapsed = Int(Date().timeIntervalSince(requestStart) * 1000)
            self.softFallbackUsed = true
            self.softFallbackLatencyMS = elapsed
            self.softFallbackShownAt = Date()
            self.finalVisibleSource = "local_first_answer_fallback"
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
                speaker: telemetrySpeaker
            ) else { return }
            self.currentSuggestionSetAt = Date()
            self.isStreamingSayFirst = false
            self.isExpandingSuggestionCard = true
            self.markFirstVisibleAnswer(generationID: generationID, fallback: true)
            self.setGenerationUIState(.showingFallback(questionID: localQuestion.id, generationID: generationID, triggerPath: triggerPath), generationID: generationID)
            self.infoAction(ActionID.generateAnswer, title: "First answer visible", message: "Local first answer is visible while the full answer expands.", autoDismissAfter: 3.0)
            print("[StreamingASR] Initial first-answer fallback triggered at \(elapsed)ms before provider text was visible.")
        }
        registerFallbackWatchdogTask(initialFallbackTask, generationID: generationID)
        applyPendingIgnoredSystemAudioFallbackIfNeeded(for: question)
        
        var retrievedContext: RetrievedContext? = nil
        var retrievalTrace: RetrievalTrace? = nil
        
        // 1. Check precomputed RAG Cache
        var hitCache = false
        if let segmentID = question.transcriptSegmentID {
            let finalIntent = AnswerRelevancePolicy.intent(for: question.questionText)
            let normalizedFinal = AnswerRelevancePolicy.normalizedQuestionText(for: question.questionText)
            let exactCacheKey = ragPrecomputeCacheKey(
                segmentID: segmentID,
                questionText: question.questionText,
                intent: finalIntent
            )
            if let cached = precomputedRAGCache[exactCacheKey] {
                if cached.normalizedQuestionText == normalizedFinal && cached.questionIntent == finalIntent {
                    retrievedContext = cached.context
                    retrievalTrace = cached.trace
                    hitCache = true
                    lastRAGOperation = "Relevant context cache hit"
                    print("[PrecomputeRAG] Exact cache hit for key: \(exactCacheKey)")
                } else {
                    lastRAGOperation = "Relevant context cache miss"
                    print("[PrecomputeRAG] Cache miss due to question/intent mismatch for key: \(exactCacheKey). Rerunning retrieval.")
                }
                precomputedRAGCache.removeValue(forKey: exactCacheKey)
            } else {
                let staleKeys = precomputedRAGCache.keys.filter { $0.hasPrefix(segmentID + "_") }
                staleKeys.forEach { precomputedRAGCache.removeValue(forKey: $0) }
                if !staleKeys.isEmpty {
                    lastRAGOperation = "Relevant context cache miss"
                    print("[PrecomputeRAG] Removed \(staleKeys.count) stale cache item(s) for segmentID: \(segmentID).")
                }
            }
        }
        
        if !hitCache {
            do {
                markRAGOperation("Relevant context retrieval started")
                let retrievalService = contextRetrievalService!
                let (context, trace) = try await Task.detached(priority: .userInitiated) {
                    try await retrievalService.retrieveContextWithTrace(
                        question: question.questionText,
                        intent: question.intent,
                        maxCVWords: 300,
                        maxJDWords: 180,
                        strategy: question.answerStrategy
                    )
                }.value
                retrievedContext = context
                retrievalTrace = trace
                lastRAGOperation = "Relevant context retrieval completed"
            } catch {
                lastRAGOperation = "Relevant context retrieval failed: \(error.localizedDescription)"
                markGenerationFailed(
                    generationID: generationID,
                    reason: "Relevant context retrieval failed: \(error.localizedDescription)",
                    providerError: error.localizedDescription
                )
                failAction(ActionID.generateAnswer, title: "Generation failed", message: "Could not prepare relevant context. \(userFacing(error))")
                throw error
            }
        }
        
        guard let context = retrievedContext, let trace = retrievalTrace else {
            let error = LLMProviderError.invalidResponse("Could not retrieve relevant context.")
            markGenerationFailed(generationID: generationID, reason: error.localizedDescription, providerError: error.localizedDescription)
            failAction(ActionID.generateAnswer, title: "Generation failed", message: "Could not prepare relevant context.")
            throw error
        }
        guard isActiveGeneration(generationID) else {
            recordStaleGenerationDiscard()
            return
        }
        self.lastRetrievalTrace = trace
        self.ragRetrievalLatencyMS = Int(trace.retrievalLatencyMS)
        
        // 2. Realtime Context Budget Optimization
        let optimizedContext = trimContextForRealtime(context, question: question)
        
        // Load CV/JD compact summaries for prompt prefix stabilization
        let documentRepository = self.documentRepository
        markSQLiteOperation("Loading document summaries in background")
        let (cvRecord, jdRecord) = await Task.detached(priority: .utility) {
            (
                try? documentRepository.document(type: .cv),
                try? documentRepository.document(type: .jobDescription)
            )
        }.value
        guard isActiveGeneration(generationID) else {
            recordStaleGenerationDiscard()
            return
        }
        lastSQLiteOperation = "Loaded document summaries"
        let cvSummary = makeCompactSummary(cvRecord)
        let jdSummary = makeCompactSummary(jdRecord)
        // Freeze the prompt inputs after RAG retrieval and before provider
        // streaming. From here on, transcript changes and later questions must
        // not alter the current prompt: question_text must stay equal to
        // prompt_primary_question for this generation.
        let generationContext = GenerationExecutionContext.make(
            session: localSession,
            question: localQuestion,
            generationID: generationID,
            triggerPath: triggerPath,
            provider: activeRealtimeProvider,
            retrievedContext: optimizedContext,
            transcriptSnapshot: localTranscript,
            cvSummary: cvSummary,
            jdSummary: jdSummary,
            startedAt: requestStart,
            source: telemetrySource,
            speaker: telemetrySpeaker,
            stage: .firstAnswer
        )
        let firstAnswerProviderRequest = GenerationProviderRequest(
            context: generationContext,
            streamingEnabled: true
        )
        let promptSnapshot = generationContext.promptSnapshot
        applyPromptSnapshotDiagnostics(promptSnapshot, providerRequest: firstAnswerProviderRequest)
        
        // Create references for background task capture
        let localTrace = trace
        
        // Helper to construct a local fallback card
        func createRAGFallbackCard(isSoft: Bool) -> SuggestionCard {
            let fallback = AnswerRelevancePolicy.fallbackAnswer(for: localQuestion)
            let intent = AnswerRelevancePolicy.intent(for: localQuestion.questionText)
            
            return SuggestionCard(
                id: cardID,
                sessionID: localSession.id,
                questionID: localQuestion.id,
                strategy: isSoft ? "RAG Template Soft Fallback (DeepSeek Delay)" : "RAG Template Fallback (DeepSeek Timeout)",
                sayFirst: fallback.sayFirst,
                keyPoints: fallback.keyPoints,
                followUpReady: ["How does this align with the role requirements?"],
                confidence: 0.5,
                caution: isSoft ? "Fast local answer shown; DeepSeek still generating..." : "Fast fallback shown; DeepSeek still expanding...",
                evidenceUsed: (optimizedContext.cvChunks + optimizedContext.jobDescriptionChunks).map { $0.id },
                riskLevel: .medium,
                modelName: "rag-fallback",
                promptVersion: "fallback-v1",
                providerKind: nil,
                providerName: "RAG Template Fallback",
                providerBaseURL: "",
                latencyMS: Int(Date().timeIntervalSince(requestStart) * 1000),
                isLocal: false,
                rawJSON: nil,
                createdAt: Date(),
                questionIntent: intent,
                promptQuestionText: localQuestion.questionText,
                promptPrimaryQuestion: promptSnapshot.promptPrimaryQuestion,
                promptContainsPreviousQuestion: promptSnapshot.promptContainsPreviousQuestion,
                previousQuestionIncluded: promptSnapshot.previousQuestionIncluded,
                previousQuestionText: promptSnapshot.previousQuestionText,
                contextBleedRisk: promptSnapshot.contextBleedRisk,
                ragChunkIDs: promptSnapshot.ragChunkIDs,
                ragChunkIntents: promptSnapshot.ragChunkIntents,
                promptTokenEstimate: promptSnapshot.promptTokenEstimate,
                promptContextPreview: promptSnapshot.ragChunkPreviews.joined(separator: "\n"),
                sayFirstSource: isSoft ? "rag_template_soft_fallback" : "rag_template_fallback",
                stageATimedOut: !isSoft,
                stageBCompleted: false,
                stageBStatus: "skipped",
                latencyFirstTokenMS: nil,
                latencyFirstVisibleMS: nil,
                latencyFullCardMS: nil,
                softFallbackUsed: isSoft,
                softFallbackLatencyMS: isSoft ? Int(Date().timeIntervalSince(requestStart) * 1000) : nil,
                deepseekFirstTokenMS: nil,
                deepseekFirstVisibleMS: nil,
                finalVisibleSource: isSoft ? "rag_template_soft_fallback" : "rag_template_fallback"
            )
        }
        
        let trigger = StageBTrigger()
        
        // Start 1.5s parallel soft fallback timer task
        let ragFallbackTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                try await self.delayProvider.sleep(nanoseconds: 1_500_000_000)
                guard self.currentGenerationID == generationID else { return }
                
                if self.streamFirstVisibleTextAt == nil {
                    let elapsed = Int(Date().timeIntervalSince(requestStart) * 1000)
                    self.softFallbackUsed = true
                    self.softFallbackLatencyMS = elapsed
                    self.finalVisibleSource = "rag_template_soft_fallback"
                    
                    let fallbackCard = createRAGFallbackCard(isSoft: true)
                    var visibleFallback = fallbackCard
                    visibleFallback.firstVisibleAnswerMS = elapsed
                    guard self.displaySuggestionIfAligned(
                        visibleFallback,
                        question: localQuestion,
                        generationID: generationID,
                        triggerPath: triggerPath,
                        source: telemetrySource,
                        speaker: telemetrySpeaker
                    ) else { return }
                    self.currentSuggestionSetAt = self.currentSuggestionSetAt ?? Date()
                    self.isStreamingSayFirst = false
                    self.isExpandingSuggestionCard = true
                    self.markFirstVisibleAnswer(generationID: generationID, fallback: true)
                    self.setGenerationUIState(.showingFallback(questionID: localQuestion.id, generationID: generationID, triggerPath: triggerPath), generationID: generationID)
                    self.infoAction(ActionID.generateAnswer, title: "First answer visible", message: "Fast local answer is visible while DeepSeek continues.", autoDismissAfter: 3.0)
                    print("[StreamingASR] Soft fallback triggered at \(elapsed)ms because no DeepSeek text was visible yet.")
                }
            } catch {
                // Cancelled or sleep error
            }
        }
        registerFallbackWatchdogTask(ragFallbackTask, generationID: generationID)
        
        // Cost Control: Launch Stage B in parallel immediately, but it waits for the trigger!
        let stageBGenerationTask = Task { [weak self] in
            guard let self = self else { return }
            // Wait for Stage B trigger (timeout after 500ms if first visible text doesn't show up sooner)
            await trigger.wait(timeoutMs: 500)
            
            guard self.currentGenerationID == generationID else {
                self.recordStaleGenerationDiscard()
                return
            }
                guard !Task.isCancelled else {
                    print("[StageB] Task was cancelled in-flight.")
                    self.clearStageBTask(generationID: generationID)
                    return
                }
                if self.visibleAnswerExists {
                    self.setGenerationUIState(.expandingFullAnswer(questionID: localQuestion.id, generationID: generationID, triggerPath: triggerPath), generationID: generationID)
                }
            
            let activeFallback = self.softFallbackUsed || self.currentSuggestion?.sayFirstSource == "rag_template_fallback" || self.currentSuggestion?.sayFirstSource == "rag_template_soft_fallback"
            
            do {
                let streamStartedMS = self.elapsedMS(since: requestStart)
                var parser = StreamingSuggestionSectionParser()
                var throttle = StreamingUpdateThrottle()
                var latestSections = StreamingSuggestionSections()
                var sawStreamingSections = false

                self.markProviderOperation("Stage B section stream started")
                let sectionStream = try await self.suggestionGenerationService.generateFullCardSectionStream(
                    question: localQuestion,
                    context: optimizedContext,
                    transcriptContext: localTranscript,
                    sessionID: localSession.id,
                    cvSummary: cvSummary,
                    jdSummary: jdSummary
                )

                for try await token in sectionStream {
                    guard self.currentGenerationID == generationID else {
                        self.recordStaleGenerationDiscard()
                        return
                    }
                    guard !Task.isCancelled else {
                        print("[StageB] Task was cancelled in-flight.")
                        self.clearStageBTask(generationID: generationID)
                        return
                    }

                    latestSections = parser.append(token)
                    guard latestSections.hasVisibleContent else { continue }
                    sawStreamingSections = true

                    let shouldForce = self.currentSuggestion?.firstKeyPointVisibleMS == nil && !latestSections.keyPoints.isEmpty
                    if throttle.shouldPublish(characterCount: latestSections.characterCount, force: shouldForce) {
                        let preserveFallbackSayFirst = self.softFallbackUsed &&
                            (self.userInteractedWithCard || (!latestSections.sayFirst.isEmpty && !self.isSpecificAnswer(latestSections.sayFirst)))
                        self.publishStreamingSections(
                            latestSections,
                            cardID: cardID,
                            generationID: generationID,
                            question: localQuestion,
                            session: localSession,
                            requestStart: requestStart,
                            stageBStreamStartedMS: streamStartedMS,
                            preserveExistingSayFirst: preserveFallbackSayFirst
                        )
                    }
                }

                guard self.currentGenerationID == generationID else {
                    self.recordStaleGenerationDiscard()
                    return
                }
                guard !Task.isCancelled else {
                    print("[StageB] Task was cancelled in-flight.")
                    self.clearStageBTask(generationID: generationID)
                    return
                }

                if !sawStreamingSections {
                    self.markProviderOperation("Stage B full-card fallback started")
                    let fullAnswerContext = GenerationExecutionContext.make(
                        session: localSession,
                        question: localQuestion,
                        generationID: generationID,
                        triggerPath: triggerPath,
                        provider: self.activeRealtimeProvider,
                        retrievedContext: optimizedContext,
                        transcriptSnapshot: localTranscript,
                        cvSummary: cvSummary,
                        jdSummary: jdSummary,
                        startedAt: requestStart,
                        source: telemetrySource,
                        speaker: telemetrySpeaker,
                        stage: .fullAnswer
                    )
                    let fullAnswerProviderRequest = GenerationProviderRequest(
                        context: fullAnswerContext,
                        streamingEnabled: false
                    )
                    let providerResult = try await self.withTimeout(seconds: 15.0) {
                        await self.generationCoordinator.executeProviderRequest(
                            fullAnswerProviderRequest,
                            question: localQuestion,
                            context: optimizedContext,
                            transcriptContext: localTranscript,
                            sessionID: localSession.id,
                            cvSummary: cvSummary,
                            jdSummary: jdSummary
                        )
                    }
                    guard self.isActiveGeneration(generationID), !Task.isCancelled else {
                        self.recordStaleGenerationDiscard()
                        return
                    }
                    let stageBDecision = self.generationCoordinator.interpretStageBResult(
                        generationID: generationID,
                        detectedQuestionID: localQuestion.id,
                        activeGenerationID: self.currentGenerationID,
                        questionText: localQuestion.questionText,
                        providerResult: providerResult,
                        sections: providerResult.parsedSections,
                        sawStreamingSections: false,
                        visibleSayFirst: self.currentSuggestion?.sayFirst,
                        visibleAnswerExists: self.visibleAnswerExists
                    )
                    let stageBApplicationPlan = self.generationCoordinator.makeStageBApplicationPlan(
                        from: stageBDecision,
                        visibleSuggestion: self.currentSuggestion,
                        activeGenerationID: self.currentGenerationID,
                        activeQuestionID: self.activeQuestionID
                    )
                    if stageBApplicationPlan.action == .discardStaleResult {
                        self.recordStaleGenerationDiscard()
                        return
                    }
                    guard providerResult.providerStatus == .completed else {
                        throw GenerationCoordinator.ProviderExecutionFailure(result: providerResult)
                    }
                    if let caution = providerResult.safeDiagnostics["caution"],
                       caution.localizedCaseInsensitiveContains("non-JSON") ||
                        caution.localizedCaseInsensitiveContains("JSON") {
                        self.currentGenerationTelemetry.jsonParseError = caution
                    }
                    latestSections = providerResult.parsedSections ?? StreamingSuggestionSections(
                        strategy: "Direct Answer",
                        sayFirst: providerResult.sayFirst,
                        keyPoints: providerResult.keyPoints,
                        followUpReady: providerResult.followUp,
                        caution: providerResult.safeDiagnostics["caution"] ?? ""
                    )
                }

                guard self.isActiveGeneration(generationID), !Task.isCancelled else {
                    self.recordStaleGenerationDiscard()
                    return
                }
                let finalStageBDecision = self.generationCoordinator.interpretStageBResult(
                    generationID: generationID,
                    detectedQuestionID: localQuestion.id,
                    activeGenerationID: self.currentGenerationID,
                    questionText: localQuestion.questionText,
                    providerResult: nil,
                    sections: latestSections,
                    sawStreamingSections: sawStreamingSections,
                    visibleSayFirst: self.currentSuggestion?.sayFirst,
                    visibleAnswerExists: self.visibleAnswerExists
                )
                let finalStageBApplicationPlan = self.generationCoordinator.makeStageBApplicationPlan(
                    from: finalStageBDecision,
                    visibleSuggestion: self.currentSuggestion,
                    activeGenerationID: self.currentGenerationID,
                    activeQuestionID: self.activeQuestionID
                )
                let preserveFallbackSayFirst = self.softFallbackUsed &&
                    (self.userInteractedWithCard || (!latestSections.sayFirst.isEmpty && !self.isSpecificAnswer(latestSections.sayFirst)))
                try await self.applyStageBApplicationPlan(
                    finalStageBApplicationPlan,
                    sections: latestSections,
                    cardID: cardID,
                    generationID: generationID,
                    question: localQuestion,
                    session: localSession,
                    requestStart: requestStart,
                    stageBStreamStartedMS: streamStartedMS,
                    retrievedChunks: localTrace.rankedCVChunks + localTrace.rankedJDChunks,
                    triggerPath: triggerPath,
                    source: telemetrySource,
                    speaker: telemetrySpeaker,
                    preserveFallbackSayFirst: preserveFallbackSayFirst
                )
            } catch {
                self.clearStageBTask(generationID: generationID)
                guard self.currentGenerationID == generationID else {
                    self.recordStaleGenerationDiscard()
                    return
                }
                print("[StreamingASR] Stage B Full SuggestionCard failed or timed out: \(error.localizedDescription)")
                let errorMessage = error.localizedDescription
                let timedOut = errorMessage.lowercased().contains("timed out") || errorMessage.lowercased().contains("timeout")
                let jsonParseError = errorMessage.lowercased().contains("json") ? errorMessage : nil
                self.markGenerationFailed(
                    generationID: generationID,
                    reason: errorMessage,
                    providerError: errorMessage,
                    jsonParseError: jsonParseError,
                    timeout: timedOut,
                    cancelled: error is CancellationError
                )
                
                // Only restore .listening if safety conditions are met
                if self.currentSession?.id == localSession.id &&
                   self.currentCaptureRuntimeState == .generating &&
                   self.stopReason == nil &&
                   self.currentGenerationID == generationID &&
                   self.anyCaptureRunning {
                    self.liveState = .listening
                    self.currentCaptureRuntimeState = .listening
                    self.addCaptureEvent(name: "listeningRestored", stateBefore: "generating", stateAfter: "listening", reason: "generationFailed")
                } else {
                    print("[CaptureState] Bypassed restoring listening on error: sessionID=\(self.currentSession?.id ?? "nil"), state=\(self.currentCaptureRuntimeState), stopReason=\(String(describing: self.stopReason)), generationID=\(String(describing: self.currentGenerationID)), anyCaptureRunning=\(self.anyCaptureRunning)")
                }
                
                if let current = self.currentSuggestion {
                    var updated = current
                    updated.stageBCompleted = false
                    updated.stageBStatus = error is CancellationError ? "cancelled" : "timed_out"
                    updated.caution = "DeepSeek full card generation failed/timed out. Showing opener only."
                    if activeFallback {
                        updated.caution = "Fast fallback is visible. Full answer expansion failed or timed out."
                    }
                    self.currentSuggestion = updated
                    self.persistSuggestionInBackground(
                        updated,
                        chunks: self.currentSuggestionRetrievedChunks,
                        generationID: generationID,
                        requestStart: requestStart
                    )
                    self.warnAction(ActionID.generateAnswer, title: "First answer preserved", message: "Full answer expansion failed. The visible answer was kept.")
                } else {
                    self.failAction(ActionID.generateAnswer, title: "Generation failed", message: "Transcript preserved. \(self.userFacing(error))")
                }
            }
        }
        registerStageBTask(stageBGenerationTask, generationID: generationID)
        
        // Stage A streaming task
        let fastSayFirstTask = Task {
            do {
                self.markProviderOperation("Stage A first-answer stream started")
                let stream = try await self.suggestionGenerationService.generateFastSayFirstStream(
                    question: localQuestion,
                    context: optimizedContext,
                    cvSummary: cvSummary,
                    jdSummary: jdSummary
                )
                
                var collected = ""
                var sayFirstThrottle = StreamingUpdateThrottle()
                for try await token in stream {
                    guard self.currentGenerationID == generationID else {
                        self.recordStaleGenerationDiscard()
                        throw CancellationError()
                    }
                    guard !Task.isCancelled else { break }
                    if self.streamFirstTokenAt == nil {
                        self.streamFirstTokenAt = Date()
                        self.currentGenerationTelemetry.firstDeepSeekTokenAt = self.streamFirstTokenAt
                        self.deepseekFirstTokenMS = Int(Date().timeIntervalSince(requestStart) * 1000)
                    }
                    collected += token
                    
                    // First visible text detection (at least 3 words or 10 characters)
                    var forcePublish = false
                    if self.streamFirstVisibleTextAt == nil {
                        let wordCount = collected.split(whereSeparator: \.isWhitespace).count
                        if (wordCount >= 3 || collected.count >= 10),
                           self.isAnswerRelevantEnoughForLivePreview(collected, question: localQuestion) {
                            self.streamFirstVisibleTextAt = Date()
                            self.firstVisibleStateSetAt = Date()
                            self.deepseekFirstVisibleMS = Int(Date().timeIntervalSince(requestStart) * 1000)
                            self.markFirstVisibleAnswer(generationID: generationID, fallback: false)
                            self.setGenerationUIState(.streamingAnswer(questionID: localQuestion.id, generationID: generationID, triggerPath: triggerPath), generationID: generationID)
                            self.infoAction(ActionID.generateAnswer, title: "First answer visible", message: "DeepSeek first answer is streaming.", autoDismissAfter: 2.5)
                            forcePublish = true
                            trigger.trigger() // Start Stage B early!
                        }
                    }

                    if sayFirstThrottle.shouldPublish(characterCount: collected.count, force: forcePublish) {
                        let relevantPreview = self.isAnswerRelevantEnoughForLivePreview(collected, question: localQuestion)
                        self.streamedSayFirst = relevantPreview ? collected : ""
                        if relevantPreview && self.streamedSayFirstSetAt == nil && !collected.isEmpty {
                            self.streamedSayFirstSetAt = Date()
                        }
                    }
                    
                    // First sentence detection
                    if self.streamFirstSentenceAt == nil && (token.contains(".") || token.contains("!") || token.contains("?")) {
                        self.streamFirstSentenceAt = Date()
                    }
                }
                let relevantFinalPreview = self.isAnswerRelevantEnoughForLivePreview(collected, question: localQuestion)
                self.streamedSayFirst = relevantFinalPreview ? collected : ""
                if relevantFinalPreview && self.streamedSayFirstSetAt == nil && !collected.isEmpty {
                    self.streamedSayFirstSetAt = Date()
                }
                self.streamFullResponseAt = Date()
                trigger.trigger() // Ensure Stage B is triggered if Stage A finishes
                return collected
            } catch {
                trigger.trigger() // Ensure Stage B is triggered on error too
                throw error
            }
        }
        registerStageATask(fastSayFirstTask, generationID: generationID)
        
        // Race Stage A with 6.0s timeout
        var fastSayFirst = ""
        do {
            fastSayFirst = try await withTimeout(seconds: stageATimeoutSeconds) {
                try await fastSayFirstTask.value
            }
            clearStageATask(generationID: generationID)
            guard self.currentGenerationID == generationID else {
                recordStaleGenerationDiscard()
                return
            }
            self.isStreamingSayFirst = false
            
            // Cancel soft fallback task since Stage A completed
            clearFallbackWatchdogTask(generationID: generationID)
            
            let elapsed = Date().timeIntervalSince(requestStart)
            let isSoft = self.softFallbackUsed
            
            if isSoft {
                // Apply conservative late DeepSeek replacement checks
                let replace = !self.userInteractedWithCard &&
                    elapsed < self.lateDeepSeekReplacementWindowSeconds &&
                    self.isSpecificAnswer(fastSayFirst)
                if replace {
                    if var current = self.currentSuggestion, current.stageBCompleted == true {
                        current.sayFirst = fastSayFirst
                        current.sayFirstSource = "deepseek_stream"
                        current.finalVisibleSource = "deepseek_stream"
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
                        self.setGenerationUIState(.expandingFullAnswer(questionID: localQuestion.id, generationID: generationID, triggerPath: triggerPath), generationID: generationID)
                        self.persistSuggestionInBackground(validated, chunks: self.currentSuggestionRetrievedChunks, generationID: generationID, requestStart: requestStart)
                    } else {
                        var updated = createRAGFallbackCard(isSoft: true)
                        updated.sayFirst = fastSayFirst
                        updated.sayFirstSource = "deepseek_stream"
                        updated.finalVisibleSource = "deepseek_stream"
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
                    }
                    print("[StreamingASR] Soft fallback replaced with late DeepSeek text at \(Int(elapsed * 1000))ms.")
                } else {
                    print("[StreamingASR] Soft fallback preserved. Late DeepSeek text rejected (elapsed: \(Int(elapsed * 1000))ms, interacted: \(self.userInteractedWithCard)).")
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
            }
        } catch {
            clearStageATask(generationID: generationID)
            guard self.currentGenerationID == generationID else {
                recordStaleGenerationDiscard()
                return
            }
            print("[StreamingASR] Stage A Fast Say-First timed out or failed: \(error.localizedDescription)")
            self.isStreamingSayFirst = false
            clearFallbackWatchdogTask(generationID: generationID)
            
            // If soft fallback was already shown, preserve it but mark timeout/failure.
            // If not, show hard fallback now.
            if !self.softFallbackUsed {
                let fallbackCard = createRAGFallbackCard(isSoft: false)
                var visibleFallback = fallbackCard
                visibleFallback.firstVisibleAnswerMS = Int(Date().timeIntervalSince(requestStart) * 1000)
                let validated = await self.validateAndRewriteIfNeeded(visibleFallback, generationID: generationID)
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
                self.softFallbackUsed = true
                self.softFallbackLatencyMS = visibleFallback.firstVisibleAnswerMS
                self.softFallbackShownAt = self.softFallbackShownAt ?? Date()
                self.markFirstVisibleAnswer(generationID: generationID, fallback: true)
                self.setGenerationUIState(.showingFallback(questionID: localQuestion.id, generationID: generationID, triggerPath: triggerPath), generationID: generationID)
                self.warnAction(ActionID.generateAnswer, title: "Local answer shown", message: "DeepSeek first answer failed or timed out. The fallback answer is visible.")
            } else if var current = self.currentSuggestion {
                current.stageATimedOut = true
                current.caution = "Fast fallback shown; DeepSeek stream timed out."
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
                self.markFirstVisibleAnswer(generationID: generationID, fallback: true)
                self.setGenerationUIState(.showingFallback(questionID: localQuestion.id, generationID: generationID, triggerPath: triggerPath), generationID: generationID)
                self.warnAction(ActionID.generateAnswer, title: "First answer preserved", message: "DeepSeek first answer timed out. The visible fallback was kept.")
            } else {
                self.markGenerationFailed(
                    generationID: generationID,
                    reason: error.localizedDescription,
                    providerError: error.localizedDescription,
                    timeout: error.localizedDescription.lowercased().contains("timed out")
                )
                self.failAction(ActionID.generateAnswer, title: "Generation failed", message: "Transcript preserved. \(self.userFacing(error))")
            }
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
                contentPreview: "Led development of a deep learning-based robotic arm manipulation project...",
                fullContent: "Led development of a deep learning-based robotic arm manipulation project using PyTorch and ROS. Achieved a 95% grasp success rate in unstructured environments.",
                keywords: ["robotic", "PyTorch", "ROS", "manipulation", "deep learning"],
                score: 8.5,
                keywordOverlapCount: 3,
                contentOverlapCount: 5,
                rank: 1,
                isIncludedInPrompt: true,
                sectionTitle: "ROBOTICS PROJECT",
                wordCount: 22
            ),
            RetrievedChunk(
                id: "cv-chunk-2",
                documentID: "doc-cv-1",
                documentType: .cv,
                chunkIndex: 1,
                contentPreview: "Implemented reinforcement learning policies for obstacle avoidance in mobile...",
                fullContent: "Implemented reinforcement learning policies for obstacle avoidance in mobile robots using DDPG and gazebo simulations. Tested and deployed on turtlebot platforms.",
                keywords: ["reinforcement learning", "obstacle avoidance", "mobile robots", "turtlebot"],
                score: 6.0,
                keywordOverlapCount: 2,
                contentOverlapCount: 3,
                rank: 2,
                isIncludedInPrompt: true,
                sectionTitle: "ROBOTICS PROJECT",
                wordCount: 20
            ),
            RetrievedChunk(
                id: "cv-chunk-3",
                documentID: "doc-cv-1",
                documentType: .cv,
                chunkIndex: 2,
                contentPreview: "Designed custom mechanical mounts and sensory integration brackets for 3D...",
                fullContent: "Designed custom mechanical mounts and sensory integration brackets for 3D LIDAR sensors on self-driving prototypes. Formulated thermal dissipation plans.",
                keywords: ["mechanical mounts", "LIDAR", "self-driving", "prototype"],
                score: 1.5,
                keywordOverlapCount: 0,
                contentOverlapCount: 1,
                rank: 3,
                isIncludedInPrompt: false,
                sectionTitle: "HARDWARE DESIGN",
                wordCount: 18
            )
        ]
        
        let jdChunks = [
            RetrievedChunk(
                id: "jd-chunk-1",
                documentID: "doc-jd-1",
                documentType: .jobDescription,
                chunkIndex: 0,
                contentPreview: "We are seeking a Robotics Engineer experienced in ROS, motion planning, and...",
                fullContent: "We are seeking a Robotics Engineer experienced in ROS, motion planning, and deep learning for autonomous systems. Experience with physical deployment is a plus.",
                keywords: ["Robotics Engineer", "ROS", "motion planning", "autonomous"],
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
            query: "Can you tell me about your robotics project?",
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
        
        let mockCard = SuggestionCard(
            id: "mock-suggestion-card-id",
            sessionID: "mock-session-id",
            questionID: nil,
            strategy: "Project Walkthrough",
            sayFirst: "Sure! I led the development of a deep learning-based robotic arm manipulation project using PyTorch and ROS.",
            keyPoints: [
                "Adapted visual feedback loops to achieve 95% grasp success rate.",
                "Implemented ROS nodes for real-time trajectory execution.",
                "Integrated reinforcement learning obstacle avoidance models."
            ],
            followUpReady: [
                "What reinforcement learning algorithm did you use?",
                "How did you calibrate the robotic arm coordinate frames?"
            ],
            confidence: 0.95,
            caution: "Emphasize manipulation success rates over simulation-only results.",
            evidenceUsed: [
                "PyTorch and ROS robotic arm manipulation",
                "95% grasp success in unstructured environments"
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
            questionText: "Can you tell me about your robotics project?",
            intent: .technical,
            answerStrategy: .projectWalkthrough,
            confidence: 0.95,
            reason: "Verifying robotics experience",
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
        _ = displaySuggestionIfAligned(
            mockCard,
            question: mockQuestion,
            generationID: nil,
            triggerPath: .manualGenerate,
            source: .mock,
            speaker: .interviewer,
            allowInactiveGeneration: true
        )
        self.currentSuggestionRetrievedChunks = cvChunks.filter { $0.isIncludedInPrompt } + jdChunks.filter { $0.isIncludedInPrompt }
        self.manualCaptureSuggestion = self.currentSuggestion
        self.manualCaptureState = .suggestionReady
        
        do {
            try? self.sessionRepository.deleteSession(id: "mock-session-id")
            
            let mockSession = InterviewSession(
                id: "mock-session-id",
                title: "Mock Interview - Robotics",
                company: "RoboCorp",
                role: "Robotics Engineer",
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
            self.sessions = try self.sessionRepository.listSessions()
            
            let mockSegment = TranscriptSegment(
                id: "mock-segment-id",
                sessionID: "mock-session-id",
                source: .mock,
                speaker: .interviewer,
                text: "Can you tell me about your robotics project?",
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
            print("Failed to save mock database elements: \(error)")
        }
    }

}
