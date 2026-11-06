import Foundation

extension AppState {
    nonisolated private static let liveSystemAudioDiagnosticRunKey = "ICRunLiveSystemAudioFinalDiagnostic"
    nonisolated private static let liveSystemAudioDiagnosticQuestionKey = "ICLiveSystemAudioDiagnosticQuestion"
    nonisolated private static let liveSystemAudioDiagnosticNotification = Notification.Name("com.langcheng.Hireva.LiveSystemAudioFinalDiagnostic")

    func installLiveSystemAudioDiagnosticNotificationObserver(
        verification: HirevaVerificationConfiguration? = .current
    ) {
        #if DEBUG
        guard !isShuttingDown, verification == nil, liveSystemAudioDiagnosticObserverToken == nil else { return }
        let center = DistributedNotificationCenter.default()
        let observer = center.addObserver(
            forName: Self.liveSystemAudioDiagnosticNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Extract the immutable value on the notification executor; the
            // non-Sendable Notification never crosses into MainActor isolation.
            let suppliedQuestion = notification.userInfo?["question"] as? String
            MainActor.assumeIsolated {
                guard let self, !self.isShuttingDown else { return }
                let question = suppliedQuestion ??
                    UserDefaults.standard.string(forKey: Self.liveSystemAudioDiagnosticQuestionKey) ??
                    "How did your system connect input processing with planning, execution, and recovery?"
                self.requestLiveSystemAudioFinalCallbackDiagnostic(question: question)
            }
        }
        liveSystemAudioDiagnosticObserverToken = Self.makeNotificationCancellation(observer: observer, center: center)
        #endif
    }

    func runLaunchLiveSystemAudioDiagnosticIfRequested(
        verification: HirevaVerificationConfiguration? = .current
    ) {
        #if DEBUG
        guard !isShuttingDown, verification == nil else { return }
        guard let question = Self.consumeLegacyDiagnosticLaunchRequest(
            defaults: .standard, verification: verification
        ) else { return }
        requestLiveSystemAudioFinalCallbackDiagnostic(question: question)
        #endif
    }

    static func consumeLegacyDiagnosticLaunchRequest(
        defaults: UserDefaults,
        verification: HirevaVerificationConfiguration?
    ) -> String? {
        guard verification == nil else { return nil }
        guard defaults.bool(forKey: Self.liveSystemAudioDiagnosticRunKey) else { return nil }
        defaults.set(false, forKey: Self.liveSystemAudioDiagnosticRunKey)
        return defaults.string(forKey: Self.liveSystemAudioDiagnosticQuestionKey) ??
            "How did your system connect input processing with planning, execution, and recovery?"
    }

    @MainActor
    func runLiveSystemAudioFinalCallbackDiagnostic(question: String) async {
        #if DEBUG
        guard !Task.isCancelled,
            let task = requestLiveSystemAudioFinalCallbackDiagnostic(question: question) else { return }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: { task.cancel() }
        #endif
    }

