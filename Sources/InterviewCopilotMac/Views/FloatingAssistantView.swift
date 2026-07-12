import AppKit
import SwiftUI

struct FloatingAssistantView: View {
    @ObservedObject var appState: AppState
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
        return appState.settings.floatingAssistantDisplayMode
    }

    private var activeCard: SuggestionCard? {
        appState.manualCaptureSuggestion ?? appState.currentSuggestion
    }

    private var renderState: VisibleAssistantRenderState {
        appState.visibleAssistantRenderState
    }

    private var effectiveOpacity: Double {
        max(appState.settings.highContrastFloatingPanel ? 0.72 : 0.62, appState.settings.floatingWindowOpacity)
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
            Label(appState.productInterviewStatus.title, systemImage: appState.productInterviewStatus.systemImage)
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
                if appState.isActionLoading(ActionID.floatingRegenerate) || appState.isActionLoading(ActionID.generateAnswer) || appState.isActionLoading(ActionID.manualGenerate) {
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
                Image(systemName: appState.latestActionFeedback(for: ActionID.floatingCopy)?.kind == .success ? "checkmark.circle.fill" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy Answer")
            .disabled(activeCard?.sayFirst.isEmpty != false && appState.streamedSayFirst.isEmpty)

            Button {
                appState.stopListening()
            } label: {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.borderless)
            .help("Stop Listening")
            .disabled(!appState.canStopCapture)

            Button {
                appState.openMainWindow()
            } label: {
                Image(systemName: "macwindow")
            }
            .buttonStyle(.borderless)
            .help("Open Main Window")
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            StatusPill(title: appState.systemCaptureRunning ? "System Active" : "System Off", systemImage: "speaker.wave.2.fill", tint: appState.systemCaptureRunning ? .green : .secondary, isCompact: true)
            StatusPill(title: appState.micCaptureRunning ? "Mic Active" : "Mic Off", systemImage: "mic.fill", tint: appState.micCaptureRunning ? .green : .secondary, isCompact: true)
            StatusPill(title: appState.deepSeekConfigured ? "DeepSeek" : "AI Missing", systemImage: appState.deepSeekConfigured ? "sparkles" : "key", tint: appState.deepSeekConfigured ? .blue : .orange, isCompact: true)
            StatusPill(title: appState.userFacingRelevantContextStatus, systemImage: "doc.text.magnifyingglass", tint: appState.hasCleanRelevantContext ? .green : .orange, isCompact: true)
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
                    diagnosticRow("currentQuestionId", renderState.activeQuestionID ?? appState.lastDetectedQuestion?.id ?? "nil")
                    diagnosticRow("currentSessionId", appState.currentSession?.id ?? emptyAware(appState.transcriptRuntimeDiagnostics.audioSessionID, fallback: "nil"))
                    diagnosticRow("activeGenerationId", renderState.activeGenerationID ?? "nil")
                    diagnosticRow("selectedProvider", activeCard?.providerName ?? appState.activeRealtimeProvider?.name ?? "None")
                    diagnosticRow("selectedModel", activeCard?.modelName ?? appState.activeRealtimeProvider?.model ?? "None")
                    diagnosticRow("generationStatus", renderState.generationStatus)
                    diagnosticRow("queuedQuestionId", appState.pendingAcceptedQuestions.first?.question.id ?? "nil")
                    diagnosticRow("queuedReason", appState.pendingAcceptedQuestions.isEmpty ? "none" : "active_generation_in_progress")
                    diagnosticRow("lastLifecycleEvent", lastLifecycleEvent?.name ?? "None")
                    diagnosticRow("lastLifecycleTimestamp", lastLifecycleEvent.map { diagnosticTime($0.timestamp) } ?? "None")
                    diagnosticRow("lastGenerationSkipReason", emptyAware(appState.transcriptRuntimeDiagnostics.lastGenerationRejectedReason, fallback: "None"))
                    diagnosticRow("lastGenerationError", renderState.generationErrorText ?? appState.diagnostics.lastError ?? "None")
                    diagnosticRow("systemAudioEnabled", appState.settings.audioCaptureMode == .microphoneOnly ? "false" : "true")
                    diagnosticRow("micEnabled", appState.settings.audioCaptureMode == .systemAudioOnly ? "false" : (appState.micCaptureRunning ? "true" : "false"))
                    diagnosticRow("answerOwnerQuestionId", activeCard?.detectedQuestionID ?? activeCard?.questionID ?? renderState.activeQuestionID ?? "nil")
                    diagnosticRow("visibleAnswerNonEmpty", renderState.hasAnswerText ? "true" : "false")
                    diagnosticRow("fallbackType", activeCard?.finalVisibleSource ?? activeCard?.sayFirstSource ?? "none")
                    diagnosticRow("answerSource", answerSource)
                    diagnosticRow("alignmentScore", activeCard?.alignmentScore.map { String(format: "%.2f", $0) } ?? "nil")
                    diagnosticRow("alignmentDecision", activeCard?.alignmentVerdict?.rawValue ?? "nil")
                    diagnosticRow("isPlaceholder", isPlaceholderAnswer ? "true" : "false")
                    diagnosticRow("isProjectGroundedFallback", isProjectGroundedFallback ? "true" : "false")
                    diagnosticRow("isGenericTemplateRejected", isGenericTemplateRejected ? "true" : "false")
                    diagnosticRow("historyRowCount", "\(appState.liveSuggestionHistory.count)")
                }

                diagnosticSection("Provider") {
                    diagnosticRow("selectedProvider", activeCard?.providerName ?? appState.activeRealtimeProvider?.name ?? appState.diagnostics.lastProviderName ?? "None")
                    diagnosticRow("selectedModel", activeCard?.modelName ?? appState.activeRealtimeProvider?.model ?? appState.diagnostics.lastProviderModel ?? "None")
                    diagnosticRow("selectedBaseURL", activeCard?.providerBaseURL ?? appState.activeRealtimeProvider?.baseURL ?? "None")
                    diagnosticRow("providerConfigured", appState.deepSeekProviderConfigured ? "true" : "false")
                    diagnosticRow("deepSeekConfigured", appState.deepSeekConfigured ? "true" : "false")
                    diagnosticRow("credentialSource", appState.deepSeekCredentialSource)
                    diagnosticRow("keyExists", appState.keychainDeepSeekKeyExists ? "true" : "false")
                    diagnosticRow("keyLengthCategory", appState.keychainDeepSeekKeyLengthCategory)
                    diagnosticRow("keychainService", appState.keychainServiceName)
                    diagnosticRow("keychainAccount", appState.keychainDeepSeekAccount)
                    diagnosticRow("bundleIdentifier", Bundle.main.bundleIdentifier ?? "nil")
                    diagnosticRow("generationConfigSource", appState.generationConfigSource)
                    diagnosticRow("settingsConfigSource", appState.settingsConfigSource)
                    diagnosticRow("lastProviderConfigError", appState.lastProviderConfigError)
                    diagnosticRow("lastError", appState.diagnostics.lastError ?? "None")
                }

                diagnosticSection("Current Generation") {
                    diagnosticRow("state", appState.generationUIState.displayName)
                    diagnosticRow("activeGenerationID", appState.activeGenerationID ?? "nil")
                    diagnosticRow("activeQuestionID", appState.activeQuestionID ?? "nil")
                    diagnosticRow("activeTriggerPath", appState.activeTriggerPath?.rawValue ?? "nil")
                    diagnosticRow("activeElapsedMs", appState.activeGenerationElapsedMs.map { "\($0)" } ?? "nil")
                    diagnosticRow("activeTaskSummary", appState.activeTaskSummary)
                    diagnosticRow("previousGenerationID", appState.previousGenerationID ?? "nil")
                    diagnosticRow("regenerate.questionId", appState.lastRegenerateQuestionID ?? "nil")
                    diagnosticRow("regenerate.sourceTextKind", appState.lastRegenerateSourceTextKind.isEmpty ? "nil" : appState.lastRegenerateSourceTextKind)
                    diagnosticRow("regenerate.oldGenerationId", appState.lastRegenerateOldGenerationID ?? "nil")
                    diagnosticRow("regenerate.newGenerationId", appState.lastRegenerateNewGenerationID ?? "nil")
                    diagnosticRow("regenerate.rejectionReason", appState.lastRegenerateRejectionReason.isEmpty ? "nil" : appState.lastRegenerateRejectionReason)
                    diagnosticRow("visibleAnswerExists", appState.visibleAnswerExists ? "true" : "false")
                    diagnosticRow("currentSpinnerVisible", appState.currentSpinnerVisible ? "true" : "false")
                    diagnosticRow("fallbackWatchdogActive", appState.fallbackWatchdogActive ? "true" : "false")
                    diagnosticRow("stageBTaskActive", appState.stageBTaskActive ? "true" : "false")
                    diagnosticRow("providerStreamActive", appState.providerStreamActive ? "true" : "false")
                    diagnosticRow("lastProviderError", appState.currentGenerationTelemetry.providerError ?? "nil")
                    diagnosticRow("generationError", renderState.generationErrorText ?? "nil")
                    diagnosticRow("lastJSONParseError", appState.currentGenerationTelemetry.jsonParseError ?? "nil")
                    diagnosticRow("lastDBError", appState.currentGenerationTelemetry.dbError ?? "nil")
                    diagnosticRow("cancelledGenerationCount", "\(appState.cancelledGenerationCount)")
                    diagnosticRow("staleCallbackDiscardCount", "\(appState.staleCallbackDiscardCount)")
                    diagnosticRow("duplicateSuppressionCount", "\(appState.duplicateSuppressionCount)")
                    diagnosticRow("heartbeatDelayMs", "\(appState.mainThreadHeartbeatDelayMs)")
                    diagnosticRow("lastSQLiteOperation", appState.lastSQLiteOperation)
                    diagnosticRow("lastRAGOperation", appState.lastRAGOperation)
                    diagnosticRow("lastProviderOperation", appState.lastProviderOperation)
                }

                diagnosticSection("Latency") {
                    diagnosticRow("latencyMS", activeCard?.latencyMS.map { "\($0)" } ?? "nil")
                    diagnosticRow("ragRetrievalLatencyMS", appState.ragRetrievalLatencyMS.map { "\($0)" } ?? "nil")
                    diagnosticRow("deepseekFirstVisibleMS", appState.deepseekFirstVisibleMS.map { "\($0)" } ?? "nil")
                    diagnosticRow("softFallbackUsed", appState.softFallbackUsed ? "true" : "false")
                }

                diagnosticSection("RAG") {
                    diagnosticRow("retrievalMode", appState.manualVerificationRAGMode)
                    diagnosticRow("latexPollutedChunkCount", "\(appState.latexPollutedChunkCount)")
                    diagnosticRow("retrievedChunks", "\(appState.currentSuggestionRetrievedChunks.count)")
                }

                diagnosticSection("Capture") {
                    diagnosticRow("captureMode", appState.captureMode.rawValue)
                    diagnosticRow("currentCaptureRuntimeState", appState.currentCaptureRuntimeState.displayName)
                    diagnosticRow("systemCaptureRunning", appState.systemCaptureRunning ? "true" : "false")
                    diagnosticRow("micCaptureRunning", appState.micCaptureRunning ? "true" : "false")
                    diagnosticRow("stopReason", appState.stopReason?.rawValue ?? "None")
                }

                diagnosticSection("ASR") {
                    diagnosticRow("recognitionRequestActive", appState.recognitionRequestActive ? "true" : "false")
                    diagnosticRow("recognitionTaskActive", appState.recognitionTaskActive ? "true" : "false")
                    diagnosticRow("systemASRTaskActive", appState.systemASRTaskActive ? "true" : "false")
                    diagnosticRow("micASRTaskActive", appState.micASRTaskActive ? "true" : "false")
                }

                sourcesDisclosure(showScores: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
                if appState.shouldShowBlockingAnswerSpinner {
                    ProgressView()
                        .controlSize(.small)
                    Text("Generating first answer")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if appState.shouldShowAnswerExpansionStatus {
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
        let included = appState.currentSuggestionRetrievedChunks.filter { $0.isIncludedInPrompt }
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
        appState.recentTranscriptRuntimeEvents.last
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
        if !appState.pendingAcceptedQuestions.isEmpty {
            return "queued"
        }
        return appState.providerStreamActive ? "provider_stream" : "none"
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
        appState.currentSuspectedMismatchReason.localizedCaseInsensitiveContains("generic coaching") ||
            appState.lastAlignmentError.localizedCaseInsensitiveContains("generic coaching") ||
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
                var next = appState.settings
                next.floatingAssistantDisplayMode = mode
                appState.infoAction(ActionID.floatingDisplayMode, title: "Display mode changed", message: "\(mode.displayName) mode is active.")
                appState.saveSettings(next)
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
        if appState.shouldShowBlockingAnswerSpinner {
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
        switch appState.productInterviewStatus {
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
        appState.beginAction(ActionID.floatingRegenerate, title: "Regenerating", message: "Keeping the current answer visible until a new answer is ready.")
        if appState.manualCaptureState == .suggestionReady {
            appState.regenerateManualSuggestion()
            appState.completeAction(ActionID.floatingRegenerate, title: "Regeneration started", message: "Manual capture answer is being refreshed.")
        } else {
            appState.regenerateVisibleSuggestion()
            appState.completeAction(ActionID.floatingRegenerate, title: "Regeneration started", message: "A new answer is being generated from the current question.")
        }
    }

    private func copyAnswer() {
        appState.beginAction(ActionID.floatingCopy, title: "Copying answer", message: "Copying the visible answer to the clipboard...")
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(answerText, forType: .string) {
            appState.completeAction(ActionID.floatingCopy, title: "Copied", message: "Answer copied to clipboard.")
        } else {
            appState.failAction(ActionID.floatingCopy, title: "Copy failed", message: "The clipboard did not accept the answer text.")
        }
    }

    private var regenerateDisabled: Bool {
        (appState.isActionLoading(ActionID.floatingRegenerate) || appState.isActionLoading(ActionID.generateAnswer) || appState.isActionLoading(ActionID.manualGenerate)) ||
        (!appState.liveState.canAnswerNow && appState.manualCaptureState != .suggestionReady)
    }

    private var floatingFeedback: ActionFeedback? {
        appState.latestActionFeedback(matching: [
            ActionID.floatingCopy,
            ActionID.floatingRegenerate,
            ActionID.floatingDisplayMode,
            ActionID.generateAnswer,
            ActionID.manualGenerate,
            ActionID.stopListening
        ])
    }
}
