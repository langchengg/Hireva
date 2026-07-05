// Handles live audio capture lifecycle for an interview session.
// This extension owns start/stop/restart behavior and audio diagnostics only.
// It must not perform question detection or suggestion generation directly;
// captured transcript segments flow into AppState+Transcript instead.

import Foundation

extension AppState {
    // MARK: - Public Entry Points

    /// Starts the selected live capture path and prepares cancellation of any
    /// stale detection or generation work from a previous run.
    ///
    /// The mode passed here is the interview runtime mode; the microphone/system
    /// routing decision is still taken from `settings.audioCaptureMode`.
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
        activeDetectionTask?.cancel()
        activeAITask?.cancel()
        detectionDebounceTask?.cancel()
        transcriptionTask?.cancel()

        Task { [weak self] in
            guard let self else { return }
            await self.startListeningAsync(mode: mode)
        }
    }

    // MARK: - Capture Startup

    /// Coordinates permissions, session creation, Apple Speech startup, and
    /// capture diagnostics on MainActor.
    ///
    /// System Audio Only must not request microphone or speech-recognition
    /// permission. Microphone Only must not start system audio capture. Mic +
    /// System starts both streams through AppleSpeechTranscriptionService.
    private func startListeningAsync(mode: InterviewMode) async {
        currentCaptureRuntimeState = .starting
        self.stopReason = nil
        self.lastCaptureStartedAt = Date()
        addCaptureEvent(name: "startListeningAsync", stateBefore: "idle", stateAfter: "starting", reason: "userRequested")

        do {
            liveState = .requestingPermission
            if mode != .mock {
                refreshPermissions()
            }
            if mode == .microphone {
                let captureMode = settings.audioCaptureMode
                let requestedASRProvider = selectedASRProviderID
                // Permission gating is capture-mode specific. Do not collapse
                // this into a generic "live transcription requires mic" check:
                // System Audio Only is the user escape hatch when mic access is
                // denied or unnecessary.
                let microphoneRequired = (captureMode == .microphoneOnly || captureMode == .microphoneAndSystem)
                let speechRecognitionRequired = microphoneRequired && requestedASRProvider == .appleSpeech
                let systemAudioRequired = (captureMode == .systemAudioOnly || captureMode == .microphoneAndSystem)

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
                let requestedASRProvider = selectedASRProviderID
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
                    let provider = LocalParakeetASRProvider()
                    let stream = try await provider.startTranscription(config: ASRConfig(
                        sessionID: session.id,
                        captureMode: captureMode
                    ))
                    self.appleSpeechService = nil
                    self.activeTranscriptionProvider = nil
                    self.markActiveASRProvider(.localParakeet)
                    self.lastSystemAudioASRError = nil
                    self.lastSystemAudioASRPartialTranscript = ""
                    self.lastSystemAudioASRFinalTranscript = ""
                    ownsSystemAudioCaptureRuntime = captureMode == .systemAudioOnly || captureMode == .microphoneAndSystem

                    transcriptionTask = Task { [weak self] in
                        do {
                            for try await segment in stream {
                                guard !Task.isCancelled else { return }
                                await self?.handleTranscriptSegment(segment)
                            }
                        } catch {
                            await MainActor.run {
                                self?.lastSystemAudioASRError = error.localizedDescription
                                self?.showError(error.localizedDescription)
                            }
                        }
                    }

                    liveState = .listening
                    currentCaptureRuntimeState = .listening
                    addCaptureEvent(name: "listeningActive", stateBefore: "starting", stateAfter: "listening", reason: "localParakeetCaptureActive")
                    showFloatingAssistant()
                    completeAction(ActionID.startInterview, title: "Listening started", message: "\(ASRProviderID.localParakeet.displayName) is active.")
                    startAudioSignalMonitoring()
                    return
                }

                let speechService = AppleSpeechTranscriptionService()
                self.appleSpeechService = speechService
                self.activeTranscriptionProvider = speechService
                self.markActiveASRProvider(.appleSpeech)

                speechService.onSessionStateChanged = { [weak self] in
                    Task { @MainActor in
                        self?.objectWillChange.send()
                    }
                }
                speechService.onRuntimeEvent = { [weak self] event in
                    Task { @MainActor in
                        self?.recordTranscriptRuntimeEvent(event)
                    }
                }

                self.lastSystemAudioASRError = nil
                self.lastSystemAudioASRPartialTranscript = ""
                self.lastSystemAudioASRFinalTranscript = ""

                // The speech service owns stream startup for the selected
                // capture mode. It is responsible for not creating disabled
                // streams for System Audio Only or Microphone Only.
                try await speechService.start(sessionID: session.id, captureMode: captureMode)
                ownsSystemAudioCaptureRuntime = captureMode == .systemAudioOnly || captureMode == .microphoneAndSystem

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
            markActiveASRProvider(nil)
            ownsSystemAudioCaptureRuntime = false
            let message = userFacing(error)
            liveState = .error(message)
            currentCaptureRuntimeState = .error(reason: message)
            addCaptureEvent(name: "startListeningFailed", stateBefore: "starting", stateAfter: "error", reason: message)
            failAction(ActionID.startInterview, title: "Could not start", message: message)
            showError(message)
        }
    }

    // MARK: - Session Reset

    private func resetLiveContextForFreshSession() {
        precomputeDebounceTask?.cancel()
        detectionDebounceTask?.cancel()
        activeDetectionTask?.cancel()
        cancelStageBTask()
        fullCardWatchdogTask?.cancel()
        fullCardWatchdogTask = nil

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
        lastAutoQuestionText = nil
        recentQuestionTimestamps.removeAll()
        acceptedQuestionSegmentIDs.removeAll()
        consumedQuestionOccurrenceKeys.removeAll()
        consumedQuestionSourceSpanKeys.removeAll()
        consumedQuestionOccurrences.removeAll()
        consumedQuestionSourceSpans.removeAll()
        consumedQuestionAbsoluteSourceSpans.removeAll()
        acceptedNormalizedQuestionKeys.removeAll()
        intentionalRepeatQuestionIDs.removeAll()
        transcriptReconciler.reset()
        cancelledPersistenceGenerationIDs.removeAll()
        terminalGenerationIDs.removeAll()
        suggestionPersistenceClaims.removeAll()
        successfulSuggestionPersistenceOwners.removeAll()
        recentQuestionsFingerprints.removeAll()
        precomputedRAGCache.removeAll()
        streamedSayFirst = ""
        streamedSayFirstSetAt = nil
        isStreamingSayFirst = false
        isExpandingSuggestionCard = false
        suggestionGenerationStarted = false
        currentGenerationID = nil
        generationUIState = .idle
    }

    // MARK: - Stop And Cleanup

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
        activeDetectionTask?.cancel()
        activeAITask?.cancel()
        detectionDebounceTask?.cancel()
        transcriptionTask?.cancel()
        markRuntimeAudioStopped()

        activeTranscriptionProvider?.stop()
        activeTranscriptionProvider = nil
        markActiveASRProvider(nil)
        ownsSystemAudioCaptureRuntime = false

        appleSpeechService?.stop()
        appleSpeechService = nil
        ownsSystemAudioCaptureRuntime = false

        // Stop diagnostics level metering
        AudioEngineManager.shared.unregister(microphoneDiagnostics)
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
            currentSession?.endedAt = stoppedAt
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

    /// Clears the current live workspace after capture has been stopped or when
    /// the user intentionally resets the interview view.
    func clearLiveSession() {
        beginAction(ActionID.clearLiveSession, title: "Clearing session", message: "Removing current transcript, question, and answer from the live workspace...")
        let stateBefore = currentCaptureRuntimeState.displayName
        cancelStageBTask()
        fullCardWatchdogTask?.cancel()
        fullCardWatchdogTask = nil
        activeDetectionTask?.cancel()
        activeAITask?.cancel()
        detectionDebounceTask?.cancel()
        transcriptionTask?.cancel()

        activeTranscriptionProvider?.stop()
        activeTranscriptionProvider = nil
        markActiveASRProvider(nil)
        ownsSystemAudioCaptureRuntime = false

        // Ensure diagnostics are unregistered
        AudioEngineManager.shared.unregister(microphoneDiagnostics)
        microphoneDiagnostics.stopMicTest()

        stopAudioSignalMonitoring()
        recentQuestionsFingerprints.removeAll()
        recentQuestionTimestamps.removeAll()
        acceptedQuestionSegmentIDs.removeAll()
        consumedQuestionOccurrenceKeys.removeAll()
        consumedQuestionSourceSpanKeys.removeAll()
        consumedQuestionOccurrences.removeAll()
        consumedQuestionSourceSpans.removeAll()
        consumedQuestionAbsoluteSourceSpans.removeAll()
        acceptedNormalizedQuestionKeys.removeAll()
        intentionalRepeatQuestionIDs.removeAll()
        transcriptReconciler.reset()
        cancelledPersistenceGenerationIDs.removeAll()
        terminalGenerationIDs.removeAll()
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
        currentGenerationID = nil
        generationUIState = .idle
        lastTranscriptSnippet = ""
        lastAutoQuestionText = nil
        errorMessage = nil
        liveState = .idle
        currentCaptureRuntimeState = .idle

        addCaptureEvent(name: "clearLiveSession", stateBefore: stateBefore, stateAfter: "idle", reason: "sessionCleared")
        completeAction(ActionID.clearLiveSession, title: "Session cleared", message: "Ready for a new question.")
    }

    public func restartAudioInput() {
        beginAction(ActionID.restartAudioInput, title: "Restarting audio input", message: "Resetting the local audio input path...")
        AudioEngineManager.shared.restartForRouteChange(reason: "Manual restart requested by user")
        completeAction(ActionID.restartAudioInput, title: "Audio input restarted", message: "Watch the audio status and retry listening if needed.")
    }

    // MARK: - Diagnostics

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

    // internal for AppState extension access only
    func stopAllContinuousPipelines(
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
        cancelActiveGenerationForStop()
        detectionDebounceTask?.cancel()
        transcriptionTask?.cancel()

        activeTranscriptionProvider?.stop()
        activeTranscriptionProvider = nil
        markActiveASRProvider(nil)

        appleSpeechService?.stop()
        appleSpeechService = nil
        ownsSystemAudioCaptureRuntime = false

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
}
