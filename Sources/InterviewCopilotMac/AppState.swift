import AppKit
import AVFoundation
import Combine
import Foundation
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case home
    case documents
    case sessions
    case readinessCheck
    case settings
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home / Interview"
        case .documents: return "Documents"
        case .sessions: return "Sessions"
        case .readinessCheck: return "Readiness Check"
        case .settings: return "Settings"
        case .diagnostics: return "Diagnostics"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house"
        case .documents: return "doc.text"
        case .sessions: return "clock.arrow.circlepath"
        case .readinessCheck: return "checklist.checked"
        case .settings: return "gearshape"
        case .diagnostics: return "stethoscope"
        }
    }
}

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
    
    // RAG Phase 3 Embedding properties
    @Published var embeddingCoverage: EmbeddingCoverage? = nil
    @Published var rebuildProgress: Double = 0.0
    @Published var isRebuildingEmbeddings: Bool = false
    @Published var lastEmbeddingTestStatus: String = "Not tested"
    @Published var lastEmbeddingError: String?
    private var activeEmbeddingRebuildTask: Task<Void, Never>? = nil
    private var actionFeedbackDismissTasks: [String: Task<Void, Never>] = [:]
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
    @Published var lastDetectionConfidence: Double = 0.0
    @Published public var lastDetectionShouldTrigger: Bool = false
    @Published public var lastDetectionReason: String = ""
    @Published public var lastDetectionRawJSON: String = ""
    @Published public var lastDetectionSkipReason: String = ""

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
    
    public func addCaptureEvent(
        name: String,
        stateBefore: String,
        stateAfter: String,
        reason: String,
        file: String = #file,
        line: Int = #line,
        function: String = #function
    ) {
        let event = CaptureEvent(
            id: UUID().uuidString,
            timestamp: Date(),
            eventName: name,
            stateBefore: stateBefore,
            stateAfter: stateAfter,
            reason: reason,
            file: file.split(separator: "/").last.map(String.init) ?? file,
            function: function,
            line: line,
            systemCaptureRunning: systemCaptureRunning,
            micCaptureRunning: micCaptureRunning,
            lastSystemAudioBufferAt: lastSystemAudioBufferAt
        )
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.recent20CaptureEvents.append(event)
            if self.recent20CaptureEvents.count > 20 {
                self.recent20CaptureEvents.removeFirst()
            }
            self.objectWillChange.send()
        }
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

    // Soft Fallback & Advanced Provenance
    @Published public var softFallbackUsed: Bool = false
    @Published public var softFallbackLatencyMS: Int? = nil
    @Published public var softFallbackShownAt: Date? = nil
    @Published public var deepseekFirstTokenMS: Int? = nil
    @Published public var deepseekFirstVisibleMS: Int? = nil
    @Published public var finalVisibleSource: String? = nil
    @Published public var currentGenerationID: String? = nil
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
    
    // Stage B lifecycle task reference for cost control / cancellation
    private var stageBTask: Task<Void, Never>? = nil
    private var softFallbackTask: Task<Void, Never>? = nil
    
    // Background RAG precompute cache and debounce
    private struct RAGPrecomputeCacheItem {
        let context: RetrievedContext
        let trace: RetrievalTrace
        let rawText: String
    }
    private var precomputedRAGCache: [String: RAGPrecomputeCacheItem] = [:]
    private var precomputeDebounceTask: Task<Void, Never>? = nil

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

        private let localDataService: LocalDataService
    private var contextRetrievalService: ContextRetrievalService!
    private let llmRouter: LLMRouter
    private let questionDetectionService: QuestionDetectionService
    private let suggestionGenerationService: SuggestionGenerationService
    private let recapGenerationService: RecapGenerationService
    private var appleSpeechService: AppleSpeechTranscriptionService?
    private var activeTranscriptionProvider: TranscriptionProvider?
    private var transcriptionTask: Task<Void, Never>?
    
    private struct RecentSystemAudioRecord {
        let text: String
        let timestamp: Date
    }
    private var recentSystemAudioRecords: [RecentSystemAudioRecord] = []
    private var detectionDebounceTask: Task<Void, Never>?
    private var activeAITask: Task<Void, Never>?
    private var lastDetectionAt: Date?
    private var lastAutoSuggestionAt: Date?
    private var lastAutoQuestionText: String?

    private var activeObserverToken: NSObjectProtocol?
    private var recentQuestionsFingerprints = [String]()
    private var cancellables = Set<AnyCancellable>()
    private var audioSignalMonitoringTimer: Timer?

    private let detectionDebounceSeconds: TimeInterval = 2
    private let autoSuggestionCooldownSeconds: TimeInterval = 5
    private let autoSuggestionConfidenceThreshold = 0.75
    private let possibleQuestionConfidenceRange = 0.55..<0.75

    static func bootstrap() -> AppState {
        do {
            let database = try AppDatabase()
            return AppState(database: database)
        } catch {
            let fallbackURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("InterviewCopilotMac-\(UUID().uuidString).sqlite")
            let fallback = (try? AppDatabase(path: fallbackURL)) ?? (try? AppDatabase(inMemory: true))
            guard let fallback else {
                preconditionFailure("Unable to initialize SQLite or in-memory database.")
            }
            let state = AppState(database: fallback)
            state.showError("Could not open the application database at the normal path. Using a temporary database for this run. \(error.localizedDescription)")
            return state
        }
    }

    init(
        database: AppDatabase,
        llmRouter: LLMRouter? = nil,
        permissionService: PermissionService? = nil,
        keychainService: KeychainService = KeychainService()
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
        self.questionDetectionService = QuestionDetectionService(llmRouter: router)
        self.suggestionGenerationService = SuggestionGenerationService(llmRouter: router)
        self.recapGenerationService = RecapGenerationService(llmRouter: router)
        
        self.contextRetrievalService = HybridContextRetrievalService(
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
                // Propagate capture stream end only for AppState instances that own
                // an active capture path. The session+mode branch keeps the
                // ScreenCaptureKit failure path testable without letting unrelated
                // AppState instances react to singleton test emissions.
                let sessionRequiresSystemAudio = self.currentSession != nil && self.systemAudioRequired
                let ownsActiveCapture = self.activeTranscriptionProvider != nil || self.appleSpeechService != nil || sessionRequiresSystemAudio
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

    deinit {
        if let token = activeObserverToken {
            NotificationCenter.default.removeObserver(token)
        }
        actionFeedbackDismissTasks.values.forEach { $0.cancel() }
    }

    func beginAction(_ id: String, title: String, message: String) {
        actionLoadingStates[id] = true
        setActionFeedback(
            ActionFeedback(
                actionID: id,
                title: title,
                message: message,
                kind: .loading
            )
        )
    }

    func completeAction(_ id: String, title: String, message: String, autoDismissAfter: TimeInterval? = 4.0) {
        actionLoadingStates[id] = false
        setActionFeedback(
            ActionFeedback(
                actionID: id,
                title: title,
                message: message,
                kind: .success,
                autoDismissAfter: autoDismissAfter
            )
        )
    }

    func warnAction(_ id: String, title: String, message: String, autoDismissAfter: TimeInterval? = 6.0) {
        actionLoadingStates[id] = false
        setActionFeedback(
            ActionFeedback(
                actionID: id,
                title: title,
                message: message,
                kind: .warning,
                autoDismissAfter: autoDismissAfter
            )
        )
    }

    func failAction(_ id: String, title: String, message: String, autoDismissAfter: TimeInterval? = nil) {
        actionLoadingStates[id] = false
        setActionFeedback(
            ActionFeedback(
                actionID: id,
                title: title,
                message: message,
                kind: .error,
                autoDismissAfter: autoDismissAfter
            )
        )
        updateDiagnostics { $0.lastError = message }
    }

    func infoAction(_ id: String, title: String, message: String, autoDismissAfter: TimeInterval? = 4.0) {
        setActionFeedback(
            ActionFeedback(
                actionID: id,
                title: title,
                message: message,
                kind: .info,
                autoDismissAfter: autoDismissAfter
            )
        )
    }

    func clearActionFeedback(_ id: String) {
        actionLoadingStates[id] = false
        activeActionFeedbacks.removeAll { $0.actionID == id }
        actionFeedbackDismissTasks[id]?.cancel()
        actionFeedbackDismissTasks[id] = nil
    }

    func isActionLoading(_ id: String) -> Bool {
        actionLoadingStates[id] == true
    }

    func latestActionFeedback(for id: String) -> ActionFeedback? {
        activeActionFeedbacks.last { $0.actionID == id }
    }

    func latestActionFeedback(matching ids: [String]) -> ActionFeedback? {
        activeActionFeedbacks.last { ids.contains($0.actionID) }
    }

    private func setActionFeedback(_ feedback: ActionFeedback) {
        actionFeedbackDismissTasks[feedback.actionID]?.cancel()
        activeActionFeedbacks.removeAll { $0.actionID == feedback.actionID }
        activeActionFeedbacks.append(feedback)
        if activeActionFeedbacks.count > 8 {
            activeActionFeedbacks = Array(activeActionFeedbacks.suffix(8))
        }
        guard let autoDismissAfter = feedback.autoDismissAfter else { return }
        actionFeedbackDismissTasks[feedback.actionID] = Task { [weak self, feedbackID = feedback.id, actionID = feedback.actionID] in
            try? await Task.sleep(for: .seconds(autoDismissAfter))
            await MainActor.run {
                guard let self else { return }
                self.activeActionFeedbacks.removeAll { $0.id == feedbackID }
                if self.actionFeedbackDismissTasks[actionID]?.isCancelled == false {
                    self.actionFeedbackDismissTasks[actionID] = nil
                }
            }
        }
    }

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
            hasAPIKey = providerConfigurations.contains { provider in
                guard let account = provider.apiKeyAccount else { return false }
                return keychainService.hasAPIKey(account: account)
            }
            
            // Hydrate Keychain Diagnostics & Mismatch Detection
            self.keychainDeepSeekKeyExists = keychainService.hasAPIKey(account: "deepseek.default")
            if self.keychainDeepSeekKeyExists {
                if let key = try? keychainService.loadAPIKey(account: "deepseek.default") {
                    self.keychainMaskedKey = KeychainService.maskKey(key)
                } else {
                    self.keychainMaskedKey = "Error reading"
                }
            } else {
                self.keychainMaskedKey = "None"
            }
            self.keychainLastReadStatus = keychainService.lastReadStatus
            self.keychainLastWriteStatus = keychainService.lastWriteStatus
            self.keychainMigrationPerformed = keychainService.migrationPerformed
            self.keychainLegacyItemFound = keychainService.legacyItemFound
            self.keychainLegacyItemCount = keychainService.legacyItemCount
            
            if self.keychainDeepSeekKeyExists {
                self.keychainMismatchStatus = "✅ DeepSeek API Key loaded successfully"
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
            injectVerificationMockData()
            if ProcessInfo.processInfo.environment["ENABLE_VERIFICATION_MOCKS"] == "1",
               let sectionStr = ProcessInfo.processInfo.environment["DEFAULT_APP_SECTION"],
               let sec = AppSection(rawValue: sectionStr) {
                self.selectedSection = sec
            }
            refreshLatencyAverages()
        } catch {
            showError(error.localizedDescription)
        }
    }

    func selectSection(_ section: AppSection) {
        selectedSection = section
    }

    func saveDocument(type: DocumentType, title: String, content: String) {
        let actionID = ActionID.saveDocument(type)
        guard !isActionLoading(actionID) else { return }
        beginAction(actionID, title: "Saving \(type.title)", message: "Saving and rebuilding clean context chunks...")
        do {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 80 else {
                warnAction(actionID, title: "More text needed", message: "Paste at least 80 characters before saving \(type.title).")
                return
            }
            let saved = try documentRepository.saveDocument(type: type, title: title, content: content)
            refreshAll()
            triggerEmbeddingGeneration(for: type)
            if saved.sanitizationWarnings?.isEmpty == false {
                warnAction(actionID, title: "Saved and cleaned", message: "LaTeX or formatting noise was cleaned for relevant context.")
            } else {
                let chunks = (try? documentRepository.chunks(type: type).count) ?? 0
                completeAction(actionID, title: "Saved and indexed", message: "\(type.title) saved. \(chunks) clean chunks are ready.")
            }
        } catch {
            let message = "Could not save \(type.title): \(error.localizedDescription)"
            failAction(actionID, title: "Save failed", message: message)
            showError(message)
        }
    }

    func deleteDocument(_ document: DocumentRecord) {
        let actionID = ActionID.clearDocument(document.type)
        guard !isActionLoading(actionID) else { return }
        beginAction(actionID, title: "Clearing \(document.type.title)", message: "Removing the saved document and refreshing context status...")
        do {
            try documentRepository.deleteDocument(id: document.id)
            refreshAll()
            completeAction(actionID, title: "Document cleared", message: "\(document.type.title) was removed.")
        } catch {
            let message = "Could not delete document: \(error.localizedDescription)"
            failAction(actionID, title: "Clear failed", message: message)
            showError(message)
        }
    }

    func saveSettings(_ newSettings: AppSettings) {
        let actionID = ActionID.saveSettings
        guard !isActionLoading(actionID) else { return }
        beginAction(actionID, title: "Saving settings", message: "Applying the latest preferences...")
        var next = newSettings
        next.compactMode = next.floatingAssistantDisplayMode == .compact
        if next.highContrastFloatingPanel {
            next.floatingWindowOpacity = max(next.floatingWindowOpacity, 0.65)
        }
        do {
            settings = next
            try settingsRepository.saveSettings(next)
            refreshAll()
            completeAction(actionID, title: "Settings saved", message: "Your settings were applied.")
        } catch {
            let message = "Could not save settings: \(error.localizedDescription)"
            failAction(actionID, title: "Save failed", message: message)
            showError(message)
        }
    }

    func saveAPIKey(_ apiKey: String) {
        let actionID = ActionID.providerSaveKey
        guard !isActionLoading(actionID) else { return }
        beginAction(actionID, title: "Saving securely", message: "Saving the provider key without displaying it.")
        do {
            try keychainService.saveAPIKey(apiKey)
            self.connectionResult = "API key securely saved."
            self.refreshAll()
            completeAction(actionID, title: "Saved securely", message: "Provider key saved. Raw key is hidden.")
        } catch {
            let message = "Could not save API key: \(error.localizedDescription)"
            failAction(actionID, title: "Key save failed", message: message)
            showError(message)
        }
    }

    func saveAPIKey(_ apiKey: String, for provider: LLMProviderConfiguration) {
        let actionID = ActionID.provider(ActionID.providerSaveKey, provider.id)
        guard !isActionLoading(actionID) else { return }
        guard let account = provider.apiKeyAccount else {
            connectionResult = "\(provider.name) does not require an API key."
            infoAction(actionID, title: "No key needed", message: "\(provider.name) does not require an API key.")
            return
        }
        beginAction(actionID, title: "Saving securely", message: "Saving \(provider.name) key without displaying it.")
        do {
            try keychainService.saveAPIKey(apiKey, account: account)
            self.providerConnectionResults[provider.id] = "API key securely saved."
            self.refreshAll()
            completeAction(actionID, title: "Saved securely", message: "\(provider.name) key saved. Raw key is hidden.")
        } catch {
            let message = "Could not save API key: \(error.localizedDescription)"
            failAction(actionID, title: "Key save failed", message: message)
            showError(message)
        }
    }

    func saveEmbeddingAPIKey(_ apiKey: String, account: String) {
        let actionID = ActionID.saveEmbeddingKey
        guard !isActionLoading(actionID) else { return }
        let cleanedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedAccount.isEmpty else {
            let message = "Embedding API key account is missing."
            failAction(actionID, title: "Key save failed", message: message)
            showError(message)
            return
        }
        beginAction(actionID, title: "Saving securely", message: "Saving the embedding provider key without displaying it.")
        do {
            try keychainService.saveAPIKey(apiKey, account: cleanedAccount)
            lastEmbeddingError = nil
            lastEmbeddingTestStatus = "Embedding API key securely saved."
            refreshAll()
            completeAction(actionID, title: "Saved securely", message: "Embedding key saved. Raw key is hidden.")
        } catch {
            let message = "Could not save embedding API key: \(error.localizedDescription)"
            failAction(actionID, title: "Key save failed", message: message)
            showError(message)
        }
    }

    func embeddingKeyStatus(account: String) -> String {
        let cleanedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedAccount.isEmpty else { return "No account configured" }
        guard keychainService.hasAPIKey(account: cleanedAccount) else { return "Missing" }
        do {
            return KeychainService.maskKey(try keychainService.loadAPIKey(account: cleanedAccount) ?? "")
        } catch {
            return "Configured, unreadable"
        }
    }

    func testEmbeddingProvider() {
        let actionID = ActionID.providerTest
        guard !isActionLoading(actionID) else { return }
        guard settings.embeddingProviderKind != .disabled else {
            lastEmbeddingError = nil
            lastEmbeddingTestStatus = "Keyword RAG ready; vector embeddings not configured."
            infoAction(actionID, title: "Keyword search ready", message: "Cloud embeddings are not configured.")
            return
        }
        guard let provider = resolveEmbeddingProvider() else {
            lastEmbeddingTestStatus = "Keyword RAG ready; vector embeddings not configured."
            warnAction(actionID, title: "Embedding key missing", message: "Keyword search remains ready. Add a cloud embedding key to test embeddings.")
            return
        }

        beginAction(actionID, title: "Testing embeddings", message: "Sending a small provider test request...")
        isTestingConnection = true
        lastEmbeddingError = nil
        activeAITask?.cancel()
        activeAITask = Task { [weak self] in
            guard let self else { return }
            let started = Date()
            do {
                let vector = try await provider.embed(text: "Embedding provider connection test.")
                guard !Task.isCancelled else { return }
                let latency = Int(Date().timeIntervalSince(started) * 1000)
                self.lastEmbeddingTestStatus = "Connected. Dimension \(vector.count), latency \(latency) ms."
                self.lastEmbeddingError = nil
                self.completeAction(actionID, title: "Embedding provider connected", message: "Dimension \(vector.count), latency \(latency) ms.")
            } catch {
                guard !Task.isCancelled else { return }
                self.lastEmbeddingTestStatus = "Embedding provider test failed."
                self.lastEmbeddingError = self.userFacing(error)
                self.failAction(actionID, title: "Embedding test failed", message: self.userFacing(error))
            }
            self.isTestingConnection = false
        }
    }

    func deleteAPIKey() {
        do {
            try keychainService.deleteAPIKey()
            self.connectionResult = "API key removed."
            self.refreshAll()
        } catch {
            showError("Could not remove API key: \(error.localizedDescription)")
        }
    }

    func saveProviderConfiguration(_ provider: LLMProviderConfiguration) {
        let actionID = ActionID.provider(ActionID.providerSave, provider.id)
        guard !isActionLoading(actionID) else { return }
        beginAction(actionID, title: "Saving provider", message: "Saving \(provider.name) configuration...")
        do {
            try settingsRepository.saveProviderConfiguration(provider)
            refreshAll()
            completeAction(actionID, title: "Provider saved", message: "\(provider.name) configuration saved.")
        } catch {
            let message = "Could not save provider: \(error.localizedDescription)"
            failAction(actionID, title: "Provider save failed", message: message)
            showError(message)
        }
    }

    func deleteProviderConfiguration(_ provider: LLMProviderConfiguration) {
        let actionID = ActionID.provider(ActionID.providerDelete, provider.id)
        guard !isActionLoading(actionID) else { return }
        beginAction(actionID, title: "Deleting provider", message: "Removing \(provider.name)...")
        do {
            try settingsRepository.deleteProviderConfiguration(id: provider.id)
            refreshAll()
            completeAction(actionID, title: "Provider deleted", message: "\(provider.name) was removed.")
        } catch {
            let message = "Could not delete provider: \(error.localizedDescription)"
            failAction(actionID, title: "Provider delete failed", message: message)
            showError(message)
        }
    }

    func setActiveRealtimeProvider(_ provider: LLMProviderConfiguration) {
        let actionID = ActionID.providerSwitch
        guard !isActionLoading(actionID) else { return }
        beginAction(actionID, title: "Switching provider", message: "Setting \(provider.name) for realtime answers...")
        do {
            try settingsRepository.setActiveRealtimeProvider(id: provider.id)
            refreshAll()
            completeAction(actionID, title: "Provider switched", message: "\(provider.name) is now used for realtime answers.")
        } catch {
            let message = "Could not set realtime provider: \(error.localizedDescription)"
            failAction(actionID, title: "Provider switch failed", message: message)
            showError(message)
        }
    }

    func updateActiveRealtimeProvider(provider: LLMProviderConfiguration, model: String?) {
        let actionID = ActionID.providerSwitch
        guard !isActionLoading(actionID) else { return }
        beginAction(actionID, title: "Switching provider", message: "Checking \(provider.name) configuration...")
        activeAITask?.cancel()
        errorMessage = nil
        lastProviderSwitchError = nil
        lastProviderSwitchTimestamp = Date()
        
        var updated = provider
        if let model = model {
            updated.model = model
        }
        
        do {
            if updated.kind == .ollamaLocal {
                let msg = "Local providers are disabled. Please choose DeepSeek or another API provider."
                self.lastProviderSwitchError = msg
                self.errorMessage = "Could not switch provider: \(msg)"
                failAction(actionID, title: "Provider switch failed", message: msg)
                return
            } else if updated.kind == .deepSeek || updated.kind == .openAICompatible {
                guard let account = updated.apiKeyAccount,
                      keychainService.hasAPIKey(account: account) else {
                    let msg = "Missing API Key for \(updated.name)."
                    self.lastProviderSwitchError = msg
                    self.errorMessage = "Could not switch provider: \(msg)"
                    failAction(actionID, title: "Provider switch failed", message: msg)
                    return
                }
                
                try settingsRepository.saveProviderConfiguration(updated)
                try settingsRepository.setActiveRealtimeProvider(id: updated.id)
                refreshAll()
            } else {
                try settingsRepository.saveProviderConfiguration(updated)
                try settingsRepository.setActiveRealtimeProvider(id: updated.id)
                refreshAll()
            }
            completeAction(actionID, title: "Provider switched", message: "\(updated.name) \(updated.model) is active.")
        } catch {
            let msg = error.localizedDescription
            self.lastProviderSwitchError = msg
            self.errorMessage = "Could not switch provider: \(msg)"
            failAction(actionID, title: "Provider switch failed", message: msg)
        }
    }

    func setActiveRecapProvider(_ provider: LLMProviderConfiguration) {
        let actionID = ActionID.provider(ActionID.providerSave, provider.id)
        guard !isActionLoading(actionID) else { return }
        beginAction(actionID, title: "Saving recap provider", message: "Setting \(provider.name) for full answers and recaps...")
        do {
            try settingsRepository.setActiveRecapProvider(id: provider.id)
            refreshAll()
            completeAction(actionID, title: "Recap provider saved", message: "\(provider.name) is now used for recaps.")
        } catch {
            let message = "Could not set recap provider: \(error.localizedDescription)"
            failAction(actionID, title: "Provider save failed", message: message)
            showError(message)
        }
    }

    func testProviderConnection(_ provider: LLMProviderConfiguration) {
        let actionID = ActionID.provider(ActionID.providerTest, provider.id)
        guard !isActionLoading(actionID) else { return }
        beginAction(actionID, title: "Testing \(provider.name)", message: "Testing provider connection...")
        isTestingConnection = true
        providerConnectionResults[provider.id] = nil
        activeAITask?.cancel()
        activeAITask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await llmRouter.testProvider(configuration: provider)
                guard !Task.isCancelled else { return }
                providerConnectionResults[provider.id] = result.message
                completeAction(actionID, title: "\(provider.name) connected", message: result.message)
                updateDiagnostics {
                    $0.lastAPILatencyMS = result.latencyMS
                    $0.lastProviderName = provider.name
                    $0.lastProviderModel = provider.model
                }
            } catch {
                guard !Task.isCancelled else { return }
                let message = self.userFacing(error)
                providerConnectionResults[provider.id] = message
                self.failAction(actionID, title: "\(provider.name) test failed", message: message)
                updateDiagnostics { $0.lastError = message }
            }
            isTestingConnection = false
        }
    }

    func retryLastFailedAITask() {
        guard let taskType = lastFailedTaskType, let session = currentSession else {
            return
        }
        
        self.errorMessage = nil
        
        activeAITask?.cancel()
        activeAITask = Task { [weak self] in
            guard let self else { return }
            switch taskType {
            case .questionDetection:
                let transcript = self.lastFailedTranscriptContext
                await self.runAutomaticDetection(session: session, transcript: transcript, triggeringSegmentID: nil)
            case .suggestionGeneration:
                guard let question = self.lastFailedQuestion else { return }
                let transcript = self.lastFailedTranscriptContext
                do {
                    self.lastFailedTaskType = nil
                    try await self.generateSuggestion(for: question, session: session, transcript: transcript, autoGenerated: false)
                } catch {
                    guard !Task.isCancelled else { return }
                    let message = self.userFacing(error)
                    self.liveState = .error(message)
                    self.showError(message)
                }
            }
        }
    }

    func switchToDeepSeekFallback() {
        guard let deepSeekProvider = providerConfigurations.first(where: { $0.kind == .deepSeek }) else {
            showError("DeepSeek provider not configured. Please configure it in Provider Settings.")
            return
        }
        
        let alert = NSAlert()
        alert.messageText = "Confirm Cloud Fallback"
        alert.informativeText = "Switching to DeepSeek will send your recent transcript and CV/JD context snippets to DeepSeek cloud APIs. Do you want to proceed?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Proceed")
        alert.addButton(withTitle: "Cancel")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            setActiveRealtimeProvider(deepSeekProvider)
            retryLastFailedAITask()
        }
    }

    func testDeepSeekConnection() {
        let actionID = ActionID.testDeepSeek
        guard !isActionLoading(actionID) else { return }
        guard let provider = providerConfigurations.first(where: { $0.kind == .deepSeek }) else {
            connectionResult = "DeepSeek provider is not configured."
            failAction(actionID, title: "DeepSeek not configured", message: "Add DeepSeek in Settings before testing.")
            return
        }
        guard provider.apiKeyAccount.map({ keychainService.hasAPIKey(account: $0) }) ?? false else {
            connectionResult = "Add a DeepSeek API key before testing the connection."
            failAction(actionID, title: "DeepSeek key missing", message: "Save a DeepSeek API key before testing.")
            return
        }
        beginAction(actionID, title: "Testing DeepSeek", message: "Checking the saved key and model endpoint...")
        isTestingConnection = true
        connectionResult = nil
        activeAITask?.cancel()
        activeAITask = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await llmRouter.testProvider(configuration: provider)
                guard !Task.isCancelled else { return }
                connectionResult = response.message
                completeAction(actionID, title: "DeepSeek connected", message: response.message)
                updateDiagnostics {
                    $0.lastAPILatencyMS = response.latencyMS
                    $0.lastProviderName = provider.name
                    $0.lastProviderModel = provider.model
                }
            } catch {
                guard !Task.isCancelled else { return }
                connectionResult = self.userFacing(error)
                failAction(actionID, title: "DeepSeek test failed", message: self.userFacing(error))
                updateDiagnostics { $0.lastError = self.userFacing(error) }
            }
            isTestingConnection = false
        }
    }

    func startListening(mode: InterviewMode) {
        let actionID = ActionID.startInterview
        guard !isActionLoading(actionID) else { return }
        guard onboardingComplete else {
            let message = liveBlockedReason ?? "Run the readiness check before starting."
            failAction(actionID, title: "Setup incomplete", message: message)
            showError(message)
            return
        }
        guard liveState.canStartListening else {
            warnAction(actionID, title: "Already running", message: "Stop listening before starting a new interview.")
            return
        }
        beginAction(actionID, title: "Starting audio", message: "Starting \(settings.audioCaptureMode.shortDisplayName) capture...")
        errorMessage = nil
        possibleQuestion = nil
        activeAITask?.cancel()
        detectionDebounceTask?.cancel()
        transcriptionTask?.cancel()

        Task { [weak self] in
            guard let self else { return }
            await self.startListeningAsync(mode: mode)
        }
    }

    private func startListeningAsync(mode: InterviewMode) async {
        currentCaptureRuntimeState = .starting
        self.stopReason = nil
        self.lastCaptureStartedAt = Date()
        addCaptureEvent(name: "startListeningAsync", stateBefore: "idle", stateAfter: "starting", reason: "userRequested")
        
        do {
            liveState = .requestingPermission
            refreshPermissions()
            if mode == .microphone {
                let captureMode = settings.audioCaptureMode
                let microphoneRequired = (captureMode == .microphoneOnly || captureMode == .microphoneAndSystem)
                let speechRecognitionRequired = microphoneRequired
                let systemAudioRequired = (captureMode == .systemAudioOnly || captureMode == .microphoneAndSystem)
                
                print("[StartListening] captureMode = \(captureMode.rawValue)")
                print("[StartListening] microphoneRequired = \(microphoneRequired)")
                print("[StartListening] speechRecognitionRequired = \(speechRecognitionRequired)")
                print("[StartListening] systemAudioRequired = \(systemAudioRequired)")
                
                let micStatusBefore = permissionService.checkMicrophonePermission()
                print("[Permission] microphone status before request = \(micStatusBefore.rawValue)")
                
                if microphoneRequired {
                    var microphone = micStatusBefore
                    if microphone == .notDetermined {
                        microphone = await permissionService.requestMicrophonePermission()
                        refreshPermissions()
                    } else if microphone == .authorized {
                        // Success immediately, do not prompt/error
                    } else {
                        print("[Permission] Microphone request bypassed (already \(microphone.rawValue))")
                    }
                    
                    let micStatusAfter = permissionService.checkMicrophonePermission()
                    print("[Permission] microphone request result = \(micStatusAfter.rawValue)")
                    
                    guard micStatusAfter == .authorized else {
                        liveState = .permissionDenied
                        currentCaptureRuntimeState = .stopped(reason: .permissionDenied)
                        addCaptureEvent(name: "listeningStopped", stateBefore: "starting", stateAfter: "stopped", reason: "permissionDenied")
                        let message = "Grant microphone permission to start live transcription. You can change this in macOS Privacy & Security settings."
                        failAction(ActionID.startInterview, title: "Microphone permission needed", message: message)
                        showError(message)
                        return
                    }
                    
                    var speech = permissionService.speechStatus()
                    if speech == .notDetermined {
                        speech = await permissionService.requestSpeechRecognition()
                        refreshPermissions()
                    }
                    
                    guard speech == .granted else {
                        liveState = .permissionDenied
                        currentCaptureRuntimeState = .stopped(reason: .permissionDenied)
                        addCaptureEvent(name: "listeningStopped", stateBefore: "starting", stateAfter: "stopped", reason: "permissionDenied")
                        let message = "Speech Recognition permission is required for Apple Speech transcription. Grant access in macOS Privacy & Security settings, or use Practice Testing."
                        failAction(ActionID.startInterview, title: "Speech permission needed", message: message)
                        showError(message)
                        return
                    }
                } else {
                    print("[Permission] microphone request result = notRequired")
                }
                
                if systemAudioRequired {
                    let probeResult = await ScreenSystemAudioPermissionProbe.shared.probe()
                    let state = determineProbeState(result: probeResult)
                    
                    self.systemAudioProbeResult = probeResult
                    self.systemAudioPermissionState = state
                    
                    if state == .granted {
                        // Success! Continue
                    } else {
                        if !probeResult.preflightGranted {
                            permissionService.requestScreenRecording()
                            try? await Task.sleep(for: .milliseconds(1000))
                            
                            let finalProbe = await ScreenSystemAudioPermissionProbe.shared.probe()
                            let finalState = determineProbeState(result: finalProbe)
                            self.systemAudioProbeResult = finalProbe
                            self.systemAudioPermissionState = finalState
                            
                            if finalState == .granted {
                                // Succeeded after prompt
                            } else {
                                liveState = .permissionDenied
                                currentCaptureRuntimeState = .stopped(reason: .permissionDenied)
                                addCaptureEvent(name: "listeningStopped", stateBefore: "starting", stateAfter: "stopped", reason: "permissionDenied")
                                switch finalState {
                                case .permissionMissing:
                                    let message = "Enable Screen & System Audio Recording in System Settings to capture interviewer audio."
                                    failAction(ActionID.startInterview, title: "Permission needed", message: message)
                                    showError(message)
                                case .restartLikely:
                                    let message = "macOS requires restarting the application for Screen & System Audio Recording to take effect."
                                    failAction(ActionID.startInterview, title: "Restart required", message: message)
                                    showError(message)
                                case .identityMismatch:
                                    let message = "Application identity mismatch suspected. macOS permissions may not match System Settings."
                                    failAction(ActionID.startInterview, title: "Permission mismatch", message: message)
                                    showError(message)
                                case .shareableContentProbeFailed(let err):
                                    let message = "ScreenCaptureKit shareable content probe failed: \(err)"
                                    failAction(ActionID.startInterview, title: "System audio failed", message: message)
                                    showError(message)
                                case .streamAudioProbeFailed(let err):
                                    let message = "System audio capture stream failed: \(err)"
                                    failAction(ActionID.startInterview, title: "System audio failed", message: message)
                                    showError(message)
                                case .granted:
                                    break
                                }
                                return
                            }
                        } else {
                            liveState = .permissionDenied
                            currentCaptureRuntimeState = .stopped(reason: .permissionDenied)
                            addCaptureEvent(name: "listeningStopped", stateBefore: "starting", stateAfter: "stopped", reason: "permissionDenied")
                            switch state {
                            case .restartLikely:
                                let message = "macOS requires restarting the application for Screen & System Audio Recording to take effect."
                                failAction(ActionID.startInterview, title: "Restart required", message: message)
                                showError(message)
                            case .identityMismatch:
                                let message = "Application identity mismatch suspected. macOS permissions may not match System Settings."
                                failAction(ActionID.startInterview, title: "Permission mismatch", message: message)
                                showError(message)
                            case .shareableContentProbeFailed(let err):
                                let message = "ScreenCaptureKit shareable content probe failed: \(err)"
                                failAction(ActionID.startInterview, title: "System audio failed", message: message)
                                showError(message)
                            case .streamAudioProbeFailed(let err):
                                let message = "System audio capture stream failed: \(err)"
                                failAction(ActionID.startInterview, title: "System audio failed", message: message)
                                showError(message)
                            case .permissionMissing:
                                let message = "Enable Screen & System Audio Recording in System Settings to capture interviewer audio."
                                failAction(ActionID.startInterview, title: "Permission needed", message: message)
                                showError(message)
                            case .granted:
                                break
                            }
                            return
                        }
                    }
                }
                refreshPermissions()
            }

            let session: InterviewSession
            if let currentSession {
                session = currentSession
            } else {
                session = try sessionRepository.createSession(mode: mode)
            }
            currentSession = session
            if transcriptSegments.isEmpty {
                transcriptSegments.append(.system("Live interview session started in \(mode.displayName). Mode: \(settings.audioCaptureMode.displayName)", sessionID: session.id))
            }

            if mode == .mock {
                let provider = mockTranscriptionService
                activeTranscriptionProvider = provider
                try await provider.start(sessionID: session.id)
                liveState = .listening
                showFloatingAssistant()
                consumeSegments(from: provider)
                completeAction(ActionID.startInterview, title: "Listening started", message: "Practice capture is active.")
            } else {
                let captureMode = settings.audioCaptureMode
                print("[DualAudio] mode = \(captureMode.rawValue)")
                
                if captureMode == .systemAudioOnly {
                    self.lastSystemAudioASRPartialTranscript = ""
                    self.microphoneDiagnostics.stopMicTest()
                    print("[DualAudio] Cleaned up buffers & diagnostics for System Audio Only mode")
                }
                
                let speechService = AppleSpeechTranscriptionService()
                self.appleSpeechService = speechService
                self.activeTranscriptionProvider = speechService
                
                speechService.onSessionStateChanged = { [weak self] in
                    Task { @MainActor in
                        self?.objectWillChange.send()
                    }
                }
                
                self.lastSystemAudioASRError = nil
                self.lastSystemAudioASRPartialTranscript = ""
                self.lastSystemAudioASRFinalTranscript = ""
                
                try await speechService.start(sessionID: session.id, captureMode: captureMode)
                
                transcriptionTask = Task { [weak self] in
                    for await segment in speechService.segments {
                        guard !Task.isCancelled else { return }
                        await self?.handleTranscriptSegment(segment)
                    }
                }
                
                if captureMode == .microphoneOnly || captureMode == .microphoneAndSystem {
                    // Keep diagnostics active during transcription for real-time visual levels
                    microphoneDiagnostics.refreshSelectedInputDevice()
                    AudioEngineManager.shared.register(microphoneDiagnostics)
                }
                
                liveState = .listening
                currentCaptureRuntimeState = .listening
                addCaptureEvent(name: "listeningActive", stateBefore: "starting", stateAfter: "listening", reason: "captureActive")
                showFloatingAssistant()
                completeAction(ActionID.startInterview, title: "Listening started", message: "\(captureMode.shortDisplayName) is active.")
                
                // Start background silence / signal validation
                startAudioSignalMonitoring()
            }
        } catch {
            let message = userFacing(error)
            liveState = .error(message)
            currentCaptureRuntimeState = .error(reason: message)
            addCaptureEvent(name: "startListeningFailed", stateBefore: "starting", stateAfter: "error", reason: message)
            failAction(ActionID.startInterview, title: "Could not start", message: message)
            showError(message)
        }
    }

    func stopListening(
        reason: StopReason = .userRequested,
        file: String = #file,
        line: Int = #line,
        function: String = #function
    ) {
        if reason == .userRequested {
            beginAction(ActionID.stopListening, title: "Stopping", message: "Stopping audio capture and preserving the current answer...")
        }
        let stateBefore = currentCaptureRuntimeState.displayName
        currentCaptureRuntimeState = .stopping
        self.stopReason = reason
        self.lastCaptureStoppedAt = Date()
        
        print("[CaptureState] stopListening reason = \(reason)")
        print("[CaptureState] systemCaptureRunning before stop = \(systemCaptureRunning)")
        print("[CaptureState] called from = \(file.split(separator: "/").last ?? ""):\(line) - \(function)")
        
        addCaptureEvent(
            name: "stopListening",
            stateBefore: stateBefore,
            stateAfter: "stopping",
            reason: reason.rawValue,
            file: file,
            line: line,
            function: function
        )
        
        cancelStageBTask()
        activeAITask?.cancel()
        detectionDebounceTask?.cancel()
        transcriptionTask?.cancel()
        
        activeTranscriptionProvider?.stop()
        activeTranscriptionProvider = nil
        
        appleSpeechService?.stop()
        appleSpeechService = nil
        
        // Stop diagnostics level metering
        AudioEngineManager.shared.unregister(microphoneDiagnostics)
        microphoneDiagnostics.stopMicTest()
        
        stopAudioSignalMonitoring()
        recentQuestionsFingerprints.removeAll()
        
        lastSystemAudioTranscript = ""
        lastSystemAudioASRError = nil
        lastQuestionDetectionResult = "No question detected yet."
        lastDetectedQuestionText = ""
        lastDetectionConfidence = 0.0
        lastDetectionShouldTrigger = false
        lastDetectionReason = ""
        lastDetectionRawJSON = ""
        lastDetectionSkipReason = ""
        
        // Reset ASR, Segment, Detection, and Suggestion Diagnostics
        systemASRTaskRunning = false
        totalSystemAudioASRBuffersAppended = 0
        lastSystemAudioASRPartialTranscript = ""
        lastSystemAudioASRFinalTranscript = ""
        recognitionRequestActive = false
        recognitionTaskActive = false
        last10SegmentsDiagnostics = []
        lastDetectionSubmittedSegmentText = ""
        lastDetectionPromptSource = ""
        lastDetectionPromptSpeaker = ""
        lastDetectionQuestionComplete = false
        lastDetectionAnswerStrategy = ""
        suggestionGenerationStarted = false
        suggestionProviderModel = ""
        ragRetrievalLatencyMS = nil
        asrFirstPartialMS = nil
        asrFinalMS = nil
        asrBestSelectedMS = nil
        lastSuggestionCardJSON = ""
        floatingPanelUpdated = false
        
        if let sessionID = currentSession?.id {
            try? sessionRepository.endSession(id: sessionID)
        }
        liveState = .stopped
        currentCaptureRuntimeState = .stopped(reason: reason)
        
        addCaptureEvent(
            name: "listeningStopped",
            stateBefore: "stopping",
            stateAfter: "stopped",
            reason: reason.rawValue,
            file: file,
            line: line,
            function: function
        )
        
        refreshAll()
        if reason == .userRequested {
            completeAction(ActionID.stopListening, title: "Listening stopped", message: "The latest suggestion remains visible.")
        }
    }
 
    func clearLiveSession() {
        beginAction(ActionID.clearLiveSession, title: "Clearing session", message: "Removing current transcript, question, and answer from the live workspace...")
        let stateBefore = currentCaptureRuntimeState.displayName
        cancelStageBTask()
        activeAITask?.cancel()
        detectionDebounceTask?.cancel()
        transcriptionTask?.cancel()
        
        activeTranscriptionProvider?.stop()
        activeTranscriptionProvider = nil
        
        // Ensure diagnostics are unregistered
        AudioEngineManager.shared.unregister(microphoneDiagnostics)
        microphoneDiagnostics.stopMicTest()
        
        stopAudioSignalMonitoring()
        recentQuestionsFingerprints.removeAll()
        
        currentSession = nil
        transcriptSegments = []
        currentSuggestion = nil
        lastDetectedQuestion = nil
        possibleQuestion = nil
        lastTranscriptSnippet = ""
        lastAutoQuestionText = nil
        errorMessage = nil
        liveState = .idle
        currentCaptureRuntimeState = .idle
        
        addCaptureEvent(name: "clearLiveSession", stateBefore: stateBefore, stateAfter: "idle", reason: "sessionCleared")
        completeAction(ActionID.clearLiveSession, title: "Session cleared", message: "Ready for a new question.")
    }

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

    func manualAnswerNow() {
        guard !isActionLoading(ActionID.generateAnswer) else { return }
        guard liveState.canAnswerNow else {
            warnAction(ActionID.generateAnswer, title: "Answer already running", message: "Wait for the current generation to finish before retrying.")
            return
        }
        guard onboardingComplete else {
            let message = liveBlockedReason ?? "Run the readiness check before generating an answer."
            failAction(ActionID.generateAnswer, title: "Setup incomplete", message: message)
            showError(message)
            return
        }
        guard let session = currentSession ?? (try? sessionRepository.createSession(mode: .mock)) else {
            let message = "Could not create an interview session."
            failAction(ActionID.generateAnswer, title: "Generation failed", message: message)
            showError(message)
            return
        }
        currentSession = session
        let transcript = recentTranscriptText()
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let message = "There is no transcript yet. Start Listening first, or use Practice / Developer Testing to inject a test question."
            failAction(ActionID.generateAnswer, title: "No transcript yet", message: message)
            showError(message)
            return
        }

        beginAction(ActionID.generateAnswer, title: "Generating first answer", message: "Transcript is preserved while DeepSeek prepares the answer.")
        activeAITask?.cancel()
        activeAITask = Task { [weak self] in
            guard let self else { return }
            await self.runManualAnswer(session: session, transcript: transcript)
        }
    }

    func generateRecap(for session: InterviewSession) {
        guard !isActionLoading(ActionID.sessionRecap) else { return }
        beginAction(ActionID.sessionRecap, title: "Generating recap", message: "Summarizing transcript and relevant context...")
        isGeneratingRecap = true
        activeAITask?.cancel()
        activeAITask = Task { [weak self] in
            guard let self else { return }
            do {
                let transcript = try transcriptRepository.segments(sessionID: session.id)
                let (context, trace) = try await contextRetrievalService.retrieveContextWithTrace(
                    question: transcript.map(\.text).joined(separator: "\n"),
                    intent: .unclear,
                    maxCVWords: 1_500,
                    maxJDWords: 1_000
                )
                self.lastRetrievalTrace = trace
                let result = try await recapGenerationService.generate(
                    session: session,
                    transcript: transcript,
                    context: context,
                    model: activeRecapProvider?.model
                )
                guard !Task.isCancelled else { return }
                try recapRepository.saveRecap(result.recap)
                selectedSessionRecap = result.recap
                updateDiagnostics {
                    $0.lastAPILatencyMS = result.response.latencyMS
                    $0.apiCallCount = (try? self.settingsRepository.apiCallCount()) ?? $0.apiCallCount
                }
                completeAction(ActionID.sessionRecap, title: "Recap ready", message: "Session recap is visible.")
            } catch {
                guard !Task.isCancelled else { return }
                let message = userFacing(error)
                failAction(ActionID.sessionRecap, title: "Recap failed", message: message)
                showError(message)
            }
            isGeneratingRecap = false
        }
    }

    func exportSelectedRecap() {
        guard let recap = selectedSessionRecap,
              let session = sessions.first(where: { $0.id == recap.sessionID }) else {
            warnAction(ActionID.sessionExport, title: "Nothing to export", message: "Generate a recap before exporting.")
            return
        }
        guard !isActionLoading(ActionID.sessionExport) else { return }
        beginAction(ActionID.sessionExport, title: "Exporting recap", message: "Writing Markdown file...")
        do {
            let url = try recapRepository.exportMarkdown(recap: recap, sessionTitle: session.title)
            connectionResult = "Exported recap to \(url.path)."
            completeAction(ActionID.sessionExport, title: "Recap exported", message: url.lastPathComponent)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            let message = "Could not export recap: \(error.localizedDescription)"
            failAction(ActionID.sessionExport, title: "Export failed", message: message)
            showError(message)
        }
    }

    func loadSessionDetails(sessionID: String) {
        selectedSessionID = sessionID
        do {
            selectedSessionTranscript = try transcriptRepository.segments(sessionID: sessionID)
            selectedSessionSuggestions = try suggestionRepository.suggestions(sessionID: sessionID)
            selectedSessionRecap = try recapRepository.recap(sessionID: sessionID)
            
            var chunksDict: [String: [RetrievedChunk]] = [:]
            for card in selectedSessionSuggestions {
                chunksDict[card.id] = (try? suggestionRepository.retrievedChunks(suggestionCardID: card.id)) ?? []
            }
            historicalSuggestionChunks = chunksDict
        } catch {
            showError("Could not load session: \(error.localizedDescription)")
        }
    }

    func deleteSession(_ session: InterviewSession) {
        guard !isActionLoading(ActionID.sessionDelete) else { return }
        beginAction(ActionID.sessionDelete, title: "Deleting session", message: "Removing \(session.title)...")
        do {
            try sessionRepository.deleteSession(id: session.id)
            if selectedSessionID == session.id {
                selectedSessionID = nil
                selectedSessionTranscript = []
                selectedSessionSuggestions = []
                selectedSessionRecap = nil
            }
            refreshAll()
            completeAction(ActionID.sessionDelete, title: "Session deleted", message: "\(session.title) was removed.")
        } catch {
            let message = "Could not delete session: \(error.localizedDescription)"
            failAction(ActionID.sessionDelete, title: "Delete failed", message: message)
            showError(message)
        }
    }

    func deleteAllLocalData(includeAPIKey: Bool) {
        guard !isActionLoading(ActionID.clearLocalData) else { return }
        beginAction(ActionID.clearLocalData, title: "Clearing local data", message: "Stopping capture and deleting local app data...")
        stopListening()
        do {
            if includeAPIKey {
                for account in providerConfigurations.compactMap(\.apiKeyAccount) {
                    try? keychainService.deleteAPIKey(account: account)
                }
            }
            try localDataService.deleteAllLocalData(includeAPIKey: includeAPIKey)
            clearLiveSession()
            refreshAll()
            completeAction(ActionID.clearLocalData, title: "Local data cleared", message: includeAPIKey ? "Documents, sessions, transcripts, and saved keys were cleared." : "Documents, sessions, and transcripts were cleared.")
        } catch {
            let message = "Could not delete local data: \(error.localizedDescription)"
            failAction(ActionID.clearLocalData, title: "Clear failed", message: message)
            showError(message)
        }
    }

    func requestMicrophonePermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .authorized {
            refreshPermissions()
            return
        }
        if status == .denied || status == .restricted {
            openMicrophonePrivacySettings()
            refreshPermissions()
            return
        }
        Task {
            _ = await permissionService.requestMicrophonePermission()
            refreshPermissions()
        }
    }

    func requestSpeechPermission() {
        Task {
            _ = await permissionService.requestSpeechRecognition()
            refreshPermissions()
        }
    }

    func requestScreenRecordingPermission() {
        permissionService.requestScreenRecording()
        refreshPermissions()
    }

    func openSystemPrivacySettings() {
        permissionService.openSystemPrivacySettings()
    }

    func openMicrophonePrivacySettings() {
        permissionService.openPrivacySettings()
    }

    func refreshPermissions() {
        microphonePermissionState = permissionService.checkMicrophonePermission()
        permissionSnapshot = permissionService.refreshPermissions()
        microphoneDiagnostics.refreshSelectedInputDevice()
        
        Task {
            await refreshScreenSystemAudioProbe()
        }
    }
    
    func refreshScreenSystemAudioProbe() async {
        let result = await ScreenSystemAudioPermissionProbe.shared.probe()
        let state = determineProbeState(result: result)
        
        await MainActor.run {
            self.systemAudioProbeResult = result
            self.systemAudioPermissionState = state
            
            if state == .granted {
                self.permissionSnapshot.screenRecording = .granted
                self.permissionSnapshot.systemAudioCapture = .granted
            } else {
                self.permissionSnapshot.screenRecording = .denied
                self.permissionSnapshot.systemAudioCapture = .denied
            }
        }
    }
    
    func determineProbeState(result: ScreenSystemAudioPermissionProbeResult) -> ScreenSystemAudioPermissionState {
        if result.shareableContentProbeSucceeded {
            if result.likelyIdentityMismatch {
                return .identityMismatch
            }
            if !result.streamAudioProbeSucceeded {
                return .streamAudioProbeFailed(result.errorDescription ?? "Stream audio timeout")
            }
            return .granted
        } else {
            if result.preflightGranted {
                if result.likelyIdentityMismatch {
                    return .identityMismatch
                }
                return .restartLikely
            } else {
                if result.likelyIdentityMismatch {
                    return .identityMismatch
                }
                return .permissionMissing
            }
        }
    }

    func showFloatingAssistant() {
        beginAction(ActionID.showFloatingPanel, title: "Opening floating panel", message: "Bringing the answer card to the front...")
        FloatingAssistantPanelController.shared.show(appState: self)
        isFloatingAssistantVisible = true
        completeAction(ActionID.showFloatingPanel, title: "Floating panel visible", message: "The answer card is ready.")
    }

    func hideFloatingAssistant() {
        FloatingAssistantPanelController.shared.hide()
        isFloatingAssistantVisible = false
        infoAction(ActionID.showFloatingPanel, title: "Floating panel hidden", message: "Use Show Floating Panel to bring it back.")
    }

    func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where !(window is NSPanel) {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func consumeSegments(from provider: TranscriptionProvider) {
        transcriptionTask = Task { [weak self] in
            for await segment in provider.segments {
                guard !Task.isCancelled else { return }
                await self?.handleTranscriptSegment(segment)
            }
        }
    }

    func handleTranscriptSegment(_ segment: TranscriptSegment) async {
        print("[AppState] Received segment: id = \(segment.id) | source = \(segment.source.rawValue) | speaker = \(segment.speaker.rawValue) | text = \"\(segment.text)\"")
        liveState = .transcribing
        
        if let index = transcriptSegments.firstIndex(where: { $0.id == segment.id }) {
            transcriptSegments[index] = segment
        } else {
            transcriptSegments.append(segment)
        }
        
        lastTranscriptSnippet = segment.text
        if segment.source == .systemAudio {
            lastSystemTranscript = segment.text
        }
        currentSession = currentSession ?? (try? sessionRepository.session(id: segment.sessionID))
        if settings.saveTranscriptsLocally {
            try? transcriptRepository.saveSegment(segment)
        }

        // Background debounced RAG precompute
        if segment.source == .systemAudio && segment.speaker == .interviewer {
            let words = segment.text.split(whereSeparator: \.isWhitespace)
            if words.count >= 6 { // 5-7 words range
                precomputeDebounceTask?.cancel()
                precomputeDebounceTask = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: 400_000_000) // 300-500ms debounce
                    } catch {
                        return
                    }
                    guard let self = self, !Task.isCancelled else { return }
                    
                    let key = segment.id + "_" + self.normalizedTextHash(segment.text)
                    do {
                        let (context, trace) = try await self.contextRetrievalService.retrieveContextWithTrace(
                            question: segment.text,
                            intent: .unclear,
                            maxCVWords: 240,
                            maxJDWords: 120
                        )
                        await MainActor.run {
                            self.precomputedRAGCache[key] = RAGPrecomputeCacheItem(
                                context: context,
                                trace: trace,
                                rawText: segment.text
                            )
                            print("[PrecomputeRAG] Cached RAG context for segmentID: \(segment.id) | key: \(key)")
                        }
                    } catch {
                        print("[PrecomputeRAG] Background RAG precompute failed: \(error)")
                    }
                }
            }
        }

        // Echo/Leakage Protection sliding window update
        if segment.source == .systemAudio {
            recentSystemAudioRecords.append(RecentSystemAudioRecord(text: segment.text, timestamp: Date()))
            recentSystemAudioRecords.removeAll { Date().timeIntervalSince($0.timestamp) > 5.0 }
            
            // Set last system audio transcript
            self.lastSystemAudioTranscript = segment.text
        }

        var isEchoLeakage = false
        if segment.source == .microphone {
            recentSystemAudioRecords.removeAll { Date().timeIntervalSince($0.timestamp) > 5.0 }
            
            let micWords = Set(segment.text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
            if !micWords.isEmpty {
                for record in recentSystemAudioRecords {
                    let systemWords = Set(record.text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
                    let intersection = micWords.intersection(systemWords)
                    let union = micWords.union(systemWords)
                    if !union.isEmpty {
                        let similarity = Double(intersection.count) / Double(union.count)
                        if similarity >= 0.5 { // 50% Jaccard word overlap indicates interviewer echo leak
                            isEchoLeakage = true
                            print("[EchoProtection] Detected interviewer leakage in mic stream: \"\(segment.text)\" matches recent system: \"\(record.text)\" with similarity \(String(format: "%.2f", similarity)). Question detection bypassed.")
                            break
                        }
                    }
                }
            }
        }

        var shouldTriggerDetection = false
        var skipReason = ""
        
        if !settings.automaticQuestionDetectionEnabled {
            skipReason = "automatic question detection disabled in settings"
        } else if settings.manualOnlyMode {
            skipReason = "manual only mode enabled"
        } else if isEchoLeakage {
            skipReason = "echo/leakage detected in mic stream"
        } else {
            switch segment.source {
            case .systemAudio, .processAudio:
                if segment.speaker == .interviewer {
                    shouldTriggerDetection = true
                } else {
                    skipReason = "speaker is not interviewer (speaker: \(segment.speaker.rawValue))"
                }
            case .mock:
                if segment.speaker == .interviewer {
                    shouldTriggerDetection = true
                } else {
                    skipReason = "mock speaker is not interviewer"
                }
            case .microphone, .mixed:
                if !settings.allowQuestionDetectionFromMicrophoneOnly {
                    skipReason = "question detection from microphone is disabled (allowQuestionDetectionFromMicrophoneOnly = false)"
                } else if segment.speaker != .interviewer && segment.speaker != .unknown {
                    skipReason = "speaker is candidate (speaker: \(segment.speaker.rawValue))"
                } else {
                    shouldTriggerDetection = true
                }
            }
        }

        // Output verbose gating logs
        print("[GatingLog] segmentSource: \(segment.source.rawValue) | segmentSpeaker: \(segment.speaker.rawValue) | eligibleForAutoDetection: \(shouldTriggerDetection)\(shouldTriggerDetection ? "" : " | skipReason: \(skipReason)")")

        // Capture attribution diagnostics
        let diag = SegmentAttributionDiagnostic(
            id: segment.id,
            textPreview: segment.text,
            source: segment.source,
            speaker: segment.speaker,
            createdAt: segment.createdAt,
            inputDeviceName: segment.inputDeviceName,
            outputDeviceName: segment.outputDeviceName,
            eligibleForAutoDetection: shouldTriggerDetection,
            skipReason: skipReason
        )
        last10SegmentsDiagnostics.append(diag)
        if last10SegmentsDiagnostics.count > 10 {
            last10SegmentsDiagnostics.removeFirst()
        }

        if shouldTriggerDetection {
            self.lastDetectionSkipReason = ""
            maybeRunAutomaticDetection(triggeringSegment: segment)
        } else {
            self.lastDetectionSkipReason = skipReason
            liveState = .listening
        }

    }

    private func normalizedTextHash(_ text: String) -> String {
        let clean = text.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return String(clean.hashValue)
    }

    private func maybeRunAutomaticDetection(triggeringSegment: TranscriptSegment) {
        detectionDebounceTask?.cancel()
        detectionDebounceTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(self.detectionDebounceSeconds * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self.beginAutomaticDetection(triggeringSegmentID: triggeringSegment.id)
        }
        liveState = .listening
    }

    private func beginAutomaticDetection(triggeringSegmentID: String?) {
        let now = Date()
        if let lastDetectionAt, now.timeIntervalSince(lastDetectionAt) < detectionDebounceSeconds {
            liveState = .listening
            return
        }
        lastDetectionAt = now
        let transcript = recentTranscriptText()
        guard !transcript.isEmpty, let session = currentSession else {
            liveState = .listening
            return
        }

        activeAITask?.cancel()
        activeAITask = Task { [weak self] in
            guard let self else { return }
            await self.runAutomaticDetection(session: session, transcript: transcript, triggeringSegmentID: triggeringSegmentID)
        }
    }

    private func runAutomaticDetection(session: InterviewSession, transcript: String, triggeringSegmentID: String?) async {
        do {
            print("[AppState] Automatic question detection running on transcript context: \"\(transcript)\" | triggeringSegmentID = \(triggeringSegmentID ?? "nil")")
            liveState = .detectingQuestion
            
            // Set input segment submitted to question detection
            let triggeringSegment = transcriptSegments.first(where: { $0.id == triggeringSegmentID })
            self.lastDetectionSubmittedSegmentText = triggeringSegment?.text ?? "Unknown segment text"
            self.lastDetectionPromptSource = triggeringSegment?.source.rawValue ?? "Unknown source"
            self.lastDetectionPromptSpeaker = triggeringSegment?.speaker.rawValue ?? "Unknown speaker"
            
            let detection = try await questionDetectionService.detect(
                transcriptContext: transcript,
                sessionID: session.id,
                transcriptSegmentID: triggeringSegmentID,
                model: activeRealtimeProvider?.model
            )
            guard !Task.isCancelled else { return }
            self.lastQuestionDetectionProvider = detection.response.providerName
            self.lastQuestionDetectionModel = detection.response.modelName
            try suggestionRepository.saveDetectedQuestion(detection.question)
            updateDiagnostics {
                $0.lastDetectedQuestionJSON = detection.question.rawJSON
                $0.lastAPILatencyMS = detection.response.latencyMS
                $0.lastProviderName = detection.response.providerName
                $0.lastProviderModel = detection.response.modelName
                $0.apiCallCount = (try? self.settingsRepository.apiCallCount()) ?? $0.apiCallCount
            }

            let question = detection.question
            lastDetectedQuestion = question
            
            // Set structured question detection diagnostics
            self.lastDetectedQuestionText = question.questionText
            self.lastDetectionConfidence = question.confidence
            self.lastDetectionShouldTrigger = question.shouldTrigger
            self.lastDetectionReason = question.intent.displayName
            self.lastDetectionRawJSON = question.rawJSON ?? ""
            self.lastDetectionSkipReason = ""
            self.lastDetectionQuestionComplete = question.questionComplete
            self.lastDetectionAnswerStrategy = question.answerStrategy.displayName
            self.lastQuestionDetectionResult = "Question complete: \(question.questionComplete) | Text: \"\(question.questionText)\" | Confidence: \(Int(question.confidence * 100))%"


            if question.shouldTrigger,
               question.questionComplete,
               question.confidence >= autoSuggestionConfidenceThreshold,
               isOutsideAutoSuggestionCooldown(),
               !isDuplicateAutoQuestion(question.questionText) {
                try await generateSuggestion(for: question, session: session, transcript: transcript, autoGenerated: true)
            } else {
                var skipMsg = ""
                if !question.shouldTrigger {
                    skipMsg = "Question shouldTrigger is false"
                } else if !question.questionComplete {
                    skipMsg = "Question is not complete"
                } else if question.confidence < autoSuggestionConfidenceThreshold {
                    skipMsg = "Confidence (\(Int(question.confidence * 100))%) below threshold (\(Int(autoSuggestionConfidenceThreshold * 100))%)"
                } else if !isOutsideAutoSuggestionCooldown() {
                    skipMsg = "Within auto-suggestion cooldown"
                } else if isDuplicateAutoQuestion(question.questionText) {
                    skipMsg = "Duplicate of recently answered question"
                } else {
                    skipMsg = "Not qualified for suggestion generation"
                }
                self.lastDetectionSkipReason = skipMsg
                
                if possibleQuestionConfidenceRange.contains(question.confidence) {
                    possibleQuestion = question
                }
                if self.stopReason == nil && self.anyCaptureRunning {
                    liveState = .listening
                    currentCaptureRuntimeState = .listening
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            self.lastQuestionDetectionResult = "Detection failed: \(error.localizedDescription)"
            self.lastDetectionSkipReason = "LLM/Detection API call error: \(error.localizedDescription)"
            if self.stopReason == nil && self.anyCaptureRunning {
                liveState = .listening
                currentCaptureRuntimeState = .listening
            }
            
            if self.lastFailedTaskType != .suggestionGeneration {
                self.lastFailedTaskType = .questionDetection
                self.lastFailedQuestion = nil
                self.lastFailedTranscriptContext = transcript
                self.lastFailedCVJDContext = nil
                self.lastFailedProviderConfig = activeRealtimeProvider
            }
            
            showError(userFacing(error))
        }
    }

    private func runManualAnswer(session: InterviewSession, transcript: String) async {
        do {
            liveState = .detectingQuestion
            let detection = try await questionDetectionService.detect(
                transcriptContext: transcript,
                sessionID: session.id,
                transcriptSegmentID: transcriptSegments.last?.id,
                model: activeRealtimeProvider?.model
            )
            guard !Task.isCancelled else { return }
            self.lastQuestionDetectionProvider = detection.response.providerName
            self.lastQuestionDetectionModel = detection.response.modelName
            try suggestionRepository.saveDetectedQuestion(detection.question)
            updateDiagnostics {
                $0.lastDetectedQuestionJSON = detection.question.rawJSON
                $0.lastAPILatencyMS = detection.response.latencyMS
                $0.lastProviderName = detection.response.providerName
                $0.lastProviderModel = detection.response.modelName
                $0.apiCallCount = (try? self.settingsRepository.apiCallCount()) ?? $0.apiCallCount
            }

            var question = detection.question
            lastDetectedQuestion = question
            if question.questionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                question.questionText = transcriptSegments.last?.text ?? transcript
            }
            try await generateSuggestion(for: question, session: session, transcript: transcript, autoGenerated: false)
        } catch {
            guard !Task.isCancelled else { return }
            let message = userFacing(error)
            liveState = .error(message)
            failAction(ActionID.generateAnswer, title: "Generation failed", message: "Transcript preserved. \(message)")
            
            if self.lastFailedTaskType != .suggestionGeneration {
                self.lastFailedTaskType = .questionDetection
                self.lastFailedQuestion = nil
                self.lastFailedTranscriptContext = transcript
                self.lastFailedCVJDContext = nil
                self.lastFailedProviderConfig = activeRealtimeProvider
            }
            
            showError(message)
        }
    }

    func cancelStageBTask() {
        softFallbackTask?.cancel()
        softFallbackTask = nil
        
        if let task = stageBTask {
            task.cancel()
            self.stageBTask = nil
            print("[StageB] Cancelled active background Stage B suggestion task.")
            
            if var current = self.currentSuggestion {
                current.stageBCompleted = false
                current.stageBStatus = "cancelled"
                current.caution = "Full answer cancelled by user action."
                self.currentSuggestion = current
                
                try? self.suggestionRepository.saveSuggestionCard(current, retrievedChunks: self.currentSuggestionRetrievedChunks)
            }
        }
    }

    private func trimContextForRealtime(_ context: RetrievedContext, question: DetectedQuestion) -> RetrievedContext {
        return RealtimePromptBudgeter.trim(
            context,
            question: question.questionText,
            intent: question.intent,
            strategy: question.answerStrategy
        )
    }

    private func makeCompactSummary(_ doc: DocumentRecord?) -> String {
        guard let doc = doc else { return "None provided." }
        let title = doc.title
        let cleanContent = doc.content.replacingOccurrences(of: "\n", with: " ")
        let excerpt = cleanContent.prefix(250)
        return "Title: \(title) | Excerpt: \(excerpt)..."
    }

    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw NSError(domain: "TimeoutDomain", code: 1, userInfo: [NSLocalizedDescriptionKey: "Request timed out after \(seconds)s"])
            }
            
            guard let result = try await group.next() else {
                throw NSError(domain: "TimeoutDomain", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown error during race"])
            }
            group.cancelAll()
            return result
        }
    }

    func validateAndRewriteIfNeeded(_ card: SuggestionCard, generationID: String) async -> SuggestionCard {
        var updated = card
        
        let locallyCleaned = AnswerQualityValidator.localCleanupAnswer(updated.sayFirst)
        updated.sayFirst = locallyCleaned
        
        let isValid = AnswerQualityValidator.isValid(
            sayFirst: updated.sayFirst,
            keyPoints: updated.keyPoints,
            followUpReady: updated.followUpReady,
            caution: updated.caution
        )
        
        if isValid {
            return updated
        }
        
        print("[QualityValidator] Card fields are invalid. Triggering background provider rewrite. Original say_first: \(card.sayFirst)")
        
        Task { [weak self] in
            guard let self = self else { return }
            let rewritten = await self.providerRewriteAnswer(locallyCleaned)
            
            await MainActor.run {
                if self.currentGenerationID == generationID, var current = self.currentSuggestion {
                    current.sayFirst = rewritten
                    self.currentSuggestion = current
                    try? self.suggestionRepository.saveSuggestionCard(current, retrievedChunks: self.currentSuggestionRetrievedChunks)
                    print("[QualityValidator] Background provider rewrite complete! Rewritten say_first: \(rewritten)")
                }
            }
        }
        
        return updated
    }
    
    private func providerRewriteAnswer(_ sayFirst: String) async -> String {
        let systemPrompt = """
        You are a helpful assistant. You must rewrite the provided text as a natural, first-person spoken interview answer that the candidate can say directly out loud.
        
        Rules:
        - Output ONLY the rewritten spoken answer.
        - Must be in first person (use "I", "my", "I'm").
        - Absolutely no meta-instructions, no commentary, no formatting.
        - Remove all LaTeX commands, braces, backslashes.
        - Remove instruction verbs like "Highlight", "Emphasize", "Use".
        - Extremely concise (1-3 sentences).
        """
        
        let userPrompt = "Rewrite this now: \(sayFirst)"
        
        do {
            if let config = try? llmRouter.realtimeConfiguration() {
                let response = try await llmRouter.chat(
                    configuration: config,
                    messages: [.system(systemPrompt), .user(userPrompt)],
                    responseFormat: .text,
                    options: LLMRequestOptions(temperature: 0.1, timeoutInterval: 3.0)
                )
                let result = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !result.isEmpty && AnswerQualityValidator.isValidField(result, isSayFirst: true) {
                    return result
                }
            }
        } catch {
            print("[AppState] Provider answer rewrite failed: \(error.localizedDescription)")
        }
        
        return AnswerQualityValidator.localCleanupAnswer(sayFirst)
    }

    private func elapsedMS(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    private func applyStreamingSections(
        _ sections: StreamingSuggestionSections,
        to current: SuggestionCard?,
        cardID: String,
        question: DetectedQuestion,
        session: InterviewSession,
        requestStart: Date,
        stageBStreamStartedMS: Int?,
        preserveExistingSayFirst: Bool = false,
        markFullCardVisible: Bool
    ) -> SuggestionCard {
        let nowMS = elapsedMS(since: requestStart)
        var card = current ?? SuggestionCard(
            id: cardID,
            sessionID: session.id,
            questionID: question.id,
            strategy: sections.strategy.isEmpty ? "Direct Answer" : sections.strategy,
            sayFirst: "",
            keyPoints: [],
            followUpReady: [],
            confidence: 0.8,
            caution: nil,
            evidenceUsed: [],
            riskLevel: .low,
            modelName: activeRealtimeProvider?.model ?? "deepseek-v4-flash",
            promptVersion: "section-stream-v1",
            providerKind: activeRealtimeProvider?.kind,
            providerName: activeRealtimeProvider?.name ?? "DeepSeek",
            providerBaseURL: activeRealtimeProvider?.baseURL ?? "https://api.deepseek.com",
            latencyMS: nowMS,
            isLocal: false,
            rawJSON: nil,
            createdAt: Date()
        )

        if !sections.strategy.isEmpty {
            card.strategy = sections.strategy
        }

        if !sections.sayFirst.isEmpty {
            let source = card.sayFirstSource ?? ""
            let isFallback = source.contains("fallback")
            if card.sayFirst.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (isFallback && !preserveExistingSayFirst) {
                card.sayFirst = sections.sayFirst
                card.sayFirstSource = "deepseek_section_stream"
                card.finalVisibleSource = "deepseek_section_stream"
            }
        }

        if !sections.keyPoints.isEmpty {
            card.keyPoints = sections.keyPoints
            if card.firstKeyPointVisibleMS == nil {
                card.firstKeyPointVisibleMS = nowMS
            }
            if markFullCardVisible || sections.keyPoints.count >= 2 {
                card.allKeyPointsVisibleMS = card.allKeyPointsVisibleMS ?? nowMS
            }
        }

        if !sections.followUpReady.isEmpty {
            card.followUpReady = sections.followUpReady
            card.followUpVisibleMS = card.followUpVisibleMS ?? nowMS
        }

        if !sections.caution.isEmpty {
            card.caution = sections.caution
        }

        if !card.sayFirst.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            card.firstVisibleAnswerMS = card.firstVisibleAnswerMS ?? card.latencyFirstVisibleMS ?? deepseekFirstVisibleMS ?? nowMS
            card.latencyFirstVisibleMS = card.latencyFirstVisibleMS ?? card.firstVisibleAnswerMS
        }

        card.stageBStreamStartedMS = card.stageBStreamStartedMS ?? stageBStreamStartedMS
        if sections.hasVisibleContent {
            card.stageBFirstSectionMS = card.stageBFirstSectionMS ?? nowMS
        }
        if markFullCardVisible {
            card.fullCardVisibleMS = nowMS
            card.latencyFullCardMS = nowMS
            card.stageBCompleted = true
            card.stageBStatus = "completed"
            card.latencyMS = nowMS
        }
        card.softFallbackUsed = softFallbackUsed
        card.softFallbackLatencyMS = softFallbackLatencyMS
        card.deepseekFirstTokenMS = deepseekFirstTokenMS
        card.deepseekFirstVisibleMS = deepseekFirstVisibleMS
        card.ragRetrievalLatencyMS = ragRetrievalLatencyMS
        return card
    }

    private func publishStreamingSections(
        _ sections: StreamingSuggestionSections,
        cardID: String,
        generationID: String,
        question: DetectedQuestion,
        session: InterviewSession,
        requestStart: Date,
        stageBStreamStartedMS: Int?,
        preserveExistingSayFirst: Bool = false,
        markFullCardVisible: Bool = false
    ) {
        guard currentGenerationID == generationID else { return }
        let card = applyStreamingSections(
            sections,
            to: currentSuggestion,
            cardID: cardID,
            question: question,
            session: session,
            requestStart: requestStart,
            stageBStreamStartedMS: stageBStreamStartedMS,
            preserveExistingSayFirst: preserveExistingSayFirst,
            markFullCardVisible: markFullCardVisible
        )
        currentSuggestion = card
        if currentSuggestionSetAt == nil {
            currentSuggestionSetAt = Date()
        }
        isExpandingSuggestionCard = !markFullCardVisible
    }

    private func persistSuggestionInBackground(
        _ card: SuggestionCard,
        chunks: [RetrievedChunk],
        generationID: String,
        requestStart: Date
    ) {
        let repository = suggestionRepository
        Task.detached(priority: .utility) { [weak self] in
            var persistedCard = card
            do {
                try repository.saveSuggestionCard(persistedCard, retrievedChunks: chunks)
                persistedCard.dbPersistedMS = Int(Date().timeIntervalSince(requestStart) * 1000)
                try repository.saveSuggestionCard(persistedCard, retrievedChunks: chunks)
                let persistedID = persistedCard.id
                let persistedDBMS = persistedCard.dbPersistedMS
                await MainActor.run { [weak self, persistedID, persistedDBMS] in
                    guard let self = self, self.currentGenerationID == generationID else { return }
                    self.streamPersistedAt = Date()
                    if self.currentSuggestion?.id == persistedID {
                        self.currentSuggestion?.dbPersistedMS = persistedDBMS
                    }
                    self.refreshLatencyAverages()
                }
            } catch {
                let message = "Suggestion is visible, but saving it failed: \(error.localizedDescription)"
                await MainActor.run { [weak self, message] in
                    guard let self = self, self.currentGenerationID == generationID else { return }
                    self.errorMessage = message
                }
            }
        }
    }

    func generateSuggestion(
        for question: DetectedQuestion,
        session: InterviewSession,
        transcript: String,
        autoGenerated: Bool
    ) async throws {
        // Cancel any existing background Stage B task first
        cancelStageBTask()
        if !isActionLoading(ActionID.generateAnswer) {
            beginAction(ActionID.generateAnswer, title: "Generating first answer", message: autoGenerated ? "Question detected. Preparing a speakable answer..." : "Preparing a speakable first answer...")
        }

        liveState = .generatingSuggestion
        let stateBefore = currentCaptureRuntimeState.displayName
        currentCaptureRuntimeState = .generating
        addCaptureEvent(name: "suggestionGenerationStarted", stateBefore: stateBefore, stateAfter: "generating", reason: "questionDetected")
        self.suggestionGenerationStarted = true
        self.floatingPanelUpdated = false
        
        var retrievedContext: RetrievedContext? = nil
        var retrievalTrace: RetrievalTrace? = nil
        
        // 1. Check precomputed RAG Cache
        var hitCache = false
        if let segmentID = question.transcriptSegmentID {
            if let cacheKey = precomputedRAGCache.keys.first(where: { $0.hasPrefix(segmentID + "_") }),
               let cached = precomputedRAGCache[cacheKey] {
                let cleanCached = cached.rawText.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                let cleanFinal = question.questionText.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                
                let cachedWords = Set(cleanCached.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty })
                let finalWords = Set(cleanFinal.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty })
                let intersection = cachedWords.intersection(finalWords)
                let union = cachedWords.union(finalWords)
                let similarity = union.isEmpty ? 0.0 : Double(intersection.count) / Double(union.count)
                
                if similarity >= 0.75 { // 75% similarity threshold
                    retrievedContext = cached.context
                    retrievalTrace = cached.trace
                    hitCache = true
                    print("[PrecomputeRAG] Cache hit! (similarity \(similarity)) for key: \(cacheKey)")
                } else {
                    print("[PrecomputeRAG] Cache miss due to significant text difference (similarity \(similarity)) for key: \(cacheKey). Rerunning retrieval.")
                }
                precomputedRAGCache.removeValue(forKey: cacheKey)
            }
        }
        
        if !hitCache {
            let (context, trace) = try await contextRetrievalService.retrieveContextWithTrace(
                question: question.questionText,
                intent: question.intent,
                maxCVWords: 300,
                maxJDWords: 180,
                strategy: question.answerStrategy
            )
            retrievedContext = context
            retrievalTrace = trace
        }
        
        guard let context = retrievedContext, let trace = retrievalTrace else {
            throw LLMProviderError.invalidResponse("Could not retrieve RAG context.")
        }
        self.lastRetrievalTrace = trace
        self.ragRetrievalLatencyMS = Int(trace.retrievalLatencyMS)
        
        // 2. Realtime Context Budget Optimization
        let optimizedContext = trimContextForRealtime(context, question: question)
        
        // Load CV/JD compact summaries for prompt prefix stabilization
        let cvRecord = try? documentRepository.document(type: .cv)
        let jdRecord = try? documentRepository.document(type: .jobDescription)
        let cvSummary = makeCompactSummary(cvRecord)
        let jdSummary = makeCompactSummary(jdRecord)
        
        // 3. Reset streaming state and metrics
        let requestStart = Date()
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
        
        // Create references for background task capture
        let localQuestion = question
        let localSession = session
        let localTrace = trace
        let localTranscript = transcript
        
        let cardID = UUID().uuidString
        let generationID = UUID().uuidString
        self.currentGenerationID = generationID
        
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
        
        // Helper to construct a local fallback card
        func createRAGFallbackCard(isSoft: Bool) -> SuggestionCard {
            var sayFirst = "Focus on explaining the relevant experience: "
            if let bestChunk = optimizedContext.cvChunks.first {
                sayFirst += "based on my experience with \(bestChunk.sectionTitle ?? "my past projects"), I worked on \(bestChunk.content.prefix(120))..."
            } else {
                sayFirst += "I can speak to my background in software engineering and design principles."
            }
            
            let keyPoints = optimizedContext.cvChunks.map { chunk in
                "\(chunk.sectionTitle ?? "Experience Detail"): \(chunk.content.prefix(80))."
            }
            
            return SuggestionCard(
                id: cardID,
                sessionID: localSession.id,
                questionID: localQuestion.id,
                strategy: isSoft ? "RAG Template Soft Fallback (DeepSeek Delay)" : "RAG Template Fallback (DeepSeek Timeout)",
                sayFirst: sayFirst,
                keyPoints: Array(keyPoints.prefix(3)),
                followUpReady: ["How does this align with the role requirements?"],
                confidence: 0.5,
                caution: isSoft ? "Fast local answer shown; DeepSeek still generating..." : "Fast fallback shown; DeepSeek still expanding...",
                evidenceUsed: optimizedContext.cvChunks.map { $0.id },
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
        self.softFallbackTask = Task { [weak self] in
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
                    self.currentSuggestion = visibleFallback
                    self.currentSuggestionSetAt = self.currentSuggestionSetAt ?? Date()
                    self.isExpandingSuggestionCard = true
                    print("[StreamingASR] Soft fallback triggered at \(elapsed)ms because no DeepSeek text was visible yet.")
                }
            } catch {
                // Cancelled or sleep error
            }
        }
        
        // Cost Control: Launch Stage B in parallel immediately, but it waits for the trigger!
        self.stageBTask = Task { [weak self] in
            guard let self = self else { return }
            // Wait for Stage B trigger (timeout after 500ms if first visible text doesn't show up sooner)
            await trigger.wait(timeoutMs: 500)
            
            guard self.currentGenerationID == generationID else { return }
            guard !Task.isCancelled else {
                print("[StageB] Task was cancelled in-flight.")
                return
            }
            
            let activeFallback = self.softFallbackUsed || self.currentSuggestion?.sayFirstSource == "rag_template_fallback" || self.currentSuggestion?.sayFirstSource == "rag_template_soft_fallback"
            
            do {
                let streamStartedMS = self.elapsedMS(since: requestStart)
                var parser = StreamingSuggestionSectionParser()
                var throttle = StreamingUpdateThrottle()
                var latestSections = StreamingSuggestionSections()
                var sawStreamingSections = false

                let sectionStream = try await self.suggestionGenerationService.generateFullCardSectionStream(
                    question: localQuestion,
                    context: optimizedContext,
                    transcriptContext: localTranscript,
                    sessionID: localSession.id,
                    cvSummary: cvSummary,
                    jdSummary: jdSummary
                )

                for try await token in sectionStream {
                    guard self.currentGenerationID == generationID else { return }
                    guard !Task.isCancelled else {
                        print("[StageB] Task was cancelled in-flight.")
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

                guard self.currentGenerationID == generationID else { return }
                guard !Task.isCancelled else {
                    print("[StageB] Task was cancelled in-flight.")
                    return
                }

                if !sawStreamingSections {
                    let result = try await self.withTimeout(seconds: 15.0) {
                        try await self.suggestionGenerationService.generateFullCard(
                            question: localQuestion,
                            context: optimizedContext,
                            transcriptContext: localTranscript,
                            sessionID: localSession.id,
                            cvSummary: cvSummary,
                            jdSummary: jdSummary
                        )
                    }
                    latestSections = StreamingSuggestionSections(
                        strategy: result.card.strategy,
                        sayFirst: result.card.sayFirst,
                        keyPoints: result.card.keyPoints,
                        followUpReady: result.card.followUpReady,
                        caution: result.card.caution ?? ""
                    )
                }

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
                    preserveExistingSayFirst: preserveFallbackSayFirst,
                    markFullCardVisible: true
                )

                guard var finalCard = self.currentSuggestion else {
                    throw LLMProviderError.emptyResponse(providerName: self.activeRealtimeProvider?.name ?? "Realtime provider")
                }

                finalCard.id = cardID
                finalCard.stageATimedOut = finalCard.stageATimedOut ?? false
                finalCard.stageBCompleted = true
                finalCard.stageBStatus = "completed"
                finalCard.latencyFirstTokenMS = self.deepseekFirstTokenMS
                finalCard.latencyFirstVisibleMS = finalCard.latencyFirstVisibleMS ?? self.deepseekFirstVisibleMS
                finalCard.firstVisibleAnswerMS = finalCard.firstVisibleAnswerMS ?? finalCard.latencyFirstVisibleMS
                finalCard.softFallbackUsed = self.softFallbackUsed
                finalCard.softFallbackLatencyMS = self.softFallbackLatencyMS
                finalCard.deepseekFirstTokenMS = self.deepseekFirstTokenMS
                finalCard.deepseekFirstVisibleMS = self.deepseekFirstVisibleMS
                finalCard.finalVisibleSource = self.finalVisibleSource ?? finalCard.finalVisibleSource ?? (self.softFallbackUsed ? "rag_template_soft_fallback" : "deepseek_section_stream")
                finalCard.ragRetrievalLatencyMS = self.ragRetrievalLatencyMS

                if let segmentID = localQuestion.transcriptSegmentID,
                   let segment = try? self.transcriptRepository.segmentByID(segmentID) {
                    finalCard.questionASRFirstPartialMS = segment.asrFirstPartialMS
                    finalCard.questionASRFinalMS = segment.asrFinalMS
                    finalCard.questionASRBestSelectedMS = segment.asrBestSelectedMS
                }

                let validatedCard = await self.validateAndRewriteIfNeeded(finalCard, generationID: generationID)
                self.currentSuggestion = validatedCard
                self.currentSuggestionRetrievedChunks = localTrace.rankedCVChunks + localTrace.rankedJDChunks
                self.isExpandingSuggestionCard = false
                self.suggestionGenerationStarted = false
                self.persistSuggestionInBackground(
                    validatedCard,
                    chunks: localTrace.rankedCVChunks + localTrace.rankedJDChunks,
                    generationID: generationID,
                    requestStart: requestStart
                )
                self.completeAction(ActionID.generateAnswer, title: "Answer ready", message: "First answer and key points are visible.")

                // Only restore .listening if safety conditions are met
                if self.currentSession?.id == localSession.id &&
                   self.currentCaptureRuntimeState == .generating &&
                   self.stopReason == nil &&
                   self.currentGenerationID == generationID &&
                   self.anyCaptureRunning {
                    self.liveState = .listening
                    self.currentCaptureRuntimeState = .listening
                    self.addCaptureEvent(name: "listeningRestored", stateBefore: "generating", stateAfter: "listening", reason: "generationSuccess")
                } else {
                    print("[CaptureState] Bypassed restoring listening: sessionID=\(self.currentSession?.id ?? "nil"), state=\(self.currentCaptureRuntimeState), stopReason=\(String(describing: self.stopReason)), generationID=\(String(describing: self.currentGenerationID)), anyCaptureRunning=\(self.anyCaptureRunning)")
                }
                
                // Refresh historical latency averages
                self.refreshLatencyAverages()
                
                print("[StreamingASR] Stage B Full SuggestionCard completed and merged successfully!")
            } catch {
                guard self.currentGenerationID == generationID else { return }
                print("[StreamingASR] Stage B Full SuggestionCard failed or timed out: \(error.localizedDescription)")
                self.isExpandingSuggestionCard = false
                self.suggestionGenerationStarted = false
                
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
                        updated.caution = "Fast fallback shown; DeepSeek still expanding..."
                    }
                    self.currentSuggestion = updated
                    try? self.suggestionRepository.saveSuggestionCard(updated, retrievedChunks: self.currentSuggestionRetrievedChunks)
                    self.warnAction(ActionID.generateAnswer, title: "First answer preserved", message: "Full answer expansion failed. The visible answer was kept.")
                } else {
                    self.failAction(ActionID.generateAnswer, title: "Generation failed", message: "Transcript preserved. \(self.userFacing(error))")
                }
            }
        }
        
        // Stage A streaming task
        let fastSayFirstTask = Task {
            do {
                let stream = try await self.suggestionGenerationService.generateFastSayFirstStream(
                    question: localQuestion,
                    context: optimizedContext,
                    cvSummary: cvSummary,
                    jdSummary: jdSummary
                )
                
                var collected = ""
                var sayFirstThrottle = StreamingUpdateThrottle()
                for try await token in stream {
                    guard self.currentGenerationID == generationID else { throw CancellationError() }
                    guard !Task.isCancelled else { break }
                    if self.streamFirstTokenAt == nil {
                        self.streamFirstTokenAt = Date()
                        self.deepseekFirstTokenMS = Int(Date().timeIntervalSince(requestStart) * 1000)
                    }
                    collected += token
                    
                    // First visible text detection (at least 3 words or 10 characters)
                    var forcePublish = false
                    if self.streamFirstVisibleTextAt == nil {
                        let wordCount = collected.split(whereSeparator: \.isWhitespace).count
                        if wordCount >= 3 || collected.count >= 10 {
                            self.streamFirstVisibleTextAt = Date()
                            self.firstVisibleStateSetAt = Date()
                            self.deepseekFirstVisibleMS = Int(Date().timeIntervalSince(requestStart) * 1000)
                            forcePublish = true
                            trigger.trigger() // Start Stage B early!
                        }
                    }

                    if sayFirstThrottle.shouldPublish(characterCount: collected.count, force: forcePublish) {
                        self.streamedSayFirst = collected
                        if self.streamedSayFirstSetAt == nil && !collected.isEmpty {
                            self.streamedSayFirstSetAt = Date()
                        }
                    }
                    
                    // First sentence detection
                    if self.streamFirstSentenceAt == nil && (token.contains(".") || token.contains("!") || token.contains("?")) {
                        self.streamFirstSentenceAt = Date()
                    }
                }
                self.streamedSayFirst = collected
                if self.streamedSayFirstSetAt == nil && !collected.isEmpty {
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
        
        // Race Stage A with 6.0s timeout
        var fastSayFirst = ""
        do {
            fastSayFirst = try await withTimeout(seconds: 6.0) {
                try await fastSayFirstTask.value
            }
            guard self.currentGenerationID == generationID else { return }
            self.isStreamingSayFirst = false
            
            // Cancel soft fallback task since Stage A completed
            softFallbackTask?.cancel()
            
            let elapsed = Date().timeIntervalSince(requestStart)
            let isSoft = self.softFallbackUsed
            
            if isSoft {
                // Apply conservative late DeepSeek replacement checks
                let replace = !self.userInteractedWithCard && elapsed < 4.0 && self.isSpecificAnswer(fastSayFirst)
                if replace {
                    if var current = self.currentSuggestion, current.stageBCompleted == true {
                        current.sayFirst = fastSayFirst
                        current.sayFirstSource = "deepseek_stream"
                        current.finalVisibleSource = "deepseek_stream"
                        let validated = await self.validateAndRewriteIfNeeded(current, generationID: generationID)
                        self.currentSuggestion = validated
                        try? self.suggestionRepository.saveSuggestionCard(validated, retrievedChunks: self.currentSuggestionRetrievedChunks)
                    } else {
                        var updated = createRAGFallbackCard(isSoft: true)
                        updated.sayFirst = fastSayFirst
                        updated.sayFirstSource = "deepseek_stream"
                        updated.finalVisibleSource = "deepseek_stream"
                        updated.caution = "DeepSeek answer updated. Expanding details..."
                        updated.firstVisibleAnswerMS = updated.firstVisibleAnswerMS ?? Int(Date().timeIntervalSince(requestStart) * 1000)
                        self.finalVisibleSource = "deepseek_stream"
                        let validated = await self.validateAndRewriteIfNeeded(updated, generationID: generationID)
                        self.currentSuggestion = validated
                        self.currentSuggestionSetAt = self.currentSuggestionSetAt ?? Date()
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
                self.currentSuggestion = validated
                self.currentSuggestionSetAt = self.currentSuggestionSetAt ?? Date()
                self.isExpandingSuggestionCard = true
            }
        } catch {
            guard self.currentGenerationID == generationID else { return }
            print("[StreamingASR] Stage A Fast Say-First timed out or failed: \(error.localizedDescription)")
            self.isStreamingSayFirst = false
            softFallbackTask?.cancel()
            
            // If soft fallback was already shown, preserve it but mark timeout/failure.
            // If not, show hard fallback now.
            if !self.softFallbackUsed {
                let fallbackCard = createRAGFallbackCard(isSoft: false)
                var visibleFallback = fallbackCard
                visibleFallback.firstVisibleAnswerMS = Int(Date().timeIntervalSince(requestStart) * 1000)
                let validated = await self.validateAndRewriteIfNeeded(visibleFallback, generationID: generationID)
                self.currentSuggestion = validated
                self.currentSuggestionSetAt = self.currentSuggestionSetAt ?? Date()
                self.isExpandingSuggestionCard = true
            } else if var current = self.currentSuggestion {
                current.stageATimedOut = true
                current.caution = "Fast fallback shown; DeepSeek stream timed out."
                let validated = await self.validateAndRewriteIfNeeded(current, generationID: generationID)
                self.currentSuggestion = validated
            }
        }
    }


    private func recentTranscriptText() -> String {
        let text = transcriptSegments
            .suffix(18)
            .map { "\($0.speaker.displayName): \($0.text)" }
            .joined(separator: "\n")
        return ContextBudgeter.limitWords(text, maxWords: 800)
    }

    private func isOutsideAutoSuggestionCooldown() -> Bool {
        guard let lastAutoSuggestionAt else { return true }
        return Date().timeIntervalSince(lastAutoSuggestionAt) >= autoSuggestionCooldownSeconds
    }

    private var recentQuestionTimestamps = [String: Date]()

    func isDuplicateAutoQuestion(_ questionText: String) -> Bool {
        let normalized = normalizedQuestion(questionText)
        guard !normalized.isEmpty else { return false }
        
        let now = Date()
        
        // Clean up entries older than 20 seconds
        for (fingerprint, timestamp) in recentQuestionTimestamps {
            if now.timeIntervalSince(timestamp) > 20.0 {
                recentQuestionTimestamps.removeValue(forKey: fingerprint)
            }
        }
        
        // Check if there is a match in recent questions within 20 seconds
        if let lastTime = recentQuestionTimestamps[normalized], now.timeIntervalSince(lastTime) <= 20.0 {
            return true
        }
        
        for (fingerprint, timestamp) in recentQuestionTimestamps {
            if now.timeIntervalSince(timestamp) <= 20.0 {
                if normalized.contains(fingerprint) || fingerprint.contains(normalized) {
                    return true
                }
            }
        }
        
        // Record the new question timestamp
        recentQuestionTimestamps[normalized] = now
        return false
    }

    private func normalizedQuestion(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public func isSpecificAnswer(_ text: String) -> Bool {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if cleaned.count < 30 {
            return false
        }
        let genericPhrases = [
            "based on my experience",
            "i can speak to my background",
            "focus on explaining",
            "as a software engineer"
        ]
        for phrase in genericPhrases {
            if cleaned.contains(phrase) && cleaned.count < 80 {
                return false
            }
        }
        return true
    }

    private func showError(_ message: String) {
        errorMessage = message
        updateDiagnostics { $0.lastError = message }
    }

    private func userFacing(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    private func updateDiagnostics(_ mutate: (inout DeveloperDiagnostics) -> Void) {
        var next = diagnostics
        mutate(&next)
        diagnostics = next
    }

    // MARK: - Audio Signal and Route Recovery monitoring

    public func restartAudioInput() {
        beginAction(ActionID.restartAudioInput, title: "Restarting audio input", message: "Resetting the local audio input path...")
        AudioEngineManager.shared.restartForRouteChange(reason: "Manual restart requested by user")
        completeAction(ActionID.restartAudioInput, title: "Audio input restarted", message: "Watch the audio status and retry listening if needed.")
    }

    private func startAudioSignalMonitoring() {
        audioSignalMonitoringTimer?.invalidate()
        audioSignalMonitoringTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.monitorAudioSignal()
            }
        }
    }

    private func stopAudioSignalMonitoring() {
        audioSignalMonitoringTimer?.invalidate()
        audioSignalMonitoringTimer = nil
        noAudioWarningVisible = false
        audioRouteError = nil
    }

    private func monitorAudioSignal() {
        // Keep ASR diagnostic properties updated
        if let speechService = appleSpeechService {
            self.systemASRTaskRunning = speechService.systemAudioSession?.recognitionTask != nil
            self.totalSystemAudioASRBuffersAppended = speechService.systemAudioSession?.totalBuffersAppended ?? 0
            self.recognitionRequestActive = speechService.systemAudioSession?.request != nil
            self.recognitionTaskActive = speechService.systemAudioSession?.recognitionTask != nil
            if let err = speechService.systemAudioSession?.lastError {
                self.lastSystemAudioASRError = err.localizedDescription
            }
            if let partial = speechService.systemAudioSession?.partialTranscriptBuffer {
                self.lastSystemAudioASRPartialTranscript = partial
            }
        } else {
            self.systemASRTaskRunning = false
            self.totalSystemAudioASRBuffersAppended = 0
            self.recognitionRequestActive = false
            self.recognitionTaskActive = false
        }

        guard liveState == .listening || liveState == .transcribing else {
            noAudioWarningVisible = false
            return
        }

        // Only monitor mic levels if microphone pipeline is actually running
        guard appleSpeechService?.microphoneSession != nil else {
            noAudioWarningVisible = false
            return
        }

        if let lastBuffer = AudioEngineManager.shared.lastAudioBufferAt {
            self.lastAudioBufferAt = lastBuffer
            let elapsed = Date().timeIntervalSince(lastBuffer)
            if elapsed > 3.0 {
                self.noAudioWarningVisible = true
                self.audioRouteError = "No microphone signal detected. Check input device or restart audio capture."
            } else {
                self.noAudioWarningVisible = false
                if self.audioRouteError == "No microphone signal detected. Check input device or restart audio capture." {
                    self.audioRouteError = "Audio input restored."
                }
            }
        } else {
            let elapsed = Date().timeIntervalSince(lastDetectionAt ?? Date())
            if elapsed > 3.0 {
                self.noAudioWarningVisible = true
                self.audioRouteError = "No microphone signal detected. Check input device or restart audio capture."
            }
        }
        
        self.currentInputDeviceName = AudioDeviceRouteMonitor.shared.currentInputDeviceName
    }
    
    // MARK: - Manual Capture Push-to-Ask Controls
    
    private func stopAllContinuousPipelines(
        reason: StopReason,
        file: String = #file,
        line: Int = #line,
        function: String = #function
    ) {
        let stateBefore = currentCaptureRuntimeState.displayName
        currentCaptureRuntimeState = .stopping
        self.stopReason = reason
        self.lastCaptureStoppedAt = Date()
        
        print("[CaptureState] stopListening reason = \(reason)")
        print("[CaptureState] systemCaptureRunning before stop = \(systemCaptureRunning)")
        print("[CaptureState] called from = \(file.split(separator: "/").last ?? ""):\(line) - \(function)")
        
        addCaptureEvent(
            name: "stopAllContinuousPipelines",
            stateBefore: stateBefore,
            stateAfter: "stopping",
            reason: reason.rawValue,
            file: file,
            line: line,
            function: function
        )
        
        activeAITask?.cancel()
        detectionDebounceTask?.cancel()
        transcriptionTask?.cancel()
        
        activeTranscriptionProvider?.stop()
        activeTranscriptionProvider = nil
        
        appleSpeechService?.stop()
        appleSpeechService = nil
        
        // Stop diagnostics level metering
        AudioEngineManager.shared.unregister(microphoneDiagnostics)
        microphoneDiagnostics.stopMicTest()
        
        stopAudioSignalMonitoring()
        recentQuestionsFingerprints.removeAll()
        
        liveState = .idle
        currentCaptureRuntimeState = .stopped(reason: reason)
        
        addCaptureEvent(
            name: "pipelinesStopped",
            stateBefore: "stopping",
            stateAfter: "stopped",
            reason: reason.rawValue,
            file: file,
            line: line,
            function: function
        )
    }
    
    @MainActor
    func startManualCapture() {
        guard !isActionLoading(ActionID.manualRecord) else { return }
        guard onboardingComplete else {
            let message = liveBlockedReason ?? "Run the readiness check before recording a question."
            failAction(ActionID.manualRecord, title: "Setup incomplete", message: message)
            showError(message)
            return
        }
        beginAction(ActionID.manualRecord, title: "Preparing capture", message: "Checking permissions and preparing the recorder...")
        
        // Prevent pipeline conflicts
        stopAllContinuousPipelines(reason: .userRequested)
        
        // Discard any previous state
        self.manualCaptureTranscript = ""
        self.manualCaptureSuggestion = nil
        self.manualCaptureError = nil
        self.manualCaptureBufferCount = 0
        self.manualCaptureLastBufferTimestamp = nil
        self.manualCaptureSource = settings.manualCaptureSource.rawValue
        
        let source = settings.manualCaptureSource
        
        Task {
            do {
                self.manualCaptureState = .waitingForPermission
                
                if source == .systemAudio {
                    // Check Screen Capture Preflight & Probe access
                    let probeResult = await ScreenSystemAudioPermissionProbe.shared.probe()
                    let state = determineProbeState(result: probeResult)
                    self.systemAudioProbeResult = probeResult
                    self.systemAudioPermissionState = state
                    
                    guard state == .granted else {
                        let message = "System audio permission is required to capture interviewer audio."
                        self.manualCaptureState = .error(message)
                        self.failAction(ActionID.manualRecord, title: "Permission needed", message: message)
                        return
                    }
                } else {
                    // Microphone permission required
                    let micStatus = await permissionService.requestMicrophonePermission()
                    refreshPermissions()
                    guard micStatus == .authorized else {
                        let message = "Microphone permission is required to record speech."
                        self.manualCaptureState = .error(message)
                        self.failAction(ActionID.manualRecord, title: "Permission needed", message: message)
                        return
                    }
                    
                    let speechStatus = await permissionService.requestSpeechRecognition()
                    refreshPermissions()
                    guard speechStatus == .granted else {
                        let message = "Speech Recognition permission is required for transcription."
                        self.manualCaptureState = .error(message)
                        self.failAction(ActionID.manualRecord, title: "Permission needed", message: message)
                        return
                    }
                }
                
                self.manualCaptureState = .recording
                self.completeAction(ActionID.manualRecord, title: "Recording question", message: "Audio capture is active. Stop when the question is complete.")
                
                // Initialize transcription task in parallel with capture for real-time partial feedback
                try await ManualQuestionTranscriptionService.shared.startTranscription(
                    onPartialResult: { [weak self] partialText in
                        guard let self = self else { return }
                        Task { @MainActor in
                            self.manualCaptureTranscript = partialText
                        }
                    },
                    onFinalResult: { [weak self] finalText in
                        guard let self = self else { return }
                        Task { @MainActor in
                            self.manualCaptureTranscript = finalText
                        }
                    },
                    onError: { [weak self] err in
                        guard let self = self else { return }
                        Task { @MainActor in
                            self.manualCaptureState = .error(err)
                        }
                    }
                )
                
                try await ManualQuestionCaptureService.shared.startCapture(
                    source: source,
                    maxDuration: settings.maxManualCaptureSeconds
                ) { [weak self] in
                    guard let self = self else { return }
                    // Max duration reached handler
                    Task { @MainActor in
                        self.stopAndTranscribeManualCapture(maxDurationReached: true)
                    }
                }
            } catch {
                self.manualCaptureState = .error(error.localizedDescription)
                self.failAction(ActionID.manualRecord, title: "Capture failed", message: error.localizedDescription)
            }
        }
    }
    
    @MainActor
    func stopAndTranscribeManualCapture(maxDurationReached: Bool = false) {
        guard self.manualCaptureState == .recording else { return }
        guard !isActionLoading(ActionID.manualStopTranscribe) else { return }
        beginAction(ActionID.manualStopTranscribe, title: "Transcribing", message: "Stopping audio and finalizing the transcript...")
        
        self.manualCaptureState = .stopping
        
        // Cache buffer metrics before stopping stream clears capturedBuffers array
        self.manualCaptureBufferCount = ManualQuestionCaptureService.shared.capturedBufferCount
        self.manualCaptureLastBufferTimestamp = ManualQuestionCaptureService.shared.lastBufferTimestamp
        self.manualCaptureSource = settings.manualCaptureSource.rawValue
        
        // Stop capturing audio
        let buffers = ManualQuestionCaptureService.shared.stopCaptureAndReturnBuffers()
        
        self.manualCaptureState = .transcribing
        
        Task {
            do {
                if maxDurationReached {
                    self.manualCaptureError = "Max recording duration reached"
                }
                
                // Feed the remaining buffers to transcription just in case
                for buffer in buffers {
                    ManualQuestionTranscriptionService.shared.appendBuffer(buffer)
                }
                
                // End Speech audio and await final transcript or timeout (10s watchdog)
                let finalTranscript = try await ManualQuestionTranscriptionService.shared.endAudioAndFinalize(timeoutSeconds: 10.0)
                let trimmed = finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                
                self.manualCaptureTranscript = trimmed
                
                if trimmed.isEmpty {
                    let message = "No speech detected or transcription failed. Try recording again."
                    self.manualCaptureState = .error(message)
                    self.failAction(ActionID.manualStopTranscribe, title: "Transcription failed", message: message)
                    return
                }
                
                self.manualCaptureState = .transcriptReady
                self.completeAction(ActionID.manualStopTranscribe, title: "Transcript ready", message: "Review the question and generate an answer.")
                
                if !settings.showTranscriptBeforeSending && settings.autoSendAfterTranscription {
                    sendManualCaptureToAI()
                }
            } catch {
                self.manualCaptureState = .error(error.localizedDescription)
                self.failAction(ActionID.manualStopTranscribe, title: "Transcription failed", message: error.localizedDescription)
            }
        }
    }
    
    @MainActor
    func cancelManualCapture() {
        beginAction(ActionID.manualCancel, title: "Cancelling", message: "Discarding the current manual capture...")
        ManualQuestionCaptureService.shared.cancelCapture()
        ManualQuestionTranscriptionService.shared.cancel()
        self.manualCaptureState = .idle
        self.manualCaptureTranscript = ""
        self.manualCaptureSuggestion = nil
        self.manualCaptureError = nil
        self.manualCaptureBufferCount = 0
        self.manualCaptureLastBufferTimestamp = nil
        completeAction(ActionID.manualCancel, title: "Recording discarded", message: "Ready to record a new question.")
    }
    
    @MainActor
    func sendManualCaptureToAI(forceDeepSeek: Bool = false) {
        guard !isActionLoading(ActionID.manualGenerate) else { return }
        guard self.manualCaptureState == .transcriptReady || 
              self.manualCaptureState == .suggestionReady || 
              caseSuggestionError(self.manualCaptureState) else { return }
        
        let rawText = self.manualCaptureTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty else {
            self.manualCaptureState = .suggestionError("Transcript is empty.")
            failAction(ActionID.manualGenerate, title: "Generation failed", message: "Transcript is empty.")
            return
        }
        
        // Clean transcript conservatively
        let text = cleanTranscript(rawText)
        
        self.manualCaptureState = .generatingSuggestion
        beginAction(ActionID.manualGenerate, title: "Generating first answer", message: "Keeping the transcript visible while generating...")
        
        Task {
            do {
                // Initialize a mock or manual DetectedQuestion
                let questionID = UUID().uuidString
                let currentSessionID = self.currentSession?.id ?? UUID().uuidString
                
                let source: AudioSourceType = (settings.manualCaptureSource == .systemAudio) ? .systemAudio : .microphone
                let speaker: SpeakerRole = (settings.manualCaptureSource == .systemAudio) ? .interviewer : .unknown
                
                let customConfig: LLMProviderConfiguration?
                if forceDeepSeek {
                    guard let deepSeekConfig = providerConfigurations.first(where: { $0.kind == .deepSeek }) else {
                        throw LLMProviderError.notConfigured("DeepSeek provider not found. Please add DeepSeek in settings.")
                    }
                    customConfig = deepSeekConfig
                } else {
                    customConfig = nil
                }
                
                let activeProvider = customConfig ?? activeRealtimeProvider
                
                let detected = DetectedQuestion(
                    id: questionID,
                    sessionID: currentSessionID,
                    transcriptSegmentID: nil,
                    questionText: text,
                    intent: .technical,
                    answerStrategy: .directAnswer,
                    confidence: 0.95,
                    reason: "Manual Capture Triggered",
                    shouldTrigger: true,
                    questionComplete: true,
                    modelName: activeProvider?.model ?? "deepseek-v4-flash",
                    promptVersion: "v1",
                    providerKind: activeProvider?.kind,
                    providerName: activeProvider?.name,
                    providerBaseURL: activeProvider?.baseURL,
                    latencyMS: nil,
                    isLocal: false,
                    rawJSON: nil,
                    createdAt: Date()
                )
                
                // gate context to 800 CV / 600 JD words
                let (context, trace) = try await contextRetrievalService.retrieveContextWithTrace(
                    question: text,
                    intent: .technical,
                    maxCVWords: 800,
                    maxJDWords: 600,
                    strategy: detected.answerStrategy
                )
                
                // empty transcript context
                let transcriptContext = ""
                
                // suggestion timeout interval is kept under the legacy settings key for migration compatibility.
                let timeout = TimeInterval(settings.generationRequestTimeoutSeconds)
                
                let result = try await suggestionGenerationService.generate(
                    question: detected,
                    context: context,
                    transcriptContext: transcriptContext,
                    sessionID: currentSessionID,
                    timeoutInterval: timeout,
                    customProviderConfig: customConfig
                )
                
                self.lastSuggestionGenerationProvider = result.response.providerName
                self.lastSuggestionGenerationModel = result.response.modelName
                self.manualCaptureSuggestion = result.card
                self.manualCaptureState = .suggestionReady
                self.completeAction(ActionID.manualGenerate, title: "Answer ready", message: "Manual capture answer is visible.")
                
                // If a live session is running, persist to database and update lists
                if let session = self.currentSession {
                    // Create and save a new TranscriptSegment representing the interviewer question
                    let segment = TranscriptSegment(
                        id: UUID().uuidString,
                        sessionID: session.id,
                        source: source,
                        speaker: speaker,
                        text: rawText, // Keep raw in transcript segment
                        startTime: nil,
                        endTime: nil,
                        createdAt: Date(),
                        inputDeviceName: AudioDeviceManager.shared.currentInputDeviceName,
                        outputDeviceName: AudioDeviceManager.shared.currentOutputDeviceName,
                        deviceID: nil,
                        confidence: 0.95
                    )
                    
                    try? self.transcriptRepository.saveSegment(segment)
                    
                    // Update current list of segments
                    self.transcriptSegments.append(segment)
                    
                    // Save detected question and suggestion card
                    var savedQuestion = detected
                    savedQuestion.transcriptSegmentID = segment.id
                    savedQuestion.latencyMS = result.response.latencyMS
                    try? self.suggestionRepository.saveDetectedQuestion(savedQuestion)
                    
                    var savedCard = result.card
                    savedCard.questionID = savedQuestion.id
                    
                    // Save card and retrieved chunks atomically
                    try self.suggestionRepository.saveSuggestionCard(savedCard, retrievedChunks: trace.rankedCVChunks + trace.rankedJDChunks)
                    
                    // Update AppState current suggestions
                    self.lastRetrievalTrace = trace
                    self.currentSuggestionRetrievedChunks = trace.rankedCVChunks + trace.rankedJDChunks
                    self.currentSuggestion = savedCard
                    self.lastDetectedQuestion = savedQuestion
                    
                    // Update diagnostics
                    self.updateDiagnostics { diag in
                        diag.apiCallCount += 1
                        diag.lastAPILatencyMS = result.response.latencyMS
                        diag.lastProviderName = result.response.providerName
                        diag.lastProviderModel = result.response.modelName
                        diag.lastRetrievalTrace = trace
                        diag.rawTranscript = rawText
                        diag.cleanedQuestion = text
                    }
                } else {
                    // Update diagnostics even if session doesn't run
                    self.lastRetrievalTrace = trace
                    self.currentSuggestionRetrievedChunks = trace.rankedCVChunks + trace.rankedJDChunks
                    self.updateDiagnostics { diag in
                        diag.apiCallCount += 1
                        diag.lastAPILatencyMS = result.response.latencyMS
                        diag.lastProviderName = result.response.providerName
                        diag.lastProviderModel = result.response.modelName
                        diag.lastRetrievalTrace = trace
                        diag.rawTranscript = rawText
                        diag.cleanedQuestion = text
                    }
                }
            } catch {
                self.manualCaptureState = .suggestionError(error.localizedDescription)
                self.failAction(ActionID.manualGenerate, title: "Generation failed", message: "Transcript preserved. \(error.localizedDescription)")
                self.updateDiagnostics { diag in
                    diag.lastError = error.localizedDescription
                    diag.rawTranscript = rawText
                    diag.cleanedQuestion = text
                }
            }
        }
    }
    
    func caseSuggestionError(_ state: ManualCaptureState) -> Bool {
        if case .suggestionError = state { return true }
        return false
    }

    func cleanTranscript(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        
        let lowercased = text.lowercased()
        
        // Conservative cleanup
        if lowercased.hasSuffix("what you offer") {
            if let range = text.range(of: "what you offer", options: [.caseInsensitive, .backwards]) {
                text.replaceSubrange(range, with: "what do you offer?")
            }
        } else if lowercased == "what you offer" {
            text = "What do you offer?"
        }
        
        if let first = text.first, first.isLowercase {
            text = text.prefix(1).uppercased() + text.dropFirst()
        }
        
        let questionWords = ["what", "why", "how", "who", "when", "where", "which", "are", "is", "do", "does", "did", "can", "could", "would", "should", "will"]
        let firstWord = text.split(separator: " ").first?.lowercased() ?? ""
        if questionWords.contains(firstWord) {
            if !text.hasSuffix("?") && !text.hasSuffix(".") && !text.hasSuffix("!") {
                text += "?"
            }
        }
        
        return text
    }
    
    @MainActor
    func retryManualCapture() {
        beginAction(ActionID.manualRecord, title: "Resetting capture", message: "Clearing the previous manual recording...")
        self.manualCaptureTranscript = ""
        self.manualCaptureSuggestion = nil
        self.manualCaptureError = nil
        self.manualCaptureBufferCount = 0
        self.manualCaptureLastBufferTimestamp = nil
        self.manualCaptureState = .idle
        completeAction(ActionID.manualRecord, title: "Ready to record", message: "Record a new interviewer question.")
    }
    
    @MainActor
    func clearManualCapture() {
        beginAction(ActionID.manualClear, title: "Clearing manual capture", message: "Removing transcript and suggestion from the manual capture panel...")
        cancelStageBTask()
        self.manualCaptureTranscript = ""
        self.manualCaptureSuggestion = nil
        self.manualCaptureError = nil
        self.manualCaptureBufferCount = 0
        self.manualCaptureLastBufferTimestamp = nil
        self.manualCaptureState = .idle
        completeAction(ActionID.manualClear, title: "Manual capture cleared", message: "Ready to record again.")
    }
    
    @MainActor
    func regenerateManualSuggestion() {
        guard self.manualCaptureState == .transcriptReady || 
              self.manualCaptureState == .suggestionReady || 
              caseSuggestionError(self.manualCaptureState) else { return }
        sendManualCaptureToAI()
    }

    @MainActor
    func injectVerificationMockData() {
        guard ProcessInfo.processInfo.environment["ENABLE_VERIFICATION_MOCKS"] == "1" else { return }
        
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
        
        self.currentSuggestion = mockCard
        self.currentSuggestionRetrievedChunks = cvChunks.filter { $0.isIncludedInPrompt } + jdChunks.filter { $0.isIncludedInPrompt }
        self.manualCaptureSuggestion = mockCard
        self.manualCaptureState = .suggestionReady
        
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
            
            if ProcessInfo.processInfo.environment["DEFAULT_APP_SECTION"] == "sessions" {
                self.selectedSessionID = "mock-session-id"
                loadSessionDetails(sessionID: "mock-session-id")
            } else if ProcessInfo.processInfo.environment["DEFAULT_APP_SECTION"] == "floating" {
                self.showFloatingAssistant()
            }
        } catch {
            print("Failed to save mock database elements: \(error)")
        }
    }

    // MARK: - RAG Phase 3 Embedding Tasks

    func resolveEmbeddingProvider() -> EmbeddingProvider? {
        let kind = settings.embeddingProviderKind
        let model = settings.embeddingModelName
        let timeout = TimeInterval(settings.embeddingTimeoutSeconds)
        switch kind {
        case .openAICompatibleCloud:
            guard keychainService.hasAPIKey(account: settings.embeddingApiKeyAccount) else {
                lastEmbeddingError = "Keyword RAG ready; vector embeddings not configured."
                return nil
            }
            return CloudEmbeddingProvider(
                providerID: currentEmbeddingProviderID(for: settings),
                displayName: "Cloud Embeddings",
                baseURL: settings.embeddingBaseURL,
                apiKeyAccount: settings.embeddingApiKeyAccount,
                modelName: model,
                dimensions: settings.embeddingDimension > 0 ? settings.embeddingDimension : nil,
                requestFormat: .openAICompatible,
                apiKeyStore: keychainService,
                timeoutInterval: timeout
            )
        case .customCloud:
            guard keychainService.hasAPIKey(account: settings.embeddingApiKeyAccount) else {
                lastEmbeddingError = "Keyword RAG ready; vector embeddings not configured."
                return nil
            }
            return CloudEmbeddingProvider(
                providerID: currentEmbeddingProviderID(for: settings),
                displayName: "Custom Cloud Embeddings",
                baseURL: settings.embeddingBaseURL,
                apiKeyAccount: settings.embeddingApiKeyAccount,
                modelName: model,
                dimensions: settings.embeddingDimension > 0 ? settings.embeddingDimension : nil,
                requestFormat: .openAICompatible,
                apiKeyStore: keychainService,
                timeoutInterval: timeout
            )
        case .localOllama:
            lastEmbeddingError = "Local embeddings are disabled. Please choose a cloud embedding provider."
            return nil
        case .disabled:
            lastEmbeddingError = "Keyword RAG ready; vector embeddings not configured."
            return nil
        case .mock:
            return ControlledMockEmbeddingProvider()
        }
    }

    func triggerEmbeddingGeneration(for type: DocumentType) {
        guard settings.autoGenerateEmbeddingsOnDocumentSave else { return }
        guard let provider = resolveEmbeddingProvider() else { return }
        
        let providerID = provider.providerID
        let modelName = provider.modelName
        
        Task {
            do {
                let dim = try await provider.dimension
                let chunks = try documentRepository.chunks(type: type)
                
                for chunk in chunks {
                    let expectedHash = documentRepository.calculateContentHash(
                        content: chunk.content,
                        sectionTitle: chunk.sectionTitle,
                        provider: providerID,
                        modelName: modelName,
                        dimension: dim
                    )
                    
                    if chunk.embeddingContentHash == expectedHash && chunk.embedding != nil {
                        continue
                    }
                    
                    let vector = try await provider.embed(text: chunk.content)
                    try documentRepository.updateChunkEmbedding(
                        chunkID: chunk.id,
                        embedding: vector,
                        model: modelName,
                        provider: providerID,
                        dimension: dim,
                        contentHash: expectedHash
                    )
                }
                
                refreshAll()
            } catch {
                print("[AppState] Background embedding generation failed: \(error.localizedDescription)")
                showError("Background embedding generation failed: \(error.localizedDescription)")
            }
        }
    }

    func rebuildAllEmbeddings() {
        let actionID = ActionID.rebuildEmbeddings
        guard !isActionLoading(actionID) else { return }
        guard let provider = resolveEmbeddingProvider() else {
            isRebuildingEmbeddings = false
            rebuildProgress = 1.0
            lastEmbeddingTestStatus = "Keyword RAG ready; vector embeddings not configured."
            refreshAll()
            infoAction(actionID, title: "Keyword search ready", message: "Embedding provider not configured; keyword context is ready.")
            return
        }
        
        cancelEmbeddingRebuild()
        beginAction(actionID, title: "Rebuilding embeddings", message: "Preparing clean context chunks for cloud embeddings...")
        isRebuildingEmbeddings = true
        rebuildProgress = 0.0
        
        let providerID = provider.providerID
        let modelName = provider.modelName
        
        activeEmbeddingRebuildTask = Task { [weak self] in
            guard let self else { return }
            do {
                let dim = try await provider.dimension
                let all = try self.documentRepository.allChunks()
                
                if all.isEmpty {
                    await MainActor.run {
                        self.isRebuildingEmbeddings = false
                        self.rebuildProgress = 1.0
                        self.warnAction(actionID, title: "No chunks to embed", message: "Save documents or rebuild the clean context index first.")
                    }
                    return
                }
                
                for (index, chunk) in all.enumerated() {
                    if Task.isCancelled { break }
                    
                    let expectedHash = self.documentRepository.calculateContentHash(
                        content: chunk.content,
                        sectionTitle: chunk.sectionTitle,
                        provider: providerID,
                        modelName: modelName,
                        dimension: dim
                    )
                    
                    if chunk.embeddingContentHash == expectedHash && chunk.embedding != nil {
                        await MainActor.run {
                            self.rebuildProgress = Double(index + 1) / Double(all.count)
                        }
                        continue
                    }
                    
                    do {
                        let vector = try await provider.embed(text: chunk.content)
                        try self.documentRepository.updateChunkEmbedding(
                            chunkID: chunk.id,
                            embedding: vector,
                            model: modelName,
                            provider: providerID,
                            dimension: dim,
                            contentHash: expectedHash
                        )
                    } catch {
                        print("[AppState] Failed to embed chunk \(chunk.id): \(error.localizedDescription)")
                    }
                    
                    await MainActor.run {
                        self.rebuildProgress = Double(index + 1) / Double(all.count)
                    }
                }
                
                await MainActor.run {
                    self.isRebuildingEmbeddings = false
                    self.lastEmbeddingTestStatus = "Embedding rebuild complete."
                    self.refreshAll()
                    self.completeAction(actionID, title: "Embeddings rebuilt", message: "\(all.count) chunks checked for cloud embeddings.")
                }
            } catch {
                await MainActor.run {
                    self.isRebuildingEmbeddings = false
                    self.lastEmbeddingError = error.localizedDescription
                    let message = "Failed to rebuild embeddings: \(error.localizedDescription)"
                    self.failAction(actionID, title: "Embedding rebuild failed", message: message)
                    self.showError(message)
                }
            }
        }
    }

    private func currentEmbeddingProviderID(for settings: AppSettings) -> String {
        switch settings.embeddingProviderKind {
        case .openAICompatibleCloud:
            return "cloudOpenAICompatible"
        case .customCloud:
            return "cloudCustom"
        case .mock:
            return "controlled-mock"
        case .disabled:
            return "disabled"
        case .localOllama:
            return "legacyLocalProviderDisabled"
        }
    }

    func cancelEmbeddingRebuild() {
        activeEmbeddingRebuildTask?.cancel()
        activeEmbeddingRebuildTask = nil
        isRebuildingEmbeddings = false
        warnAction(ActionID.rebuildEmbeddings, title: "Embedding rebuild cancelled", message: "Existing context remains available.")
    }

    func rebuildCleanRAGIndex() {
        let actionID = ActionID.rebuildCleanRAG
        guard !isActionLoading(actionID) else { return }
        beginAction(actionID, title: "Rebuilding clean index", message: "Sanitizing documents and rebuilding chunks...")
        Task {
            do {
                let result = try documentRepository.rebuildCleanRAGIndex()
                await MainActor.run {
                    self.refreshAll()
                    let polluted = self.latexPollutedChunkCount
                    if self.settings.enableVectorRAG {
                        self.completeAction(actionID, title: "Clean index rebuilt", message: "\(result.chunksRebuilt) clean chunks ready. Updating embeddings next...")
                        self.rebuildAllEmbeddings()
                    } else {
                        self.completeAction(actionID, title: "Clean index rebuilt", message: "\(result.chunksRebuilt) clean chunks ready. \(polluted) LaTeX warnings remain.")
                    }
                }
            } catch {
                await MainActor.run {
                    let message = "Failed to rebuild clean RAG index: \(error.localizedDescription)"
                    self.failAction(actionID, title: "Rebuild failed", message: "Existing index preserved. \(message)")
                    self.showError(message)
                }
            }
        }
    }

    public func refreshLatencyAverages() {
        do {
            self.latencyAveragesOverall = try self.suggestionRepository.fetchLatencyAverages(last: 10)
            self.latencyAveragesDeepSeek = try self.suggestionRepository.fetchLatencyAverages(last: 10, provider: "DeepSeek")
        } catch {
            print("[AppState] Failed to refresh latency averages: \(error.localizedDescription)")
        }
    }
}

private final class StageBTrigger {
    private var continuation: CheckedContinuation<Void, Never>?
    private var triggered = false
    private let lock = NSLock()
    
    func wait(timeoutMs: Int) async {
        await withCheckedContinuation { cont in
            lock.lock()
            if triggered {
                lock.unlock()
                cont.resume()
                return
            }
            continuation = cont
            lock.unlock()
            
            // Set up a timeout fallback
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                self.trigger()
            }
        }
    }
    
    func trigger() {
        lock.lock()
        defer { lock.unlock() }
        guard !triggered else { return }
        triggered = true
        continuation?.resume()
        continuation = nil
    }
}

public protocol DelayProvider: Sendable {
    func sleep(nanoseconds: UInt64) async throws
}

public final class RealDelayProvider: DelayProvider {
    public init() {}
    public func sleep(nanoseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}
