import SwiftUI

struct DiagnosticsView: View {
    @ObservedObject var appState: AppState

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
                diagnosticRow("ignoredSmallTalkCount", "\(appState.ignoredSmallTalkCount)")
                diagnosticRow("detectedQuestionsInSessionCount", "\(appState.detectedQuestionsInSessionCount)")
                diagnosticRow("currentGenerationState", appState.generationUIState.displayName)
            }

            card("Main Thread / Long Operations", icon: "cpu") {
                diagnosticRow("mainThreadHeartbeatAt", diagnosticTime(appState.mainThreadHeartbeatAt))
                diagnosticRow("mainThreadHeartbeatDelayMs", "\(appState.mainThreadHeartbeatDelayMs)")
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
