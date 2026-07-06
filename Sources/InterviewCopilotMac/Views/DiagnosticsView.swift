import AppKit
import SwiftUI

struct DiagnosticsView: View {
    @ObservedObject var appState: AppState
    @StateObject private var localModels = LocalModelsSetupViewModel()

    var body: some View {
        TabView {
            diagnosticsPage(title: "Build") {
                BuildIdentityCardView(identity: appState.buildIdentity)
            }
            .tabItem { Label("Build", systemImage: "shippingbox") }

            diagnosticsPage(title: "Provider") {
                providerTab
            }
            .tabItem { Label("Provider", systemImage: "server.rack") }

            diagnosticsPage(title: "Local Models") {
                localModelsTab
            }
            .tabItem { Label("Local", systemImage: "square.stack.3d.up") }

            diagnosticsPage(title: "Current Generation") {
                currentGenerationTab
            }
            .tabItem { Label("Generation", systemImage: "sparkles") }

            ScrollView {
                RAGDiagnosticsView(appState: appState)
                    .padding(28)
                    .frame(maxWidth: 960, alignment: .leading)
            }
            .tabItem { Label("RAG", systemImage: "doc.text.magnifyingglass") }

            diagnosticsPage(title: "Audio") {
                audioTab
            }
            .tabItem { Label("Audio", systemImage: "waveform") }

            diagnosticsPage(title: "Capture Events") {
                captureEventsTab
            }
            .tabItem { Label("Capture Events", systemImage: "list.bullet.rectangle") }

            diagnosticsPage(title: "Latency") {
                latencyTab
            }
            .tabItem { Label("Latency", systemImage: "timer") }

            diagnosticsPage(title: "Keychain") {
                keychainTab
            }
            .tabItem { Label("Keychain", systemImage: "key.fill") }
        }
        .navigationTitle("Diagnostics")
        .task {
            await localModels.refresh(qwenModel: appState.selectedQwenModelName)
        }
    }

