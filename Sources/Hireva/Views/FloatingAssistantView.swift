import AppKit
import SwiftUI

struct FloatingAssistantView: View {
    @ObservedObject var live: LiveInterviewFeature
    @ObservedObject var manual: ManualCaptureController
    @ObservedObject var settingsState: SettingsState
    @ObservedObject var diagnosticsState: DiagnosticsState
    let activeIdentity: GenerationIdentity?
    private var generationState: GenerationUIState { live.generationUIState }
    let elapsedMS: Int
    private var isStreaming: Bool { live.isStreamingSayFirst }
    private var isExpanding: Bool { live.isExpandingSuggestionCard }
    let providerStreamActive: Bool
    let productInterviewStatus: ProductInterviewStatus
    let systemCaptureRunning: Bool
    let micCaptureRunning: Bool
    let canStopCapture: Bool
    let selectedAnswerProviderStatusTitle: String
    let selectedAnswerProviderConfigured: Bool
    let userFacingRelevantContextStatus: String
    let hasCleanRelevantContext: Bool
    var queuedQuestionID: String? { live.pendingAcceptedQuestions.first?.question.id }
    var hasQueuedQuestions: Bool { !live.pendingAcceptedQuestions.isEmpty }
    let diagnosticDisplay: FloatingAssistantDiagnosticsDisplay?
    let currentSuspectedMismatchReason: String
    let lastAlignmentError: String
    let saveSettings: (AppSettings) -> Void
    let stopListening: () -> Void
    let openMainWindow: () -> Void
    let regenerateManualSuggestion: () -> Void
    let regenerateVisibleSuggestion: () -> Void
    let feedbacks: [ActionFeedback]
    let loadingStates: [String: Bool]
    let beginFeedback: (String, String, String) -> Void
    let completeFeedback: (String, String, String) -> Void
    let infoFeedback: (String, String, String, TimeInterval?) -> Void
    let failFeedback: (String, String, String) -> Void

    init(live: LiveInterviewFeature,
        manual: ManualCaptureController,
        settingsState: SettingsState,
        diagnosticsState: DiagnosticsState,
        activeIdentity: GenerationIdentity?,
        elapsedMS: Int,
        providerStreamActive: Bool,
        productInterviewStatus: ProductInterviewStatus,
        systemCaptureRunning: Bool,
        micCaptureRunning: Bool,
        canStopCapture: Bool,
        selectedAnswerProviderStatusTitle: String,
        selectedAnswerProviderConfigured: Bool,
        userFacingRelevantContextStatus: String,
        hasCleanRelevantContext: Bool,
        diagnosticDisplay: FloatingAssistantDiagnosticsDisplay?,
        currentSuspectedMismatchReason: String,
        lastAlignmentError: String,
        saveSettings: @escaping (AppSettings) -> Void,
        stopListening: @escaping () -> Void,
        openMainWindow: @escaping () -> Void,
        regenerateManualSuggestion: @escaping () -> Void,
        regenerateVisibleSuggestion: @escaping () -> Void,
        feedbacks: [ActionFeedback],
        loadingStates: [String: Bool],
        beginFeedback: @escaping (String, String, String) -> Void,
        completeFeedback: @escaping (String, String, String) -> Void,
        infoFeedback: @escaping (String, String, String, TimeInterval?) -> Void,
        failFeedback: @escaping (String, String, String) -> Void) {
        self.live = live
        self.manual = manual
        self.settingsState = settingsState
        self.diagnosticsState = diagnosticsState
        self.activeIdentity = activeIdentity
        self.elapsedMS = elapsedMS
        self.providerStreamActive = providerStreamActive
        self.productInterviewStatus = productInterviewStatus
        self.systemCaptureRunning = systemCaptureRunning
        self.micCaptureRunning = micCaptureRunning
        self.canStopCapture = canStopCapture
        self.selectedAnswerProviderStatusTitle = selectedAnswerProviderStatusTitle
        self.selectedAnswerProviderConfigured = selectedAnswerProviderConfigured
        self.userFacingRelevantContextStatus = userFacingRelevantContextStatus
        self.hasCleanRelevantContext = hasCleanRelevantContext
        self.diagnosticDisplay = diagnosticDisplay
        self.currentSuspectedMismatchReason = currentSuspectedMismatchReason
        self.lastAlignmentError = lastAlignmentError
        self.saveSettings = saveSettings
        self.stopListening = stopListening
        self.openMainWindow = openMainWindow
        self.regenerateManualSuggestion = regenerateManualSuggestion
        self.regenerateVisibleSuggestion = regenerateVisibleSuggestion
        self.feedbacks = feedbacks
        self.loadingStates = loadingStates
        self.beginFeedback = beginFeedback
        self.completeFeedback = completeFeedback
        self.infoFeedback = infoFeedback
        self.failFeedback = failFeedback
    }
    @State private var answerVisible = true
    @State private var sourcesExpanded = false
    @State private var followUpExpanded = false

