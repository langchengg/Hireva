import AppKit
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
    @Published var diagnostics = DeveloperDiagnostics.empty

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
    private let contextRetrievalService: ContextRetrievalService
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

    init(database: AppDatabase) {
        let documents = DocumentRepository(database: database)
        let sessions = SessionRepository(database: database)
        let transcripts = TranscriptRepository(database: database)
        let suggestions = SuggestionRepository(database: database)
        let recaps = RecapRepository(database: database)
        let settings = SettingsRepository(database: database)
        let keychain = KeychainService()
        let router = LLMRouter(settingsRepository: settings, apiKeyStore: keychain)

        self.documentRepository = documents
        self.sessionRepository = sessions
        self.transcriptRepository = transcripts
        self.suggestionRepository = suggestions
        self.recapRepository = recaps
        self.settingsRepository = settings
        self.keychainService = keychain
        self.permissionService = PermissionService()
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
        self.contextRetrievalService = SimpleContextRetrievalService(documentRepository: documents)
        self.llmRouter = router
        self.questionDetectionService = QuestionDetectionService(llmRouter: router)
        self.suggestionGenerationService = SuggestionGenerationService(llmRouter: router)
        self.recapGenerationService = RecapGenerationService(llmRouter: router)
        
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
            refreshPermissions()
            updateDiagnostics { $0.apiCallCount = (try? settingsRepository.apiCallCount()) ?? 0 }
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
                
                // Verify Microphone and Speech permissions if mic is needed
                if captureMode == .microphoneOnly || captureMode == .microphoneAndSystem {
                    var microphone = permissionService.checkMicrophonePermission()
                    if microphone == .notDetermined {
                        microphone = await permissionService.requestMicrophonePermission()
                        refreshPermissions()
                    }

                    guard microphone == .authorized else {
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
                }
                
                // Verify Screen & System Audio recording permission if system capture is needed
                if captureMode == .systemAudioOnly || captureMode == .microphoneAndSystem {
                    guard CGPreflightScreenCaptureAccess() else {
                        liveState = .permissionDenied
                        showError("Enable Screen & System Audio Recording in System Settings to capture interviewer audio.")
                        return
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
                }
                
                // Start System Audio Pipeline
                if captureMode == .systemAudioOnly || captureMode == .microphoneAndSystem {
                    let sysPipeline = SystemAudioTranscriptionPipeline()
                    self.systemAudioPipeline = sysPipeline
                    self.lastSystemAudioASRError = nil
                    try await sysPipeline.start(sessionID: session.id) { [weak self] errMsg in
                        self?.lastSystemAudioASRError = errMsg
                    }
                    
                    systemTranscriptionTask = Task { [weak self] in
                        for await segment in sysPipeline.segments {
                            guard !Task.isCancelled else { return }
                            await self?.handleTranscriptSegment(segment)
                        }
                    }
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
                let context = try contextRetrievalService.retrieveContext(
                    question: transcript.map(\.text).joined(separator: "\n"),
                    intent: .unclear,
                    maxCVWords: 1_500,
                    maxJDWords: 1_000
                )
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
            liveState = .detectingQuestion
            let detection = try await questionDetectionService.detect(
                transcriptContext: transcript,
                sessionID: session.id,
                transcriptSegmentID: triggeringSegmentID,
                model: activeRealtimeProvider?.model
            )
            guard !Task.isCancelled else { return }
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
        let context = try contextRetrievalService.retrieveContext(
            question: question.questionText,
            intent: question.intent,
            maxCVWords: 1_500,
            maxJDWords: 1_000
        )
        let result = try await suggestionGenerationService.generate(
            question: question,
            context: context,
            transcriptContext: transcript,
            sessionID: session.id,
            model: activeRealtimeProvider?.model
        )
        guard !Task.isCancelled else { return }
        try suggestionRepository.saveSuggestionCard(result.card)
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
            $0.apiCallCount = (try? self.settingsRepository.apiCallCount()) ?? $0.apiCallCount
        }
        liveState = .listening
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
}