    private func diagnosticsPage<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(title)
                    .font(.largeTitle.weight(.bold))
                content()
            }
            .padding(28)
            .frame(maxWidth: 960, alignment: .leading)
        }
    }

    private var providerTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            card("Active Provider", icon: "brain") {
                diagnosticRow("Realtime", appState.activeRealtimeProviderBadge)
                diagnosticRow("Recap", appState.activeRecapProvider.map { "\($0.name): \($0.model)" } ?? "None")
                diagnosticRow("Last provider", appState.diagnostics.lastProviderName ?? "None")
                diagnosticRow("Last model", appState.diagnostics.lastProviderModel ?? "None")
                diagnosticRow("Last error", appState.diagnostics.lastError ?? "None")
                ActionButton(
                    appState: appState,
                    actionID: ActionID.testDeepSeek,
                    title: "Test DeepSeek",
                    loadingTitle: "Testing...",
                    successTitle: "Connected",
                    systemImage: "network",
                    isProminent: true,
                    disabled: appState.isTestingConnection
                ) {
                    appState.testDeepSeekConnection()
                }
                InlineStatusBanner(appState.latestActionFeedback(for: ActionID.testDeepSeek))
                if let result = appState.connectionResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            card("AI Router Diagnostics", icon: "point.3.connected.trianglepath.dotted") {
                diagnosticRow("Last switched at", appState.lastProviderSwitchTimestamp.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .medium) } ?? "Never")
                diagnosticRow("Last switch error", appState.lastProviderSwitchError ?? "None")
                diagnosticRow("Question detection provider", appState.lastQuestionDetectionProvider ?? "None")
                diagnosticRow("Question detection model", appState.lastQuestionDetectionModel ?? "None")
                diagnosticRow("Suggestion provider", appState.lastSuggestionGenerationProvider ?? "None")
                diagnosticRow("Suggestion model", appState.lastSuggestionGenerationModel ?? "None")
            }
        }
    }

    private var localModelsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            card("Local Model Readiness", icon: "square.stack.3d.up") {
                diagnosticRow("Local setup page", "Setup & Local Models")
                diagnosticRow("selectedQwenModel", appState.selectedQwenModelName)
                diagnosticRow("ollamaRunning", localModels.qwenHealth.ollamaRunning ? "true" : "false")
                diagnosticRow("qwenModelInstalled", localModels.qwenHealth.modelInstalled ? "true" : "false")
                diagnosticRow("localQwenReady", localModels.qwenHealth.isReady ? "true" : "false")
                diagnosticRow("selectedAnswerProvider", appState.selectedAnswerProviderMode.rawValue)
                diagnosticRow("defaultAnswerProvider", AnswerProviderMode.localQwenPrimary.rawValue)
                diagnosticRow("lastOllamaError", localModels.qwenHealth.lastError ?? "None")
                diagnosticRow("selectedASRProvider", appState.selectedASRProviderID.rawValue)
                diagnosticRow("activeASRProvider", appState.activeASRProviderID?.rawValue ?? "None")
                diagnosticRow("defaultASRSelection", ASRProviderID.localParakeet.rawValue)
                diagnosticRow("asrModelStatus", localModels.transcriptionStatus.displayName)
                diagnosticRow("recommendedLocalASR", LocalModelDescriptor.defaultParakeetASR.displayName)
                diagnosticRow("parakeetModelPath", localModels.modelPath(for: .defaultParakeetASR).path)
                diagnosticRow("parakeetRuntimeStatus", localModels.parakeetRuntimeStatusText)
                diagnosticRow("latestTranscriptASRSource", appState.latestTranscriptASRSource)
                diagnosticRow("Answer source", AnswerSource.ollamaQwen.rawValue)
                diagnosticRow("ASR sources", ASRSource.allCases.map(\.rawValue).joined(separator: ", "))
                diagnosticRow("DeepSeek source remains", AnswerSource.deepseekStream.rawValue)
                diagnosticRow("Apple Speech fallback", "explicit selection only")
                Button {
                    appState.selectSection(.localModels)
                } label: {
                    Label("Open Setup & Local Models", systemImage: "arrow.right.circle")
                }
                .buttonStyle(.borderedProminent)
            }

            card("Source Metadata Rules", icon: "tag") {
                diagnosticRow("Provider success", AnswerSource.deepseekStream.rawValue)
                diagnosticRow("Local Qwen", AnswerSource.ollamaQwen.rawValue)
                diagnosticRow("Soft fallback", AnswerSource.ragTemplateSoftFallback.rawValue)
                diagnosticRow("Timeout fallback", AnswerSource.localTimeoutFallback.rawValue)
                diagnosticRow("Provider error", AnswerSource.providerError.rawValue)
            }
        }
    }

    private var currentGenerationTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            card("Current Generation", icon: "sparkles") {
                diagnosticRow("generationState", appState.generationUIState.displayName)
                diagnosticRow("activeGenerationID", appState.activeGenerationID ?? "None")
                diagnosticRow("activeQuestionID", appState.activeQuestionID ?? "None")
                diagnosticRow("activeTriggerPath", appState.activeTriggerPath?.rawValue ?? "None")
                diagnosticRow("activeGenerationStartedAt", diagnosticTime(appState.activeGenerationStartedAt))
                diagnosticRow("activeGenerationElapsedMs", appState.activeGenerationElapsedMs.map { "\($0)" } ?? "None")
                diagnosticRow("lastGenerationStateChangeAt", diagnosticTime(appState.lastGenerationStateChangeAt))
                diagnosticRow("activeTaskSummary", appState.activeTaskSummary)
                diagnosticRow("previousGenerationID", appState.previousGenerationID ?? "None")
                diagnosticRow("questionID", appState.currentGenerationTelemetry.questionID ?? "None")
                diagnosticRow("generationID", appState.currentGenerationTelemetry.generationID ?? "None")
                diagnosticRow("triggerPath", appState.currentGenerationTelemetry.triggerPath?.rawValue ?? "None")
                diagnosticRow("elapsedMs", appState.currentGenerationTelemetry.elapsedMs.map { "\($0)" } ?? "None")
                diagnosticRow("visibleAnswerExists", appState.visibleAnswerExists ? "true" : "false")
                diagnosticRow("currentSpinnerVisible", appState.currentSpinnerVisible ? "true" : "false")
                diagnosticRow("currentSuggestionExists", appState.currentSuggestion == nil ? "false" : "true")
                diagnosticRow("fallbackWatchdogActive", appState.fallbackWatchdogActive ? "true" : "false")
                diagnosticRow("stageBTaskActive", appState.stageBTaskActive ? "true" : "false")
                diagnosticRow("providerStreamActive", appState.providerStreamActive ? "true" : "false")
                diagnosticRow("lastProviderError", appState.currentGenerationTelemetry.providerError ?? "None")
                diagnosticRow("lastJSONParseError", appState.currentGenerationTelemetry.jsonParseError ?? "None")
                diagnosticRow("lastDBError", appState.currentGenerationTelemetry.dbError ?? "None")
                diagnosticRow("wasStaleDiscarded", appState.currentGenerationTelemetry.wasStaleDiscarded ? "true" : "false")
                diagnosticRow("cancelledGenerationCount", "\(appState.cancelledGenerationCount)")
                diagnosticRow("staleCallbackDiscardCount", "\(appState.staleCallbackDiscardCount)")
                diagnosticRow("staleDiscardCount", "\(appState.currentGenerationTelemetry.staleDiscardCount)")
                diagnosticRow("duplicateSuppressionCount", "\(appState.duplicateSuppressionCount)")
            }

            card("Question Detection", icon: "questionmark.bubble") {
                diagnosticRow("lastDetectedQuestionText", appState.lastDetectedQuestionText.isEmpty ? "None" : appState.lastDetectedQuestionText)
                diagnosticRow("lastDetectedQuestionSource", appState.lastDetectedQuestionSource.isEmpty ? "None" : appState.lastDetectedQuestionSource)
                diagnosticRow("lastDetectedQuestionSpeaker", appState.lastDetectedQuestionSpeaker.isEmpty ? "None" : appState.lastDetectedQuestionSpeaker)
                diagnosticRow("lastQuestionConfidence", String(format: "%.2f", appState.lastQuestionConfidence))
                diagnosticRow("lastQuestionIntent", appState.lastDetectionReason.isEmpty ? "None" : appState.lastDetectionReason)
                diagnosticRow("duplicateSuppressionCount", "\(appState.duplicateSuppressionCount)")
                diagnosticRow("ignoredCandidateQuestionCount", "\(appState.ignoredCandidateQuestionCount)")
                diagnosticRow("ignoredSystemAudioAnswerLikeCount", "\(appState.ignoredSystemAudioAnswerLikeCount)")
                diagnosticRow("lastIgnoredSystemAudioReason", appState.lastIgnoredSystemAudioReason.isEmpty ? "None" : appState.lastIgnoredSystemAudioReason)
                diagnosticRow("ignoredSmallTalkCount", "\(appState.ignoredSmallTalkCount)")
                diagnosticRow("detectedQuestionsInSessionCount", "\(appState.detectedQuestionsInSessionCount)")
                diagnosticRow("currentGenerationState", appState.generationUIState.displayName)
            }

            card("Last Transcript -> Question -> Generation Trace", icon: "point.3.connected.trianglepath.dotted") {
                let trace = appState.lastTranscriptQuestionGenerationTrace
                diagnosticRow("transcriptSegmentID", trace.transcriptSegmentID.isEmpty ? "None" : trace.transcriptSegmentID)
                diagnosticRow("source", trace.source.isEmpty ? "None" : trace.source)
                diagnosticRow("asrSource", trace.asrSource.isEmpty ? "None" : trace.asrSource)
                diagnosticRow("speaker", trace.speaker.isEmpty ? "None" : trace.speaker)
                diagnosticRow("isFinal", trace.isFinal ? "true" : "false")
                diagnosticRow("textLength", "\(trace.textLength)")
                diagnosticRow("normalizedText", trace.normalizedText.isEmpty ? "None" : trace.normalizedText)
                diagnosticRow("extractedQuestionCount", "\(trace.extractedQuestionCount)")
                diagnosticRow("extractedQuestionsPreview", trace.extractedQuestionsPreview.isEmpty ? "None" : trace.extractedQuestionsPreview.joined(separator: " | "))
                diagnosticRow("questionCandidate", trace.questionCandidate ? "true" : "false")
                diagnosticRow("questionConfidence", String(format: "%.2f", trace.questionConfidence))
                diagnosticRow("questionIntent", trace.questionIntent.isEmpty ? "None" : trace.questionIntent)
                diagnosticRow("ignoredReason", trace.ignoredReason.isEmpty ? "None" : trace.ignoredReason)
                diagnosticRow("duplicateSuppressed", trace.duplicateSuppressed ? "true" : "false")
                diagnosticRow("detectedQuestionID", trace.detectedQuestionID ?? "None")
                diagnosticRow("generationTriggered", trace.generationTriggered ? "true" : "false")
                diagnosticRow("generationID", trace.generationID ?? "None")
                diagnosticRow("generationBlockedReason", trace.generationBlockedReason.isEmpty ? "None" : trace.generationBlockedReason)
                diagnosticRow("firstQuestionSuppressedReason", trace.firstQuestionSuppressedReason.isEmpty ? "None" : trace.firstQuestionSuppressedReason)
                diagnosticRow("providerStatus", trace.providerStatus.isEmpty ? "None" : trace.providerStatus)
                diagnosticRow("visibleSuggestionCreated", trace.visibleSuggestionCreated ? "true" : "false")
                diagnosticRow("currentGenerationState", trace.currentGenerationState.isEmpty ? "None" : trace.currentGenerationState)
                diagnosticRow("currentSuggestionExists", trace.currentSuggestionExists ? "true" : "false")
                if !trace.text.isEmpty {
                    Text(trace.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            card("Current QA Binding", icon: "link") {
                let binding = appState.currentQABinding
                diagnosticRow("currentQuestionID", binding.currentQuestionID ?? "None")
                diagnosticRow("currentQuestionText", binding.currentQuestionText.isEmpty ? "None" : binding.currentQuestionText)
                diagnosticRow("currentSuggestionID", binding.currentSuggestionID ?? "None")
                diagnosticRow("currentSuggestionDetectedQuestionID", binding.currentSuggestionDetectedQuestionID ?? "None")
                diagnosticRow("currentSuggestionQuestionText", binding.currentSuggestionQuestionText.isEmpty ? "None" : binding.currentSuggestionQuestionText)
                diagnosticRow("activeGenerationID", binding.activeGenerationID ?? "None")
                diagnosticRow("activeGenerationQuestionID", binding.activeGenerationQuestionID ?? "None")
                diagnosticRow("bindingStatus", binding.bindingStatus.rawValue)
                diagnosticRow("lastAlignmentError", binding.lastAlignmentError.isEmpty ? "None" : binding.lastAlignmentError)
                diagnosticRow("detectedQuestionID", appState.lastDetectedQuestion?.id ?? "None")
                diagnosticRow("generationID", appState.activeGenerationID ?? "None")
                diagnosticRow("questionTextSnapshot", appState.currentPromptPrimaryQuestion.isEmpty ? "None" : appState.currentPromptPrimaryQuestion)
                diagnosticRow("questionIntent", appState.currentAnswerQuestionIntent?.rawValue ?? "None")
                diagnosticRow("promptQuestionText", appState.currentPromptQuestionText.isEmpty ? "None" : appState.currentPromptQuestionText)
                diagnosticRow("promptPrimaryQuestion", appState.currentPromptPrimaryQuestion.isEmpty ? "None" : appState.currentPromptPrimaryQuestion)
                diagnosticRow("promptContainsPreviousQuestion", appState.currentPromptContainsPreviousQuestion ? "true" : "false")
                diagnosticRow("previousQuestionIncluded", appState.currentPreviousQuestionIncluded ? "true" : "false")
                diagnosticRow("previousQuestionText", appState.currentPreviousQuestionText.isEmpty ? "None" : appState.currentPreviousQuestionText)
                diagnosticRow("contextBleedRisk", appState.currentContextBleedRisk.rawValue)
                diagnosticRow("ragChunkIDs", appState.currentRAGChunkIDs.isEmpty ? "None" : appState.currentRAGChunkIDs.joined(separator: ", "))
                diagnosticRow("ragChunkIntents", appState.currentRAGChunkIntents.isEmpty ? "None" : appState.currentRAGChunkIntents.map(\.rawValue).joined(separator: ", "))
                diagnosticRow("generationBlockedReason", appState.lastTranscriptQuestionGenerationTrace.generationBlockedReason.isEmpty ? "None" : appState.lastTranscriptQuestionGenerationTrace.generationBlockedReason)
                diagnosticRow("firstQuestionSuppressedReason", appState.currentFirstQuestionSuppressedReason.isEmpty ? "None" : appState.currentFirstQuestionSuppressedReason)
                diagnosticRow("answerAlignmentVerdict", appState.currentSuggestion?.alignmentVerdict?.rawValue ?? "None")
                diagnosticRow("mismatchReason", appState.currentSuggestion?.mismatchReason ?? "None")
                diagnosticRow("promptTokenEstimate", appState.currentPromptTokenEstimate.map(String.init) ?? "None")
                diagnosticRow("answerIntent", appState.currentAnswerIntent?.rawValue ?? "None")
                diagnosticRow("expectedThemesMatched", appState.currentExpectedThemesMatched.isEmpty ? "None" : appState.currentExpectedThemesMatched.joined(separator: ", "))
                diagnosticRow("suspectedMismatchReason", appState.currentSuspectedMismatchReason.isEmpty ? "None" : appState.currentSuspectedMismatchReason)
                diagnosticRow("promptContextPreviews", appState.currentPromptContextPreviews.isEmpty ? "None" : appState.currentPromptContextPreviews.joined(separator: " | "))
                diagnosticRow("staleAnswerDiscardCount", "\(appState.staleAnswerDiscardCount)")
                diagnosticRow("answerQuestionMismatchCount", "\(appState.answerQuestionMismatchCount)")
                if appState.recentSuggestionAlignments.isEmpty {
                    diagnosticRow("recentSuggestions", "None")
                } else {
                    ForEach(appState.recentSuggestionAlignments) { record in
                        VStack(alignment: .leading, spacing: 4) {
                            diagnosticRow("detectedQuestionID", record.detectedQuestionID ?? "None")
                            diagnosticRow("questionText", record.questionText)
                            diagnosticRow("sayFirstPreview", record.sayFirstPreview)
                            diagnosticRow("alignmentScore", String(format: "%.2f", record.alignmentScore))
                            diagnosticRow("alignmentVerdict", record.alignmentVerdict.rawValue)
                            diagnosticRow("answerIntent", record.answerIntent.rawValue)
                            diagnosticRow("expectedThemesMatched", record.expectedThemesMatched.isEmpty ? "None" : record.expectedThemesMatched.joined(separator: ", "))
                            diagnosticRow("suspectedMismatchReason", record.suspectedMismatchReason.isEmpty ? "None" : record.suspectedMismatchReason)
                        }
                        Divider()
                    }
                }
            }

            card("Main Thread / Long Operations", icon: "cpu") {
                diagnosticRow("mainThreadHeartbeatAt", diagnosticTime(appState.mainThreadHeartbeatAt))
                diagnosticRow("mainThreadHeartbeatDelayMs", "\(appState.mainThreadHeartbeatDelayMs)")
                diagnosticRow("lastTranscriptIngestionMs", "\(appState.lastTranscriptIngestionMs)")
                diagnosticRow("lastQuestionClassificationMs", "\(appState.lastQuestionClassificationMs)")
                diagnosticRow("lastLongOperationName", appState.lastLongOperationName)
                diagnosticRow("lastLongOperationStartedAt", diagnosticTime(appState.lastLongOperationStartedAt))
                diagnosticRow("lastSQLiteOperation", appState.lastSQLiteOperation)
                diagnosticRow("lastRAGOperation", appState.lastRAGOperation)
                diagnosticRow("lastProviderOperation", appState.lastProviderOperation)
            }

            card("Generation Timestamps", icon: "timer") {
                diagnosticRow("startedAt", diagnosticTime(appState.currentGenerationTelemetry.startedAt))
                diagnosticRow("firstVisibleAt", diagnosticTime(appState.currentGenerationTelemetry.firstVisibleAt))
                diagnosticRow("fallbackShownAt", diagnosticTime(appState.currentGenerationTelemetry.fallbackShownAt))
                diagnosticRow("firstDeepSeekTokenAt", diagnosticTime(appState.currentGenerationTelemetry.firstDeepSeekTokenAt))
                diagnosticRow("firstKeyPointAt", diagnosticTime(appState.currentGenerationTelemetry.firstKeyPointAt))
                diagnosticRow("fullCardAt", diagnosticTime(appState.currentGenerationTelemetry.fullCardAt))
                diagnosticRow("dbPersistedAt", diagnosticTime(appState.currentGenerationTelemetry.dbPersistedAt))
                diagnosticRow("failureReason", appState.currentGenerationTelemetry.failureReason ?? "None")
            }
        }
    }

    private var audioTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            card("Capture State", icon: "waveform.path.ecg") {
                diagnosticRow("captureMode", appState.captureMode.rawValue)
                diagnosticRow("currentCaptureRuntimeState", appState.currentCaptureRuntimeState.displayName)
                diagnosticRow("liveState", appState.liveState.displayName)
                diagnosticRow("stopReason", appState.stopReason?.rawValue ?? "None")
                diagnosticRow("streamNotRunningReason", appState.streamNotRunningReason ?? "None")
            }

            card("ASR Health", icon: "waveform.badge.mic") {
                diagnosticRow("recognitionRequestActive", appState.recognitionRequestActive ? "true" : "false")
                diagnosticRow("recognitionTaskActive", appState.recognitionTaskActive ? "true" : "false")
                diagnosticRow("systemASRTaskRunning", appState.systemASRTaskRunning ? "true" : "false")
                diagnosticRow("micASRTaskActive", appState.micASRTaskActive ? "true" : "false")
                diagnosticRow("systemASRTaskActive", appState.systemASRTaskActive ? "true" : "false")
                diagnosticRow("lastSystemAudioASRError", appState.lastSystemAudioASRError ?? "None")
            }

            card("Runtime Signals", icon: "dot.radiowaves.left.and.right") {
                health("systemCaptureRunning", appState.systemCaptureRunning)
                health("micCaptureRunning", appState.micCaptureRunning)
                health("anyCaptureRunning", appState.anyCaptureRunning)
                health("systemRecentBufferAlive", appState.systemRecentBufferAlive)
                health("micRecentBufferAlive", appState.micRecentBufferAlive)
            }

            card("Runtime Transcript Chain", icon: "point.3.connected.trianglepath.dotted") {
                let runtime = appState.transcriptRuntimeDiagnostics
                diagnosticRow("chainStatus", appState.runtimeTranscriptChainStatus)
                diagnosticRow("audio_session_id", runtime.audioSessionID.isEmpty ? "None" : runtime.audioSessionID)
                diagnosticRow("audio_is_running", runtime.audioIsRunning ? "true" : "false")
                diagnosticRow("last_audio_buffer_at", diagnosticTime(runtime.lastAudioBufferAt))
                diagnosticRow("audio_buffer_count", "\(runtime.audioBufferCount)")
                diagnosticRow("last_asr_partial_at", diagnosticTime(runtime.lastASRPartialAt))
                diagnosticRow("last_asr_final_at", diagnosticTime(runtime.lastASRFinalAt))
                diagnosticRow("partial_transcript_count", "\(runtime.partialTranscriptCount)")
                diagnosticRow("final_transcript_count", "\(runtime.finalTranscriptCount)")
                diagnosticRow("last_question_candidate_at", diagnosticTime(runtime.lastQuestionCandidateAt))
                diagnosticRow("last_question_accepted_at", diagnosticTime(runtime.lastQuestionAcceptedAt))
                diagnosticRow("last_question_rejected_at", diagnosticTime(runtime.lastQuestionRejectedAt))
                diagnosticRow("last_generation_started_at", diagnosticTime(runtime.lastGenerationStartedAt))
                diagnosticRow("last_generation_rejected_reason", runtime.lastGenerationRejectedReason.isEmpty ? "None" : runtime.lastGenerationRejectedReason)
                diagnosticRow("rawTranscriptText", appState.rawTranscriptText.isEmpty ? "None" : appState.rawTranscriptText)
                diagnosticRow("partialTranscriptText", appState.partialTranscriptText.isEmpty ? "None" : appState.partialTranscriptText)
                diagnosticRow("finalTranscriptText", appState.finalTranscriptText.isEmpty ? "None" : appState.finalTranscriptText)
                diagnosticRow("displayTranscriptText", appState.displayTranscriptText.isEmpty ? "None" : appState.displayTranscriptText)
                diagnosticRow("lastAcceptedQuestionText", appState.lastAcceptedQuestionText.isEmpty ? "None" : appState.lastAcceptedQuestionText)
                diagnosticRow("traceLogPath", appState.runtimeTranscriptTraceLogURL.path)
                ActionButton(
                    appState: appState,
                    actionID: ActionID.diagnosticsCopy,
                    title: "Copy Runtime Transcript Trace",
                    loadingTitle: "Copying...",
                    successTitle: "Trace Copied",
                    systemImage: "doc.on.doc"
                ) {
                    copyRuntimeTranscriptTrace()
                }
                InlineStatusBanner(appState.latestActionFeedback(for: ActionID.diagnosticsCopy))
                if appState.recentTranscriptRuntimeEvents.isEmpty {
                    diagnosticRow("recentEvents", "None")
                } else {
                    ForEach(Array(appState.recentTranscriptRuntimeEvents.suffix(8).reversed())) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            diagnosticRow(event.name, event.text.isEmpty ? (event.reason.isEmpty ? "event" : event.reason) : event.text)
                            if let frameCount = event.frameCount {
                                diagnosticRow("frameCount", "\(frameCount)")
                            }
                            Divider()
                        }
                    }
                }
            }

            card("Runtime Persistence", icon: "externaldrive.badge.checkmark") {
                diagnosticRow("activeDatabasePath", appState.activeDatabasePath)
                diagnosticRow("persistenceState", appState.diagnosticPersistenceState)
                diagnosticRow("suggestionRowCount", "\(appState.diagnosticSuggestionRowCount)")
                diagnosticRow("latestSuggestionCreatedAt", appState.diagnosticLatestSuggestionCreatedAt)
                diagnosticRow("latestSuggestionQuestion", appState.diagnosticLatestSuggestionQuestionText)
                diagnosticRow("lastSQLiteOperation", appState.lastSQLiteOperation)
            }
        }
    }

    private var captureEventsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            card("recent20CaptureEvents", icon: "list.bullet.rectangle") {
                if appState.recent20CaptureEvents.isEmpty {
                    Text("No capture events logged yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(appState.recent20CaptureEvents.reversed())) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(event.timestamp, style: .time)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text(event.eventName)
                                    .font(.callout.weight(.semibold))
                                Spacer()
                            }
                            Text("\(event.stateBefore) -> \(event.stateAfter) [\(event.reason)]")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Text("\(event.file):\(event.line) \(event.function)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var latencyTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            card("Current Latency", icon: "bolt.horizontal.fill") {
                diagnosticRow("ASR first partial", appState.asrFirstPartialMS.map { "\($0) ms" } ?? "Pending")
                diagnosticRow("ASR final", appState.asrFinalMS.map { "\($0) ms" } ?? "Pending")
                diagnosticRow("ASR best selected", appState.asrBestSelectedMS.map { "\($0) ms" } ?? "Pending")
                diagnosticRow("RAG retrieval", appState.ragRetrievalLatencyMS.map { "\($0) ms" } ?? "Pending")
                diagnosticRow("DeepSeek first token", appState.deepseekFirstTokenMS.map { "\($0) ms" } ?? "Pending")
                diagnosticRow("DeepSeek first visible", appState.deepseekFirstVisibleMS.map { "\($0) ms" } ?? "Pending")
                diagnosticRow("Soft fallback latency", appState.softFallbackLatencyMS.map { "\($0) ms" } ?? "Pending")
            }

            card("Last 10 Suggestions", icon: "chart.bar.xaxis") {
                diagnosticRow("Overall count", "\(appState.latencyAveragesOverall.count)")
                diagnosticRow("Overall P50 first visible", appState.latencyAveragesOverall.p50FirstVisibleMS.map { "\($0) ms" } ?? "None")
                diagnosticRow("Overall P90 first visible", appState.latencyAveragesOverall.p90FirstVisibleMS.map { "\($0) ms" } ?? "None")
                diagnosticRow("DeepSeek count", "\(appState.latencyAveragesDeepSeek.count)")
                diagnosticRow("DeepSeek P50 full card", appState.latencyAveragesDeepSeek.p50FullCardMS.map { "\($0) ms" } ?? "None")
                diagnosticRow("DeepSeek P90 full card", appState.latencyAveragesDeepSeek.p90FullCardMS.map { "\($0) ms" } ?? "None")
            }
        }
    }

    private var keychainTab: some View {
        card("Keychain Masked Status", icon: "key.fill") {
            diagnosticRow("keychainServiceName", appState.keychainServiceName)
            diagnosticRow("keychainDeepSeekAccount", appState.keychainDeepSeekAccount)
            diagnosticRow("keychainDeepSeekKeyExists", appState.keychainDeepSeekKeyExists ? "true" : "false")
            diagnosticRow("keychainMaskedKey", appState.keychainMaskedKey)
            diagnosticRow("keychainLastReadStatus", appState.keychainLastReadStatus)
            diagnosticRow("keychainLastWriteStatus", appState.keychainLastWriteStatus)
            diagnosticRow("keychainMigrationPerformed", appState.keychainMigrationPerformed ? "true" : "false")
            diagnosticRow("keychainLegacyItemFound", appState.keychainLegacyItemFound ? "true" : "false")
            diagnosticRow("keychainLegacyItemCount", "\(appState.keychainLegacyItemCount)")
            diagnosticRow("keychainMismatchStatus", appState.keychainMismatchStatus)
        }
    }

    private func card<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
            content()
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func diagnosticRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 210, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
            Spacer()
        }
        .font(.callout)
    }

    private func diagnosticTime(_ date: Date?) -> String {
        guard let date else { return "None" }
        return DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .medium)
    }

    private func copyRuntimeTranscriptTrace() {
        appState.beginAction(ActionID.diagnosticsCopy, title: "Copying trace", message: "Copying recent runtime transcript trace as JSONL...")
        let trace = appState.runtimeTranscriptTraceExportText()
        guard !trace.isEmpty else {
            appState.warnAction(ActionID.diagnosticsCopy, title: "No trace yet", message: "Start listening or run a smoke test first.")
            return
        }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(trace, forType: .string) {
            appState.completeAction(ActionID.diagnosticsCopy, title: "Trace copied", message: "Recent runtime transcript trace copied as JSONL.")
        } else {
            appState.failAction(ActionID.diagnosticsCopy, title: "Copy failed", message: "The clipboard did not accept the trace text.")
        }
    }

    private func health(_ title: String, _ active: Bool) -> some View {
        HStack {
            Image(systemName: active ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(active ? .green : .red)
            Text(title)
            Spacer()
            Text(active ? "true" : "false")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}
