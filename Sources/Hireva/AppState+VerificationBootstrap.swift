import AppKit
import Foundation

func resolveVerificationPreferences(
    configuration: HirevaVerificationConfiguration,
    suiteFactory: (String) -> UserDefaults? = { UserDefaults(suiteName: $0) }
) throws -> UserDefaults {
    guard let defaults = suiteFactory(configuration.userDefaultsSuiteName) else {
        throw VerificationPreferencesError.unavailableSuite
    }
    return defaults
}

private enum VerificationPreferencesError: LocalizedError {
    case unavailableSuite

    var errorDescription: String? {
        "Unable to initialize verification preferences."
    }
}

enum HirevaVerificationEventPolicy {
    static func fieldsForLogging(_ fields: [String: Any], settings: AppSettings) -> [String: Any]? {
        switch settings.effectiveDiagnosticTraceMode {
        case .off: return nil
        case .fullText: return fields
        case .metadataOnly:
            // Explicit allowlist: future diagnostic strings must not silently
            // become another transcript/answer persistence channel.
            // Metric values accept NSNumber (including Swift numeric bridges),
            // so a whitelisted key cannot carry text or a container in metadata mode.
            let numericKeys: Set<String> = [
                "workMetricsMonotonicNS", "verificationPendingTasks", "generationActiveTasks",
                "generationRetiringTasks", "generationPendingTasks", "liveDetectionActiveTasks",
                "liveDetectionRetiringTasks", "liveDetectionPendingTasks", "capturePendingTasks",
                "captureRetiringRecords", "captureFailedTeardownRecords", "documentImportActiveTasks",
                "documentImportRetiringTasks", "documentImportPendingTasks", "documentEmbeddingActiveTasks",
                "documentEmbeddingRetiringTasks", "documentEmbeddingPendingTasks", "ragPrefetchActiveTasks",
                "ragPrefetchRetiringTasks", "ragPrefetchPendingTasks", "localParakeetOwnerVisible",
                "parakeetOwnedWorkPresent", "parakeetCleanupFailurePresent",
                "diagnosticSamplingIdentityCount", "diagnosticSamplingIdentityCapacity",
                "diagnosticSamplingIdentityEvictions"
            ]
            let allowed: Set<String> = numericKeys.union([
                "runID", "synthetic", "sessionID", "segmentID", "questionID",
                "generationID", "suggestionID", "contextSnapshotID",
                "candidateProfileID", "opportunityContextID", "totalBuffers",
                "sampleRate", "channelCount", "lastBufferAt", "source", "speaker",
                "asrProvider", "answerProvider", "isFinal", "finalizationReason",
                "alignmentVerdict", "triggerDecision", "count", "captureState",
                "systemCaptureRunning", "activeASRProvider", "suggestionRows",
            ])
            return fields.filter {
                allowed.contains($0.key) &&
                    (!numericKeys.contains($0.key) || $0.value is NSNumber)
            }
        }
    }

    static func recordsTranscript(isSystemSpeaker: Bool, isFinal: Bool = true) -> Bool {
        !isSystemSpeaker && isFinal
    }

    static func orderedUniqueCandidates<T>(
        history: [T],
        current: T?,
        id: (T) -> String
    ) -> [T] {
        var seen = Set<String>()
        return (history + [current].compactMap { $0 }).filter { seen.insert(id($0)).inserted }
    }

    static func alignmentVerdictValue(_ verdict: AnswerAlignmentVerdict?) -> String {
        verdict?.rawValue ?? ""
    }

    static func recordsVisibleSuggestion(
        stageBStatus: String?,
        finalVisibleSource: String?
    ) -> Bool {
        stageBStatus != "superseded" &&
            finalVisibleSource != "local_superseded_question_snapshot"
    }
}

struct HirevaVerificationSeededDocuments {
    let candidate: DocumentRecord
    let opportunity: DocumentRecord
}

