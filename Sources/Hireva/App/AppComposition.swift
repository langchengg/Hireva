import AppKit
import Combine
import Foundation

/// Concrete application assembly belongs here, outside feature state owners.
@MainActor
enum AppComposition {
    /// Constructor-local handles sharing one database. No feature retains this
    /// group; its initializer receives only the repositories it actually uses.
    @MainActor
    struct Repositories {
        let documents: DocumentRepository
        let interviewContexts: InterviewContextRepository
        let sessions: SessionRepository
        let transcripts: TranscriptRepository
        let suggestions: SuggestionRepository
        let recaps: RecapRepository
        let settings: SettingsRepository

        init(database: AppDatabase) {
            documents = DocumentRepository(database: database)
            interviewContexts = InterviewContextRepository(database: database)
            sessions = SessionRepository(database: database)
            transcripts = TranscriptRepository(database: database)
            suggestions = SuggestionRepository(database: database)
            recaps = RecapRepository(database: database)
            settings = SettingsRepository(database: database)
        }
    }

    /// The provider-facing services and runtime must share the resolved router.
    /// This value is used only while constructing the application, never as a
    /// feature dependency or a mutable service registry.
    @MainActor
    struct LanguageServices {
        let router: LLMRouter
        let recaps: RecapGenerationService
        let questions: QuestionDetectionService
        let suggestions: SuggestionGenerationService
        let generations: GenerationCoordinator

        init(settings: SettingsRepository, keychain: KeychainService, routerOverride: LLMRouter?) {
            let router = routerOverride ?? LLMRouter(settingsRepository: settings, apiKeyStore: keychain)
            let suggestions = SuggestionGenerationService(llmRouter: router)
            self.router = router
            recaps = RecapGenerationService(llmRouter: router)
            questions = QuestionDetectionService(llmRouter: router)
            self.suggestions = suggestions
            generations = GenerationCoordinator(dependencies: .init(suggestionGenerationService: suggestions))
        }
    }

    @MainActor
    struct DialoguePreferences {
        let defaults: UserDefaults
        let ownedSuiteName: String?
        let migration: DialogueSettingsMigrationResult
    }

    static func resolveDialoguePreferences(override: UserDefaults?, isTestProcess: Bool) -> DialoguePreferences {
        let defaults: UserDefaults
        let ownedSuiteName: String?
        if let override {
            defaults = override
            ownedSuiteName = nil
        } else if isTestProcess {
            let suiteName = "com.langcheng.Hireva.tests.app-state.\(UUID().uuidString)"
            guard let isolated = UserDefaults(suiteName: suiteName) else {
                preconditionFailure("Unable to initialize test preferences.")
            }
            defaults = isolated
            ownedSuiteName = suiteName
        } else {
            defaults = .standard
            ownedSuiteName = nil
        }
        return DialoguePreferences(defaults: defaults, ownedSuiteName: ownedSuiteName,
            migration: DialogueSettingsStore.loadAndMigrate(defaults: defaults))
    }

    static func makeKeychain(override: KeychainService?, isTestProcess: Bool) -> KeychainService {
        let keychain = override ?? KeychainService(store: KeychainService.defaultStore(
            isTestProcess: isTestProcess, verification: HirevaVerificationConfiguration.current))
        if keychain.store is RealKeychainStore {
            keychain.lastReadStatus = "Deferred"
        } else {
            keychain.performMigrationIfNeeded()
        }
        return keychain
    }

