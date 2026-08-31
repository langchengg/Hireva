import AppKit
import CryptoKit
import Foundation
import NaturalLanguage

enum HirevaVerificationEventPolicy {
    private static let allowedFieldsByEvent: [String: Set<String>] = [
        "bootstrap.started": ["runID", "databaseLocation", "scenarioSHA256"],
        "bootstrap.configured": ["asrProvider", "answerProvider", "candidateProfileID", "opportunityContextID"],
        "bootstrap.failed": ["errorCode"],
        "control.next_session.requested": [],
        "control.next_session.failed": ["errorCode"],
        "control.stopped": [],
        "verification.finished": ["suggestionRows", "databaseLocation", "systemCaptureRunning"],
        "control.rejected": ["actionCode"],
        "bootstrap.ready": ["sessionID", "contextSnapshotID", "activeASRProvider", "systemCaptureRunning"],
        "sck.first_buffer": ["sessionID", "totalBuffers", "sampleRate", "channelCount", "lastBufferAt"],
        "asr.transcript": ["sessionID", "segmentID", "textCharacters", "textWords", "source", "speaker", "asrProvider", "isFinal", "finalizationReason"],
        "question.accepted": ["sessionID", "questionID", "questionCharacters", "contextSnapshotID"],
        "generation.started": ["sessionID", "questionID", "generationID", "contextSnapshotID"],
        "suggestion.visible": ["sessionID", "suggestionID", "questionID", "generationID", "contextSnapshotID", "matchedTurnID", "answerCharacters", "answerProvider", "alignmentVerdict"],
        "dialogue.decision": ["sessionID", "segmentID", "triggerDecision", "questionID", "generationID", "speaker", "source", "asrProvider"],
        "sqlite.suggestion_count": ["sessionID", "count", "latestQuestionCharacters"],
        "app.error": ["errorCode", "sessionID"],
        "status": ["sessionID", "captureState", "systemCaptureRunning", "activeASRProvider", "questionID", "generationID", "suggestionID", "suggestionRows"],
    ]

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

    static func allows(event: String, fields: [String: Any]) -> Bool {
        guard let allowedFields = allowedFieldsByEvent[event] else { return false }
        return Set(fields.keys) == allowedFields
    }

    static func verificationTurnID(sessionID: String, turnIndex: Int) -> String {
        "\(sessionID).\(turnIndex)"
    }

    static func expectedTurnMatch(
        sessionID: String,
        turnIndex: Int,
        expectedShouldTrigger: Bool,
        isRapid _: Bool,
        expectedQuestionNeedle: String?
    ) -> (turnID: String, needle: String)? {
        guard expectedShouldTrigger,
              let expectedQuestionNeedle,
              !expectedQuestionNeedle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return (verificationTurnID(sessionID: sessionID, turnIndex: turnIndex), expectedQuestionNeedle)
    }

    static func questionContainsExpectedNeedle(question: String, needle: String) -> Bool {
        let questionTokens = verificationComparisonTokens(question)
        let needleTokens = verificationComparisonTokens(needle)
        guard !needleTokens.isEmpty, questionTokens.count >= needleTokens.count else {
            return false
        }
        for start in 0...(questionTokens.count - needleTokens.count) {
            let end = start + needleTokens.count
            if questionTokens[start..<end].elementsEqual(needleTokens) {
                return true
            }
        }
        return false
    }

    private static func verificationComparisonTokens(_ text: String) -> [String] {
        let normalized = verificationComparisonText(text)
        guard !normalized.isEmpty else { return [] }

        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = normalized
        tagger.setLanguage(.english, range: normalized.startIndex..<normalized.endIndex)

        var tokens: [String] = []
        tagger.enumerateTags(
            in: normalized.startIndex..<normalized.endIndex,
            unit: .word,
            scheme: .lemma,
            options: [.omitPunctuation, .omitWhitespace, .omitOther]
        ) { tag, range in
            let original = String(normalized[range]).lowercased()
            let lemma = tag?.rawValue.lowercased()
            if let lemma, !lemma.isEmpty {
                tokens.append(lemma)
            } else {
                tokens.append(original)
            }
            return true
        }
        return tokens
    }