enum HirevaVerificationDocumentSeeder {
    static func seed(
        in repository: DocumentRepository,
        candidateStatements: [String],
        opportunityStatements: [String],
        candidateEvidenceTypes: [String]? = nil
    ) throws -> HirevaVerificationSeededDocuments {
        let candidateContent: String
        if let candidateEvidenceTypes {
            guard !candidateStatements.isEmpty,
                  candidateEvidenceTypes.count == candidateStatements.count,
                  candidateStatements.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw VerificationBootstrapError.invalidScenario("Candidate evidence types must match nonempty declared statements.")
            }
            candidateContent = try zip(candidateEvidenceTypes, candidateStatements).map { type, statement in
                guard let heading = candidateSection(for: type) else {
                    throw VerificationBootstrapError.invalidScenario("Unsupported candidate evidence type: \(type)")
                }
                return "## \(heading)\n\(statement)"
            }.joined(separator: "\n\n")
        } else {
            candidateContent = candidateStatements.joined(separator: "\n\n")
        }
        let candidate = try repository.saveDocument(
            type: .cv,
            title: "Verification Candidate CV",
            content: candidateContent
        )
        let opportunity = try repository.saveDocument(
            type: .jobDescription,
            title: "Verification Role Description",
            content: opportunityStatements.joined(separator: "\n\n")
        )
        return HirevaVerificationSeededDocuments(candidate: candidate, opportunity: opportunity)
    }

    // Verification retains the supplied synthetic type through the existing
    // document extractor; normal product evidence admission stays unchanged.
    private static func candidateSection(for type: String) -> String? {
        switch EvidenceType(rawValue: type) {
        case .education: return "Education"
        case .experience: return "Experience"
        case .project: return "Projects"
        case .skill: return "Skills"
        case .publication: return "Publications"
        case .achievement: return "Achievements"
        case .declaredGap: return "Declared gaps"
        case .goal: return "Goals"
        default: return nil
        }
    }

    static func admitsDeclaredCandidateEvidence(
        statements: [String], types: [String], documentID: String,
        evidence: [ProfileEvidence]
    ) -> Bool {
        guard !statements.isEmpty, statements.count == types.count else { return false }
        var remaining = evidence.filter(\.isUsable)
        for (type, statement) in zip(types, statements) {
            guard candidateSection(for: type) != nil else { return false }
            let lines = statement.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !lines.isEmpty else { return false }
            for line in lines {
                guard let index = remaining.firstIndex(where: {
                    $0.sourceDocumentID == documentID && $0.sourceSpan == line &&
                        $0.statement == line && $0.evidenceType.rawValue == type
                }) else { return false }
                remaining.remove(at: index)
            }
        }
        return true
    }
}

enum HirevaVerificationReadinessPolicy {
    static func accepts(
        _ readiness: AutomaticContextReadiness,
        hasUsableCandidateContext: Bool
    ) -> Bool {
        (readiness == .ready || readiness == .needsReview) && hasUsableCandidateContext
    }
}

extension AppState {
    func runVerificationBootstrapIfRequested(configuration: HirevaVerificationConfiguration? = HirevaVerificationConfiguration.current) {
        guard let configuration else { return }
        guard !isShuttingDown else { return }
        verificationCoordinator.start(appState: self, configuration: configuration)
    }
}

@MainActor
final class HirevaVerificationCoordinator {
    private static let controlNotification = Notification.Name("com.langcheng.Hireva.VerificationControl")

    private weak var appState: AppState?
    private var configuration: HirevaVerificationConfiguration?
    private var writer: HirevaVerificationEventWriter?
    private var observer: NSObjectProtocol?
    private var monitorTask: (id: UUID, task: Task<Void, Never>)?
    private var bootstrapTask: (id: UUID, task: Task<Void, Never>)?
    private var started = false
    private var closed = false
    private let ownerID = UUID()
    private var controls: [UUID: Task<Void, Never>] = [:]
    private var shutdownTask: (id: UUID, task: Task<Bool, Never>)?
    private static let maximumPendingControls = 8
    private var seenTranscriptIDs = Set<String>()
    private var seenQuestionIDs = Set<String>()
    private var seenGenerationIDs = Set<String>()
    private var seenSuggestionIDs = Set<String>()
    private var firstBufferSessionIDs = Set<String>()
    private var lastTraceKey = ""
    private var lastPersistenceCount = 0
    private var lastError = ""

#if DEBUG
    // Read-only worker receipts and a nil-default scheduling checkpoint. Tests
    // instantiate their own coordinator and never start the process singleton.
    var workerTaskDidRegisterForTesting: (@MainActor (String, Task<Void, Never>) -> Void)?
    var workerWillBeginForTesting: (@MainActor (String) async -> Void)?
    // Actual Task outer final-defer; a cancellation receipt is not Task exit.
    var workerTaskDidCompleteForTesting: (@MainActor (String) -> Void)?
    var workerTaskWillJoinForTesting: (@MainActor (String) -> Void)?
    var observerForTesting: NSObjectProtocol? { observer }
    // Calls the actual diagnostic poll; tests retain and join both workers.
    func captureObservableEventsForTesting() { captureObservableEvents() }
    // Fixture teardown only, after exact observed worker receipts have joined.
    // It cannot make an App shutdown assertion pass: tests call it afterward.
    func finishTestOwnedIOAfterJoiningWorkers() {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
        writer = nil
    }
    @discardableResult
    func submitControlForTesting(_ action: String) -> Task<Void, Never>? { makeControlTask(action) }
#endif

