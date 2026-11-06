// Handles live audio capture lifecycle for an interview session.
// This extension owns start/stop/restart behavior and audio diagnostics only.
// It must not perform question detection or suggestion generation directly;
// captured transcript segments flow into AppState+Transcript instead.

import Foundation
import Darwin

extension AppState {
    static func verificationPCMCommit(verification: HirevaVerificationConfiguration?,
        verificationOnlyBundle: Bool, captureMode: AudioCaptureMode, provider: ASRProviderID,
        consent: PersistenceConsent, ticket: Int) throws -> ParakeetSidecarRuntimeClient.VerificationPCMCommit? {
        guard let verification, verification.retainNativePCM else { return nil }
        guard captureMode == .systemAudioOnly, provider == .localParakeet,
              verification.controlledAudioProcessID != nil, verification.controlledAudioBundleIdentifier != nil,
              verificationOnlyBundle, consent.isCurrent(ticket: ticket) else { throw CancellationError() }
        // Explicit synthetic PCM opt-in is separate from trace mode; never place audio in trace records.
        guard let frozenDirectory = verification.nativePCMOutputDirectory,
              let device = verification.nativePCMOutputDevice, let inode = verification.nativePCMOutputInode,
              verification.outputDirectory.resolvingSymlinksInPath().standardizedFileURL == frozenDirectory else { throw POSIXError(.ESTALE) }
        let directory = frozenDirectory.path
        var identity = stat()
        guard lstat(directory, &identity) == 0, identity.st_dev == device, identity.st_ino == inode else { throw POSIXError(.ESTALE) }
        let stem = "writer-submitted-pcm-\(verification.runID)-\(UUID().uuidString)"
        return { data, generation, truncated, diagnostics in
            try consent.write(ticket: ticket) {
                let directoryFD = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard directoryFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                defer { close(directoryFD) }
                var current = stat()
                guard fstat(directoryFD, &current) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                guard current.st_dev == device, current.st_ino == inode else { throw POSIXError(.ESTALE) }
                let filename = "\(stem)-g\(generation).jsonl"
                let fd = openat(directoryFD, filename, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                do { try handle.write(contentsOf: data); try handle.close() }
                catch { try? handle.close(); throw error }
                print("[VerificationPCM] writer-submitted file=\(filename) generation=\(generation) bytes=\(data.count) truncated=\(truncated) dropped=\(diagnostics.droppedChunks)")
            }
        }
    }

    // MARK: - Public Entry Points

    /// Starts the selected live capture path and prepares cancellation of any
    /// stale detection or generation work from a previous run.
    ///
    /// The mode passed here is the interview runtime mode; the microphone/system
    /// routing decision is still taken from `settings.audioCaptureMode`.
    func startListening(mode: InterviewMode) {
        guard !isShuttingDown else { return }
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
        // Permission requests and backend startup use the same submitted
        // configuration, even if settings change while authorization awaits.
        let captureMode = settings.audioCaptureMode
        let requestedASRProvider = selectedASRProviderID
        let answerMode = selectedAnswerProviderMode
        let answerModel = selectedQwenModelName
        let modelPreparation = mode != .mock && answerMode == .localQwenPrimary
            ? ((localLLMProviderOverride ?? OllamaQwenProvider()) as? OllamaQwenProvider)
                .map { (provider: $0, model: answerModel) } : nil
        let pcmTicket = persistenceConsent.ticket()
        let pcmCommit: ParakeetSidecarRuntimeClient.VerificationPCMCommit?
        do {
            pcmCommit = try Self.verificationPCMCommit(verification: HirevaVerificationConfiguration.current,
                verificationOnlyBundle: Bundle.main.object(forInfoDictionaryKey: "HirevaVerificationOnly") as? Bool == true,
                captureMode: captureMode, provider: requestedASRProvider, consent: persistenceConsent, ticket: pcmTicket)
        } catch {
            failAction(actionID, title: "Audio evidence unavailable", message: userFacing(error))
            showError(userFacing(error))
            return
        }
        let pcmConsent = persistenceConsent
        let requiresOnDeviceRecognition = HirevaVerificationConfiguration.current?.requiresLocalASR ?? false
        let biasSelection = requestedASRProvider == .localParakeet && settingsState.parakeetContextBiasEnabled
            ? currentInterviewContextSelection : nil
        let biasOpportunity = biasSelection == nil ? nil : activeOpportunityContext
        let contextualStrings = ASRConfig.opportunityTerms(biasOpportunity)
        // This handoff is filled synchronously on MainActor before the owned
        // startup can execute on that same actor. Register before any publisher
        // can submit a later Manual/Live intent and revoke this exact startup.
        var manualTeardown: Task<Void, Error>?
        guard let startup = captureLifecycle.start(onCleanupBlocked: { [weak self] in
            self?.failAction(actionID, title: "Audio cleanup failed",
                message: "The previous audio capture has not been released. Retry cleanup before starting another capture.")
        }, operation: { [weak self] startupID in
            guard let self, self.captureStartupIsCurrent(startupID) else { return }
            await self.startListeningAsync(mode: mode, captureMode: captureMode,
                requestedASRProvider: requestedASRProvider, modelPreparation: modelPreparation,
                requiresOnDeviceRecognition: requiresOnDeviceRecognition,
                pcmCommit: pcmCommit, pcmIsCurrent: { pcmConsent.isCurrent(ticket: pcmTicket) },
                contextualStrings: contextualStrings, biasSelection: biasSelection,
                biasOpportunityID: biasOpportunity?.id, biasOpportunityVersion: biasOpportunity?.version,
                manualTeardown: manualTeardown, startupID: startupID)
        }), let startupID = captureStartupID else { return }
        do { manualTeardown = try manualCaptureController.prepareForLiveCapture() }
        catch {
            guard captureStartupIsCurrent(startupID) else { return }
            captureLifecycle.invalidateStartup()
            let message = userFacing(error)
            liveState = .error(message)
            guard captureStartupTask == startup else { return }
            currentCaptureRuntimeState = .error(reason: message)
            guard captureStartupTask == startup else { return }
            failAction(actionID, title: "Could not start", message: message)
            guard captureStartupTask == startup else { return }
            showError(message)
            return
        }
        guard captureStartupIsCurrent(startupID) else { return }
        practiceController.pause()
        guard captureStartupIsCurrent(startupID) else { return }
        pausePreparationForLive()
        guard captureStartupIsCurrent(startupID) else { return }
        beginAction(actionID, title: "Starting audio", message: "Starting \(captureMode.shortDisplayName) capture...")
        guard captureStartupIsCurrent(startupID) else {
            // A replacement Manual owns its own action. Clear this revoked
            // loading feedback only when no newer Live startup owns it.
            if captureStartupID == nil { clearActionFeedback(actionID) }
            return
        }
        errorMessage = nil
        guard captureStartupIsCurrent(startupID) else { return }
        possibleQuestion = nil
        guard captureStartupIsCurrent(startupID) else { return }
        liveInterview.cancelAutomaticDetection()
        cancelActiveGenerationForStop()
        guard captureStartupIsCurrent(startupID) else { return }
        liveInterview.cancelAutomaticDetectionDebounce()
        captureLifecycle.invalidateConsumer()
    }

    func pausePreparationForLive() {
        preparationState.cancel()
        if materialImportTask != nil { cancelMaterialImport() }
        interviewContextState.invalidateBuild()
        documentsState.embeddings.cancelRebuild()
        clearActionFeedback(ActionID.rebuildEmbeddings)
        historyState.cancelRecap()
        clearActionFeedback(ActionID.sessionRecap)
    }

    // MARK: - Capture Startup

    private func captureAdmissionState(for result: ScreenSystemAudioPermissionProbeResult) throws
        -> ScreenSystemAudioPermissionState {
        let state = determineProbeState(result: result)
        switch state {
        case .shareableContentProbeFailed(let detail), .streamAudioProbeFailed(let detail):
            throw TranscriptionError.unavailable("System audio capture unavailable: \(detail)")
        default:
            return state
        }
    }

    /// Coordinates permissions, session creation, Apple Speech startup, and
    /// capture diagnostics on MainActor.
    ///
    /// System Audio Only never requests microphone permission. Speech
    /// recognition permission follows the selected provider's requirements.
    /// Microphone Only never starts system audio capture.
    private func startListeningAsync(mode: InterviewMode, captureMode: AudioCaptureMode,
        requestedASRProvider: ASRProviderID, modelPreparation: (provider: OllamaQwenProvider, model: String)?,
        requiresOnDeviceRecognition: Bool,
        pcmCommit: ParakeetSidecarRuntimeClient.VerificationPCMCommit?,
        pcmIsCurrent: @escaping @Sendable () -> Bool,
        contextualStrings: [String], biasSelection: InterviewContextSelection?,
        biasOpportunityID: String?, biasOpportunityVersion: Int?,
        manualTeardown: Task<Void, Error>?, startupID: UUID) async {
        await practiceController.finishStoppingAudio()
        guard captureStartupIsCurrent(startupID) else { return }
        currentCaptureRuntimeState = .starting
        self.stopReason = nil
        self.lastCaptureStartedAt = Date()
        addCaptureEvent(name: "startListeningAsync", stateBefore: "idle", stateAfter: "starting", reason: "userRequested")
        recordLifecycleTrace("capture.start.requested", reason: "user_requested")

        do {
            try await manualTeardown?.value
            guard captureStartupIsCurrent(startupID) else { return }
            guard mode == .mock || requestedASRProvider != .localWhisper else {
                throw ASRProviderError.providerUnavailable(
                    "Local Whisper runtime is not configured. Select Apple Speech or Local Parakeet to start listening."
                )
            }
            try await systemAudioCaptureService.finishStoppingSystemAudioCapture()
            guard captureStartupIsCurrent(startupID) else { return }
            try await systemAudioPermissions.finishPreparingForCapture()
            guard captureStartupIsCurrent(startupID) else { return }
            liveState = .requestingPermission
            if mode != .mock {
                refreshPermissions(automaticallyProbe: false)
            }
            if mode == .microphone {
                // Permission gating is capture-mode specific. Do not collapse
                // this into a generic "live transcription requires mic" check:
                // System Audio Only is the user escape hatch when mic access is
                // denied or unnecessary.
                let permissionRequirements = ASRPermissionRequirements(
                    provider: requestedASRProvider,
                    captureMode: captureMode
                )
                let microphoneRequired = permissionRequirements.microphone
                let speechRecognitionRequired = permissionRequirements.speechRecognition
                let systemAudioRequired = permissionRequirements.screenAndSystemAudio

                print("[StartListening] captureMode = \(captureMode.rawValue)")
                print("[StartListening] selectedASRProvider = \(requestedASRProvider.rawValue)")
                print("[StartListening] microphoneRequired = \(microphoneRequired)")
                print("[StartListening] speechRecognitionRequired = \(speechRecognitionRequired)")
                print("[StartListening] systemAudioRequired = \(systemAudioRequired)")

                let micStatusBefore = permissionService.checkMicrophonePermission()
                print("[Permission] microphone status before request = \(micStatusBefore.rawValue)")

                if microphoneRequired {
                    var microphone = micStatusBefore
                    if microphone == .notDetermined {
                        microphone = await permissionService.requestMicrophonePermission()
                        guard captureStartupIsCurrent(startupID) else { return }
                        refreshPermissions(automaticallyProbe: false)
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

                } else {
                    print("[Permission] microphone request result = notRequired")
                }

                if speechRecognitionRequired {
                    var speech = permissionService.speechStatus()
                    if speech == .notDetermined {
                        speech = await permissionService.requestSpeechRecognition()
                        guard captureStartupIsCurrent(startupID) else { return }
                        refreshPermissions(automaticallyProbe: false)
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
                }

                if systemAudioRequired {
                    let probeResult = try await systemAudioPermissions.probeNow()
                    guard captureStartupIsCurrent(startupID) else { return }
                    let state = try captureAdmissionState(for: probeResult)

                    if state == .granted {
                        // Success! Continue
                    } else {
                        if !probeResult.preflightGranted {
                            permissionService.requestScreenRecording()
                            try? await Task.sleep(for: .milliseconds(1000))
                            guard captureStartupIsCurrent(startupID) else { return }

                            let finalProbe = try await systemAudioPermissions.probeNow()
                            guard captureStartupIsCurrent(startupID) else { return }
                            let finalState = try captureAdmissionState(for: finalProbe)
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
                refreshPermissions(automaticallyProbe: false)
            }

            try await systemAudioPermissions.finishPreparingForCapture()
            guard captureStartupIsCurrent(startupID) else { return }
            var modelPreparationNote = ""
            if let preparation = modelPreparation {
                guard selectedAnswerProviderMode == .localQwenPrimary, selectedQwenModelName == preparation.model else {
                    throw MaterialError.invalid("Answer model changed during startup. Start listening again.")
                }
                do {
                    try await GenerationCoordinator.withTimeout(seconds: 8) {
                        try await preparation.provider.prepareModel(modelName: preparation.model)
                    }
                    guard captureStartupIsCurrent(startupID) else { return }
                    addCaptureEvent(name: "localModelPrepared", stateBefore: "starting", stateAfter: "starting", reason: "loadConfirmed")
                } catch {
                    guard captureStartupIsCurrent(startupID) else { return }
                    modelPreparationNote = " Local answer model preparation failed; the first answer may be unavailable."
                    addCaptureEvent(name: "localModelPreparationFailed", stateBefore: "starting", stateAfter: "starting", reason: userFacing(error))
                }
                guard captureStartupIsCurrent(startupID) else { return }
                guard selectedAnswerProviderMode == .localQwenPrimary, selectedQwenModelName == preparation.model else {
                    throw MaterialError.invalid("Answer model changed during startup. Start listening again.")
                }
            }
            if let biasSelection {
                guard currentInterviewContextSelection == biasSelection,
                      activeOpportunityContext?.id == biasOpportunityID,
                      activeOpportunityContext?.version == biasOpportunityVersion else {
                    throw ASRProviderError.providerUnavailable("Opportunity context changed during audio startup. Start listening again to use its current vocabulary.")
                }
            }
            let reusableSession: InterviewSession? = {
                guard let currentSession else { return nil }
                let persistedSession = try? sessionRepository.session(id: currentSession.id)
                let candidate = persistedSession ?? currentSession
                return candidate.endedAt == nil ? candidate : nil
            }()

            let session: InterviewSession
            if let reusableSession {
                session = reusableSession
            } else {
                resetLiveContextForFreshSession()
                session = try createContextBoundSession(mode: mode)
            }
            currentSession = session
            if transcriptSegments.isEmpty {
                transcriptSegments.append(.system("Live interview session started in \(mode.displayName). Mode: \(captureMode.displayName)", sessionID: session.id))
            }

            if mode == .mock {
                let provider = mockTranscriptionService
                activeTranscriptionProvider = provider
                try await provider.start(sessionID: session.id)
                guard captureStartupIsCurrent(startupID) else {
                    provider.stop()
                    return
                }
                liveState = .listening
                showFloatingAssistant()
                consumeSegments(from: provider)
                completeAction(ActionID.startInterview, title: "Listening started", message: "Practice capture is active.")
            } else {
                print("[DualAudio] mode = \(captureMode.rawValue)")
                print("[DualAudio] selectedASRProvider = \(requestedASRProvider.rawValue)")

                if captureMode == .systemAudioOnly {
                    // Keep System Audio Only isolated from microphone metering.
                    // This prevents stale mic diagnostics from implying that
                    // microphone permission or capture is required.
                    self.lastSystemAudioASRPartialTranscript = ""
                    self.microphoneDiagnostics.stopMicTest()
                    print("[DualAudio] Cleaned up buffers & diagnostics for System Audio Only mode")
                }

                if requestedASRProvider == .localParakeet {
                    try liveASRWillStart?(.localParakeet, captureMode)
                    let provider = LocalParakeetASRProvider(runtimeClient: pcmCommit.map {
                        ParakeetSidecarRuntimeClient(verificationPCMCommit: $0, verificationPCMIsCurrent: pcmIsCurrent)
                    })
                    // Failed startup can retain its native cleanup capability.
                    // Register that exact owner before the first suspension;
                    // listening and the provider badge still require success.
                    self.appleSpeechService = nil
                    self.activeTranscriptionProvider = nil
                    self.activeASRProviderRuntime = provider
                    let stream = try await provider.startTranscription(config: ASRConfig(
                        sessionID: session.id,
                        captureMode: captureMode,
                        requiresOnDeviceRecognition: requiresOnDeviceRecognition,
                        contextualStrings: contextualStrings
                    ))
                    guard captureStartupIsCurrent(startupID) else {
                        await provider.stopTranscription(retryFailedResource: false)
                        return
                    }
                    if let biasSelection,
                       currentInterviewContextSelection != biasSelection ||
                        activeOpportunityContext?.id != biasOpportunityID ||
                        activeOpportunityContext?.version != biasOpportunityVersion {
                        await provider.stopTranscription(retryFailedResource: false)
                        throw ASRProviderError.providerUnavailable("Opportunity context changed during audio startup. Start listening again to use its current vocabulary.")
                    }
                    self.markActiveASRProvider(.localParakeet)
                    self.lastSystemAudioASRError = nil
                    self.lastSystemAudioASRPartialTranscript = ""
                    self.lastSystemAudioASRFinalTranscript = ""
                    ownsSystemAudioCaptureRuntime = captureMode == .systemAudioOnly || captureMode == .microphoneAndSystem

                    consumeParakeetSegments(stream, provider: provider, sessionID: session.id, startupID: startupID)

                    liveState = .listening
                    currentCaptureRuntimeState = .listening
                    addCaptureEvent(name: "listeningActive", stateBefore: "starting", stateAfter: "listening", reason: "localParakeetCaptureActive")
                    showFloatingAssistant()
                    completeAction(ActionID.startInterview, title: "Listening started", message: "\(ASRProviderID.localParakeet.displayName) is active." + modelPreparationNote)
                    if provider.hasHealthyCaptureSource {
                        for (source, error) in provider.captureSourceFailures {
                            reportParakeetSourceFailure(source: source, error: error)
                        }
                    }
                    await startAudioSignalMonitoring()
                    return
                }

                let speechService = AppleSpeechTranscriptionService()
                self.appleSpeechService = speechService
                self.activeTranscriptionProvider = speechService
                self.activeASRProviderRuntime = nil
                self.markActiveASRProvider(.appleSpeech)

                speechService.onSessionStateChanged = { [weak self, weak speechService] in
                    guard let self, let speechService,
                        (self.captureStartupID == nil || self.captureStartupID == startupID),
                        self.currentSession?.id == session.id,
                        self.appleSpeechService === speechService else { return }
                    self.objectWillChange.send()
                }
                speechService.onRuntimeEvent = { [weak self, weak speechService] event in
                    guard let self, let speechService,
                        (self.captureStartupID == nil || self.captureStartupID == startupID),
                        self.currentSession?.id == session.id,
                        self.appleSpeechService === speechService else { return }
                    self.recordTranscriptRuntimeEvent(event)
                }

                self.lastSystemAudioASRError = nil
                self.lastSystemAudioASRPartialTranscript = ""
                self.lastSystemAudioASRFinalTranscript = ""

                // The speech service owns stream startup for the selected
                // capture mode. It is responsible for not creating disabled
                // streams for System Audio Only or Microphone Only.
                try liveASRWillStart?(.appleSpeech, captureMode)
                try await speechService.start(sessionID: session.id, captureMode: captureMode,
                    requiresOnDeviceRecognition: requiresOnDeviceRecognition)
                guard captureStartupIsCurrent(startupID) else {
                    speechService.stop(retryFailedResource: false)
                    return
                }
                ownsSystemAudioCaptureRuntime = captureMode == .systemAudioOnly || captureMode == .microphoneAndSystem

                consumeSegments(from: speechService)

                if captureMode == .microphoneOnly || captureMode == .microphoneAndSystem {
                    // Keep diagnostics active during transcription for real-time visual levels
                    do {
                        try microphoneDiagnostics.startMeteringForCapture()
                    } catch {
                        // The selected ASR already started before level metering.
                        // A failed shared engine start must release that exact
                        // speech capture before publishing startup failure.
                        speechService.stop(retryFailedResource: false)
                        captureLifecycle.invalidateConsumer()
                        activeTranscriptionProvider = nil
                        appleSpeechService = nil
                        queueCaptureTeardown(after: nil, provider: nil, speech: speechService)
                        throw error
                    }
                }

                liveState = .listening
                currentCaptureRuntimeState = .listening
                addCaptureEvent(name: "listeningActive", stateBefore: "starting", stateAfter: "listening", reason: "captureActive")
                showFloatingAssistant()
                completeAction(ActionID.startInterview, title: "Listening started", message: "\(captureMode.shortDisplayName) is active." + modelPreparationNote)

                // Start background silence / signal validation
                await startAudioSignalMonitoring()
            }
        } catch {
            guard captureStartupIsCurrent(startupID) else { return }
            if let provider = activeASRProviderRuntime as? LocalParakeetASRProvider {
                // Retain failed native cleanup before another startup can replace the public slot.
                queueCaptureTeardown(after: nil, provider: provider)
                activeASRProviderRuntime = nil
            }
            markActiveASRProvider(nil)
            guard captureStartupIsCurrent(startupID) else { return }
            ownsSystemAudioCaptureRuntime = false
            let message = userFacing(error)
            liveState = .error(message)
            currentCaptureRuntimeState = .error(reason: message)
            addCaptureEvent(name: "startListeningFailed", stateBefore: "starting", stateAfter: "error", reason: message)
            failAction(ActionID.startInterview, title: "Could not start", message: message)
            showError(message)
        }
    }

    func consumeParakeetSegments(
        _ stream: AsyncThrowingStream<TranscriptSegment, Error>,
        provider: any ASRProvider,
        sessionID: String,
        startupID: UUID
    ) {
        if let local = provider as? LocalParakeetASRProvider {
            local.onCaptureSourceFailure = { [weak self] failedProvider, source, error in
                guard let self,
                      self.parakeetCaptureIsCurrent(provider: failedProvider, sessionID: sessionID, startupID: startupID),
                      failedProvider.hasHealthyCaptureSource else { return }
                self.reportParakeetSourceFailure(source: source, error: error)
            }
        }
        captureLifecycle.consume { [weak self] consumerID in
            do {
                for try await segment in stream {
                    guard let self,
                          self.captureLifecycle.isConsumerCurrent(consumerID),
                          self.parakeetCaptureIsCurrent(provider: provider, sessionID: sessionID, startupID: startupID),
                          segment.sessionID == sessionID else { return }
                    await self.handleTranscriptSegment(segment)
                    guard self.captureLifecycle.isConsumerCurrent(consumerID),
                          self.parakeetCaptureIsCurrent(provider: provider, sessionID: sessionID, startupID: startupID) else { return }
                }
                guard let self, self.captureLifecycle.isConsumerCurrent(consumerID) else { return }
                self.handleParakeetStreamTermination(error: nil, provider: provider, sessionID: sessionID, startupID: startupID)
            } catch {
                guard let self, self.captureLifecycle.isConsumerCurrent(consumerID) else { return }
                self.handleParakeetStreamTermination(error: error, provider: provider, sessionID: sessionID, startupID: startupID)
            }
        }
    }

    // Current provider/source facts drive display; a queued signal does not
    // create another writable capture state or revive a retired runtime.
    var hasHealthyParakeetAfterSystemFailure: Bool {
        guard let local = activeASRProviderRuntime as? LocalParakeetASRProvider else { return false }
        return local.hasHealthyCaptureSource && local.captureSourceFailures[.systemAudio] != nil
    }

    func reportParakeetSourceFailure(source: AudioSourceType, error: Error) {
        let name = source == .microphone ? "Microphone" : "System audio"
        let message = name + " capture failed: " + error.localizedDescription +
            ". The other selected audio source is still listening."
        // Repeated display signals of the same fact do not restart feedback.
        if latestActionFeedback(for: ActionID.startInterview)?.message != message {
            warnAction(ActionID.startInterview, title: name + " unavailable", message: message)
        }
        updateDiagnostics { $0.lastError = message }
        objectWillChange.send()
    }

    func handleParakeetStreamTermination(
        error: Error?,
        provider: any ASRProvider,
        sessionID: String,
        startupID: UUID
    ) {
        guard parakeetCaptureIsCurrent(provider: provider, sessionID: sessionID, startupID: startupID) else { return }
        let message = error?.localizedDescription ?? "Local Parakeet transcript stream ended unexpectedly."
        stopListening(reason: .asrTaskFailed)
        lastSystemAudioASRError = message
        liveState = .error(message)
        currentCaptureRuntimeState = .error(reason: message)
        showError(message)
    }

    private func parakeetCaptureIsCurrent(provider: any ASRProvider, sessionID: String, startupID: UUID) -> Bool {
        guard !Task.isCancelled,
              activeASRProviderID == .localParakeet,
              activeASRProviderRuntime === provider,
              currentSession?.id == sessionID else { return false }
        // Startup identity is cleared when startup completes. The exact runtime
        // instance remains the live epoch; a newer pending startup invalidates it.
        return captureStartupID == nil || captureStartupID == startupID
    }

    private func captureStartupIsCurrent(_ startupID: UUID) -> Bool {
        captureLifecycle.isStartupCurrent(startupID)
    }

    @discardableResult
    private func invalidateCaptureStartup() -> Task<Void, Never>? {
        captureLifecycle.invalidateStartup()
    }

    private func queueCaptureTeardown(
        after startupTask: Task<Void, Never>?,
        provider: (any ASRProvider)?,
        speech: AppleSpeechTranscriptionService? = nil,
        retryRetainedFailures: Bool = false
    ) {
        let metering = microphoneDiagnostics
        let cleanupSessionID = currentSession?.id ?? transcriptRuntimeDiagnostics.audioSessionID
        let monitorWorker = audioSignalMonitor.stop()
        captureLifecycle.queueTeardown(after: startupTask, quiescing: monitorWorker,
            retryRetainedFailures: retryRetainedFailures,
            onCleanupChanged: { [weak self] teardownID, released in
                guard let self else { return }
                self.objectWillChange.send()
                self.diagnosticsState.recordCaptureCleanupResult(
                    sessionID: cleanupSessionID, teardownID: teardownID, released: released,
                    mode: self.settings.effectiveDiagnosticTraceMode)
            }) { [weak self] teardownID, retryAuthorized in
            await metering.finishStoppingMicTest()
            if let local = provider as? LocalParakeetASRProvider {
                await local.stopTranscription(retryFailedResource: retryAuthorized)
            } else if let apple = provider as? AppleSpeechASRProvider {
                await apple.stopTranscription(retryFailedResource: retryAuthorized)
            } else {
                await provider?.stopTranscription()
            }
            // A synchronous stop has already closed this standalone service.
            // Only an explicit retained-operation replay can retry its failure.
            // A provider owning the same service performs that exact retry once.
            if retryAuthorized, let speech,
               (provider as? AppleSpeechASRProvider)?.ownsSpeechService(speech) != true {
                speech.retryStoppingAudioInput()
            }
            await speech?.finishStoppingAudioInput()
            let failure = (provider as? LocalParakeetASRProvider)?.captureCleanupFailure ??
                (provider as? AppleSpeechASRProvider)?.captureCleanupFailure ?? speech?.captureCleanupFailure
            guard failure == nil, speech?.hasUnreleasedAudioInput != true else {
                if self?.captureLifecycle.isCurrentTeardown(teardownID) == true {
                    self?.lastSystemAudioASRError = failure?.localizedDescription ??
                        "Audio input cleanup has not completed."
                }
                return false
            }
            // Captured concrete owners prove their exact native leases exited.
            // Draining a mutable shared-service slot can join another caller's
            // resource or falsely report release after our owner's failure.
            return true
        }
    }

    // MARK: - Session Reset

    private func resetLiveContextForFreshSession() {
        liveRAGPrefetch.cancelWorker()
        liveInterview.cancelAutomaticDetectionDebounce()
        liveInterview.cancelAutomaticDetection()
        cancelStageBTask()

        transcriptSegments = []
        resetRuntimeTranscriptState(clearEvents: true)
        currentSuggestion = nil
        manualCaptureSuggestion = nil
        liveSuggestionHistory = []
        currentSuggestionRetrievedChunks = []
        lastDetectedQuestion = nil
        possibleQuestion = nil
        lastTranscriptSnippet = ""
        lastSystemTranscript = ""
        lastSystemAudioTranscript = ""
        lastQuestionDetectionResult = "No question detected yet."
        lastDetectedQuestionText = ""
        lastDetectedQuestionSource = ""
        lastDetectedQuestionSpeaker = ""
        lastDetectionConfidence = 0.0
        lastQuestionConfidence = 0.0
        lastDetectionShouldTrigger = false
        lastDetectionReason = ""
        lastDetectionRawJSON = ""
        lastDetectionSkipReason = ""
        ignoredCandidateQuestionCount = 0
        ignoredSmallTalkCount = 0
        lastTranscriptIngestionMs = 0
        lastQuestionClassificationMs = 0
        lastIgnoredSystemAudioReason = ""
        ignoredSystemAudioAnswerLikeCount = 0
        detectedQuestionsInSessionCount = 0
        lastDetectionQuestionComplete = false
        lastDetectionAnswerStrategy = ""
        lastDetectionAt = nil
        liveInterview.resetQuestionIngress()
        cancelledPersistenceGenerationIDs.removeAll()
        generationCoordinator.resetTerminalHistory()
        suggestionPersistenceClaims.removeAll()
        successfulSuggestionPersistenceOwners.removeAll()
        recentQuestionsFingerprints.removeAll()
        liveRAGPrefetch.clearCache()
        streamedSayFirst = ""
        streamedSayFirstSetAt = nil
        isStreamingSayFirst = false
        isExpandingSuggestionCard = false
        suggestionGenerationStarted = false
        generationUIState = .idle
        resolvedInterviewSessionPhase = .initial(for: interviewSessionMode)
        detectedDialogueSpeakerRole = .ambiguous
        detectedDialogueTurnType = .unknown
        lastDialogueSourceChannel = ""
        lastModeTransition = ""
        lastModeTransitionReason = ""
        lastSpeakerRole = DialogueTurnRole.ambiguous.rawValue
        lastTriggerDecision = ""
        lastTriggerReason = ""
        lastSuppressionReason = ""
        candidateQuestionsToPanelCount = 0
    }

    // MARK: - Stop And Cleanup

    func handleApplicationWillTerminate() {
        practiceController.cancel()
        let sessionIsOpen = currentSession?.endedAt == nil
        guard sessionIsOpen || captureStartupTask != nil || activeTranscriptionProvider != nil || activeASRProviderRuntime != nil else {
            return
        }
        stopListening(reason: .applicationTerminated)
    }

    /// Stops continuous capture and cancels in-flight detection/generation tasks
    /// that should not survive a user stop.
    ///
    /// The visible suggestion is intentionally preserved so the user can still
    /// read the latest answer after stopping. Stop must safely tear down both
    /// system and microphone runtime paths without requiring another permission
    /// prompt.
    func stopListening(
        reason: StopReason = .userRequested,
        file: String = #file,
        line: Int = #line,
        function: String = #function
    ) {
        liveRAGPrefetch.cancelAndClear()
        let startupTask = invalidateCaptureStartup()
        if isActionLoading(ActionID.startInterview) {
            clearActionFeedback(ActionID.startInterview)
        }
        if reason == .userRequested {
            beginAction(ActionID.stopListening, title: "Stopping", message: "Stopping audio capture and preserving the current answer...")
        }
        let stateBefore = currentCaptureRuntimeState.displayName
        currentCaptureRuntimeState = .stopping
        self.stopReason = reason
        let stoppedAt = Date()
        self.lastCaptureStoppedAt = stoppedAt

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

        if reason == .userRequested {
            // User stop owns the lifetime of the full-answer expansion task.
            // This prevents background Stage B work from reviving capture state
            // after the user has explicitly stopped listening.
            cancelStageBTask()
        }
        liveInterview.cancelAutomaticDetection()
        cancelActiveGenerationForStop()
        liveInterview.cancelAutomaticDetectionDebounce()
        captureLifecycle.invalidateConsumer()
        markRuntimeAudioStopped()

        let capturedSpeech = appleSpeechService ?? activeTranscriptionProvider as? AppleSpeechTranscriptionService
        let activeSpeech = activeTranscriptionProvider as? AppleSpeechTranscriptionService
        activeSpeech?.stop(retryFailedResource: reason == .userRequested)
        if let capturedSpeech, capturedSpeech !== activeSpeech {
            capturedSpeech.stop(retryFailedResource: reason == .userRequested)
        }
        if activeSpeech == nil { activeTranscriptionProvider?.stop() }
        activeTranscriptionProvider = nil
        let asrProviderRuntime = activeASRProviderRuntime
        activeASRProviderRuntime = nil
        queueCaptureTeardown(after: startupTask, provider: asrProviderRuntime, speech: capturedSpeech,
            retryRetainedFailures: reason == .userRequested)
        markActiveASRProvider(nil)
        ownsSystemAudioCaptureRuntime = false

        appleSpeechService = nil
        ownsSystemAudioCaptureRuntime = false

        // Stop diagnostics level metering
        microphoneDiagnostics.stopMicTest()

        stopAudioSignalMonitoring()
        recentQuestionsFingerprints.removeAll()

        lastSystemAudioTranscript = ""
        lastSystemAudioASRError = nil
        lastQuestionDetectionResult = "No question detected yet."
        lastDetectedQuestionText = ""
        lastDetectedQuestionSource = ""
        lastDetectedQuestionSpeaker = ""
        lastDetectionConfidence = 0.0
        lastQuestionConfidence = 0.0
        lastDetectionShouldTrigger = false
        lastDetectionReason = ""
        lastDetectionRawJSON = ""
        lastDetectionSkipReason = ""
        ignoredCandidateQuestionCount = 0
        ignoredSmallTalkCount = 0
        lastTranscriptIngestionMs = 0
        lastQuestionClassificationMs = 0
        lastIgnoredSystemAudioReason = ""
        ignoredSystemAudioAnswerLikeCount = 0
        detectedQuestionsInSessionCount = 0

        // Reset ASR, Segment, Detection, and Suggestion Diagnostics
        systemASRTaskRunning = false
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

        let endingSessionID = currentSession?.id
        var persistedSessionEnd: Date?
        var sessionEndFailed = false
        if let endingSessionID {
            do {
                persistedSessionEnd = try sessionRepository.endSession(id: endingSessionID,
                    at: currentSession?.endedAt ?? stoppedAt)
            } catch { sessionEndFailed = true }
        }
        liveState = .stopped
        currentCaptureRuntimeState = .stopped(reason: reason)

        recordLifecycleTrace(
            "capture.stop.request.closed",
            reason: "reason=\(reason.rawValue)"
        )

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
        if let persistedSessionEnd, currentSession?.id == endingSessionID {
            currentSession?.endedAt = persistedSessionEnd
        }
        if sessionEndFailed, currentSession?.id == endingSessionID {
            showError("Audio stopped, but the session end could not be saved. Stop again or quit to retry.")
        }
    }

    /// Clears the current live workspace after capture has been stopped or when
    /// the user intentionally resets the interview view.
    func clearLiveSession() {
        liveRAGPrefetch.cancelAndClear()
        let startupTask = invalidateCaptureStartup()
        beginAction(ActionID.clearLiveSession, title: "Clearing session", message: "Removing current transcript, question, and answer from the live workspace...")
        let stateBefore = currentCaptureRuntimeState.displayName
        cancelStageBTask()
        liveInterview.cancelAutomaticDetection()
        liveInterview.cancelAutomaticDetectionDebounce()
        captureLifecycle.invalidateConsumer()

        let capturedSpeech = appleSpeechService ?? activeTranscriptionProvider as? AppleSpeechTranscriptionService
        let activeSpeech = activeTranscriptionProvider as? AppleSpeechTranscriptionService
        activeSpeech?.stop(retryFailedResource: true)
        if let capturedSpeech, capturedSpeech !== activeSpeech {
            capturedSpeech.stop(retryFailedResource: true)
        }
        if activeSpeech == nil { activeTranscriptionProvider?.stop() }
        activeTranscriptionProvider = nil
        let asrProviderRuntime = activeASRProviderRuntime
        activeASRProviderRuntime = nil
        queueCaptureTeardown(after: startupTask, provider: asrProviderRuntime, speech: capturedSpeech,
            retryRetainedFailures: true)
        markActiveASRProvider(nil)
        ownsSystemAudioCaptureRuntime = false

        // Ensure diagnostics are unregistered
        microphoneDiagnostics.stopMicTest()

        stopAudioSignalMonitoring()
        recentQuestionsFingerprints.removeAll()
        liveInterview.resetQuestionIngress()
        cancelledPersistenceGenerationIDs.removeAll()
        generationCoordinator.resetTerminalHistory()
        suggestionPersistenceClaims.removeAll()
        successfulSuggestionPersistenceOwners.removeAll()

        currentSession = nil
        transcriptSegments = []
        resetRuntimeTranscriptState(clearEvents: true)
        currentSuggestion = nil
        manualCaptureSuggestion = nil
        liveSuggestionHistory = []
        lastDetectedQuestion = nil
        possibleQuestion = nil
        generationUIState = .idle
        lastTranscriptSnippet = ""
        errorMessage = nil
        liveState = .idle
        currentCaptureRuntimeState = .idle

        addCaptureEvent(name: "clearLiveSession", stateBefore: stateBefore, stateAfter: "idle", reason: "sessionCleared")
        completeAction(ActionID.clearLiveSession, title: "Session cleared", message: "Ready for a new question.")
    }

    public func restartAudioInput() {
        guard !isShuttingDown else { return }
        beginAction(ActionID.restartAudioInput, title: "Restarting audio input", message: "Resetting the local audio input path...")
        audioDeviceRouteMonitor?.handleRouteChange(reason: "Manual restart requested by user")
        completeAction(ActionID.restartAudioInput, title: "Audio input restarted", message: "Watch the audio status and retry listening if needed.")
    }

    // MARK: - Diagnostics

    func startAudioSignalMonitoring() async {
        guard !isShuttingDown else { return }
        await audioSignalMonitor.start()
    }

    func stopAudioSignalMonitoring() {
        audioSignalMonitor.stop()
        noAudioWarningVisible = false
        audioRouteError = nil
    }

    func monitorAudioSignal(now: Date = Date()) {
        // Sample the exact local round on the existing owned one-second timer.
        // PCM itself stays on the capture executor; numeric events stay off disk.
        if let local = activeASRProviderRuntime as? LocalParakeetASRProvider,
           let sessionID = currentSession?.id {
            if let snapshot = local.captureIngressSnapshot(forSessionID: sessionID) {
                for event in diagnosticsState.sampleCaptureIngress(snapshot, sessionID: sessionID) {
                    recordTranscriptRuntimeEvent(event)
                }
            }
            systemASRTaskRunning = local.isTranscriptionActive(source: .systemAudio, sessionID: sessionID)
            // These are Apple-specific request diagnostics. Local Parakeet has
            // no SFSpeech request/task, even while its own bridge is active.
            recognitionRequestActive = false
            recognitionTaskActive = false
        } else if let speechService = appleSpeechService {
            self.systemASRTaskRunning = speechService.systemAudioSession?.recognitionTask != nil
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
            self.recognitionRequestActive = false
            self.recognitionTaskActive = false
        }

        guard liveState == .listening || liveState == .transcribing else {
            noAudioWarningVisible = false
            return
        }

        // The exact current microphone session owns this epoch's start and PCM
        // activity. Question detection and another capture's shared meter cannot
        // postpone or manufacture its no-buffer deadline.
        guard let microphone = appleSpeechService?.microphoneSession,
              microphone.serviceState == .running,
              let startedAt = microphone.sessionStartedAt else {
            noAudioWarningVisible = false
            return
        }
        let lastBuffer = microphone.lastBufferReceivedAt.flatMap { $0 >= startedAt ? $0 : nil }
        if let lastBuffer { self.lastAudioBufferAt = lastBuffer }
        let elapsed = now.timeIntervalSince(lastBuffer ?? startedAt)
        let noSignal = "No microphone signal detected. Check input device or restart audio capture."
        if elapsed > 3.0 {
            noAudioWarningVisible = true
            audioRouteError = noSignal
        } else {
            noAudioWarningVisible = false
            if audioRouteError == noSignal {
                audioRouteError = lastBuffer == nil ? nil : "Audio input restored."
            }
        }

    }

    // internal for AppState extension access only
    func stopAllContinuousPipelines(
        reason: StopReason,
        file: String = #file,
        line: Int = #line,
        function: String = #function
    ) {
        liveInterview.cancelAutomaticDetection()
        liveRAGPrefetch.cancelAndClear()
        let startupTask = invalidateCaptureStartup()
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

        cancelActiveGenerationForStop()
        liveInterview.cancelAutomaticDetectionDebounce()
        captureLifecycle.invalidateConsumer()

        let capturedSpeech = appleSpeechService ?? activeTranscriptionProvider as? AppleSpeechTranscriptionService
        let activeSpeech = activeTranscriptionProvider as? AppleSpeechTranscriptionService
        activeSpeech?.stop(retryFailedResource: false)
        if let capturedSpeech, capturedSpeech !== activeSpeech {
            capturedSpeech.stop(retryFailedResource: false)
        }
        if activeSpeech == nil { activeTranscriptionProvider?.stop() }
        activeTranscriptionProvider = nil
        let asrProviderRuntime = activeASRProviderRuntime
        activeASRProviderRuntime = nil
        queueCaptureTeardown(after: startupTask, provider: asrProviderRuntime, speech: capturedSpeech)
        markActiveASRProvider(nil)

        appleSpeechService = nil
        ownsSystemAudioCaptureRuntime = false

        // Stop diagnostics level metering
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
}
