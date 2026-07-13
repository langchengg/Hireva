import Foundation

extension AppState {
    nonisolated private static let liveSystemAudioDiagnosticRunKey = "ICRunLiveSystemAudioFinalDiagnostic"
    nonisolated private static let liveSystemAudioDiagnosticQuestionKey = "ICLiveSystemAudioDiagnosticQuestion"
    nonisolated private static let liveSystemAudioDiagnosticNotification = Notification.Name("com.langcheng.Hireva.LiveSystemAudioFinalDiagnostic")

    func installLiveSystemAudioDiagnosticNotificationObserver() {
        #if DEBUG
        guard liveSystemAudioDiagnosticObserverToken == nil else { return }
        liveSystemAudioDiagnosticObserverToken = DistributedNotificationCenter.default().addObserver(
            forName: Self.liveSystemAudioDiagnosticNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let question = notification.userInfo?["question"] as? String ??
                UserDefaults.standard.string(forKey: Self.liveSystemAudioDiagnosticQuestionKey) ??
                "How did your system connect input processing with planning, execution, and recovery?"
            Task { @MainActor [weak self] in
                await self?.runLiveSystemAudioFinalCallbackDiagnostic(question: question)
            }
        }
        #endif
    }

    func runLaunchLiveSystemAudioDiagnosticIfRequested() {
        #if DEBUG
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Self.liveSystemAudioDiagnosticRunKey) else { return }
        defaults.set(false, forKey: Self.liveSystemAudioDiagnosticRunKey)
        let question = defaults.string(forKey: Self.liveSystemAudioDiagnosticQuestionKey) ??
            "How did your system connect input processing with planning, execution, and recovery?"
        Task { [weak self] in
            await self?.runLiveSystemAudioFinalCallbackDiagnostic(question: question)
        }
        #endif
    }

    @MainActor
    func runLiveSystemAudioFinalCallbackDiagnostic(question: String) async {
        #if DEBUG
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            recordAnswerRequestSkipped(reason: "empty_question")
            return
        }

        do {
            var nextSettings = settings
            nextSettings.audioCaptureMode = .systemAudioOnly
            nextSettings.automaticQuestionDetectionEnabled = true
            nextSettings.manualOnlyMode = false
            nextSettings.allowQuestionDetectionFromMicrophoneOnly = false
            saveSettings(nextSettings)

            let session: InterviewSession
            if let currentSession, currentSession.endedAt == nil {
                session = currentSession
            } else {
                session = try createContextBoundSession(mode: .microphone, title: "Live System Audio Diagnostic")
                currentSession = session
            }

            if transcriptSegments.isEmpty {
                transcriptSegments.append(.system("Live system-audio diagnostic session started.", sessionID: session.id))
            }

            let speechService = AppleSpeechTranscriptionService()
            appleSpeechService = speechService
            activeTranscriptionProvider = speechService
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

            showFloatingAssistant()
            liveState = .listening
            currentCaptureRuntimeState = .listening
            consumeSegments(from: speechService)
            await Task.yield()
            speechService.startDiagnosticSystemAudioSession(sessionID: session.id)
            await Task.yield()
            recordLifecycleTrace(
                "diagnostic.live_system_audio_final.started",
                sessionID: session.id,
                text: trimmed
            )

            guard let systemSession = speechService.systemAudioSession else {
                recordAnswerRequestSkipped(reason: "system_audio_session_missing", sessionID: session.id, text: trimmed)
                return
            }
            systemSession.simulateEmit(text: trimmed, isFinal: false)
            try? await Task.sleep(nanoseconds: 50_000_000)
            systemSession.simulateEmit(text: trimmed, isFinal: true)
        } catch {
            let message = userFacing(error)
            recordAnswerRequestSkipped(reason: "diagnostic_harness_failed", text: trimmed)
            liveState = .error(message)
            showError(message)
        }
        #endif
    }
}