    func start(appState: AppState, configuration: HirevaVerificationConfiguration) {
        guard !started, !closed, !appState.isShuttingDown else { return }
        started = true
        self.appState = appState
        self.configuration = configuration

        do {
            writer = try HirevaVerificationEventWriter(configuration: configuration)
            emit("bootstrap.started", [
                "runID": configuration.runID,
                "databasePath": AppPaths.databaseURL.path,
                "scenarioPath": configuration.scenarioURL.path,
            ])
        } catch {
            fputs("Hireva verification bootstrap could not create its event log: \(error.localizedDescription)\n", stderr)
            return
        }

        observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.controlNotification,
            object: configuration.runID,
            queue: .main
        ) { [weak self] notification in
            guard let action = notification.userInfo?["action"] as? String else { return }
            DispatchQueue.main.async { [weak self] in
                _ = self?.makeControlTask(action)
            }
        }

        let monitorID = UUID()
        let monitor = Task { @MainActor [self] in
            defer {
                if monitorTask?.id == monitorID { monitorTask = nil }
#if DEBUG
                workerTaskDidCompleteForTesting?("monitor")
#endif
            }
            await VerificationWorkerScope.$current.withValue(.init(ownerID: ownerID, workerID: monitorID)) {
#if DEBUG
                await workerWillBeginForTesting?("monitor")
#endif
                while hasAdmission {
                    captureObservableEvents()
                    do { try await Task.sleep(for: .milliseconds(100)) }
                    catch { break }
                }
            }
        }
        monitorTask = (monitorID, monitor)
        let bootstrapID = UUID()
        let bootstrap = Task { @MainActor [self] in
            defer {
                if bootstrapTask?.id == bootstrapID { bootstrapTask = nil }
#if DEBUG
                workerTaskDidCompleteForTesting?("bootstrap")
#endif
            }
            await VerificationWorkerScope.$current.withValue(.init(ownerID: ownerID, workerID: bootstrapID)) {
#if DEBUG
                await workerWillBeginForTesting?("bootstrap")
#endif
                guard hasAdmission else { return }
                await configureAndStart()
            }
        }
        bootstrapTask = (bootstrapID, bootstrap)
#if DEBUG
        if let monitorTask { workerTaskDidRegisterForTesting?("monitor", monitorTask.task) }
        if let bootstrapTask { workerTaskDidRegisterForTesting?("bootstrap", bootstrapTask.task) }
#endif
    }

    var pendingWorkerCount: Int {
        (monitorTask == nil ? 0 : 1) + (bootstrapTask == nil ? 0 : 1) + controls.count
    }
    var hasUnreleasedResources: Bool {
        pendingWorkerCount > 0 || observer != nil || writer != nil || shutdownTask != nil
    }

    /// A callback already queued by the notification center can arrive after
    /// removal; this synchronous actor entry rejects it before Task creation.
    @discardableResult
    private func makeControlTask(_ action: String) -> Task<Void, Never>? {
        guard hasAdmission else { return nil }
        guard controls.count < Self.maximumPendingControls else {
            emit("control.queue_overflow", ["count": controls.count])
            return nil
        }
        let id = UUID()
        let task = Task { @MainActor [self] in
            defer {
                controls.removeValue(forKey: id)
#if DEBUG
                workerTaskDidCompleteForTesting?("control")
#endif
            }
            await VerificationWorkerScope.$current.withValue(.init(ownerID: ownerID, workerID: id)) {
#if DEBUG
                await workerWillBeginForTesting?("control")
#endif
                guard hasAdmission else { return }
                await handleControl(action)
            }
        }
        controls[id] = task
#if DEBUG
        workerTaskDidRegisterForTesting?("control", task)
#endif
        return task
    }

    func closeAdmission() {
        guard !closed else { return }
        closed = true
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
            self.observer = nil
        }
        bootstrapTask?.task.cancel()
        monitorTask?.task.cancel()
        controls.values.forEach { $0.cancel() }
    }

    // TaskLocal metadata may outlive a completed parent in an inherited child.
    // Reject only a root still present in this sole owner's real handle slots.
    var canDrainFromCurrentTask: Bool {
        guard let scope = VerificationWorkerScope.current, scope.ownerID == ownerID else { return true }
        return monitorTask?.id != scope.workerID && bootstrapTask?.id != scope.workerID &&
            controls[scope.workerID] == nil
    }

    /// Check scope before borrowing an existing drain that can await this root.
    /// Own-worker callers close admission and return false; an external caller
    /// can later join the actual task and close its retained writer.
    func shutdown() async -> Bool {
        closeAdmission()
        guard canDrainFromCurrentTask else { return false }
        if let owned = shutdownTask { return await owned.task.value }
        let bootstrap = bootstrapTask?.task
        let monitor = monitorTask?.task
        let controlTasks = Array(controls.values)
        let id = UUID()
        let task = Task { @MainActor [self] in
            defer { if shutdownTask?.id == id { shutdownTask = nil } }
#if DEBUG
            if bootstrap != nil { workerTaskWillJoinForTesting?("bootstrap") }
#endif
            await bootstrap?.value
            await monitor?.value
            for control in controlTasks { await control.value }
            if let writer, !writer.close() { return false }
            writer = nil
            return pendingWorkerCount == 0 && observer == nil
        }
        shutdownTask = (id, task)
        return await task.value
    }

    private var hasAdmission: Bool {
        !closed && !Task.isCancelled && appState?.isShuttingDown == false
    }
    private func requireAdmission() throws {
        try Task.checkCancellation()
        guard hasAdmission else { throw CancellationError() }
    }

    private func configureAndStart() async {
        guard hasAdmission, let appState, let configuration else { return }
        do {
            let scenarioData = try Data(contentsOf: configuration.scenarioURL)
            if let object = try JSONSerialization.jsonObject(with: scenarioData) as? [String: Any] {
                guard object["synthetic"] as? Bool == true,
                      object["runID"] as? String == configuration.runID else {
                    throw VerificationBootstrapError.invalidScenario("Scenario identity is not synthetic or does not match the configured run.")
                }
                // Keep the valid isolation configuration; returning nil from
                // configuration loading would fall back to product storage.
                if object.keys.contains("requiresLocalASR"), object["requiresLocalASR"] as? Bool != true {
                    throw VerificationBootstrapError.invalidScenario("Verification requires local ASR; requiresLocalASR must be true.")
                }
                if object["manualUI"] as? Bool == true {
                    var settings = appState.settings
                    settings.audioCaptureMode = .systemAudioOnly
                    appState.saveSettings(settings)
                    emit("bootstrap.manual_ui_ready", ["synthetic": true])
                    return
                }
            }
            let scenario = try JSONDecoder().decode(
                HirevaAppVerificationScenario.self,
                from: Data(contentsOf: configuration.scenarioURL)
            )
            guard scenario.synthetic, scenario.runID == configuration.runID else {
                throw VerificationBootstrapError.invalidScenario("Scenario identity is not synthetic or does not match the configured run.")
            }
            guard scenario.answerProvider == "local_qwen" else {
                throw VerificationBootstrapError.invalidScenario("Verification may only select the local Qwen answer provider.")
            }

            appState.interviewContextState.invalidateBuild()
            let seeded = try HirevaVerificationDocumentSeeder.seed(
                in: appState.documentRepository,
                candidateStatements: scenario.candidateProfile.evidence.map(\.statement),
                opportunityStatements: scenario.opportunityContext.evidence.map(\.statement),
                candidateEvidenceTypes: scenario.candidateProfile.evidence.map(\.type)
            )
            appState.refreshAll()
            await appState.rebuildAutomaticInterviewContext(useLocalQwen: false)
            try requireAdmission()
            guard HirevaVerificationReadinessPolicy.accepts(
                appState.automaticContextReadiness,
                hasUsableCandidateContext: appState.hasUsableCandidateContext
            ) else {
                throw VerificationBootstrapError.invalidScenario(
                    "Synthetic verification documents did not produce usable interview context."
                )
            }
            guard HirevaVerificationDocumentSeeder.admitsDeclaredCandidateEvidence(
                statements: scenario.candidateProfile.evidence.map(\.statement),
                types: scenario.candidateProfile.evidence.map(\.type),
                documentID: seeded.candidate.id,
                evidence: appState.activeCandidateProfile?.allEvidence ?? []
            ) else {
                throw VerificationBootstrapError.invalidScenario(
                    "Declared synthetic candidate facts did not all enter usable interview context with their original type and source."
                )
            }
            appState.selectInterviewDomain(try scenario.domain)
            try requireAdmission()
            appState.setSelectedAnswerProviderMode(.localQwenPrimary)
            try requireAdmission()
            appState.setSelectedQwenModelName(scenario.qwenModel)
            appState.settingsState.setParakeetContextBiasEnabled(scenario.parakeetContextBiasEnabled ?? false)
            try requireAdmission()
            switch scenario.asrProvider {
            case "local_parakeet":
                guard configuration.localModelsDirectory != nil else {
                    throw VerificationBootstrapError.invalidScenario("Local Parakeet verification requires an explicit model root.")
                }
                appState.setSelectedASRProvider(.localParakeet)
            case "apple_speech":
                appState.setSelectedASRProvider(.appleSpeech)
            default:
                throw VerificationBootstrapError.invalidScenario("Unsupported ASR provider: \(scenario.asrProvider)")
            }

            try requireAdmission()
            var settings = appState.settings
            settings.audioCaptureMode = .systemAudioOnly
            settings.automaticQuestionDetectionEnabled = true
            settings.manualOnlyMode = false
            settings.allowQuestionDetectionFromMicrophoneOnly = false
            settings.saveTranscriptsLocally = true
            settings.diagnosticTraceMode = scenario.diagnosticTraceMode == "fullText" ? .fullText : .metadataOnly
            appState.saveSettings(settings)
            try requireAdmission()
            appState.interviewSessionMode = .auto
            appState.detectionDebounceSeconds = 0.05
            emit("bootstrap.configured", [
                "asrProvider": scenario.asrProvider,
                "answerProvider": scenario.answerProvider,
                "candidateProfileID": appState.activeCandidateProfileID ?? "",
                "opportunityContextID": appState.activeOpportunityContextID ?? "",
            ])
            try requireAdmission()
            appState.startListening(mode: .microphone)
            try await waitForListening(appState)
        } catch {
            guard hasAdmission, !(error is CancellationError) else { return }
            emit("bootstrap.failed", ["error": error.localizedDescription])
            guard hasAdmission else { return }
            appState.showError("Verification bootstrap failed: \(error.localizedDescription)")
        }
    }

    private func handleControl(_ action: String) async {
        guard hasAdmission, let appState else { return }
        switch action {
        case "next_session":
            guard appState.settings.audioCaptureMode == .systemAudioOnly else {
                emit("control.next_session.failed", ["error": "Verification controls require System Audio Only."])
                return
            }
            emit("control.next_session.requested")
            captureObservableEvents(includePartials: true)
            appState.stopListening(reason: .userRequested)
            let stop = appState.captureTeardownTask
            await stop?.value
            guard hasAdmission else { return }
            appState.currentSession = nil
            do {
                try await Task.sleep(for: .milliseconds(250))
                try requireAdmission()
                guard appState.settings.audioCaptureMode == .systemAudioOnly else {
                    throw VerificationBootstrapError.invalidScenario("Verification controls require System Audio Only.")
                }
                appState.startListening(mode: .microphone)
                try await waitForListening(appState)
            } catch {
                guard hasAdmission, !(error is CancellationError) else { return }
                emit("control.next_session.failed", ["error": error.localizedDescription])
            }
        case "stop":
            appState.stopListening(reason: .userRequested)
            let stop = appState.captureTeardownTask
            await stop?.value
            guard hasAdmission else { return }
            emit("control.stopped")
        case "work_counts":
            emitWorkCounts(appState)
        case "status":
            emitStatus(appState)
        case "finish":
            captureObservableEvents(includePartials: true)
            emit("ollama.transport.request_count", [
                "sessionID": appState.ollamaLifecycleEvents.last?.sessionID ?? "",
                "questionID": appState.ollamaLifecycleEvents.last?.questionID ?? "",
                "generationID": appState.ollamaLifecycleEvents.last?.generationID ?? "",
                "count": appState.ollamaDiagnostics.transportRequestCount,
            ])
            appState.stopListening(reason: .userRequested)
            let stop = appState.captureTeardownTask
            await stop?.value
            guard hasAdmission else { return }
            captureObservableEvents()
            emit("verification.finished", [
                "suggestionRows": appState.diagnosticSuggestionRowCount,
                "databasePath": appState.activeDatabasePath,
                "systemCaptureRunning": appState.systemCaptureRunning,
            ])
        default:
            emit("control.rejected", ["action": action])
        }
    }

    private func waitForListening(_ appState: AppState) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while ContinuousClock.now < deadline {
            try requireAdmission()
            captureObservableEvents()
            if appState.currentCaptureRuntimeState == .listening,
               appState.systemCaptureRunning,
               appState.activeASRProviderID != nil,
               let session = appState.currentSession {
                emit("bootstrap.ready", [
                    "sessionID": session.id,
                    "contextSnapshotID": session.contextSnapshotID ?? "",
                    "activeASRProvider": appState.activeASRProviderID?.rawValue ?? "",
                    "systemCaptureRunning": true,
                ])
                return
            }
            if case .error(let reason) = appState.currentCaptureRuntimeState {
                throw VerificationBootstrapError.captureFailed(reason)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw VerificationBootstrapError.captureFailed("Timed out waiting for real system-audio capture to start.")
    }

    private func captureObservableEvents(includePartials: Bool = false) {
        guard hasAdmission, let appState else { return }
        let sessionID = appState.currentSession?.id ?? ""
        let capture = appState.systemAudioCaptureService
        if VerificationTiming.enabled, let batch = capture.takeVerificationPCMAnchors() {
            appState.diagnosticsState.recordVerificationPCM(batch,
                mode: appState.settings.effectiveDiagnosticTraceMode)
        }
        if !sessionID.isEmpty,
           appState.ownsCurrentSystemAudioCaptureRuntime,
           let receivedAt = capture.currentCaptureBufferReceivedAt,
           capture.totalBuffersReceived > 0,
           firstBufferSessionIDs.insert(sessionID).inserted {
            emit("sck.first_buffer", [
                "sessionID": sessionID,
                "totalBuffers": capture.totalBuffersReceived,
                "sampleRate": capture.sampleRate,
                "channelCount": capture.channelCount,
                "lastBufferAt": iso8601(receivedAt),
            ])
        }

        for segment in appState.transcriptSegments where HirevaVerificationEventPolicy.recordsTranscript(
            isSystemSpeaker: segment.speaker == .system,
            isFinal: includePartials || (segment.recognitionIsFinal ?? (segment.asrFinalizationReason != "partial"))
        ) {
            guard seenTranscriptIDs.insert(segment.id).inserted else { continue }
            emit("asr.transcript", [
                "sessionID": segment.sessionID,
                "segmentID": segment.id,
                "text": segment.text,
                "source": segment.source.rawValue,
                "speaker": segment.speaker.rawValue,
                "asrProvider": segment.asrSource?.rawValue ?? "unknown",
                "isFinal": segment.recognitionIsFinal ?? true,
                "finalizationReason": segment.asrFinalizationReason ?? "",
            ])
        }

        if let questionID = appState.activeQuestionID,
           seenQuestionIDs.insert(questionID).inserted {
            emit("question.accepted", [
                "sessionID": sessionID,
                "questionID": questionID,
                "questionText": appState.lastDetectedQuestion?.questionText ?? "",
                "contextSnapshotID": appState.currentSession?.contextSnapshotID ?? "",
            ])
        }
        if let generationID = appState.activeGenerationID,
           seenGenerationIDs.insert(generationID).inserted {
            emit("generation.started", [
                "sessionID": sessionID,
                "questionID": appState.activeQuestionID ?? "",
                "generationID": generationID,
                "contextSnapshotID": appState.currentSession?.contextSnapshotID ?? "",
            ])
        }
        let visibleSuggestions = HirevaVerificationEventPolicy.orderedUniqueCandidates(
            history: appState.liveSuggestionHistory,
            current: appState.currentSuggestion,
            id: \.id
        )
        for suggestion in visibleSuggestions where HirevaVerificationEventPolicy.recordsVisibleSuggestion(
            stageBStatus: suggestion.stageBStatus,
            finalVisibleSource: suggestion.finalVisibleSource
        ) && seenSuggestionIDs.insert(suggestion.id).inserted {
            emit("suggestion.visible", [
                "sessionID": suggestion.sessionID,
                "suggestionID": suggestion.id,
                "questionID": suggestion.detectedQuestionID ?? "",
                "generationID": suggestion.generationID ?? "",
                "contextSnapshotID": suggestion.contextSnapshotID ?? "",
                "questionText": suggestion.questionText ?? "",
                "answer": suggestion.sayFirst,
                "answerProvider": suggestion.finalVisibleSource ?? suggestion.sayFirstSource ?? "",
                "alignmentVerdict": HirevaVerificationEventPolicy.alignmentVerdictValue(
                    suggestion.alignmentVerdict
                ),
            ])
        }

        let trace = appState.lastTranscriptQuestionGenerationTrace
        let traceKey = "\(trace.transcriptSegmentID)|\(trace.triggerDecision)|\(trace.detectedQuestionID ?? "")|\(trace.generationID ?? "")|\(trace.ignoredReason)"
        if !trace.transcriptSegmentID.isEmpty, traceKey != lastTraceKey {
            lastTraceKey = traceKey
            emit("dialogue.decision", [
                "sessionID": sessionID,
                "segmentID": trace.transcriptSegmentID,
                "triggerDecision": trace.triggerDecision,
                "triggerReason": trace.triggerReason,
                "suppressionReason": trace.suppressionReason,
                "ignoredReason": trace.ignoredReason,
                "questionID": trace.detectedQuestionID ?? "",
                "generationID": trace.generationID ?? "",
                "speaker": trace.speaker,
                "source": trace.source,
                "asrProvider": trace.asrSource,
            ])
        }

        let persistenceCount = appState.diagnosticSuggestionRowCount
        if persistenceCount != lastPersistenceCount {
            lastPersistenceCount = persistenceCount
            emit("sqlite.suggestion_count", [
                "sessionID": sessionID,
                "count": persistenceCount,
                "latestQuestion": appState.diagnosticLatestSuggestionQuestionText,
            ])
        }
        if let error = appState.errorMessage, !error.isEmpty, error != lastError {
            lastError = error
            emit("app.error", ["error": error, "sessionID": sessionID])
        }
    }

    // Numeric-only control observation through the existing bounded owner.
    // No repository query, text, polling task or mirrored business state.
    private func emitWorkCounts(_ appState: AppState) {
        let generations = appState.generationCoordinator
        let live = appState.liveInterview.detectionTaskCounts
        let documents = appState.documentsState
        let embeddings = documents.embeddings
        let prefetch = appState.liveRAGPrefetch
        let generationPending = generations.pendingCleanupTaskCount
        let generationRetiring = generations.retiringTaskCount
        let importsRetiring = documents.retiringImportTaskCount
        let prefetchActive = prefetch.currentTask == nil ? 0 : 1
        var fields: [String: Any] = [
            "workMetricsMonotonicNS": DispatchTime.now().uptimeNanoseconds,
            "verificationPendingTasks": pendingWorkerCount,
            "generationActiveTasks": generationPending - generationRetiring,
            "generationRetiringTasks": generationRetiring,
            "generationPendingTasks": generationPending,
            "liveDetectionActiveTasks": live.active,
            "liveDetectionRetiringTasks": live.retiring,
            "liveDetectionPendingTasks": live.active + live.retiring,
            "capturePendingTasks": appState.captureLifecycle.pendingTaskCount,
            "captureRetiringRecords": appState.captureLifecycle.retiringTaskCount,
            "captureFailedTeardownRecords": appState.captureLifecycle.failedTeardownCount,
            "documentImportActiveTasks": documents.importTask == nil ? 0 : 1,
            "documentImportRetiringTasks": importsRetiring,
            "documentImportPendingTasks": documents.pendingImportTaskCount,
            "documentEmbeddingActiveTasks": embeddings.activeTaskCount,
            "documentEmbeddingRetiringTasks": embeddings.retiringTaskCount,
            "documentEmbeddingPendingTasks": embeddings.pendingTaskCount,
            "ragPrefetchActiveTasks": prefetchActive,
            "ragPrefetchRetiringTasks": prefetch.pendingTaskCount - prefetchActive,
            "ragPrefetchPendingTasks": prefetch.pendingTaskCount,
            "localParakeetOwnerVisible": appState.activeASRProviderRuntime is LocalParakeetASRProvider ? 1 : 0,
            "diagnosticSamplingIdentityCount": appState.diagnosticsState.sampledIdentityCount,
            "diagnosticSamplingIdentityCapacity": DiagnosticsState.retainedEventLimit,
            "diagnosticSamplingIdentityEvictions": appState.diagnosticsState.sampledIdentityEvictionCount,
        ]
        if let provider = appState.activeASRProviderRuntime as? LocalParakeetASRProvider {
            // Teardown closures can retain original tasks after public slots
            // clear. Existing presence is accurate; a guessed total is not.
            fields["parakeetOwnedWorkPresent"] = provider.hasOwnedTranscriptionWork ? 1 : 0
            fields["parakeetCleanupFailurePresent"] = provider.captureCleanupFailure == nil ? 0 : 1
        }
        emit("work_counts", fields)
    }

    private func emitStatus(_ appState: AppState) {
        emit("status", [
            "sessionID": appState.currentSession?.id ?? "",
            "captureState": appState.currentCaptureRuntimeState.displayName,
            "systemCaptureRunning": appState.systemCaptureRunning,
            "activeASRProvider": appState.activeASRProviderID?.rawValue ?? "",
            "questionID": appState.activeQuestionID ?? "",
            "generationID": appState.activeGenerationID ?? "",
            "suggestionID": appState.currentSuggestion?.id ?? "",
            "suggestionRows": appState.diagnosticSuggestionRowCount,
        ])
    }

    func recordLocalAnswerEvent(_ event: GenerationCoordinator.LocalAnswerEvent,
        identity: GenerationIdentity, persistenceTicket: Int) {
        switch event {
        case .requestStarted, .streamCompleted: break
        default: return
        }
        guard hasAdmission, let appState, let configuration, let writer,
              appState.settings.effectiveDiagnosticTraceMode == .fullText,
              let data = try? Data(contentsOf: configuration.scenarioURL),
              let scenario = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              scenario["synthetic"] as? Bool == true,
              scenario["runID"] as? String == configuration.runID else { return }
        let name: String, launchID: UUID, requestIndex: Int, attempt: Int
        var fields: [String: Any] = ["runID": configuration.runID, "sessionID": identity.sessionID,
            "questionID": identity.acceptedQuestionID, "generationID": identity.generationID]
        fields["contextSnapshotID"] = identity.contextSnapshotID
        switch event {
        case .requestStarted(let request, let launch, let index, let ordinal):
            // Prepared components precede provider readiness and are not an HTTP receipt.
            (name, launchID, requestIndex, attempt) = ("local_answer.request_prepared", launch, index, ordinal)
            fields["prompt"] = request.prompt
            fields["systemPrompt"] = request.systemPrompt
            fields["modelName"] = request.modelName
            fields["temperature"] = request.temperature
            fields["numPredict"] = request.numPredict
            fields["responseFormat"] = request.responseFormat
            fields["responseSchemaPropertyOrder"] = request.responseSchemaPropertyOrder
            fields["thinkingEnabled"] = request.thinkingEnabled
            if let schema = request.responseSchema {
                guard let encoded = try? JSONEncoder().encode(schema),
                      let object = try? JSONSerialization.jsonObject(with: encoded, options: .fragmentsAllowed) else { return }
                fields["responseSchema"] = object
            }
        case .streamCompleted(let formal, let launch, let index, let ordinal):
            (name, launchID, requestIndex, attempt) = ("local_answer.formal_stream_completed", launch, index, ordinal)
            fields["formalResponse"] = formal
        default: return
        }
        fields["launchID"] = launchID.uuidString
        fields["requestIndex"] = requestIndex
        fields["attempt"] = attempt
        // No suspension or publication between the original consent ticket and write.
        try? appState.persistenceConsent.write(ticket: persistenceTicket) {
            guard hasAdmission, appState.settings.effectiveDiagnosticTraceMode == .fullText,
                  appState.currentSession?.id == identity.sessionID,
                  appState.generationCoordinator.canPublish(identity),
                  let active = appState.generationCoordinator.activeGeneration,
                  active.persistenceTicket == persistenceTicket,
                  active.stageALaunchID == launchID else { return }
            writer.write(event: name, fields: fields)
        }
    }

    private func emit(_ event: String, _ fields: [String: Any] = [:]) {
        guard !closed, appState?.isShuttingDown != true,
              let settings = appState?.settings,
              let permitted = HirevaVerificationEventPolicy.fieldsForLogging(fields, settings: settings) else { return }
        writer?.write(event: event, fields: permitted)
    }

    private func iso8601(_ date: Date?) -> String {
        guard let date else { return "" }
        return ISO8601DateFormatter().string(from: date)
    }
}