    #if DEBUG
    @discardableResult
    private func requestLiveSystemAudioFinalCallbackDiagnostic(question: String) -> Task<Void, Never>? {
        guard !isShuttingDown else { return nil }
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            recordAnswerRequestSkipped(reason: "empty_question")
            return nil
        }
        guard let task = diagnosticsState.requestSystemAudioDiagnostic(operation: { [weak self] id in
            await self?.performLiveSystemAudioFinalCallbackDiagnostic(question: trimmed, id: id)
        }) else {
            recordAnswerRequestSkipped(reason: "diagnostic_busy")
            return nil
        }
        return task
    }

    private func isCurrentLiveSystemAudioDiagnostic(_ id: UUID, sessionID: String?,
        speech: AppleSpeechTranscriptionService?, provider: (any TranscriptionProvider)?) -> Bool {
        !isShuttingDown && diagnosticsState.isCurrentSystemAudioDiagnostic(id) &&
            currentSession?.id == sessionID && appleSpeechService === speech &&
            activeTranscriptionProvider === provider
    }

    private func performLiveSystemAudioFinalCallbackDiagnostic(question trimmed: String, id: UUID) async {
        guard !isShuttingDown, diagnosticsState.isCurrentSystemAudioDiagnostic(id) else { return }
        var expectedSessionID = currentSession?.id
        var expectedSpeech = appleSpeechService
        var expectedProvider = activeTranscriptionProvider
        do {
            var nextSettings = settings
            nextSettings.audioCaptureMode = .systemAudioOnly
            nextSettings.automaticQuestionDetectionEnabled = true
            nextSettings.manualOnlyMode = false
            nextSettings.allowQuestionDetectionFromMicrophoneOnly = false
            saveSettings(nextSettings)
            guard isCurrentLiveSystemAudioDiagnostic(id, sessionID: expectedSessionID,
                speech: expectedSpeech, provider: expectedProvider) else { return }

            let session: InterviewSession
            if let currentSession, currentSession.endedAt == nil {
                session = currentSession
            } else {
                session = try createContextBoundSession(mode: .microphone, title: "Live System Audio Diagnostic")
                currentSession = session
            }
            expectedSessionID = session.id
            guard isCurrentLiveSystemAudioDiagnostic(id, sessionID: expectedSessionID,
                speech: expectedSpeech, provider: expectedProvider) else { return }

            if transcriptSegments.isEmpty {
                transcriptSegments.append(.system("Live system-audio diagnostic session started.", sessionID: session.id))
            }
            if let beforeService = liveSystemAudioDiagnosticWillCreateServiceForTesting {
                try await beforeService()
                guard isCurrentLiveSystemAudioDiagnostic(id, sessionID: expectedSessionID,
                    speech: expectedSpeech, provider: expectedProvider) else { return }
            }

            let speechService = AppleSpeechTranscriptionService()
            appleSpeechService = speechService
            activeTranscriptionProvider = speechService
            expectedSpeech = speechService
            expectedProvider = speechService
            speechService.onSessionStateChanged = { [weak self, weak speechService] in
                guard let self, !self.isShuttingDown, let speechService,
                    self.currentSession?.id == session.id,
                    self.appleSpeechService === speechService,
                    self.activeTranscriptionProvider === speechService else { return }
                // These callbacks belong to continuous listening after the script exits.
                self.objectWillChange.send()
            }
            speechService.onRuntimeEvent = { [weak self, weak speechService] event in
                guard let self, !self.isShuttingDown, let speechService,
                    self.currentSession?.id == session.id,
                    self.appleSpeechService === speechService,
                    self.activeTranscriptionProvider === speechService else { return }
                self.recordTranscriptRuntimeEvent(event)
            }

            showFloatingAssistant()
            guard isCurrentLiveSystemAudioDiagnostic(id, sessionID: expectedSessionID,
                speech: expectedSpeech, provider: expectedProvider) else { return }
            liveState = .listening
            currentCaptureRuntimeState = .listening
            guard isCurrentLiveSystemAudioDiagnostic(id, sessionID: expectedSessionID,
                speech: expectedSpeech, provider: expectedProvider) else { return }
            speechService.startDiagnosticSystemAudioSession(sessionID: session.id)
            let expectedSystemSession = speechService.systemAudioSession
            guard isCurrentLiveSystemAudioDiagnostic(id, sessionID: expectedSessionID,
                speech: expectedSpeech, provider: expectedProvider) else { return }
            consumeSegments(from: speechService)
            await Task.yield()
            guard isCurrentLiveSystemAudioDiagnostic(id, sessionID: expectedSessionID,
                speech: expectedSpeech, provider: expectedProvider),
                speechService.systemAudioSession === expectedSystemSession else { return }
            recordLifecycleTrace("diagnostic.live_system_audio_final.started",
                sessionID: session.id, text: trimmed)

            guard let systemSession = expectedSystemSession else {
                recordAnswerRequestSkipped(reason: "system_audio_session_missing", sessionID: session.id, text: trimmed)
                return
            }
            systemSession.simulateEmit(text: trimmed, isFinal: false)
            try await Task.sleep(nanoseconds: 50_000_000)
            guard isCurrentLiveSystemAudioDiagnostic(id, sessionID: expectedSessionID,
                speech: expectedSpeech, provider: expectedProvider),
                speechService.systemAudioSession === systemSession else { return }
            systemSession.simulateEmit(text: trimmed, isFinal: true)
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentLiveSystemAudioDiagnostic(id, sessionID: expectedSessionID,
                speech: expectedSpeech, provider: expectedProvider) else { return }
            let message = userFacing(error)
            recordAnswerRequestSkipped(reason: "diagnostic_harness_failed", text: trimmed)
            liveState = .error(message)
            showError(message)
        }
    }
    #endif
}
