import AppKit
import Foundation

enum HirevaVerificationEventPolicy {
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
        opportunityStatements: [String]
    ) throws -> HirevaVerificationSeededDocuments {
        let candidate = try repository.saveDocument(
            type: .cv,
            title: "Verification Candidate CV",
            content: candidateStatements.joined(separator: "\n\n")
        )
        let opportunity = try repository.saveDocument(
            type: .jobDescription,
            title: "Verification Role Description",
            content: opportunityStatements.joined(separator: "\n\n")
        )
        return HirevaVerificationSeededDocuments(candidate: candidate, opportunity: opportunity)
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
    func runVerificationBootstrapIfRequested() {
        guard let configuration = HirevaVerificationConfiguration.current else { return }
        HirevaVerificationCoordinator.shared.start(appState: self, configuration: configuration)
    }
}

@MainActor
private final class HirevaVerificationCoordinator {
    static let shared = HirevaVerificationCoordinator()
    private static let controlNotification = Notification.Name("com.langcheng.Hireva.VerificationControl")

    private weak var appState: AppState?
    private var configuration: HirevaVerificationConfiguration?
    private var writer: HirevaVerificationEventWriter?
    private var observer: NSObjectProtocol?
    private var monitorTask: Task<Void, Never>?
    private var bootstrapTask: Task<Void, Never>?
    private var started = false
    private var seenTranscriptIDs = Set<String>()
    private var seenQuestionIDs = Set<String>()
    private var seenGenerationIDs = Set<String>()
    private var seenSuggestionIDs = Set<String>()
    private var firstBufferSessionIDs = Set<String>()
    private var lastTraceKey = ""
    private var lastPersistenceCount = 0
    private var lastError = ""

    func start(appState: AppState, configuration: HirevaVerificationConfiguration) {
        guard !started else { return }
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
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let action = notification.userInfo?["action"] as? String else { return }
            Task { @MainActor [weak self] in
                await self?.handleControl(action)
            }
        }

        monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.captureObservableEvents()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        bootstrapTask = Task { @MainActor [weak self] in
            await self?.configureAndStart()
        }
    }

    private func configureAndStart() async {
        guard let appState, let configuration else { return }
        do {
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

            appState.automaticContextBuildTask?.cancel()
            appState.automaticContextBuildID = UUID()
            _ = try HirevaVerificationDocumentSeeder.seed(
                in: appState.documentRepository,
                candidateStatements: scenario.candidateProfile.evidence.map(\.statement),
                opportunityStatements: scenario.opportunityContext.evidence.map(\.statement)
            )
            appState.refreshAll()
            await appState.rebuildAutomaticInterviewContext(useLocalQwen: false)
            guard HirevaVerificationReadinessPolicy.accepts(
                appState.automaticContextReadiness,
                hasUsableCandidateContext: appState.hasUsableCandidateContext
            ) else {
                throw VerificationBootstrapError.invalidScenario(
                    "Synthetic verification documents did not produce usable interview context."
                )
            }
            appState.selectInterviewDomain(try scenario.domain)
            appState.setSelectedAnswerProviderMode(.localQwenPrimary)
            appState.setSelectedQwenModelName(scenario.qwenModel)
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

            var settings = appState.settings
            settings.audioCaptureMode = .systemAudioOnly
            settings.automaticQuestionDetectionEnabled = true
            settings.manualOnlyMode = false
            settings.allowQuestionDetectionFromMicrophoneOnly = false
            settings.saveTranscriptsLocally = true
            settings.diagnosticTraceMode = scenario.diagnosticTraceMode == "fullText" ? .fullText : .metadataOnly
            appState.saveSettings(settings)
            appState.interviewSessionMode = .auto
            appState.detectionDebounceSeconds = 0.05
            emit("bootstrap.configured", [
                "asrProvider": scenario.asrProvider,
                "answerProvider": scenario.answerProvider,
                "candidateProfileID": appState.activeCandidateProfileID ?? "",
                "opportunityContextID": appState.activeOpportunityContextID ?? "",
            ])
            appState.startListening(mode: .microphone)
            try await waitForListening(appState)
        } catch {
            emit("bootstrap.failed", ["error": error.localizedDescription])
            appState.showError("Verification bootstrap failed: \(error.localizedDescription)")
        }
    }

    private func handleControl(_ action: String) async {
        guard let appState else { return }
        switch action {
        case "next_session":
            emit("control.next_session.requested")
            captureObservableEvents(includePartials: true)
            appState.stopListening(reason: .userRequested)
            await appState.captureTeardownTask?.value
            appState.currentSession = nil
            try? await Task.sleep(for: .milliseconds(250))
            appState.startListening(mode: .microphone)
            do {
                try await waitForListening(appState)
            } catch {
                emit("control.next_session.failed", ["error": error.localizedDescription])
            }
        case "stop":
            appState.stopListening(reason: .userRequested)
            await appState.captureTeardownTask?.value
            emit("control.stopped")
        case "status":
            emitStatus(appState)
        case "finish":
            captureObservableEvents(includePartials: true)
            appState.stopListening(reason: .userRequested)
            await appState.captureTeardownTask?.value
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
        guard let appState else { return }
        let sessionID = appState.currentSession?.id ?? ""
        let capture = ScreenCaptureKitSystemAudioCaptureService.shared
        if !sessionID.isEmpty,
           capture.totalBuffersReceived > 0,
           firstBufferSessionIDs.insert(sessionID).inserted {
            emit("sck.first_buffer", [
                "sessionID": sessionID,
                "totalBuffers": capture.totalBuffersReceived,
                "sampleRate": capture.sampleRate,
                "channelCount": capture.channelCount,
                "lastBufferAt": iso8601(capture.lastBufferReceivedAt),
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

    private func emit(_ event: String, _ fields: [String: Any] = [:]) {
        writer?.write(event: event, fields: fields)
    }

    private func iso8601(_ date: Date?) -> String {
        guard let date else { return "" }
        return ISO8601DateFormatter().string(from: date)
    }
}

private final class HirevaVerificationEventWriter {
    private let fileHandle: FileHandle
    private let encoder = JSONEncoder()

    init(configuration: HirevaVerificationConfiguration) throws {
        let url = configuration.outputDirectory.appendingPathComponent("app_verification_events.jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fileHandle = try FileHandle(forWritingTo: url)
    }

    deinit {
        try? fileHandle.close()
    }

    func write(event: String, fields: [String: Any]) {
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
}

private struct HirevaAppVerificationScenario: Decodable {
    let synthetic: Bool
    let runID: String
    let asrProvider: String
    let answerProvider: String
    let qwenModel: String
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