private final class HirevaVerificationEventWriter {
    private let fileHandle: FileHandle
    private let encoder = JSONEncoder()
    private var closed = false

    init(configuration: HirevaVerificationConfiguration) throws {
        let url = configuration.outputDirectory.appendingPathComponent("app_verification_events.jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fileHandle = try FileHandle(forWritingTo: url)
    }

    deinit {
        try? fileHandle.close()
    }

    func write(event: String, fields: [String: Any]) {
        guard !closed else { return }
        var payload = fields
        payload["event"] = event
        payload["timestamp"] = ISO8601DateFormatter().string(from: Date())
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return
        }
        fileHandle.write(data)
        fileHandle.write(Data([0x0A]))
        try? fileHandle.synchronize()
    }

    func close() -> Bool {
        guard !closed else { return true }
        do {
            try fileHandle.close()
            closed = true
            return true
        } catch { return false }
    }
}

private struct HirevaAppVerificationScenario: Decodable {
    let synthetic: Bool
    let runID: String
    let asrProvider: String
    let answerProvider: String
    let qwenModel: String
    let parakeetContextBiasEnabled: Bool?
    let diagnosticTraceMode: String
    let candidateProfile: VerificationCandidateProfile
    let opportunityContext: VerificationOpportunityContext

    var domain: InterviewDomainID {
        get throws {
            guard let domain = InterviewDomainID(rawValue: candidateProfile.domain) else {
                throw VerificationBootstrapError.invalidScenario("Unsupported interview domain: \(candidateProfile.domain)")
            }
            return domain
        }
    }
}

private struct VerificationCandidateProfile: Decodable {
    let id: String
    let displayName: String
    let domain: String
    let evidence: [VerificationEvidence]

}

private struct VerificationOpportunityContext: Decodable {
    let id: String
    let title: String
    let evidence: [VerificationEvidence]

}

private struct VerificationEvidence: Decodable {
    let id: String
    let type: String
    let statement: String

}

private enum VerificationBootstrapError: LocalizedError {
    case invalidScenario(String)
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidScenario(let reason), .captureFailed(let reason): return reason
        }
    }
}

private enum VerificationWorkerScope {
    struct Identity: Sendable {
        let ownerID: UUID
        let workerID: UUID
    }
    @TaskLocal static var current: Identity? = nil
}
