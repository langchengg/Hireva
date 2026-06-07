import SwiftUI

struct ProviderDiagnosticsView: View {
    @ObservedObject var appState: AppState

    @State private var selectedProvider: String = "All"
    @State private var selectedMode: String = "All"
    @State private var latencyAverages: LatencyAverages = .empty

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Provider Diagnostics")
                    .font(.largeTitle.weight(.bold))

                manualVerificationPanel
                
                RAGDiagnosticsView(appState: appState)
                
                Divider()
                
                currentPipelineLatencySection
                
                historicalPipelineLatencySection
                
                Divider()
                
                Text("Inspect active AI routing, cloud provider connection state, embedding coverage, and latency.")
                    .foregroundStyle(.secondary)

                providerSummary("Active Realtime Provider", provider: appState.activeRealtimeProvider)
                providerSummary("Active Recap Provider", provider: appState.activeRecapProvider)
                embeddingDiagnosticsCard

                keychainDiagnosticsCard

                captureDiagnosticsCard

                VStack(alignment: .leading, spacing: 10) {
                    Label("AI Router Diagnostics", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.headline)
                    row("Last Switched At", appState.lastProviderSwitchTimestamp.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .medium) } ?? "Never")
                    row("Last Switch Error", appState.lastProviderSwitchError ?? "None")
                    row("Q Detect Provider", appState.lastQuestionDetectionProvider ?? "None")
                    row("Q Detect Model", appState.lastQuestionDetectionModel ?? "None")
                    row("Suggestion Gen Provider", appState.lastSuggestionGenerationProvider ?? "None")
                    row("Suggestion Gen Model", appState.lastSuggestionGenerationModel ?? "None")
                }
                .padding(18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 10) {
                    Label("Suggestion Provenance", systemImage: "signature")
                        .font(.headline)
                    row("Say First Source", appState.finalVisibleSource ?? "None")
                    row("Soft Fallback Used", appState.softFallbackUsed ? "Yes" : "No")
                    if let softLat = appState.softFallbackLatencyMS {
                        row("Soft Fallback Latency", "\(softLat) ms")
                    }
                    if let firstTok = appState.deepseekFirstTokenMS {
                        row("DeepSeek First Token", "\(firstTok) ms")
                    }
                    if let firstVis = appState.deepseekFirstVisibleMS {
                        row("DeepSeek First Visible", "\(firstVis) ms")
                    }
                }
                .padding(18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 10) {
                    Label("Last AI Call", systemImage: "timer")
                        .font(.headline)
                    row("Provider", appState.diagnostics.lastProviderName ?? "None")
                    row("Model", appState.diagnostics.lastProviderModel ?? "None")
                    row("Latency", appState.diagnostics.lastAPILatencyMS.map { "\($0) ms" } ?? "None")
                    row("Last Error", appState.diagnostics.lastError ?? "None")
                }
                .padding(18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))


            }
            .padding(28)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .onAppear {
            fetchFilteredAverages()
        }
        .onChange(of: selectedProvider) { _, _ in
            fetchFilteredAverages()
        }
        .onChange(of: selectedMode) { _, _ in
            fetchFilteredAverages()
        }
    }

    private func providerSummary(_ title: String, provider: LLMProviderConfiguration?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: "brain")
                    .font(.headline)
                Spacer()
                if title == "Active Realtime Provider" {
                    LLMProviderQuickSwitcherView(appState: appState, isCompact: false)
                } else if let provider {
                    StatusPill(title: provider.kind.isLocal ? "Local" : "Cloud", systemImage: provider.kind.isLocal ? "desktopcomputer" : "cloud", tint: provider.kind.isLocal ? .green : .blue)
                }
            }
            if let provider {
                row("Name", provider.name)
                row("Kind", provider.kind.displayName)
                row("Base URL", provider.baseURL)
                row("Model", provider.model)
                row("Connection", appState.providerConnectionResults[provider.id] ?? "Not tested")
                HStack {
                    Button("Test Connection") {
                        appState.testProviderConnection(provider)
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Text("No provider selected.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var manualVerificationPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Manual Runtime Verification", systemImage: "checklist.checked")
                    .font(.headline)
                Spacer()
                Text("No Accessibility automation")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                manualCheckRow(
                    "System Audio Only active",
                    passed: appState.captureMode == .systemAudioOnly,
                    value: appState.captureMode.shortDisplayName
                )
                manualCheckRow(
                    "Floating panel active",
                    passed: appState.isFloatingAssistantVisible,
                    value: appState.isFloatingAssistantVisible ? "Visible" : "Not visible"
                )
                manualCheckRow(
                    "Start/Stop state",
                    passed: appState.canStopCapture || appState.currentCaptureRuntimeState != .idle,
                    value: appState.currentCaptureRuntimeState.displayName
                )
                manualCheckRow(
                    "DeepSeek configured",
                    passed: appState.keychainDeepSeekKeyExists && appState.providerConfigurations.contains(where: { $0.kind == .deepSeek }),
                    value: appState.keychainDeepSeekKeyExists ? "Configured" : "Missing key"
                )
                manualCheckRow(
                    "RAG clean",
                    passed: appState.latexPollutedChunkCount == 0,
                    value: "\(appState.latexPollutedChunkCount) polluted chunks"
                )
                manualCheckRow(
                    "Last suggestion visible",
                    passed: appState.currentSuggestion != nil,
                    value: appState.currentSuggestion == nil ? "No suggestion" : "Suggestion loaded"
                )
                manualCheckRow(
                    "System capture running",
                    passed: appState.systemCaptureRunning,
                    value: appState.systemCaptureRunning ? "Running" : "Stopped"
                )
                manualCheckRow(
                    "Mic capture running",
                    passed: appState.micCaptureRunning,
                    value: appState.micCaptureRunning ? "Running" : "Stopped"
                )
            }

            Divider()

            Group {
                captureRow("captureMode", appState.captureMode.rawValue)
                captureRow("currentCaptureRuntimeState", appState.currentCaptureRuntimeState.displayName, valueColor: stateColor(appState.currentCaptureRuntimeState))
                captureRow("systemCaptureRunning", appState.systemCaptureRunning ? "true" : "false")
                captureRow("micCaptureRunning", appState.micCaptureRunning ? "true" : "false")
                captureRow("lastSystemTranscript", manualTranscriptPreview)
                captureRow("currentSuggestion exists", appState.currentSuggestion == nil ? "false" : "true")
                captureRow("stopReason", appState.stopReason?.rawValue ?? "None")
                captureRow("DeepSeek configured", appState.keychainDeepSeekKeyExists ? "true" : "false")
                captureRow("RAG mode", appState.manualVerificationRAGMode)
                captureRow("LaTeX polluted chunk count", "\(appState.latexPollutedChunkCount)", valueColor: appState.latexPollutedChunkCount == 0 ? .green : .red)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var manualTranscriptPreview: String {
        let raw = appState.lastSystemTranscript.isEmpty
            ? appState.lastSystemAudioASRFinalTranscript
            : appState.lastSystemTranscript
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "None" }
        return String(trimmed.prefix(220))
    }

    private var embeddingDiagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Embedding Provider", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.headline)
            row("Provider Kind", appState.settings.embeddingProviderKind.displayName)
            row("Base URL", appState.settings.embeddingProviderKind == .disabled ? "Disabled" : appState.settings.embeddingBaseURL)
            row("Model", appState.settings.embeddingProviderKind == .disabled ? "Keyword only" : appState.settings.embeddingModelName)
            row("Key Status", appState.embeddingKeyStatus(account: appState.settings.embeddingApiKeyAccount))
            row("Last Test", appState.lastEmbeddingTestStatus)
            if let error = appState.lastEmbeddingError {
                row("Last Error", error)
            }
            if let coverage = appState.embeddingCoverage {
                row("Coverage", "\(coverage.chunksWithEmbeddings) / \(coverage.totalChunks) chunks (\(Int(coverage.coveragePercent))%)")
                row("Dimension", coverage.dimension.map { "\($0)" } ?? "None")
            }
            HStack {
                Button("Test Embedding Provider") {
                    appState.testEmbeddingProvider()
                }
                .buttonStyle(.bordered)
                Button("Rebuild Embeddings") {
                    appState.rebuildAllEmbeddings()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
            Spacer()
        }
        .font(.callout)
    }

    private func fetchFilteredAverages() {
        let provParam = selectedProvider == "All" ? nil : selectedProvider
        let modeParam: InterviewMode?
        switch selectedMode {
        case "Practice": modeParam = .mock
        case "Interview": modeParam = .microphone
        default: modeParam = nil
        }
        
        do {
            self.latencyAverages = try appState.suggestionRepository.fetchLatencyAverages(last: 10, provider: provParam, mode: modeParam)
        } catch {
            print("Failed to fetch filtered averages: \(error)")
            self.latencyAverages = .empty
        }
    }

    private func latencyRow(_ title: String, value: Int?, status: LatencyStatus, suffix: String = "ms") -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            if let value {
                Text("\(value) \(suffix)")
                    .font(.body.monospacedDigit())
                    .bold()
            } else {
                Text("Pending")
                    .foregroundStyle(.secondary)
            }
            LatencyBadgeView(status: status)
        }
        .font(.callout)
    }

    private func latencyRowAvg(_ title: String, value: Double?, status: LatencyStatus, suffix: String = "ms") -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            if let value {
                Text(String(format: "%.1f %@", value, suffix))
                    .font(.body.monospacedDigit())
                    .bold()
            } else {
                Text("N/A")
                    .foregroundStyle(.secondary)
            }
            LatencyBadgeView(status: status)
        }
        .font(.callout)
    }

    private var currentPipelineLatencySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Pipeline Latency (Current)", systemImage: "bolt.horizontal.fill")
                .font(.headline)
                .foregroundStyle(.primary)
            
            Text("Detailed timings for the most recent suggestion segment.")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            Divider()
            
            VStack(spacing: 10) {
                latencyRow(
                    "ASR First Partial",
                    value: appState.asrFirstPartialMS,
                    status: LatencyBudget.asrFirstPartial(appState.asrFirstPartialMS)
                )
                
                latencyRow(
                    "ASR Best Selected (Final)",
                    value: appState.asrBestSelectedMS,
                    status: LatencyBudget.asrBestSelected(appState.asrBestSelectedMS)
                )
                
                latencyRow(
                    "RAG Retrieval",
                    value: appState.ragRetrievalLatencyMS,
                    status: LatencyBudget.ragRetrieval(appState.ragRetrievalLatencyMS)
                )
                
                let firstVisibleVal = appState.softFallbackUsed ? appState.softFallbackLatencyMS : appState.deepseekFirstVisibleMS
                let visibleSource = appState.softFallbackUsed ? "soft fallback" : "DeepSeek"
                let canonicalFirstVisibleVal = appState.currentSuggestion?.firstVisibleAnswerMS ?? firstVisibleVal
                latencyRow(
                    "First Visible Answer (\(visibleSource))",
                    value: canonicalFirstVisibleVal,
                    status: LatencyBudget.firstVisible(canonicalFirstVisibleVal)
                )

                let firstKeyPointVal = appState.currentSuggestion?.firstKeyPointVisibleMS
                latencyRow(
                    "First Key Point",
                    value: firstKeyPointVal,
                    status: LatencyBudget.firstKeyPoint(firstKeyPointVal)
                )

                let allKeyPointsVal = appState.currentSuggestion?.allKeyPointsVisibleMS
                latencyRow(
                    "All Key Points",
                    value: allKeyPointsVal,
                    status: LatencyBudget.firstKeyPoint(allKeyPointsVal)
                )

                let followUpVal = appState.currentSuggestion?.followUpVisibleMS
                latencyRow(
                    "Follow-up Ready",
                    value: followUpVal,
                    status: LatencyBudget.fullCard(followUpVal)
                )
                
                let fullCardVal = appState.currentSuggestion?.fullCardVisibleMS ?? appState.currentSuggestion?.latencyFullCardMS
                latencyRow(
                    "Full Card (Stage B)",
                    value: fullCardVal,
                    status: LatencyBudget.fullCard(fullCardVal)
                )

                let dbPersistedVal = appState.currentSuggestion?.dbPersistedMS
                latencyRow(
                    "DB Persisted",
                    value: dbPersistedVal,
                    status: LatencyBudget.backgroundPersistence(dbPersistedVal)
                )
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var historicalPipelineLatencySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Pipeline Latency (Last 10)", systemImage: "chart.bar.xaxis")
                    .font(.headline)
                Spacer()
                
                // Filters
                HStack(spacing: 8) {
                    Picker("Provider", selection: $selectedProvider) {
                        Text("All Providers").tag("All")
                        Text("DeepSeek").tag("DeepSeek")
                        Text("Custom API").tag("Custom API")
                    }
                    .pickerStyle(.menu)
                    .frame(width: 140)
                    
                    Picker("Mode", selection: $selectedMode) {
                        Text("All Modes").tag("All")
                        Text("Practice").tag("Practice")
                        Text("Interview").tag("Interview")
                    }
                    .pickerStyle(.menu)
                    .frame(width: 120)
                }
            }
            
            Text("Rolling averages and percentiles over the last 10 suggestions.")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            Divider()
            
            if latencyAverages.count == 0 {
                Text("No historical suggestion card data found matching the selected filters.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 10) {
                    HStack {
                        Text("Total Records Analyzed")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(latencyAverages.count)")
                            .bold()
                    }
                    .font(.callout)
                    
                    latencyRowAvg(
                        "Avg First Visible",
                        value: latencyAverages.avgFirstVisibleMS,
                        status: LatencyBudget.firstVisibleAvg(latencyAverages.avgFirstVisibleMS)
                    )
                    
                    if let p50 = latencyAverages.p50FirstVisibleMS, let p90 = latencyAverages.p90FirstVisibleMS {
                        HStack {
                            Text("First Visible Percentiles")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("P50: \(p50) ms | P90: \(p90) ms")
                                .font(.body.monospacedDigit())
                                .foregroundStyle(.primary)
                        }
                        .font(.caption)
                    }

                    latencyRowAvg(
                        "Avg First Key Point",
                        value: latencyAverages.avgFirstKeyPointVisibleMS,
                        status: LatencyBudget.firstKeyPointAvg(latencyAverages.avgFirstKeyPointVisibleMS)
                    )

                    if let p50 = latencyAverages.p50FirstKeyPointVisibleMS, let p90 = latencyAverages.p90FirstKeyPointVisibleMS {
                        HStack {
                            Text("First Key Point Percentiles")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("P50: \(p50) ms | P90: \(p90) ms")
                                .font(.body.monospacedDigit())
                                .foregroundStyle(.primary)
                        }
                        .font(.caption)
                    }

                    latencyRowAvg(
                        "Avg All Key Points",
                        value: latencyAverages.avgAllKeyPointsVisibleMS,
                        status: LatencyBudget.firstKeyPointAvg(latencyAverages.avgAllKeyPointsVisibleMS)
                    )

                    latencyRowAvg(
                        "Avg Follow-up Ready",
                        value: latencyAverages.avgFollowUpVisibleMS,
                        status: LatencyBudget.fullCardAvg(latencyAverages.avgFollowUpVisibleMS)
                    )
                    
                    latencyRowAvg(
                        "Avg Full Card (Stage B)",
                        value: latencyAverages.avgFullCardMS,
                        status: LatencyBudget.fullCardAvg(latencyAverages.avgFullCardMS)
                    )
                    
                    if let p50 = latencyAverages.p50FullCardMS, let p90 = latencyAverages.p90FullCardMS {
                        HStack {
                            Text("Full Card Percentiles")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("P50: \(p50) ms | P90: \(p90) ms")
                                .font(.body.monospacedDigit())
                                .foregroundStyle(.primary)
                        }
                        .font(.caption)
                    }
                    
                    latencyRowAvg(
                        "Avg RAG Retrieval",
                        value: latencyAverages.avgRagRetrievalMS,
                        status: LatencyBudget.ragRetrievalAvg(latencyAverages.avgRagRetrievalMS)
                    )
                    
                    latencyRowAvg(
                        "Avg ASR Best Selected (Final)",
                        value: latencyAverages.avgASRBestSelectedMS,
                        status: LatencyBudget.asrBestSelectedAvg(latencyAverages.avgASRBestSelectedMS)
                    )

                    latencyRowAvg(
                        "Avg DB Persisted",
                        value: latencyAverages.avgDBPersistedMS,
                        status: LatencyBudget.backgroundPersistenceAvg(latencyAverages.avgDBPersistedMS)
                    )

                    latencyRowAvg(
                        "Avg Stage B Stream Start",
                        value: latencyAverages.avgStageBStreamStartedMS,
                        status: LatencyBudget.firstVisibleAvg(latencyAverages.avgStageBStreamStartedMS)
                    )

                    latencyRowAvg(
                        "Avg Stage B First Section",
                        value: latencyAverages.avgStageBFirstSectionMS,
                        status: LatencyBudget.firstKeyPointAvg(latencyAverages.avgStageBFirstSectionMS)
                    )
                    
                    HStack {
                        Text("Soft Fallback Rate")
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let rate = latencyAverages.softFallbackRate {
                            Text(String(format: "%.1f%%", rate * 100.0))
                                .bold()
                        } else {
                            Text("N/A").foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                    
                    HStack {
                        Text("Stage B Failure/Timeout Rate")
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let rate = latencyAverages.failureRate {
                            Text(String(format: "%.1f%%", rate * 100.0))
                                .bold()
                                .foregroundColor(rate > 0.1 ? .red : .primary)
                        } else {
                            Text("N/A").foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                }
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var keychainDiagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Keychain & Identity Diagnostics", systemImage: "key.fill")
                .font(.headline)
            
            Text(appState.keychainMismatchStatus)
                .font(.subheadline)
                .bold()
                .foregroundStyle(appState.keychainDeepSeekKeyExists ? .green : (appState.keychainLegacyItemFound ? .orange : .red))
                .padding(.vertical, 4)
            
            Divider()

            row("Keychain Service", appState.keychainServiceName)
            row("DeepSeek Account", appState.keychainDeepSeekAccount)
            row("Key Exists", appState.keychainDeepSeekKeyExists ? "Yes" : "No")
            row("Masked Key", appState.keychainMaskedKey)
            row("Last Read Status", appState.keychainLastReadStatus)
            row("Last Write Status", appState.keychainLastWriteStatus)
            row("Migration Run", appState.keychainMigrationPerformed ? "Yes" : "No")
            row("Legacy Key Found", appState.keychainLegacyItemFound ? "Yes" : "No")
            if appState.keychainLegacyItemCount > 0 {
                row("Legacy Item Count", "\(appState.keychainLegacyItemCount)")
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var captureDiagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("System & Mic Audio Capture Diagnostics", systemImage: "waveform.path.ecg")
                .font(.headline)
            
            Group {
                captureRow("Runtime State", appState.currentCaptureRuntimeState.displayName, valueColor: stateColor(appState.currentCaptureRuntimeState))
                if let stopReason = appState.stopReason {
                    captureRow("Stop Reason", stopReason.rawValue, valueColor: .orange)
                }
                captureRow("Last Capture Started", appState.lastCaptureStartedAt.map { dateFormatter.string(from: $0) } ?? "Never")
                captureRow("Last Capture Stopped", appState.lastCaptureStoppedAt.map { dateFormatter.string(from: $0) } ?? "Never")
                captureRow("Last System Buffer", appState.lastSystemAudioBufferAt.map { dateFormatter.string(from: $0) } ?? "Never")
                if let err = appState.lastSystemAudioError {
                    captureRow("System Audio Error", err, valueColor: .red)
                }
            }
            
            Divider()
            
            Text("Health Statuses")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
            
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                healthPill("System Capture Running", appState.systemCaptureRunning)
                healthPill("System Buffer Alive", appState.systemRecentBufferAlive)
                healthPill("System ASR Active", appState.systemASRTaskActive)
                healthPill("Mic Capture Running", appState.micCaptureRunning)
                healthPill("Mic Buffer Alive", appState.micRecentBufferAlive)
                healthPill("Mic ASR Active", appState.micASRTaskActive)
                healthPill("Any Capture Running", appState.anyCaptureRunning)
                healthPill("Can Stop Capture", appState.canStopCapture)
            }
            
            Divider()
            
            Text("Capture Event History (Last 20)")
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
            
            if appState.recent20CaptureEvents.isEmpty {
                Text("No capture events logged yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(appState.recent20CaptureEvents.reversed()) { event in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(alignment: .top) {
                                    Text(dateFormatter.string(from: event.timestamp))
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                    Text("|")
                                        .foregroundStyle(.secondary)
                                    Text(event.eventName)
                                        .font(.caption.bold())
                                        .foregroundStyle(.primary)
                                    Spacer()
                                }
                                
                                Text("\(event.stateBefore) -> \(event.stateAfter) [Reason: \(event.reason)]")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                
                                Text("At: \(event.file):\(event.line) (\(event.function))")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                
                                Divider()
                                    .padding(.top, 2)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .frame(height: 200)
                .padding(8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func captureRow(_ title: String, _ value: String, valueColor: Color = .primary) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 200, alignment: .leading)
            Text(value)
                .foregroundColor(valueColor)
                .textSelection(.enabled)
            Spacer()
        }
        .font(.callout)
    }

    private func manualCheckRow(_ title: String, passed: Bool, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: passed ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(passed ? .green : .secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.medium))
                Text(value)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    private func stateColor(_ state: CaptureRuntimeState) -> Color {
        switch state {
        case .idle: return .gray
        case .starting: return .blue
        case .listening: return .green
        case .generating: return .purple
        case .stopping: return .orange
        case .stopped: return .orange
        case .error: return .red
        }
    }

    private func healthPill(_ label: String, _ active: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: active ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(active ? .green : .red)
            Text(label)
                .font(.caption)
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
    }

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }
}

struct LatencyBadgeView: View {
    let status: LatencyStatus
    
    var body: some View {
        HStack(spacing: 4) {
            Text(status.emoji)
            Text(status.rawValue.uppercased())
                .font(.caption2.bold())
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(backgroundColor, in: Capsule())
        .foregroundColor(foregroundColor)
    }
    
    private var backgroundColor: Color {
        switch status {
        case .pass: return .green.opacity(0.15)
        case .warn: return .orange.opacity(0.15)
        case .fail: return .red.opacity(0.15)
        case .unknown: return .gray.opacity(0.15)
        }
    }
    
    private var foregroundColor: Color {
        switch status {
        case .pass: return .green
        case .warn: return .orange
        case .fail: return .red
        case .unknown: return .secondary
        }
    }
}