    static func bootstrap() -> AppState {
        let dialogueDefaults: UserDefaults
        if let verification = HirevaVerificationConfiguration.current {
            do {
                dialogueDefaults = try resolveVerificationPreferences(configuration: verification)
            } catch {
                preconditionFailure(error.localizedDescription)
            }
        } else {
            dialogueDefaults = .standard
        }
        do {
            let database = try AppDatabase()
            let state = AppState(database: database, dialogueDefaults: dialogueDefaults)
            state.startMainThreadHeartbeat()
            return state
        } catch {
            let fallbackURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("Hireva-\(UUID().uuidString).sqlite")
            let fallback = (try? AppDatabase(path: fallbackURL)) ?? (try? AppDatabase(inMemory: true))
            guard let fallback else {
                preconditionFailure("Unable to initialize SQLite or in-memory database.")
            }
            let state = AppState(database: fallback, dialogueDefaults: dialogueDefaults)
            state.startMainThreadHeartbeat()
            state.showError("Could not open the application database at the normal path. Using a temporary database for this run. \(error.localizedDescription)")
            return state
        }
    }

    static func makeHistoryState(database: AppDatabase, repositories: Repositories,
        recapService: RecapGenerationService, consent: PersistenceConsent) -> HistoryState {
        HistoryState(sessions: repositories.sessions, transcripts: repositories.transcripts,
            suggestions: repositories.suggestions, recaps: repositories.recaps,
            corrections: HistoryCorrectionRepository(database: database),
            practice: PracticeRepository(database: database), recapService: recapService, consent: consent)
    }

    static func makeLocalDataService(repositories: Repositories, keychain: KeychainService) -> LocalDataService {
        LocalDataService(documents: repositories.documents, sessions: repositories.sessions,
            transcripts: repositories.transcripts, suggestions: repositories.suggestions,
            recaps: repositories.recaps, settings: repositories.settings, keychainService: keychain)
    }

    static func makeContextRetrievalService(repository: DocumentRepository,
        override: (any ContextRetrievalService)?,
        configuration: @escaping @MainActor @Sendable () -> (AppSettings, (any EmbeddingProvider)?))
        -> any ContextRetrievalService {
        override ?? HybridContextRetrievalService(documentRepository: repository,
            configurationProvider: configuration)
    }

    /// Exact subscription handles are returned to the application's existing
    /// lifetime owner. No background task or second state mirror is created.
    static func connectFeatureObservations(app: AppState) -> Set<AnyCancellable> {
        var subscriptions = Set<AnyCancellable>()
        app.settingsState.objectWillChange
            .sink { [weak app] _ in app?.objectWillChange.send() }
            .store(in: &subscriptions)
        app.systemAudioPermissions.objectWillChange
            .sink { [weak app] _ in app?.objectWillChange.send() }
            .store(in: &subscriptions)
        app.historyState.objectWillChange
            .sink { [weak app] _ in app?.objectWillChange.send() }
            .store(in: &subscriptions)
        app.documentsState.objectWillChange
            .sink { [weak app] _ in app?.objectWillChange.send() }
            .store(in: &subscriptions)
        app.documentsState.embeddings.objectWillChange
            .sink { [weak app] _ in app?.objectWillChange.send() }
            .store(in: &subscriptions)
        app.interviewContextState.objectWillChange
            .sink { [weak app] _ in app?.objectWillChange.send() }
            .store(in: &subscriptions)
        app.liveInterview.objectWillChange
            .sink { [weak app] _ in app?.objectWillChange.send() }
            .store(in: &subscriptions)
        app.liveInterview.liveStateUpdates.dropFirst()
            .sink { [weak app] value in app?.updateDiagnostics { $0.liveState = value } }
            .store(in: &subscriptions)
        app.generationCoordinator.objectWillChange
            .sink { [weak app] _ in app?.objectWillChange.send() }
            .store(in: &subscriptions)
        // Preserve the former App summary notification without relaying
        // unrelated diagnostic sampling or maintaining a second value.
        app.diagnosticsState.activeTaskSummaryUpdates.dropFirst()
            .sink { [weak app] _ in app?.objectWillChange.send() }
            .store(in: &subscriptions)
        return subscriptions
    }

