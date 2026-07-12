import Foundation

enum ProductInterviewStatus: String, Hashable {
    case ready
    case listening
    case questionDetected
    case generatingFirstAnswer
    case expandingAnswer
    case needsAttention
    case stopped

    var title: String {
        switch self {
        case .ready: return "Ready"
        case .listening: return "Listening"
        case .questionDetected: return "Question detected"
        case .generatingFirstAnswer: return "Generating first answer"
        case .expandingAnswer: return "Expanding answer"
        case .needsAttention: return "Needs attention"
        case .stopped: return "Stopped"
        }
    }

    var systemImage: String {
        switch self {
        case .ready: return "checkmark.circle.fill"
        case .listening: return "dot.radiowaves.left.and.right"
        case .questionDetected: return "questionmark.bubble.fill"
        case .generatingFirstAnswer: return "sparkles"
        case .expandingAnswer: return "text.badge.plus"
        case .needsAttention: return "exclamationmark.triangle.fill"
        case .stopped: return "stop.circle"
        }
    }
}

enum ReadinessCheckStatus: String, Hashable {
    case passed
    case warning
    case failed
}

enum ReadinessAction: String, Hashable, CaseIterable {
    case openSettings
    case openDocuments
    case testDeepSeek
    case rebuildRAG
    case openPermissions
    case showFloatingPanel
    case openHome
}

struct ReadinessCheckItem: Identifiable, Hashable {
    var id: String
    var title: String
    var detail: String
    var status: ReadinessCheckStatus
    var actionTitle: String?
    var action: ReadinessAction?

    var needsAction: Bool {
        status != .passed && action != nil
    }
}

extension AppState {
    var productInterviewStatus: ProductInterviewStatus {
        if case .error = liveState {
            return .needsAttention
        }
        if liveState == .permissionDenied || noAudioWarningVisible || !coreInterviewReadinessPassed {
            return .needsAttention
        }
        if shouldShowBlockingAnswerSpinner {
            return .generatingFirstAnswer
        }
        if shouldShowAnswerExpansionStatus {
            return .expandingAnswer
        }
        if lastDetectedQuestion != nil || possibleQuestion != nil {
            return .questionDetected
        }
        if isListening {
            return .listening
        }
        if liveState == .stopped || currentCaptureRuntimeState.id == CaptureRuntimeState.stopped(reason: nil).id {
            return .stopped
        }
        if currentSuggestion != nil {
            return .ready
        }
        return .ready
    }

    var primaryHomeActionTitle: String {
        if primaryHomeActionShouldStop {
            return "Stop Listening"
        }
        if !coreInterviewReadinessPassed {
            return "Run Readiness Check"
        }
        return "Start Interview"
    }

    var primaryHomeActionSystemImage: String {
        if primaryHomeActionShouldStop {
            return "stop.fill"
        }
        if !coreInterviewReadinessPassed {
            return "checklist.checked"
        }
        return "play.fill"
    }

    var primaryHomeActionShouldStop: Bool {
        liveState.canStop || currentCaptureRuntimeState == .starting || currentCaptureRuntimeState == .listening || currentCaptureRuntimeState == .generating || currentCaptureRuntimeState == .stopping
    }

    var homeLiveAnswerPreviewText: String? {
        if let card = currentSuggestion, !card.sayFirst.isEmpty {
            return card.sayFirst
        }
        if !streamedSayFirst.isEmpty {
            return streamedSayFirst
        }
        if shouldShowBlockingAnswerSpinner {
            return streamedSayFirst.isEmpty ? "Generating first answer..." : streamedSayFirst
        }
        return nil
    }

    var coreInterviewReadinessPassed: Bool {
        hasCV
            && hasJD
            && selectedAnswerProviderConfigured
            && hasCleanRelevantContext
            && latexPollutedChunkCount == 0
            && requiredPermissionsReady
    }

    var selectedAnswerProviderConfigured: Bool {
        switch selectedAnswerProviderMode {
        case .localQwenPrimary:
            return true
        case .deepSeekPrimary, .deepSeekWithLocalQwenFallback:
            return deepSeekConfigured
        }
    }