    private static func verificationComparisonText(_ text: String) -> String {
        var result = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        guard let regex = try? NSRegularExpression(
            pattern: #"(?<![\p{L}\p{N}])\d[\d,]*(?:\.\d+)?(?![\p{L}\p{N}])"#
        ) else {
            return QuestionTextUtilities.collapse(result)
        }

        let decimal = NumberFormatter()
        decimal.locale = Locale(identifier: "en_US_POSIX")
        decimal.numberStyle = .decimal
        decimal.isLenient = false

        let spellOut = NumberFormatter()
        spellOut.locale = Locale(identifier: "en_US")
        spellOut.numberStyle = .spellOut

        let range = NSRange(location: 0, length: (result as NSString).length)
        for match in regex.matches(in: result, range: range).reversed() {
            let token = (result as NSString).substring(with: match.range)
            guard let number = decimal.number(from: token),
                  let words = spellOut.string(from: number) else {
                continue
            }
            result = (result as NSString).replacingCharacters(in: match.range, with: words)
        }
        return QuestionTextUtilities.collapse(result)
    }

    static func finalizationReasonCode(_ reason: String?) -> String {
        switch reason {
        case "partial": return "partial"
        case "stable_partial": return "stable_partial"
        case "final", "final_accepted", "final is longer or similar": return "final_accepted"
        case "final empty but partial meaningful": return "partial_used_for_empty_final"
        case "final much shorter than recent partial": return "partial_used_for_short_final"
        case nil, "": return "unspecified"
        default: return "other"
        }
    }

    static func appErrorCode(
        systemAudioPermissionState: ScreenSystemAudioPermissionState
    ) -> String {
        switch systemAudioPermissionState {
        case .granted:
            "app_reported_error"
        case .permissionMissing:
            "screen_audio_permission_missing"
        case .restartLikely:
            "screen_audio_restart_required"
        case .identityMismatch:
            "screen_audio_identity_mismatch"
        case .shareableContentProbeFailed:
            "screen_audio_shareable_probe_failed"
        case .streamAudioProbeFailed:
            "screen_audio_stream_probe_failed"
        }
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
        guard HirevaVerificationConfiguration.isRequested else { return }
        guard let configuration = HirevaVerificationConfiguration.current else {
            preconditionFailure("Hireva verification configuration is invalid.")
        }
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
    private var expectedVisibleQuestionMatches: [(turnID: String, needle: String)] = []

    func start(appState: AppState, configuration: HirevaVerificationConfiguration) {
        guard !started else { return }
        started = true
        self.appState = appState
        self.configuration = configuration

        do {
            writer = try HirevaVerificationEventWriter(configuration: configuration)
            emit("bootstrap.started", [
                "runID": configuration.runID,
                "databaseLocation": "isolated_verification_support",
                "scenarioSHA256": configuration.scenarioSHA256,
            ])
        } catch {
            PrivacySafeLogger.verificationFailure(code: .eventLogUnavailable)
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
            let scenarioData = try Data(contentsOf: configuration.scenarioURL)
            let scenarioSHA256 = SHA256.hash(data: scenarioData)
                .map { String(format: "%02x", $0) }
                .joined()
            guard scenarioSHA256 == configuration.scenarioSHA256 else {
                throw VerificationBootstrapError.invalidScenario("Scenario changed after validation.")
            }
            let scenario = try JSONDecoder().decode(
                HirevaAppVerificationScenario.self,
                from: scenarioData
            )
            guard scenario.synthetic, scenario.runID == configuration.runID else {
                throw VerificationBootstrapError.invalidScenario("Scenario identity is not synthetic or does not match the configured run.")
            }
            guard scenario.answerProvider == "local_qwen" else {
                throw VerificationBootstrapError.invalidScenario("Verification may only select the local Qwen answer provider.")
            }
            guard scenario.diagnosticTraceMode == "metadataOnly" else {
                throw VerificationBootstrapError.invalidScenario("Verification evidence requires metadata-only diagnostic traces.")
            }
            expectedVisibleQuestionMatches = scenario.sessions.flatMap { session in
                session.turns.enumerated().compactMap { turnIndex, turn in
                    HirevaVerificationEventPolicy.expectedTurnMatch(
                        sessionID: session.id,
                        turnIndex: turnIndex,
                        expectedShouldTrigger: turn.expectedShouldTrigger,
                        isRapid: turn.rapid == true,
                        expectedQuestionNeedle: turn.expectedQuestionNeedle
                    )
                }
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
            settings.diagnosticTraceMode = .metadataOnly
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
            emit("bootstrap.failed", ["errorCode": "bootstrap_failure"])
            clearOwnedVerificationDefaults()
            appState.showError("Verification bootstrap failed. Review the synthetic scenario and local runtime prerequisites.")
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
                emit("control.next_session.failed", ["errorCode": "capture_restart_failure"])
            }
        case "stop":
            appState.stopListening(reason: .userRequested)
            await appState.captureTeardownTask?.value
            emit("control.stopped")
            clearOwnedVerificationDefaults()
        case "status":
            emitStatus(appState)
        case "finish":
            captureObservableEvents(includePartials: true)
            appState.stopListening(reason: .userRequested)
            await appState.captureTeardownTask?.value
            captureObservableEvents()
            emit("verification.finished", [
                "suggestionRows": appState.diagnosticSuggestionRowCount,
                "databaseLocation": "isolated_verification_support",
                "systemCaptureRunning": appState.systemCaptureRunning,
            ])
            clearOwnedVerificationDefaults()
        default:
            emit("control.rejected", ["actionCode": "unsupported_action"])
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
                "textCharacters": segment.text.count,
                "textWords": segment.text.split(whereSeparator: \.isWhitespace).count,
                "source": segment.source.rawValue,
                "speaker": segment.speaker.rawValue,
                "asrProvider": segment.asrSource?.rawValue ?? "unknown",
                "isFinal": segment.recognitionIsFinal ?? true,
                "finalizationReason": HirevaVerificationEventPolicy.finalizationReasonCode(
                    segment.asrFinalizationReason
                ),
            ])
        }