    /// Startup order preserves the existing migration and diagnostic boundaries.
    /// Called only after the concrete graph and feature relays are installed.
    static func startInitialRuntimeWork(app: AppState, loadKeychain: Bool, isTestProcess: Bool) {
        app.refreshAll(loadKeychain: loadKeychain)
        app.clearStaleActiveASRProviderOnLaunch()
        app.runLaunchASRProviderDefaultMigrationIfNeeded()
        app.runLaunchLocalQwenDefaultMigrationIfNeeded()
        app.scheduleAutomaticContextRebuild()
        if !isTestProcess {
            app.installLiveSystemAudioDiagnosticNotificationObserver()
            app.runLaunchLiveSystemAudioDiagnosticIfRequested()
        }
    }

    /// Returns the exact subscriptions to the application's existing lifetime owner.
    /// Native callbacks keep the original MainActor delivery and diagnostic throttle.
    static func connectRuntimeObservations(app: AppState) -> Set<AnyCancellable> {
        var subscriptions = Set<AnyCancellable>()
        if let monitor = app.audioDeviceRouteMonitor {
            app.initializeAudioRouteRecoveryPresentation()
            monitor.$currentInputDeviceName
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak app] _ in app?.objectWillChange.send() }
                .store(in: &subscriptions)
            monitor.$isRecoveringAudioRoute
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak app] isRecovering in
                    app?.audioRouteRecoveryDidUpdate(isRecovering, monitor: monitor)
                }
                .store(in: &subscriptions)
        }
        app.systemAudioCaptureService.isCapturingUpdates
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak app] capturing in app?.systemAudioCaptureStateDidUpdate(capturing) }
            .store(in: &subscriptions)
        app.systemAudioCaptureService.lastBufferReceivedAtUpdates
            .dropFirst()
            .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak app] _ in app?.objectWillChange.send() }
            .store(in: &subscriptions)
        app.systemAudioCaptureService.lastErrorUpdates
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak app] error in app?.systemAudioCaptureErrorDidUpdate(error) }
            .store(in: &subscriptions)
        return subscriptions
    }

    /// The constructor immediately retains these exact tokens in its existing
    /// private fields; shutdown/ARC removes only this application's registrations.
    static func connectApplicationNotifications(app: AppState, isTestProcess: Bool)
        -> (active: AnyCancellable?, termination: AnyCancellable?) {
        guard !isTestProcess else { return (nil, nil) }
        let center = NotificationCenter.default
        let active = center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak app] _ in
            // queue: .main delivers synchronously on the checked executor;
            // removing a token does not join an older already-queued Task.
            MainActor.assumeIsolated {
                guard let app, !app.isShuttingDown else { return }
                app.refreshPermissions()
            }
        }
        let activeCancellation = AppState.makeNotificationCancellation(observer: active, center: center)
        let termination = center.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak app] _ in
            MainActor.assumeIsolated {
                app?.handleApplicationWillTerminate()
            }
        }
        let terminationCancellation = AppState.makeNotificationCancellation(observer: termination, center: center)
        return (activeCancellation, terminationCancellation)
    }

    static func makeAudioRouteMonitor(isTestProcess: Bool) -> AudioDeviceRouteMonitor? {
        guard !isTestProcess else { return nil }
        return AudioDeviceRouteMonitor(dependencies: .native())
    }

    static func makeSystemAudioPermissions(permissions: PermissionService,
        isTestProcess: Bool,
        diagnosticCaptureService: ScreenCaptureKitSystemAudioCaptureService? = nil) -> SystemAudioPermissionController {
        let initial = permissions.refreshPermissions()
        // Ordinary tests preserve their actual injected permission observations.
        // This result describes synthetic I/O and never authorizes native capture.
        let testResult = isTestProcess ? fixtureProbeResult(for: initial) : nil
        return SystemAudioPermissionController(permissions: permissions,
            initialSnapshot: initial, initialProbeResult: testResult,
            probe: {
                if isTestProcess { return fixtureProbeResult(for: permissions.refreshPermissions()) }
                return await ScreenSystemAudioPermissionProbe.shared.probe()
            },
            stopProbe: { retryFailedResource in
                try await ScreenSystemAudioPermissionProbe.shared.finishStoppingProbe(
                    retryFailedResource: retryFailedResource)
            },
            diagnosticCaptureService: diagnosticCaptureService)
    }

    private static func fixtureProbeResult(for snapshot: PermissionSnapshot)
        -> ScreenSystemAudioPermissionProbeResult {
        let screen = snapshot.screenRecording == .granted
        let system = snapshot.systemAudioCapture == .granted
        return .init(preflightGranted: screen,
            shareableContentProbeSucceeded: screen,
            streamAudioProbeSucceeded: screen && system,
            errorDescription: screen && system ? nil : "Synthetic system audio permission is unavailable.",
            likelyIdentityMismatch: false)
    }

    static func makeManualCaptureController(app: AppState) -> ManualCaptureController {
        ManualCaptureController(dependencies: .init(
            permissions: app.permissionService, systemPermissions: app.systemAudioPermissions,
            audio: app.manualCaptureCapabilities.audio, speech: app.manualCaptureCapabilities.speech,
            prepareLiveTeardown: { [weak app] in
                guard let app else { return nil }
                let manual = app.manualCaptureController
                let revision = manual.revision
                let practiceStop = app.practiceController.pause()
                guard manual.revision == revision, manual.state == .waitingForPermission else { return practiceStop }
                app.stopAllContinuousPipelines(reason: .userRequested)
                let liveStop = app.captureTeardownTask
                guard manual.revision == revision, manual.state == .waitingForPermission else { return liveStop }
                return Task {
                    await liveStop?.value
                    await practiceStop?.value
                }
            },
            feedback: { [weak app] feedback in
                guard let app else { return }
                app.publishActionFeedback(feedback)
            },
            clearFeedback: { [weak app] in app?.clearActionFeedback($0) },
            onReady: { [weak app] _, _ in app?.sendManualCaptureToAI() }))
    }

    static func makeSettingsState(app: AppState) -> SettingsState {
        return SettingsState(repository: app.settingsRepository, keychain: app.keychainService,
            router: app.llmRouter, defaults: app.dialogueDefaults ?? .standard,
            localQwenHealthCheck: { await OllamaQwenProvider().healthCheck(modelName: $0) },
            isActionLoading: { [weak app] in app?.isActionLoading($0) ?? false },
            feedback: { [weak app] feedback in
                guard let app else { return }
                app.publishActionFeedback(feedback)
            },
            clearFeedback: { [weak app] in app?.clearActionFeedback($0) },
            onChange: { [weak app] change in
                guard let app else { return }
                switch change {
                case .settingsChanged(let previous, let current):
                    app.liveRAGPrefetch.configurationDidChange(previous: previous, current: current)
                    app.documentsState.embeddings.configurationDidChange(previous: previous, current: current)
                    app.persistenceConsent.update(enabled: current.saveTranscriptsLocally)
                    if previous.saveTranscriptsLocally && !current.saveTranscriptsLocally {
                        (app.activeASRProviderRuntime as? LocalParakeetASRProvider)?.revokeVerificationPCM()
                        app.practiceController.revokePersistence()
                        app.historyState.cancelRecap()
                        app.clearActionFeedback(ActionID.sessionRecap)
                    }
                case .apiKeyWillChange(let account):
                    app.liveRAGPrefetch.credentialWillChange(account: account,
                        configuredAccount: app.settings.embeddingApiKeyAccount)
                    app.documentsState.embeddings.credentialWillChange(account: account)
                case .selectedQwenModelChanged(_, let current):
                    app.localModelsSetupState.selectedQwenModelDidChange(to: current)
                case .answerModeWillChange:
                    app.liveInterview.invalidateAutomaticDetectionAdmission()
                    app.persistenceConsent.invalidate()
                    app.cancelActiveGenerationForContextChange()
                    app.practiceController.pause()
                    app.historyState.cancelRecap()
                    app.clearActionFeedback(ActionID.sessionRecap)
                case .sessionModeChanged(let previous, let current):
                    if previous != current { app.liveInterview.invalidateAutomaticDetectionAdmission() }
                    app.interviewSessionModeSelectionDidChange(from: previous)
                case .realtimeProviderRequestChanged:
                    app.liveInterview.invalidateAutomaticDetectionAdmission()
                case .providerConnected(let provider, let result):
                    app.updateDiagnostics {
                        $0.lastAPILatencyMS = result.latencyMS
                        $0.lastProviderName = provider.name
                        $0.lastProviderModel = provider.model
                    }
                case .providerFailed(let message):
                    app.updateDiagnostics { $0.lastError = message }
                case .refreshApplication: app.refreshAll()
                case .showError(let message): app.showError(message)
                case .clearError: app.errorMessage = nil
                }
            })
    }

    static func makeLocalModelsSetupState() -> LocalModelsSetupViewModel {
        // Concrete constructors honor the existing verification configuration;
        // no permission request, model download or readiness probe occurs here.
        LocalModelsSetupViewModel(modelManager: FileLocalModelManager(),
            qwenProvider: OllamaQwenProvider(), parakeetRuntimeClient: ParakeetSidecarRuntimeClient())
    }

    static func makePreparationState(app: AppState) -> PreparationState {
        PreparationState(
            repository: PreparationRepository(database: app.database),
            consent: app.persistenceConsent,
            historyEnabled: { [weak app] in app?.settings.saveTranscriptsLocally ?? false },
            fetch: { text in
                let work = Task.detached(priority: .utility) { try PublicRoleBriefService.fetch(text) }
                return try await withTaskCancellationHandler {
                    try await work.value
                } onCancel: { work.cancel() }
            },
            runSQL: { text in
                let work = Task.detached(priority: .utility) { PracticeSQLService.run(text) }
                return await withTaskCancellationHandler {
                    await work.value
                } onCancel: { work.cancel() }
            }
        )
    }

    static func makeInterviewContextState(app: AppState) -> InterviewContextState {
        let documents = app.documentsState
        return InterviewContextState(repository: app.interviewContextRepository,
            documents: app.documentRepository,
            documentRecords: { [weak documents] in documents?.documents ?? [] },
            makeBuilder: { [weak app, repository = app.documentRepository] useLocalQwen in
                guard let app else { throw CancellationError() }
                let model = app.selectedQwenModelName
                let extractor: (any AutomaticDocumentEvidenceExtracting)? = useLocalQwen
                    ? LocalQwenDocumentEvidenceExtractor(provider: app.localLLMProviderOverride ?? OllamaQwenProvider(), modelName: model)
                    : nil
                return AutomaticInterviewContextBuilder(evidenceExtractor: extractor,
                    chunkProvider: { try repository.chunks(documentID: $0) },
                    cacheNamespace: useLocalQwen ? "local-qwen-\(model)" : "verified-local-v1")
            },
            selectionWillChange: { [weak app] in app?.practiceController.cancel() },
            domainDidChange: { [weak app] domain in
                app?.interviewContextMode = domain == .roboticsResearch ? .phdRobotics : .general
            },
            contextDidChange: { [weak app] in
                guard let app else { throw CancellationError() }
                try app.rollContextSnapshotForCurrentSession()
            },
            refreshApplication: { [weak app] in app?.refreshAll() },
            feedback: { [weak app] feedback in
                guard let app else { return }
                app.publishActionFeedback(feedback)
            },
            clearFeedback: { [weak app] in app?.clearActionFeedback($0) },
            showError: { [weak app] in app?.showError($0) },
            selectionDidChange: { [weak app] in app?.liveInterview.invalidateAutomaticDetectionAdmission() })
    }

    static func makeDocumentsState(app: AppState) -> DocumentsState {
        let settings = app.settingsState
        let embeddings = DocumentEmbeddingState(repository: app.documentRepository,
            configuration: { settings.settings },
            resolveProvider: { [weak app] snapshot in app?.resolveEmbeddingProvider(settings: snapshot) },
            feedback: { [weak app] value in
                guard let app else { return }
                app.publishActionFeedback(value)
            },
            changed: { [weak app] in
                guard let app else { return }
                app.liveRAGPrefetch.indexDidChange()
                app.refreshAll()
            },
            showError: { [weak app] in app?.showError($0) })
        return DocumentsState(repository: app.documentRepository,
            extractURL: app.materialURLExtraction,
            extractData: app.materialDataExtraction,
            willSave: { [weak app] _ in
                guard let app else { return }
                app.interviewContextState.invalidateBuild()
                app.practiceController.cancel()
                app.cancelActiveGenerationForContextChange()
                app.liveRAGPrefetch.cancelAndClear()
                AutomaticInterviewContextBuilder.clearExtractionCache()
            },
            didSave: { [weak app] saved, origin in
                guard let app else { throw CancellationError() }
                if case .typed = origin, ProductionContextPolicy.isTestProcess {
                    try app.ingestDocumentIntoActiveContext(saved)
                }
                app.refreshAll()
                if case .typed = origin {
                    app.scheduleAutomaticContextRebuild()
                    app.triggerEmbeddingGeneration(for: saved.type)
                } else {
                    app.scheduleAutomaticContextRebuild(useLocalQwen: false)
                }
            }, embeddings: embeddings)
    }

    static func makePracticeController(app: AppState) -> PracticeController {
        let permissions = app.permissionService
        return PracticeController(dependencies: PracticeDependencies(
            repository: PracticeRepository(database: app.database),
            sessions: app.sessionRepository,
            questions: app.suggestionRepository,
            contexts: app.interviewContextRepository,
            persistenceConsent: app.persistenceConsent,
            context: { [weak app] in
                guard let app else { throw CancellationError() }
                return PracticeDependencies.Context(
                    historyEnabled: app.settings.saveTranscriptsLocally,
                    selection: app.currentInterviewContextSelection,
                    temporarySnapshotID: app.activeContextSnapshot?.id,
                    requiresOnDeviceRecognition: HirevaVerificationConfiguration.current?.requiresLocalASR ?? false
                )
            },
            evaluationConfiguration: { [weak app] in
                guard let app else { throw CancellationError() }
                return (app.localLLMProviderOverride ?? OllamaQwenProvider(), app.selectedQwenModelName)
            },
            selectedASRProvider: { [weak app] in app?.selectedASRProviderID ?? .appleSpeech },
            isLiveCaptureActive: { [weak app] in
                guard let app else { return true }
                return app.primaryHomeActionShouldStop || app.manualCaptureController.hasUnreleasedResources
            },
            prepareForPractice: { [weak app] in app?.pausePreparationForLive() },
            requestAudioPermissions: { provider in
                let requirements = ASRPermissionRequirements(provider: provider, captureMode: .microphoneOnly)
                if requirements.microphone {
                    guard await permissions.requestMicrophonePermission() == .authorized else {
                        throw MaterialError.invalid("Microphone permission denied.")
                    }
                }
                if requirements.speechRecognition {
                    guard await permissions.requestSpeechRecognition() == .granted else {
                        throw MaterialError.invalid("Speech permission denied.")
                    }
                }
            },
            makeAudioProvider: { provider in
                switch provider {
                case .localParakeet: return LocalParakeetASRProvider()
                case .appleSpeech: return AppleSpeechASRProvider()
                case .localWhisper:
                    throw MaterialError.invalid("Local Whisper runtime is not configured. Use keyboard input or an available ASR provider.")
                }
            },
            historyDidChange: { [weak app] sessionID in
                guard let app else { return }
                if let sessionID {
                    if app.selectedSessionID == sessionID { app.loadSessionDetails(sessionID: sessionID) }
                } else {
                    app.refreshAll()
                }
            },
            // Live debounce clocks do not change the Practice evaluation
            // deadline. Tests inject a controlled clock into the feature.
            delayProvider: RealDelayProvider()
        ))
    }
}