    var selectedAnswerProviderStatusTitle: String {
        switch selectedAnswerProviderMode {
        case .localQwenPrimary:
            return "Local Qwen Primary"
        case .deepSeekPrimary:
            return deepSeekConfigured ? "DeepSeek Primary" : "DeepSeek Missing"
        case .deepSeekWithLocalQwenFallback:
            return deepSeekConfigured ? "DeepSeek + Local Fallback" : "DeepSeek Missing"
        }
    }

    var selectedAnswerProviderReadinessDetail: String {
        switch selectedAnswerProviderMode {
        case .localQwenPrimary:
            return "Local Qwen is selected; runtime health is checked before generation."
        case .deepSeekPrimary:
            return deepSeekConfigured ? "DeepSeek is securely saved." : "DeepSeek is selected but not configured."
        case .deepSeekWithLocalQwenFallback:
            return deepSeekConfigured
                ? "DeepSeek is securely saved and Local Qwen fallback is enabled."
                : "DeepSeek is selected as primary but not configured."
        }
    }

    var deepSeekConfigured: Bool {
        keychainDeepSeekKeyExists && providerConfigurations.contains { $0.kind == .deepSeek }
    }

    var deepSeekProviderConfigured: Bool {
        providerConfigurations.contains { $0.kind == .deepSeek }
    }

    var deepSeekCredentialSource: String {
        guard providerConfigurations.contains(where: { $0.kind == .deepSeek && ($0.apiKeyAccount?.isEmpty == false) }) else {
            return "None"
        }
        return "Keychain"
    }

    var settingsConfigSource: String {
        "DB: llm_provider_configurations"
    }

    var generationConfigSource: String {
        "DB: active_realtime_provider_id + llm_provider_configurations"
    }