        if let questionID = appState.activeQuestionID,
           seenQuestionIDs.insert(questionID).inserted {
            emit("question.accepted", [
                "sessionID": sessionID,
                "questionID": questionID,
                "questionCharacters": appState.lastDetectedQuestion?.questionText.count ?? 0,
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
                "matchedTurnID": matchingTurnID(for: suggestion.questionText ?? ""),
                "answerCharacters": suggestion.sayFirst.count,
                "answerProvider": suggestion.finalVisibleSource ?? suggestion.sayFirstSource ?? "",
                "alignmentVerdict": HirevaVerificationEventPolicy.alignmentVerdictValue(
                    suggestion.alignmentVerdict
                ),
            ])
        }

        let trace = appState.lastTranscriptQuestionGenerationTrace
        let traceKey = "\(trace.transcriptSegmentID)|\(trace.triggerDecision)|\(trace.detectedQuestionID ?? "")|\(trace.generationID ?? "")"
        if !trace.transcriptSegmentID.isEmpty, traceKey != lastTraceKey {
            lastTraceKey = traceKey
            emit("dialogue.decision", [
                "sessionID": sessionID,
                "segmentID": trace.transcriptSegmentID,
                "triggerDecision": trace.triggerDecision,
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
                "latestQuestionCharacters": appState.diagnosticLatestSuggestionQuestionText.count,
            ])
        }
        if let error = appState.errorMessage, !error.isEmpty, error != lastError {
            lastError = error
            emit("app.error", [
                "errorCode": HirevaVerificationEventPolicy.appErrorCode(
                    systemAudioPermissionState: appState.systemAudioPermissionState
                ),
                "sessionID": sessionID,
            ])
        }
    }

    private func emitStatus(_ appState: AppState) {
        emit("status", [
            "sessionID": appState.currentSession?.id ?? "",
            "captureState": appState.currentCaptureRuntimeState.id,
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

    private func clearOwnedVerificationDefaults() {
        guard let suiteName = configuration?.userDefaultsSuiteName,
              let defaults = UserDefaults(suiteName: suiteName) else { return }
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func matchingTurnID(for question: String) -> String {
        return expectedVisibleQuestionMatches.first { candidate in
            HirevaVerificationEventPolicy.questionContainsExpectedNeedle(
                question: question,
                needle: candidate.needle
            )
        }?.turnID ?? ""
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
        guard HirevaVerificationEventPolicy.allows(event: event, fields: fields) else { return }
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
    let sessions: [VerificationSession]

    var domain: InterviewDomainID {
        get throws {
            guard let domain = InterviewDomainID(rawValue: candidateProfile.domain) else {
                throw VerificationBootstrapError.invalidScenario("Unsupported interview domain: \(candidateProfile.domain)")
            }
            return domain
        }
    }
}

private struct VerificationSession: Decodable {
    let id: String
    let turns: [VerificationTurn]
}

private struct VerificationTurn: Decodable {
    let expectedShouldTrigger: Bool
    let rapid: Bool?
    let expectedQuestionNeedle: String?
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
