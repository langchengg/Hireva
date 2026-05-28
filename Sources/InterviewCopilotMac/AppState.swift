import AppKit
import AVFoundation
import Combine
import Foundation
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case home
    case live
    case documents
    case sessions
    case providerDiagnostics
    case permissions
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .live: return "Live Interview"
        case .documents: return "Documents"
        case .sessions: return "Sessions"
        case .providerDiagnostics: return "Provider Diagnostics"
        case .permissions: return "Audio Diagnostics"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house"
        case .live: return "waveform.and.mic"
        case .documents: return "doc.text"
        case .sessions: return "clock.arrow.circlepath"
        case .providerDiagnostics: return "server.rack"
        case .permissions: return "waveform.path.ecg"
        case .settings: return "gearshape"
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
    @Published var ollamaModels: [LLMModelInfo] = []
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
    
    // RAG Phase 3 Embedding properties
    @Published var embeddingCoverage: EmbeddingCoverage? = nil
    @Published var rebuildProgress: Double = 0.0
    @Published var isRebuildingEmbeddings: Bool = false
    private var activeEmbeddingRebuildTask: Task<Void, Never>? = nil
    @Published var historicalSuggestionChunks: [String: [RetrievedChunk]] = [:]

    // MARK: - Manual Capture Push-to-Ask state
    @Published public var interviewCopilotMode: InterviewCopilotMode = .autoDetect {
        didSet {
            if interviewCopilotMode == .manualCapture {
                stopAllContinuousPipelines()
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
    @Published public var recognitionRequestActive: Bool = false
    @Published public var recognitionTaskActive: Bool = false

    // --- Pipeline Helper Diagnostics ---
    var isAudioEngineRunning: Bool { AudioEngineManager.shared.isEngineRunning }
    var isMicPipelineActive: Bool { microphonePipeline != nil }
    var isMicASRTaskActive: Bool { microphonePipeline?.isRecognitionTaskActive == true }
    var isSystemAudioASRActive: Bool { systemAudioPipeline?.isRecognitionTaskActive == true }


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
    @Published public var suggestionLatencyMS: Int = 0
    @Published public var lastSuggestionCardJSON: String = ""
    @Published public var floatingPanelUpdated: Bool = false


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
    private var microphonePipeline: MicrophoneTranscriptionPipeline?
    private var systemAudioPipeline: SystemAudioTranscriptionPipeline?
    private var micTranscriptionTask: Task<Void, Never>?
    private var systemTranscriptionTask: Task<Void, Never>?
    
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
        permissionService: PermissionService? = nil
    ) {
        let documents = DocumentRepository(database: database)
        let sessions = SessionRepository(database: database)
        let transcripts = TranscriptRepository(database: database)
        let suggestions = SuggestionRepository(database: database)
        let recaps = RecapRepository(database: database)
        let settings = SettingsRepository(database: database)
        let keychain = KeychainService()
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
    }

    var onboardingComplete: Bool {
        hasCV && hasJD
    }

    var liveBlockedReason: String? {
        if !hasCV && !hasJD { return "Add your CV and job description before using Live Interview." }
        if !hasCV { return "Add your CV before using Live Interview." }
        if !hasJD { return "Add the job description before using Live Interview." }
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
        if provider.kind == .ollamaLocal {
            return "Local mode: prompts stay on this Mac, except transcription provider may still use cloud if configured."
        }
        return "Cloud mode: selected transcript and CV/JD snippets are sent to \(provider.name)."
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
            let cvCount = (try? documentRepository.chunks(type: .cv).count) ?? 0
            let jdCount = (try? documentRepository.chunks(type: .jobDescription).count) ?? 0
            refreshPermissions()
            updateDiagnostics {
                $0.storedCVChunkCount = cvCount
                $0.storedJDChunkCount = jdCount
                $0.apiCallCount = (try? self.settingsRepository.apiCallCount()) ?? 0
            }
            
            let currentProvStr = settings.embeddingProviderKind.rawValue
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
        } catch {
            showError(error.localizedDescription)
        }
    }

    func selectSection(_ section: AppSection) {
        if section == .live, let reason = liveBlockedReason {
            showError(reason)
            selectedSection = .documents
            return
        }
        selectedSection = section
    }

    func saveDocument(type: DocumentType, title: String, content: String) {
        do {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 80 else {
                showError("\(type.title) is too short to save. Paste at least 80 characters so suggestions can be grounded in meaningful context.")
                return
            }
            _ = try documentRepository.saveDocument(type: type, title: title, content: content)
            refreshAll()
            triggerEmbeddingGeneration(for: type)
        } catch {
            showError("Could not save \(type.title): \(error.localizedDescription)")
        }
    }

    func deleteDocument(_ document: DocumentRecord) {
        do {
            try documentRepository.deleteDocument(id: document.id)
            refreshAll()
        } catch {
            showError("Could not delete document: \(error.localizedDescription)")
        }
    }

    func saveSettings(_ newSettings: AppSettings) {
        var next = newSettings
        if next.highContrastFloatingPanel {
            next.floatingWindowOpacity = max(next.floatingWindowOpacity, 0.65)
        }
        do {
            settings = next
            try settingsRepository.saveSettings(next)
            refreshAll()
        } catch {
            showError("Could not save settings: \(error.localizedDescription)")
        }
    }

    func saveAPIKey(_ apiKey: String) {
        do {
            try keychainService.saveAPIKey(apiKey)
            hasAPIKey = true
            connectionResult = "API key saved in Keychain."
        } catch {
            showError("Could not save API key: \(error.localizedDescription)")
        }
    }

    func saveAPIKey(_ apiKey: String, for provider: LLMProviderConfiguration) {
        guard let account = provider.apiKeyAccount else {
            connectionResult = "\(provider.name) does not require an API key."
            return
        }
        do {
            try keychainService.saveAPIKey(apiKey, account: account)
            hasAPIKey = true
            providerConnectionResults[provider.id] = "API key saved in Keychain."
        } catch {
            showError("Could not save API key: \(error.localizedDescription)")
        }
    }

    func deleteAPIKey() {
        do {
            try keychainService.deleteAPIKey()
            hasAPIKey = false
            connectionResult = "API key removed."
        } catch {
            showError("Could not remove API key: \(error.localizedDescription)")
        }
    }

    func saveProviderConfiguration(_ provider: LLMProviderConfiguration) {
        do {
            try settingsRepository.saveProviderConfiguration(provider)
            refreshAll()
        } catch {
            showError("Could not save provider: \(error.localizedDescription)")
        }
    }

    func deleteProviderConfiguration(_ provider: LLMProviderConfiguration) {
        do {
            try settingsRepository.deleteProviderConfiguration(id: provider.id)
            refreshAll()
        } catch {
            showError("Could not delete provider: \(error.localizedDescription)")
        }
    }

    func setActiveRealtimeProvider(_ provider: LLMProviderConfiguration) {
        do {
            try settingsRepository.setActiveRealtimeProvider(id: provider.id)
            refreshAll()
        } catch {
            showError("Could not set realtime provider: \(error.localizedDescription)")
        }
    }

    func updateActiveRealtimeProvider(provider: LLMProviderConfiguration, model: String?) {
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
                Task {
                    do {
                        let models = try await llmRouter.listModels(configuration: updated)
                        if !models.contains(where: { $0.name == updated.model }) {
                            throw LLMProviderError.modelNotFound(updated.model)
                        }
                        
                        try settingsRepository.saveProviderConfiguration(updated)
                        try settingsRepository.setActiveRealtimeProvider(id: updated.id)
                        
                        await MainActor.run {
                            self.refreshAll()
                            self.refreshOllamaModels(for: updated)
                        }
                    } catch {
                        await MainActor.run {
                            let msg = self.userFacing(error)
                            self.lastProviderSwitchError = msg
                            self.errorMessage = "Could not switch provider: \(msg)"
                        }
                    }
                }
            } else if updated.kind == .deepSeek || updated.kind == .openAICompatible {
                guard let account = updated.apiKeyAccount,
                      keychainService.hasAPIKey(account: account) else {
                    let msg = "Missing API Key for \(updated.name)."
                    self.lastProviderSwitchError = msg
                    self.errorMessage = "Could not switch provider: \(msg)"
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
        } catch {
            let msg = error.localizedDescription
            self.lastProviderSwitchError = msg
            self.errorMessage = "Could not switch provider: \(msg)"
        }
    }

    func setActiveRecapProvider(_ provider: LLMProviderConfiguration) {
        do {
            try settingsRepository.setActiveRecapProvider(id: provider.id)
            refreshAll()
        } catch {
            showError("Could not set recap provider: \(error.localizedDescription)")
        }
    }

    func testProviderConnection(_ provider: LLMProviderConfiguration) {
        isTestingConnection = true
        providerConnectionResults[provider.id] = nil
        activeAITask?.cancel()
        activeAITask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await llmRouter.testProvider(configuration: provider)
                guard !Task.isCancelled else { return }
                providerConnectionResults[provider.id] = result.message
                if provider.kind == .ollamaLocal {
                    ollamaModels = result.models
                }
                updateDiagnostics {
                    $0.lastAPILatencyMS = result.latencyMS
                    $0.lastProviderName = provider.name
                    $0.lastProviderModel = provider.model
                }
            } catch {
                guard !Task.isCancelled else { return }
                let message = self.userFacing(error)
                providerConnectionResults[provider.id] = message
                updateDiagnostics { $0.lastError = message }
            }
            isTestingConnection = false
        }
    }

    func refreshOllamaModels(for provider: LLMProviderConfiguration) {
        activeAITask?.cancel()
        activeAITask = Task { [weak self] in
            guard let self else { return }
            do {
                let models = try await llmRouter.listModels(configuration: provider)
                guard !Task.isCancelled else { return }
                ollamaModels = models
                providerConnectionResults[provider.id] = "Found \(models.count) local Ollama models."
            } catch {
                guard !Task.isCancelled else { return }
                providerConnectionResults[provider.id] = self.userFacing(error)
            }
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
        guard let provider = providerConfigurations.first(where: { $0.kind == .deepSeek }) else {
            connectionResult = "DeepSeek provider is not configured."
            return
        }
        guard provider.apiKeyAccount.map({ keychainService.hasAPIKey(account: $0) }) ?? false else {
            connectionResult = "Add a DeepSeek API key before testing the connection."
            return
        }
        isTestingConnection = true
        connectionResult = nil
        activeAITask?.cancel()
        activeAITask = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await llmRouter.testProvider(configuration: provider)
                guard !Task.isCancelled else { return }
                connectionResult = response.message
                updateDiagnostics {
                    $0.lastAPILatencyMS = response.latencyMS
                    $0.lastProviderName = provider.name
                    $0.lastProviderModel = provider.model
                }
            } catch {
                guard !Task.isCancelled else { return }
                connectionResult = self.userFacing(error)
                updateDiagnostics { $0.lastError = self.userFacing(error) }
            }
            isTestingConnection = false
        }
    }

    func startListening(mode: InterviewMode) {
        guard onboardingComplete else {
            showError(liveBlockedReason ?? "Complete onboarding first.")
            return
        }
        guard liveState.canStartListening else { return }
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
                        showError("Grant microphone permission to start live transcription. You can change this in macOS Privacy & Security settings.")
                        return
                    }
                    
                    var speech = permissionService.speechStatus()
                    if speech == .notDetermined {
                        speech = await permissionService.requestSpeechRecognition()
                        refreshPermissions()
                    }
                    
                    guard speech == .granted else {
                        liveState = .permissionDenied
                        showError("Speech Recognition permission is required for Apple Speech transcription. Grant access in macOS Privacy & Security settings, or use Practice Testing.")
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
                                switch finalState {
                                case .permissionMissing:
                                    showError("Enable Screen & System Audio Recording in System Settings to capture interviewer audio.")
                                case .restartLikely:
                                    showError("macOS requires restarting the application for Screen & System Audio Recording to take effect.")
                                case .identityMismatch:
                                    showError("Application identity mismatch suspected. macOS permissions may not match System Settings.")
                                case .shareableContentProbeFailed(let err):
                                    showError("ScreenCaptureKit shareable content probe failed: \(err)")
                                case .streamAudioProbeFailed(let err):
                                    showError("System audio capture stream failed: \(err)")
                                case .granted:
                                    break
                                }
                                return
                            }
                        } else {
                            liveState = .permissionDenied
                            switch state {
                            case .restartLikely:
                                showError("macOS requires restarting the application for Screen & System Audio Recording to take effect.")
                            case .identityMismatch:
                                showError("Application identity mismatch suspected. macOS permissions may not match System Settings.")
                            case .shareableContentProbeFailed(let err):
                                showError("ScreenCaptureKit shareable content probe failed: \(err)")
                            case .streamAudioProbeFailed(let err):
                                showError("System audio capture stream failed: \(err)")
                            case .permissionMissing:
                                showError("Enable Screen & System Audio Recording in System Settings to capture interviewer audio.")
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
            } else {
                let captureMode = settings.audioCaptureMode
                
                // Start Microphone Pipeline
                if captureMode == .microphoneOnly || captureMode == .microphoneAndSystem {
                    print("[Pipeline] starting microphone pipeline = true")
                    let micPipeline = MicrophoneTranscriptionPipeline()
                    self.microphonePipeline = micPipeline
                    try await micPipeline.start(sessionID: session.id)
                    
                    micTranscriptionTask = Task { [weak self] in
                        for await segment in micPipeline.segments {
                            guard !Task.isCancelled else { return }
                            await self?.handleTranscriptSegment(segment)
                        }
                    }
                    
                    // Keep diagnostics active during transcription for real-time visual levels
                    microphoneDiagnostics.refreshSelectedInputDevice()
                    AudioEngineManager.shared.register(microphoneDiagnostics)
                } else {
                    print("[Pipeline] starting microphone pipeline = false")
                }
                
                // Start System Audio Pipeline
                if captureMode == .systemAudioOnly || captureMode == .microphoneAndSystem {
                    print("[Pipeline] starting system audio pipeline = true")
                    let sysPipeline = SystemAudioTranscriptionPipeline()
                    self.systemAudioPipeline = sysPipeline
                    self.lastSystemAudioASRError = nil
                    self.lastSystemAudioASRPartialTranscript = ""
                    self.lastSystemAudioASRFinalTranscript = ""
                    try await sysPipeline.start(
                        sessionID: session.id,
                        onPartialResult: { [weak self] partial in
                            Task { @MainActor in
                                self?.lastSystemAudioASRPartialTranscript = partial
                            }
                        },
                        onFinalResult: { [weak self] final in
                            Task { @MainActor in
                                self?.lastSystemAudioASRFinalTranscript = final
                            }
                        },
                        onError: { [weak self] errMsg in
                            Task { @MainActor in
                                self?.lastSystemAudioASRError = errMsg
                            }
                        }
                    )
                    
                    systemTranscriptionTask = Task { [weak self] in
                        for await segment in sysPipeline.segments {
                            guard !Task.isCancelled else { return }
                            await self?.handleTranscriptSegment(segment)
                        }
                    }
                } else {
                    print("[Pipeline] starting system audio pipeline = false")
                }
                
                liveState = .listening
                showFloatingAssistant()
                
                // Start background silence / signal validation
                startAudioSignalMonitoring()
            }
        } catch {
            let message = userFacing(error)
            liveState = .error(message)
            showError(message)
        }
    }

    func stopListening() {
        guard liveState.canStop else { return }
        activeAITask?.cancel()
        detectionDebounceTask?.cancel()
        transcriptionTask?.cancel()
        micTranscriptionTask?.cancel()
        systemTranscriptionTask?.cancel()
        
        activeTranscriptionProvider?.stop()
        activeTranscriptionProvider = nil
        
        microphonePipeline?.stop()
        microphonePipeline = nil
        systemAudioPipeline?.stop()
        systemAudioPipeline = nil
        
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
        suggestionLatencyMS = 0
        lastSuggestionCardJSON = ""
        floatingPanelUpdated = false

        
        if let sessionID = currentSession?.id {
            try? sessionRepository.endSession(id: sessionID)
        }
        liveState = .stopped
        refreshAll()
    }

    func clearLiveSession() {
        activeAITask?.cancel()
        detectionDebounceTask?.cancel()
        transcriptionTask?.cancel()
        micTranscriptionTask?.cancel()
        systemTranscriptionTask?.cancel()
        
        activeTranscriptionProvider?.stop()
        activeTranscriptionProvider = nil
        
        microphonePipeline?.stop()
        microphonePipeline = nil
        systemAudioPipeline?.stop()
        systemAudioPipeline = nil
        
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
        guard liveState.canAnswerNow else { return }
        guard onboardingComplete else {
            showError(liveBlockedReason ?? "Complete onboarding first.")
            return
        }
        guard let session = currentSession ?? (try? sessionRepository.createSession(mode: .mock)) else {
            showError("Could not create an interview session.")
            return
        }
        currentSession = session
        let transcript = recentTranscriptText()
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showError("There is no transcript yet. Start Listening first, or use Practice / Developer Testing to inject a test question.")
            return
        }

        activeAITask?.cancel()
        activeAITask = Task { [weak self] in
            guard let self else { return }
            await self.runManualAnswer(session: session, transcript: transcript)
        }
    }

    func generateRecap(for session: InterviewSession) {
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
            } catch {
                guard !Task.isCancelled else { return }
                showError(userFacing(error))
            }
            isGeneratingRecap = false
        }
    }

    func exportSelectedRecap() {
        guard let recap = selectedSessionRecap,
              let session = sessions.first(where: { $0.id == recap.sessionID }) else { return }
        do {
            let url = try recapRepository.exportMarkdown(recap: recap, sessionTitle: session.title)
            connectionResult = "Exported recap to \(url.path)."
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            showError("Could not export recap: \(error.localizedDescription)")
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
        do {
            try sessionRepository.deleteSession(id: session.id)
            if selectedSessionID == session.id {
                selectedSessionID = nil
                selectedSessionTranscript = []
                selectedSessionSuggestions = []
                selectedSessionRecap = nil
            }
            refreshAll()
        } catch {
            showError("Could not delete session: \(error.localizedDescription)")
        }
    }

    func deleteAllLocalData(includeAPIKey: Bool) {
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
        } catch {
            showError("Could not delete local data: \(error.localizedDescription)")
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
        FloatingAssistantPanelController.shared.show(appState: self)
        isFloatingAssistantVisible = true
    }

    func hideFloatingAssistant() {
        FloatingAssistantPanelController.shared.hide()
        isFloatingAssistantVisible = false
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
        transcriptSegments.append(segment)
        lastTranscriptSnippet = segment.text
        currentSession = currentSession ?? (try? sessionRepository.session(id: segment.sessionID))
        if settings.saveTranscriptsLocally {
            try? transcriptRepository.saveSegment(segment)
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
                liveState = .listening
            }
        } catch {
            guard !Task.isCancelled else { return }
            self.lastQuestionDetectionResult = "Detection failed: \(error.localizedDescription)"
            self.lastDetectionSkipReason = "LLM/Detection API call error: \(error.localizedDescription)"
            liveState = .listening
            
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

    private func generateSuggestion(
        for question: DetectedQuestion,
        session: InterviewSession,
        transcript: String,
        autoGenerated: Bool
    ) async throws {
        liveState = .generatingSuggestion
        self.suggestionGenerationStarted = true
        self.floatingPanelUpdated = false
        
        var retrievedContext: RetrievedContext? = nil
        var retrievalTrace: RetrievalTrace? = nil
        do {
            let (context, trace) = try await contextRetrievalService.retrieveContextWithTrace(
                question: question.questionText,
                intent: question.intent,
                maxCVWords: 1_500,
                maxJDWords: 1_000
            )
            retrievedContext = context
            retrievalTrace = trace
            let result = try await suggestionGenerationService.generate(
                question: question,
                context: context,
                transcriptContext: transcript,
                sessionID: session.id,
                model: activeRealtimeProvider?.model
            )
            guard !Task.isCancelled else {
                self.suggestionGenerationStarted = false
                return
            }
            self.lastSuggestionGenerationProvider = result.response.providerName
            self.lastSuggestionGenerationModel = result.response.modelName
            try suggestionRepository.saveSuggestionCard(result.card, retrievedChunks: trace.rankedCVChunks + trace.rankedJDChunks)
            self.lastRetrievalTrace = trace
            self.currentSuggestionRetrievedChunks = trace.rankedCVChunks + trace.rankedJDChunks
            currentSuggestion = result.card
            possibleQuestion = nil
            if autoGenerated {
                lastAutoSuggestionAt = Date()
                let fingerprint = normalizedQuestion(question.questionText)
                lastAutoQuestionText = fingerprint
                if !recentQuestionsFingerprints.contains(fingerprint) {
                    recentQuestionsFingerprints.append(fingerprint)
                }
                if recentQuestionsFingerprints.count > 30 {
                    recentQuestionsFingerprints.removeFirst()
                }
            }
            updateDiagnostics {
                $0.lastSuggestionJSON = result.card.rawJSON
                $0.lastAPILatencyMS = result.response.latencyMS
                $0.lastProviderName = result.response.providerName
                $0.lastProviderModel = result.response.modelName
                $0.lastRetrievalTrace = retrievalTrace
                $0.apiCallCount = (try? self.settingsRepository.apiCallCount()) ?? $0.apiCallCount
            }
            
            // Set Suggestion Diagnostics
            self.suggestionProviderModel = "\(result.response.providerName) / \(result.response.modelName)"
            self.suggestionLatencyMS = result.response.latencyMS ?? 0
            self.lastSuggestionCardJSON = result.card.rawJSON ?? ""
            self.floatingPanelUpdated = true
            self.suggestionGenerationStarted = false
            
            print("[AppState] Suggestion card generated and saved: \(result.card.id). Displaying in FloatingAssistantView. Say First: \"\(result.card.sayFirst)\" | Key Points count: \(result.card.keyPoints.count)")
            
            liveState = .listening
        } catch {
            self.suggestionGenerationStarted = false
            self.lastFailedTaskType = .suggestionGeneration
            self.lastFailedQuestion = question
            self.lastFailedTranscriptContext = transcript
            self.lastFailedCVJDContext = retrievedContext
            self.lastFailedProviderConfig = activeRealtimeProvider
            throw error
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

    private func isDuplicateAutoQuestion(_ questionText: String) -> Bool {
        let normalized = normalizedQuestion(questionText)
        guard !normalized.isEmpty else { return false }
        if recentQuestionsFingerprints.contains(normalized) {
            return true
        }
        for fingerprint in recentQuestionsFingerprints {
            if normalized.contains(fingerprint) || fingerprint.contains(normalized) {
                return true
            }
        }
        return false
    }

    private func normalizedQuestion(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
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
        AudioEngineManager.shared.restartForRouteChange(reason: "Manual restart requested by user")
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
        if let sysPipeline = systemAudioPipeline {
            self.systemASRTaskRunning = true
            self.totalSystemAudioASRBuffersAppended = sysPipeline.totalBuffersAppended
            self.recognitionRequestActive = sysPipeline.isRecognitionRequestActive
            self.recognitionTaskActive = sysPipeline.isRecognitionTaskActive
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
        guard microphonePipeline != nil else {
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
    
    private func stopAllContinuousPipelines() {
        activeAITask?.cancel()
        detectionDebounceTask?.cancel()
        transcriptionTask?.cancel()
        micTranscriptionTask?.cancel()
        systemTranscriptionTask?.cancel()
        
        activeTranscriptionProvider?.stop()
        activeTranscriptionProvider = nil
        
        microphonePipeline?.stop()
        microphonePipeline = nil
        systemAudioPipeline?.stop()
        systemAudioPipeline = nil
        
        // Stop diagnostics level metering
        AudioEngineManager.shared.unregister(microphoneDiagnostics)
        microphoneDiagnostics.stopMicTest()
        
        stopAudioSignalMonitoring()
        recentQuestionsFingerprints.removeAll()
        
        liveState = .idle
    }
    
    @MainActor
    func startManualCapture() {
        guard onboardingComplete else {
            showError(liveBlockedReason ?? "Complete onboarding first.")
            return
        }
        
        // Prevent pipeline conflicts
        stopAllContinuousPipelines()
        
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
                        self.manualCaptureState = .error("System audio permission is required to capture interviewer audio.")
                        return
                    }
                } else {
                    // Microphone permission required
                    let micStatus = await permissionService.requestMicrophonePermission()
                    refreshPermissions()
                    guard micStatus == .authorized else {
                        self.manualCaptureState = .error("Microphone permission is required to record speech.")
                        return
                    }
                    
                    let speechStatus = await permissionService.requestSpeechRecognition()
                    refreshPermissions()
                    guard speechStatus == .granted else {
                        self.manualCaptureState = .error("Speech Recognition permission is required for transcription.")
                        return
                    }
                }
                
                self.manualCaptureState = .recording
                
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
            }
        }
    }
    
    @MainActor
    func stopAndTranscribeManualCapture(maxDurationReached: Bool = false) {
        guard self.manualCaptureState == .recording else { return }
        
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
                    self.manualCaptureState = .error("No speech detected or transcription failed. Try recording again.")
                    return
                }
                
                self.manualCaptureState = .transcriptReady
                
                if !settings.showTranscriptBeforeSending && settings.autoSendAfterTranscription {
                    sendManualCaptureToAI()
                }
            } catch {
                self.manualCaptureState = .error(error.localizedDescription)
            }
        }
    }
    
    @MainActor
    func cancelManualCapture() {
        ManualQuestionCaptureService.shared.cancelCapture()
        ManualQuestionTranscriptionService.shared.cancel()
        self.manualCaptureState = .idle
        self.manualCaptureTranscript = ""
        self.manualCaptureSuggestion = nil
        self.manualCaptureError = nil
        self.manualCaptureBufferCount = 0
        self.manualCaptureLastBufferTimestamp = nil
    }
    
    @MainActor
    func sendManualCaptureToAI(forceDeepSeek: Bool = false) {
        guard self.manualCaptureState == .transcriptReady || 
              self.manualCaptureState == .suggestionReady || 
              caseSuggestionError(self.manualCaptureState) else { return }
        
        let rawText = self.manualCaptureTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty else {
            self.manualCaptureState = .suggestionError("Transcript is empty.")
            return
        }
        
        // Clean transcript conservatively
        let text = cleanTranscript(rawText)
        
        self.manualCaptureState = .generatingSuggestion
        
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
                    modelName: activeProvider?.model ?? "Ollama",
                    promptVersion: "v1",
                    providerKind: activeProvider?.kind,
                    providerName: activeProvider?.name,
                    providerBaseURL: activeProvider?.baseURL,
                    latencyMS: nil,
                    isLocal: activeProvider?.kind == .ollamaLocal,
                    rawJSON: nil,
                    createdAt: Date()
                )
                
                // gate context to 800 CV / 600 JD words
                let (context, trace) = try await contextRetrievalService.retrieveContextWithTrace(
                    question: text,
                    intent: .technical,
                    maxCVWords: 800,
                    maxJDWords: 600
                )
                
                // empty transcript context
                let transcriptContext = ""
                
                // suggestion timeout interval is settings.ollamaRequestTimeoutSeconds
                let timeout = TimeInterval(settings.ollamaRequestTimeoutSeconds)
                
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
        self.manualCaptureTranscript = ""
        self.manualCaptureSuggestion = nil
        self.manualCaptureError = nil
        self.manualCaptureBufferCount = 0
        self.manualCaptureLastBufferTimestamp = nil
        self.manualCaptureState = .idle
    }
    
    @MainActor
    func clearManualCapture() {
        self.manualCaptureTranscript = ""
        self.manualCaptureSuggestion = nil
        self.manualCaptureError = nil
        self.manualCaptureBufferCount = 0
        self.manualCaptureLastBufferTimestamp = nil
        self.manualCaptureState = .idle
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
            modelName: "gemma4:26b",
            promptVersion: "v1.0",
            providerKind: .ollamaLocal,
            providerName: "Local Ollama",
            providerBaseURL: "http://localhost:11434",
            latencyMS: 1250,
            isLocal: true,
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
            modelName: "gemma4:26b",
            promptVersion: "v1.0",
            providerKind: .ollamaLocal,
            providerName: "Local Ollama",
            providerBaseURL: "http://localhost:11434",
            latencyMS: 1250,
            isLocal: true,
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
        case .localOllama:
            let config = providerConfigurations.first { $0.kind == .ollamaLocal }
            let url = config?.baseURL ?? "http://localhost:11434"
            return OllamaEmbeddingProvider(modelName: model, baseURL: url, timeoutInterval: timeout)
        case .mock:
            return ControlledMockEmbeddingProvider()
        case .futureCloud:
            return nil
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
        guard let provider = resolveEmbeddingProvider() else {
            showError("No embedding provider resolved.")
            return
        }
        
        cancelEmbeddingRebuild()
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
                    self.refreshAll()
                }
            } catch {
                await MainActor.run {
                    self.isRebuildingEmbeddings = false
                    self.showError("Failed to rebuild embeddings: \(error.localizedDescription)")
                }
            }
        }
    }

    func cancelEmbeddingRebuild() {
        activeEmbeddingRebuildTask?.cancel()
        activeEmbeddingRebuildTask = nil
        isRebuildingEmbeddings = false
    }
}