    var lastProviderConfigError: String {
        guard let provider = providerConfigurations.first(where: { $0.kind == .deepSeek }) else {
            return "missing_deepseek_provider"
        }
        guard let account = provider.apiKeyAccount,
              !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "missing_deepseek_keychain_account"
        }
        if keychainAuthorizationWarning != nil {
            return "keychain_authorization_required"
        }
        guard keychainDeepSeekKeyExists else {
            return "missing_keychain_credential"
        }
        return "none"
    }

    var hasCleanRelevantContext: Bool {
        diagnostics.storedCVChunkCount > 0 && diagnostics.storedJDChunkCount > 0
    }

    var relevantContextStatus: String {
        if !hasCV || !hasJD || !hasCleanRelevantContext {
            return "Needs Documents"
        }
        if latexPollutedChunkCount > 0 {
            return "Needs Clean Rebuild"
        }
        if settings.enableVectorRAG,
           let coverage = embeddingCoverage,
           settings.forceHybridRAG || coverage.coveragePercent >= 80 {
            return "Hybrid RAG"
        }
        return "Clean Keyword RAG"
    }

    var userFacingRelevantContextStatus: String {
        switch relevantContextStatus {
        case "Hybrid RAG":
            return "Hybrid relevant context"
        case "Clean Keyword RAG":
            return "Clean keyword context"
        case "Needs Clean Rebuild":
            return "Needs clean rebuild"
        default:
            return "Needs documents"
        }
    }

    var permissionSummary: String {
        var missing: [String] = []
        if microphoneRequired && microphonePermissionState != .authorized {
            missing.append("your microphone")
        }
        if speechRecognitionRequired && permissionSnapshot.speechRecognition != .granted {
            missing.append("speech recognition")
        }
        if systemAudioRequired && systemAudioPermissionState != .granted {
            missing.append("interviewer audio")
        }
        return missing.isEmpty ? "Ready" : "Needs " + missing.joined(separator: ", ")
    }

    var speechRecognitionRequired: Bool {
        selectedASRProviderID == .appleSpeech && (microphoneRequired || systemAudioRequired)
    }

    var requiredPermissionsReady: Bool {
        let microphoneOK = !microphoneRequired || microphonePermissionState == .authorized
        let speechOK = !speechRecognitionRequired || permissionSnapshot.speechRecognition == .granted
        let systemAudioOK = !systemAudioRequired || systemAudioPermissionState == .granted
        return microphoneOK && speechOK && systemAudioOK
    }

    var readinessCheckItems: [ReadinessCheckItem] {
        [
            ReadinessCheckItem(
                id: "answer-provider",
                title: "Answer provider selected",
                detail: selectedAnswerProviderReadinessDetail,
                status: selectedAnswerProviderConfigured ? .passed : .failed,
                actionTitle: selectedAnswerProviderConfigured ? nil : "Open Settings",
                action: selectedAnswerProviderConfigured ? nil : .openSettings
            ),
            ReadinessCheckItem(
                id: "documents",
                title: "Documents loaded",
                detail: hasCV && hasJD ? "CV and job description are saved." : "Add your CV and job description to personalize answers.",
                status: hasCV && hasJD ? .passed : .failed,
                actionTitle: "Open Documents",
                action: .openDocuments
            ),
            ReadinessCheckItem(
                id: "chunks",
                title: "Clean relevant context exists",
                detail: hasCleanRelevantContext ? "\(diagnostics.storedCVChunkCount + diagnostics.storedJDChunkCount) clean chunks are ready." : "Save documents or rebuild the clean context index.",
                status: hasCleanRelevantContext ? .passed : .failed,
                actionTitle: "Rebuild Context",
                action: .rebuildRAG
            ),
            ReadinessCheckItem(
                id: "latex",
                title: "No LaTeX pollution",
                detail: latexPollutedChunkCount == 0 ? "Visible answers use cleaned plain text." : "\(latexPollutedChunkCount) chunks still contain formatting noise.",
                status: latexPollutedChunkCount == 0 ? .passed : .failed,
                actionTitle: "Rebuild Context",
                action: .rebuildRAG
            ),
            ReadinessCheckItem(
                id: "system-audio",
                title: "Interviewer audio permission",
                detail: systemAudioRequired ? systemAudioPermissionState.displayName : "Not needed for the selected capture mode.",
                status: (!systemAudioRequired || systemAudioPermissionState == .granted) ? .passed : .failed,
                actionTitle: "Open Screen Audio Settings",
                action: .openPermissions
            ),
            ReadinessCheckItem(
                id: "microphone",
                title: "Your microphone permission",
                detail: microphoneRequired ? microphonePermissionState.displayName : "Not needed for the selected capture mode.",
                status: (!microphoneRequired || microphonePermissionState == .authorized) ? .passed : .failed,
                actionTitle: microphonePermissionState == .notDetermined ? "Request Microphone" : "Open Microphone Settings",
                action: .openPermissions
            ),
            ReadinessCheckItem(
                id: "speech",
                title: "Speech recognition permission",
                detail: speechRecognitionRequired ? permissionSnapshot.speechRecognition.displayName : "Not needed for the selected capture mode.",
                status: (!speechRecognitionRequired || permissionSnapshot.speechRecognition == .granted) ? .passed : .failed,
                actionTitle: permissionSnapshot.speechRecognition == .notDetermined ? "Request Speech Access" : "Open Speech Settings",
                action: .openPermissions
            ),
            ReadinessCheckItem(
                id: "capture-mode",
                title: "Capture mode selected",
                detail: settings.audioCaptureMode.displayName,
                status: .passed,
                actionTitle: nil,
                action: nil
            ),
            ReadinessCheckItem(
                id: "floating",
                title: "Floating panel visible",
                detail: isFloatingAssistantVisible ? "Floating Assistant is visible." : "Show the floating answer card before the interview starts.",
                status: isFloatingAssistantVisible ? .passed : .failed,
                actionTitle: "Show Floating Panel",
                action: .showFloatingPanel
            ),
            ReadinessCheckItem(
                id: "transcript-test",
                title: "Last test transcript received",
                detail: displayTranscriptText.isEmpty && transcriptSegments.isEmpty ? "No test transcript yet." : "A transcript has been received.",
                status: displayTranscriptText.isEmpty && transcriptSegments.isEmpty ? .warning : .passed,
                actionTitle: "Open Interview",
                action: .openHome
            ),
            ReadinessCheckItem(
                id: "first-answer-test",
                title: "First answer generation test passed",
                detail: currentSuggestion == nil ? "No answer has been generated in this session yet." : "First answer is visible.",
                status: currentSuggestion == nil ? .warning : .passed,
                actionTitle: "Open Interview",
                action: .openHome
            )
        ]
    }

    var readinessOutcomeTitle: String {
        readinessCheckItems.contains { $0.status == .failed } ? "Needs attention" : "Ready for interview"
    }
}