    private var displayMode: FloatingAssistantDisplayMode {
        if ProductionContextPolicy.verificationMocksEnabled(
            explicitOverride: nil,
            environmentValue: ProcessInfo.processInfo.environment["ENABLE_VERIFICATION_MOCKS"]
        ) {
            return .normal
        }
        return settingsState.settings.floatingAssistantDisplayMode
    }

    private var activeCard: SuggestionCard? {
        manual.suggestion ?? live.currentSuggestion
    }

    var renderState: VisibleAssistantRenderState {
        live.renderState(activeIdentity: activeIdentity, generationState: generationState,
            elapsedMS: elapsedMS, isStreaming: isStreaming, isExpanding: isExpanding,
            providerStreamActive: providerStreamActive)
    }
    private var shouldShowBlockingAnswerSpinner: Bool {
        live.shouldShowBlockingAnswerSpinner(generationState: generationState, elapsedMS: elapsedMS)
    }
    private var shouldShowAnswerExpansionStatus: Bool {
        live.shouldShowAnswerExpansionStatus(generationState: generationState, isExpanding: isExpanding)
    }
    private var effectiveOpacity: Double {
        max(settingsState.settings.highContrastFloatingPanel ? 0.72 : 0.62, settingsState.settings.floatingWindowOpacity)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: displayMode == .compact ? 10 : 12) {
            header
            statusRow
            InlineStatusBanner(floatingFeedback)

            Divider()

            switch displayMode {
            case .compact:
                compactBody
            case .normal:
                normalBody
            case .diagnostic:
                diagnosticBody
            }
        }
        .padding(displayMode == .compact ? 12 : 14)
        .frame(minWidth: displayMode == .compact ? 360 : 430, minHeight: displayMode == .compact ? 220 : 320, alignment: .topLeading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(effectiveOpacity))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 10, x: 0, y: 5)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label(productInterviewStatus.title, systemImage: productInterviewStatus.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(statusTint)

            Spacer()

            Picker("", selection: displayModeBinding) {
                ForEach(FloatingAssistantDisplayMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 210)
            .labelsHidden()

            Button {
                answerVisible.toggle()
            } label: {
                Image(systemName: answerVisible ? "eye" : "eye.slash")
            }
            .buttonStyle(.borderless)
            .help(answerVisible ? "Hide Answer" : "Show Answer")

            Button {
                regenerate()
            } label: {
                if isActionLoading(ActionID.floatingRegenerate) || isActionLoading(ActionID.generateAnswer) || isActionLoading(ActionID.manualGenerate) {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .help("Regenerate")
            .disabled(regenerateDisabled)

            Button {
                copyAnswer()
            } label: {
                Image(systemName: latestActionFeedback(for: ActionID.floatingCopy)?.kind == .success ? "checkmark.circle.fill" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy Answer")
            .disabled(activeCard?.sayFirst.isEmpty != false && live.streamedSayFirst.isEmpty)

            Button {
                stopListening()
            } label: {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.borderless)
            .help("Stop Listening")
            .disabled(!canStopCapture)

            Button {
                openMainWindow()
            } label: {
                Image(systemName: "macwindow")
            }
            .buttonStyle(.borderless)
            .help("Open Main Window")
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            StatusPill(title: systemCaptureRunning ? "System Active" : "System Off", systemImage: "speaker.wave.2.fill", tint: systemCaptureRunning ? .green : .secondary, isCompact: true)
            StatusPill(title: micCaptureRunning ? "Mic Active" : "Mic Off", systemImage: "mic.fill", tint: micCaptureRunning ? .green : .secondary, isCompact: true)
            StatusPill(title: selectedAnswerProviderStatusTitle, systemImage: selectedAnswerProviderConfigured ? "sparkles" : "key", tint: selectedAnswerProviderConfigured ? .blue : .orange, isCompact: true)
            StatusPill(title: userFacingRelevantContextStatus, systemImage: "doc.text.magnifyingglass", tint: hasCleanRelevantContext ? .green : .orange, isCompact: true)
        }
    }

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            questionBlock(lineLimit: 2)
            if answerVisible {
                sayFirstBlock(fontSize: 16, lineLimit: 5)
                keyPointsBlock(limit: 2)
            }
        }
    }

    private var normalBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                questionBlock(lineLimit: 4)

                if answerVisible {
                    sayFirstBlock(fontSize: 17, lineLimit: nil)
                    keyPointsBlock(limit: 4)
                    followUpDisclosure
                    sourcesDisclosure(showScores: false)
                } else {
                    Text("Answer hidden")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var diagnosticBody: some View {
        ScrollView {
            if let diagnosticDisplay {
            VStack(alignment: .leading, spacing: 12) {
                questionBlock(lineLimit: 4)

                if answerVisible {
                    sayFirstBlock(fontSize: 15, lineLimit: nil)
                    keyPointsBlock(limit: 4)
                    Divider()
                } else {
                    Text("Answer hidden")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                diagnosticSection("Visible Lifecycle") {
                    diagnosticRow("currentQuestionText", currentQuestionText)
                    diagnosticRow("currentQuestionId", renderState.activeQuestionID ?? live.lastDetectedQuestion?.id ?? "nil")
                    diagnosticRow("currentSessionId", live.currentSession?.id ?? emptyAware(diagnosticsState.runtime.audioSessionID, fallback: "nil"))
                    diagnosticRow("activeGenerationId", renderState.activeGenerationID ?? "nil")
                    diagnosticRow("selectedProvider", activeCard?.providerName ?? settingsState.activeRealtimeProvider?.name ?? "None")
                    diagnosticRow("selectedModel", activeCard?.modelName ?? settingsState.activeRealtimeProvider?.model ?? "None")
                    diagnosticRow("generationStatus", renderState.generationStatus)
                    diagnosticRow("queuedQuestionId", queuedQuestionID ?? "nil")
                    diagnosticRow("queuedReason", !hasQueuedQuestions ? "none" : "active_generation_in_progress")
                    diagnosticRow("lastLifecycleEvent", lastLifecycleEvent?.name ?? "None")
                    diagnosticRow("lastLifecycleTimestamp", lastLifecycleEvent.map { diagnosticTime($0.timestamp) } ?? "None")
                    diagnosticRow("lastGenerationSkipReason", emptyAware(diagnosticsState.runtime.lastGenerationRejectedReason, fallback: "None"))
                    diagnosticRow("lastGenerationError", renderState.generationErrorText ?? diagnosticsState.developer.lastError ?? "None")
                    diagnosticRow("systemAudioEnabled", settingsState.settings.audioCaptureMode == .microphoneOnly ? "false" : "true")
                    diagnosticRow("micEnabled", settingsState.settings.audioCaptureMode == .systemAudioOnly ? "false" : (micCaptureRunning ? "true" : "false"))
                    diagnosticRow("answerOwnerQuestionId", activeCard?.detectedQuestionID ?? activeCard?.questionID ?? renderState.activeQuestionID ?? "nil")
                    diagnosticRow("visibleAnswerNonEmpty", renderState.hasAnswerText ? "true" : "false")
                    diagnosticRow("fallbackType", activeCard?.finalVisibleSource ?? activeCard?.sayFirstSource ?? "none")
                    diagnosticRow("answerSource", answerSource)
                    diagnosticRow("alignmentScore", activeCard?.alignmentScore.map { String(format: "%.2f", $0) } ?? "nil")
                    diagnosticRow("alignmentDecision", activeCard?.alignmentVerdict?.rawValue ?? "nil")
                    diagnosticRow("isPlaceholder", isPlaceholderAnswer ? "true" : "false")
                    diagnosticRow("isProjectGroundedFallback", isProjectGroundedFallback ? "true" : "false")
                    diagnosticRow("isGenericTemplateRejected", isGenericTemplateRejected ? "true" : "false")
                    diagnosticRow("historyRowCount", "\(live.liveSuggestionHistory.count)")
                }

                diagnosticSection("Provider") {
                    diagnosticRow("selectedProvider", activeCard?.providerName ?? settingsState.activeRealtimeProvider?.name ?? diagnosticsState.developer.lastProviderName ?? "None")
                    diagnosticRow("selectedModel", activeCard?.modelName ?? settingsState.activeRealtimeProvider?.model ?? diagnosticsState.developer.lastProviderModel ?? "None")
                    diagnosticRow("selectedBaseURL", activeCard?.providerBaseURL ?? settingsState.activeRealtimeProvider?.baseURL ?? "None")
                    diagnosticRow("providerConfigured", diagnosticDisplay.providerConfigured)
                    diagnosticRow("deepSeekConfigured", diagnosticDisplay.deepSeekConfigured)
                    diagnosticRow("credentialSource", diagnosticDisplay.credentialSource)
                    diagnosticRow("keyExists", diagnosticDisplay.keyExists)
                    diagnosticRow("keyLengthCategory", diagnosticDisplay.keyLengthCategory)
                    diagnosticRow("keychainService", diagnosticDisplay.keychainService)
                    diagnosticRow("keychainAccount", diagnosticDisplay.keychainAccount)
                    diagnosticRow("bundleIdentifier", Bundle.main.bundleIdentifier ?? "nil")
                    diagnosticRow("generationConfigSource", diagnosticDisplay.generationConfigSource)
                    diagnosticRow("settingsConfigSource", diagnosticDisplay.settingsConfigSource)
                    diagnosticRow("lastProviderConfigError", diagnosticDisplay.lastProviderConfigError)
                    diagnosticRow("lastError", diagnosticsState.developer.lastError ?? "None")
                }

                diagnosticSection("Current Generation") {
                    diagnosticRow("state", diagnosticDisplay.generationStateTitle)
                    diagnosticRow("activeGenerationID", diagnosticDisplay.activeGenerationID)
                    diagnosticRow("activeQuestionID", diagnosticDisplay.activeQuestionID)
                    diagnosticRow("activeTriggerPath", diagnosticDisplay.activeTriggerPath)
                    diagnosticRow("activeElapsedMs", diagnosticDisplay.activeElapsedMs)
                    diagnosticRow("activeTaskSummary", diagnosticDisplay.activeTaskSummary)
                    diagnosticRow("previousGenerationID", diagnosticDisplay.previousGenerationID)
                    diagnosticRow("regenerate.questionId", diagnosticDisplay.regenerate_questionId)
                    diagnosticRow("regenerate.sourceTextKind", diagnosticDisplay.regenerate_sourceTextKind)
                    diagnosticRow("regenerate.oldGenerationId", diagnosticDisplay.regenerate_oldGenerationId)
                    diagnosticRow("regenerate.newGenerationId", diagnosticDisplay.regenerate_newGenerationId)
                    diagnosticRow("regenerate.rejectionReason", diagnosticDisplay.regenerate_rejectionReason)
                    diagnosticRow("visibleAnswerExists", live.visibleAnswerExists ? "true" : "false")
                    diagnosticRow("currentSpinnerVisible", diagnosticDisplay.currentSpinnerVisible)
                    diagnosticRow("fallbackWatchdogActive", diagnosticDisplay.fallbackWatchdogActive)
                    diagnosticRow("stageBTaskActive", diagnosticDisplay.stageBTaskActive)
                    diagnosticRow("providerStreamActive", providerStreamActive ? "true" : "false")
                    diagnosticRow("lastProviderError", diagnosticDisplay.lastProviderError)
                    diagnosticRow("generationError", renderState.generationErrorText ?? "nil")
                    diagnosticRow("lastJSONParseError", diagnosticDisplay.lastJSONParseError)
                    diagnosticRow("lastDBError", diagnosticDisplay.lastDBError)
                    diagnosticRow("cancelledGenerationCount", diagnosticDisplay.cancelledGenerationCount)
                    diagnosticRow("staleCallbackDiscardCount", diagnosticDisplay.staleCallbackDiscardCount)
                    diagnosticRow("duplicateSuppressionCount", diagnosticDisplay.duplicateSuppressionCount)
                    diagnosticRow("heartbeatDelayMs", diagnosticDisplay.heartbeatDelayMs)
                    diagnosticRow("lastSQLiteOperation", diagnosticDisplay.lastSQLiteOperation)
                    diagnosticRow("lastRAGOperation", diagnosticDisplay.lastRAGOperation)
                    diagnosticRow("lastProviderOperation", diagnosticDisplay.lastProviderOperation)
                }

                diagnosticSection("Latency") {
                    diagnosticRow("latencyMS", activeCard?.latencyMS.map { "\($0)" } ?? "nil")
                    diagnosticRow("ragRetrievalLatencyMS", diagnosticDisplay.ragRetrievalLatencyMS)
                    diagnosticRow("deepseekFirstVisibleMS", diagnosticDisplay.deepseekFirstVisibleMS)
                    diagnosticRow("softFallbackUsed", diagnosticDisplay.softFallbackUsed)
                }

                diagnosticSection("RAG") {
                    diagnosticRow("retrievalMode", diagnosticDisplay.retrievalMode)
                    diagnosticRow("latexPollutedChunkCount", diagnosticDisplay.latexPollutedChunkCount)
                    diagnosticRow("retrievedChunks", "\(live.currentSuggestionRetrievedChunks.count)")
                }

                diagnosticSection("Capture") {
                    diagnosticRow("captureMode", diagnosticDisplay.captureMode)
                    diagnosticRow("currentCaptureRuntimeState", diagnosticDisplay.currentCaptureRuntimeState)
                    diagnosticRow("systemCaptureRunning", systemCaptureRunning ? "true" : "false")
                    diagnosticRow("micCaptureRunning", micCaptureRunning ? "true" : "false")
                    diagnosticRow("stopReason", diagnosticDisplay.stopReason)
                }

                diagnosticSection("ASR") {
                    diagnosticRow("recognitionRequestActive", diagnosticDisplay.recognitionRequestActive)
                    diagnosticRow("recognitionTaskActive", diagnosticDisplay.recognitionTaskActive)
                    diagnosticRow("systemASRTaskActive", diagnosticDisplay.systemASRTaskActive)
                    diagnosticRow("micASRTaskActive", diagnosticDisplay.micASRTaskActive)
                }

                sourcesDisclosure(showScores: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func questionBlock(lineLimit: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Current question")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(currentQuestionText)
                .font(displayMode == .compact ? .callout.weight(.semibold) : .title3.weight(.semibold))
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(currentQuestionText == emptyQuestionText ? .secondary : .primary)
        }
    }

    private func sayFirstBlock(fontSize: CGFloat, lineLimit: Int?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Text("Say First")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                if shouldShowBlockingAnswerSpinner {
                    ProgressView()
                        .controlSize(.small)
                    Text("Generating first answer")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if shouldShowAnswerExpansionStatus {
                    Text("Expanding full answer...")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if let errorText = renderState.generationErrorText {
                Text(errorText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(answerText)
                .font(.system(size: fontSize, weight: .semibold))
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(answerText == emptyAnswerText ? .secondary : .primary)
        }
    }

    private func keyPointsBlock(limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Key Points")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            if keyPoints.isEmpty {
                Text("Key points will appear after the first answer.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(keyPoints.prefix(limit), id: \.self) { point in
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.green)
                            .padding(.top, 3)
                        Text(point)
                            .font(.system(size: 14))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var followUpDisclosure: some View {
        DisclosureGroup(isExpanded: $followUpExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach((activeCard?.followUpReady ?? []).prefix(4), id: \.self) { item in
                    Text(item)
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if activeCard?.followUpReady.isEmpty ?? true {
                    Text("Follow-up prompts will appear with the full answer.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
        } label: {
            Label("Follow-up Ready", systemImage: "arrowshape.turn.up.right")
                .font(.system(size: 12, weight: .semibold))
        }
    }

    private func sourcesDisclosure(showScores: Bool) -> some View {
        let included = live.currentSuggestionRetrievedChunks.filter { $0.isIncludedInPrompt }
        return DisclosureGroup(isExpanded: $sourcesExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                if included.isEmpty {
                    Text("No sources included yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(included) { chunk in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(chunk.documentType.shortTitle)
                                    .font(.system(size: 11, weight: .bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(sourceTint(for: chunk.documentType).opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                                    .foregroundStyle(sourceTint(for: chunk.documentType))
                                if let section = chunk.sectionTitle {
                                    Text(section)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if showScores {
                                    Text("rank \(chunk.rank), score \(String(format: "%.2f", chunk.score))")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(chunk.contentPreview + (chunk.fullContent.count > chunk.contentPreview.count ? "..." : ""))
                                .font(.system(size: 12))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(8)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            Label("Sources (\(included.count))", systemImage: "doc.text.magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
        }
    }

    private func diagnosticSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func diagnosticRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 180, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
        }
    }

    private var lastLifecycleEvent: TranscriptRuntimeEventRecord? {
        diagnosticsState.recentEvents.last
    }

    private var answerSource: String {
        if let source = activeCard?.finalVisibleSource ?? activeCard?.sayFirstSource {
            return source
        }
        if renderState.hasAnswerText {
            return "stream"
        }
        if renderState.generationErrorText != nil {
            return "error"
        }
        if hasQueuedQuestions {
            return "queued"
        }
        return providerStreamActive ? "provider_stream" : "none"
    }

    private var isPlaceholderAnswer: Bool {
        activeCard?.sayFirst.isEmpty == false &&
            QuestionAnswerAlignmentEvaluator.containsGenericCoachingTemplate(activeCard?.sayFirst ?? "")
    }

    private var isProjectGroundedFallback: Bool {
        guard let source = activeCard?.finalVisibleSource ?? activeCard?.sayFirstSource else { return false }
        return source.contains("fallback") &&
            activeCard?.isLocal == true &&
            !isPlaceholderAnswer &&
            activeCard?.alignmentVerdict == .aligned
    }

    private var isGenericTemplateRejected: Bool {
        currentSuspectedMismatchReason.localizedCaseInsensitiveContains("generic coaching") ||
            lastAlignmentError.localizedCaseInsensitiveContains("generic coaching") ||
            (activeCard?.mismatchReason?.localizedCaseInsensitiveContains("generic coaching") == true)
    }

    private func diagnosticTime(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func emptyAware(_ value: String, fallback: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : value
    }

    private var displayModeBinding: Binding<FloatingAssistantDisplayMode> {
        Binding(
            get: { displayMode },
            set: { mode in
                var next = settingsState.settings
                next.floatingAssistantDisplayMode = mode
                infoAction(ActionID.floatingDisplayMode, title: "Display mode changed", message: "\(mode.displayName) mode is active.")
                saveSettings(next)
            }
        )
    }

    private var currentQuestionText: String {
        if !renderState.questionText.isEmpty {
            return renderState.questionText
        }
        return emptyQuestionText
    }

    private var answerText: String {
        if renderState.hasAnswerText {
            return renderState.answerText
        }
        if shouldShowBlockingAnswerSpinner {
            return "Generating first answer..."
        }
        if renderState.generationErrorText != nil {
            return "No answer content was produced."
        }
        return emptyAnswerText
    }

    private var keyPoints: [String] {
        renderState.keyPoints
    }

    private var emptyQuestionText: String {
        "Start listening or capture a question."
    }

    private var emptyAnswerText: String {
        "No answer yet. Start listening or generate an answer from the current question."
    }

    private var statusTint: Color {
        switch productInterviewStatus {
        case .ready: return .green
        case .listening, .questionDetected, .generatingFirstAnswer, .expandingAnswer: return .blue
        case .needsAttention: return .orange
        case .stopped: return .secondary
        }
    }

    private func sourceTint(for type: DocumentType) -> Color {
        switch type {
        case .cv: return .blue
        case .jobDescription: return .purple
        case .additionalNotes: return .teal
        }
    }

    private func regenerate() {
        guard !regenerateDisabled else { return }
        beginAction(ActionID.floatingRegenerate, title: "Regenerating", message: "Keeping the current answer visible until a new answer is ready.")
        if manual.state == .suggestionReady {
            regenerateManualSuggestion()
            completeAction(ActionID.floatingRegenerate, title: "Regeneration started", message: "Manual capture answer is being refreshed.")
        } else {
            regenerateVisibleSuggestion()
            completeAction(ActionID.floatingRegenerate, title: "Regeneration started", message: "A new answer is being generated from the current question.")
        }
    }

    private func copyAnswer() {
        beginAction(ActionID.floatingCopy, title: "Copying answer", message: "Copying the visible answer to the clipboard...")
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(answerText, forType: .string) {
            completeAction(ActionID.floatingCopy, title: "Copied", message: "Answer copied to clipboard.")
        } else {
            failAction(ActionID.floatingCopy, title: "Copy failed", message: "The clipboard did not accept the answer text.")
        }
    }

    private var regenerateDisabled: Bool {
        (isActionLoading(ActionID.floatingRegenerate) || isActionLoading(ActionID.generateAnswer) || isActionLoading(ActionID.manualGenerate)) ||
        (!live.liveState.canAnswerNow && manual.state != .suggestionReady)
    }

    private var floatingFeedback: ActionFeedback? {
        latestActionFeedback(matching: [
            ActionID.floatingCopy,
            ActionID.floatingRegenerate,
            ActionID.floatingDisplayMode,
            ActionID.generateAnswer,
            ActionID.manualGenerate,
            ActionID.stopListening
        ])
    }
    private func isActionLoading(_ id: String) -> Bool { loadingStates[id] == true }
    private func latestActionFeedback(for id: String) -> ActionFeedback? {
        feedbacks.last { $0.actionID == id }
    }
    private func latestActionFeedback(matching ids: [String]) -> ActionFeedback? {
        feedbacks.last { ids.contains($0.actionID) }
    }
    private func beginAction(_ id: String, title: String, message: String) {
        beginFeedback(id, title, message)
    }
    private func completeAction(_ id: String, title: String, message: String) {
        completeFeedback(id, title, message)
    }
    private func infoAction(_ id: String, title: String, message: String, autoDismissAfter: TimeInterval? = 4) {
        infoFeedback(id, title, message, autoDismissAfter)
    }
    private func failAction(_ id: String, title: String, message: String) {
        failFeedback(id, title, message)
    }

}
