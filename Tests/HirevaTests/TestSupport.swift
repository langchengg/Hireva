import Foundation
import Testing
import os
@testable import Hireva

final class HermeticTestASRProvider: ASRProvider {
    let id: ASRProviderID = .localParakeet
    let displayName = "Hermetic ASR"

    private struct Round: Sendable {
        let id: UUID
        let continuation: AsyncThrowingStream<TranscriptSegment, Error>.Continuation
    }
    private let state = OSAllocatedUnfairLock(initialState: Optional<Round>.none)

    var hasActiveContinuationForTesting: Bool { state.withLock { $0 != nil } }

    func isAvailable() async -> Bool { true }

    func startTranscription(config: ASRConfig) async throws -> AsyncThrowingStream<TranscriptSegment, Error> {
        let roundID = UUID()
        return AsyncThrowingStream { continuation in
            state.withLock { $0 = Round(id: roundID, continuation: continuation) }
            continuation.onTermination = { [weak self] _ in
                self?.state.withLock { current in
                    if current?.id == roundID { current = nil }
                }
            }
        }
    }

    func emit(
        text: String,
        sessionID: String,
        isFinal: Bool,
        segmentID: String = UUID().uuidString
    ) {
        let segment = TranscriptSegment(
            id: segmentID,
            sessionID: sessionID,
            source: .systemAudio,
            speaker: .interviewer,
            text: text,
            confidence: 1,
            asrSource: .localParakeetASR,
            asrFinalizationReason: isFinal ? "final_accepted" : "partial",
            recognitionIsFinal: isFinal
        )
        let continuation = state.withLock { $0?.continuation }
        continuation?.yield(segment)
    }

    func stopTranscription() async {
        let continuation = state.withLock { current in
            let captured = current?.continuation
            current = nil
            return captured
        }
        continuation?.finish()
    }
}

final class HermeticPermissionService: PermissionService {
    var currentSnapshot = PermissionSnapshot(
        microphone: .granted,
        speechRecognition: .granted,
        screenRecording: .granted,
        systemAudioCapture: .granted
    )

    override func snapshot() -> PermissionSnapshot { currentSnapshot }
    override func refreshPermissions() -> PermissionSnapshot { currentSnapshot }
    override func checkMicrophonePermission() -> MicrophonePermissionState {
        currentSnapshot.microphone == .granted ? .authorized : .denied
    }
    override func microphoneStatus() -> PermissionState { currentSnapshot.microphone }
    override func speechStatus() -> PermissionState { currentSnapshot.speechRecognition }
    override func requestMicrophone() async -> PermissionState { currentSnapshot.microphone }
    override func requestMicrophonePermission() async -> MicrophonePermissionState {
        checkMicrophonePermission()
    }
    override func requestSpeechRecognition() async -> PermissionState {
        currentSnapshot.speechRecognition
    }
    override func requestScreenRecording() {}
}

final class HermeticTestLLMClient: LLMClientProtocol, @unchecked Sendable {
    let providerKind: LLMProviderKind = .deepSeek

    func testConnection(configuration: LLMProviderConfiguration) async throws -> LLMConnectionTestResult {
        LLMConnectionTestResult(success: true, message: "Hermetic provider ready", latencyMS: 0, models: [])
    }

    func chatCompletion(
        configuration: LLMProviderConfiguration,
        messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions
    ) async throws -> LLMChatResult {
        let prompt = messages.map(\.content).joined(separator: "\n")
        let content = Self.response(for: prompt, responseFormat: responseFormat)
        return LLMChatResult(
            content: content,
            modelName: "hermetic-test-model",
            providerKind: .deepSeek,
            providerName: "Hermetic Test Provider",
            baseURL: "test://local",
            latencyMS: 0,
            isLocal: false,
            rawResponse: content
        )
    }

    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] { [] }

    func chatCompletionStream(
        configuration: LLMProviderConfiguration,
        messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?,
        options: LLMRequestOptions
    ) -> AsyncThrowingStream<String, Error> {
        let content = Self.response(
            for: messages.map(\.content).joined(separator: "\n"),
            responseFormat: responseFormat
        )
        return AsyncThrowingStream { continuation in
            continuation.yield(content)
            continuation.finish()
        }
    }

    private static func response(for prompt: String, responseFormat: LLMResponseFormat?) -> String {
        if prompt.contains("Decide whether the interviewer has asked") {
            return """
            {
              "should_trigger": true,
              "question_complete": true,
              "question_text": "What did you learn from debugging the service?",
              "intent": "technical",
              "answer_strategy": "technical_explanation",
              "confidence": 0.95,
              "reason": "Deterministic test response."
            }
            """
        }
        if responseFormat == .jsonObject {
            return """
            {
              "strategy": "Evidence-based technical answer",
              "say_first": "I investigated the service failure with logs and metrics, isolated the faulty handoff, and validated the repair with repeatable tests.",
              "key_points": ["Used observable evidence to isolate the fault.", "Validated the repair with repeatable tests."],
              "follow_up_ready": ["I can explain the validation steps."],
              "confidence": 0.9,
              "caution": "Use only the evidence in the active synthetic profile.",
              "evidence_used": [],
              "risk_level": "low"
            }
            """
        }
        return "I investigated the service failure with logs and metrics, isolated the faulty handoff, and validated the repair with repeatable tests."
    }
}

enum TestSupport {
    // Scripted answer providers preserve their supplied text under the actual wire contract.
    static func scriptedLocalAnswer(_ answer: String, request: LocalLLMRequest) throws -> String {
        guard !answer.isEmpty, request.responseSchema == LocalQwenAnswerParser.scopedResponseSchema else { return answer }
        return String(decoding: try JSONEncoder().encode(["scoped_claim": answer, "say_first": answer]), as: UTF8.self)
    }

    static var realAppDatabaseTestsEnabled: Bool {
        ProcessInfo.processInfo.environment["REAL_APP_DB_TESTS"] == "1"
    }

    static func makeTemporaryDatabase(prefix: String = "HirevaTests") throws -> AppDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AppDatabase(path: directory.appendingPathComponent("test.sqlite"))
    }

    /// Each fixture still runs every migration on its own queue. Preparing that
    /// queue must not block unrelated MainActor lifecycle tests from progressing.
    static func makeInMemoryDatabase() async throws -> sending AppDatabase {
        try await makeDatabase()
    }

    /// Keep the supplied file URL and migrations; only queue preparation moves.
    static func makeDatabase(at path: URL? = nil) async throws -> sending AppDatabase {
        try Task.checkCancellation()
        let trace = TestEventWaitTrace(label: "fixture.database.preparation")
        trace.mark("requested")
        let database: AppDatabase = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                precondition(!Thread.isMainThread)
                trace.mark("worker.entered")
                do {
                    let database: AppDatabase
                    if let path { database = try AppDatabase(path: path) }
                    else { database = try AppDatabase(inMemory: true) }
                    trace.mark("worker.completed")
                    continuation.resume(returning: database)
                }
                catch { continuation.resume(throwing: error) }
            }
        }
        trace.mark("transferred")
        do { try Task.checkCancellation() }
        catch { try? database.close(); throw error }
        return database
    }

    static func makeEvidence(
        id: String,
        statement: String,
        type: EvidenceType,
        documentID: String
    ) -> ProfileEvidence {
        ProfileEvidence(
            id: id,
            statement: statement,
            sourceDocumentID: documentID,
            sourceChunkID: "\(id)-chunk",
            sourceSpan: statement,
            confidence: 1,
            evidenceType: type,
            explicitness: .explicit
        )
    }

    static func makeCandidateProfile(
        id: String = "test-candidate",
        documentID: String = "test-cv",
        statements: [String] = [
            "The candidate designed a service, investigated failures with logs and metrics, and validated the repair with repeatable tests."
        ]
    ) -> CandidateProfile {
        CandidateProfile(
            id: id,
            displayName: "Synthetic Test Candidate",
            sourceDocumentIDs: [documentID],
            education: [],
            experience: statements.enumerated().map { index, statement in
                makeEvidence(
                    id: "\(id)-evidence-\(index)",
                    statement: statement,
                    type: .experience,
                    documentID: documentID
                )
            },
            projects: [],
            skills: [],
            publications: [],
            achievements: [],
            declaredGaps: [],
            goals: [],
            generatedSummary: nil,
            version: 1,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    static func makeOpportunityContext(
        id: String = "test-opportunity",
        documentID: String = "test-jd",
        statements: [String] = [
            "The role requires clear technical reasoning, reliable delivery, and evidence-based debugging."
        ]
    ) -> OpportunityContext {
        OpportunityContext(
            id: id,
            title: "Synthetic Test Role",
            organisation: "Test Organisation",
            opportunityType: .job,
            responsibilities: statements.enumerated().map { index, statement in
                makeEvidence(
                    id: "\(id)-evidence-\(index)",
                    statement: statement,
                    type: .responsibility,
                    documentID: documentID
                )
            },
            requiredSkills: [],
            preferredSkills: [],
            researchTopics: [],
            evaluationCriteria: [],
            sourceDocumentIDs: [documentID],
            version: 1,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}

@MainActor
final class HirevaTestEnvironment {
    let rootDirectory: URL
    let applicationSupportDirectory: URL
    let databaseURL: URL
    let userDefaultsSuiteName: String
    let userDefaults: UserDefaults
    let database: AppDatabase
    let appState: AppState
    let asrProvider: HermeticTestASRProvider

    private var isShutdown = false

    init(
        prefix: String = "HirevaTests",
        llmRouter: LLMRouter? = nil,
        permissionService: PermissionService? = nil,
        systemAudioCaptureService: ScreenCaptureKitSystemAudioCaptureService? = nil,
        systemAudioPermissions: SystemAudioPermissionController? = nil,
        candidateProfile: CandidateProfile? = nil,
        opportunityContext: OpportunityContext? = nil,
        domain: InterviewDomainID = .general
    ) async throws {
        let identifier = UUID().uuidString
        rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(identifier)", isDirectory: true)
        applicationSupportDirectory = rootDirectory
            .appendingPathComponent("Application Support", isDirectory: true)
        databaseURL = applicationSupportDirectory.appendingPathComponent("hireva.sqlite")
        userDefaultsSuiteName = "com.langcheng.Hireva.tests.\(identifier)"
        guard let defaults = UserDefaults(suiteName: userDefaultsSuiteName) else {
            throw NSError(
                domain: "HirevaTestEnvironment",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not create isolated UserDefaults suite."]
            )
        }
        userDefaults = defaults
        try FileManager.default.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true)
        do {
            database = try await TestSupport.makeDatabase(at: databaseURL)
        } catch {
            // The helper closes a transferred queue before propagating cancellation.
            // Initialization has not published an AppState; only this UUID scope exists.
            defaults.removePersistentDomain(forName: userDefaultsSuiteName)
            do { try FileManager.default.removeItem(at: rootDirectory) }
            catch let cleanupError { Issue.record(cleanupError) }
            throw error
        }
        asrProvider = HermeticTestASRProvider()
        let resolvedRouter = llmRouter ?? LLMRouter(
            settingsRepository: SettingsRepository(database: database),
            clients: [.deepSeek: HermeticTestLLMClient()]
        )
        appState = AppState(
            database: database,
            questionRoutingProvider: HermeticQuestionRoutingProvider(),
            llmRouter: resolvedRouter,
            permissionService: permissionService ?? HermeticPermissionService(),
            systemAudioPermissions: systemAudioPermissions,
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            systemAudioCaptureService: systemAudioCaptureService,
            dialogueDefaults: defaults
        )
        appState.localLLMProviderOverride = HermeticUnavailableLocalProvider()

        if let candidateProfile {
            try appState.interviewContextRepository.saveCandidateProfile(candidateProfile)
        }
        if let opportunityContext {
            try appState.interviewContextRepository.saveOpportunityContext(opportunityContext)
        }
        appState.refreshAll()
        appState.selectCandidateProfile(candidateProfile?.id)
        appState.selectOpportunityContext(opportunityContext?.id)
        appState.selectInterviewDomain(domain)
    }

    func makeContextBoundSession(
        mode: InterviewMode = .mock,
        title: String = "Hermetic Test Interview"
    ) throws -> InterviewSession {
        let session = try appState.createContextBoundSession(mode: mode, title: title)
        appState.currentSession = session
        return session
    }

    func shutdown() async throws {
        guard !isShutdown else { return }
        isShutdown = true
        await asrProvider.stopTranscription()
        await appState.shutdownForTesting()
        try database.close()
        userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
        try FileManager.default.removeItem(at: rootDirectory)
    }
}

/// A fixture must explicitly supply successful local inference; absent injection
/// is a configuration error instead of access to the machine's Ollama service.
struct HermeticUnavailableLocalProvider: LocalLLMProvider {
    let id = "hermetic-unavailable-local"
    let displayName = "Unconfigured hermetic local provider"
    func healthCheck(modelName: String) async -> LocalLLMHealth {
        .init(ollamaRunning: false, selectedModel: modelName, modelInstalled: false,
            providerSource: .localQwen, lastError: "No local fixture provider was supplied.")
    }
    func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        AsyncThrowingStream { $0.finish(throwing: LLMProviderError.notConfigured(displayName)) }
    }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        throw LLMProviderError.notConfigured(displayName)
    }
}

/// Explicit transport stub for existing lifecycle/ownership tests. It retains
/// their legacy routing fixture semantics; it is NOT a classification quality
/// or installed-model test. Native quality evaluations use real Ollama.
struct HermeticQuestionRoutingProvider: LocalLLMProvider {
    var documentedIntegrationFixture = false
    var id: String { "hermetic-routing-only" }
    var displayName: String { id }
    func healthCheck(modelName: String) async -> LocalLLMHealth {
        .init(ollamaRunning: true, selectedModel: modelName, modelInstalled: true, providerSource: .localQwen, lastError: nil)
    }
    func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> { AsyncThrowingStream { $0.finish() } }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        let input = try JSONSerialization.jsonObject(with: Data(request.prompt.utf8)) as? [String: Any]
        let questionText = input?["question"] as? String ?? ""
        var task = InterviewTaskDescriptor(question: questionText)
        // Preserve the established domain rubric metadata in these synthetic
        // lifecycle fixtures; production classification is tested separately.
        if let academic = PhDInterviewRubricPolicy.intent(for: questionText),
           [.preMScBackground, .llmVlmExperience, .skillFit, .tactileExperience, .realRobotExperience, .robotArchitecture, .rosControl].contains(academic) {
            task = InterviewTaskDescriptor(question: questionText, kind: .project)
            task.requiresPersonalEvidence = true
        }
        if documentedIntegrationFixture && AnswerRelevancePolicy.intent(for: questionText) == .systemIntegrationDebugging {
            // These established lifecycle scenarios supply a documented past
            // integration incident. Keep that fixture metadata explicit rather
            // than letting the old "debug" keyword suppress their source pool.
            task = InterviewTaskDescriptor(question: questionText, kind: .project)
            task.requiresPersonalEvidence = true
        }
        let personal = PromptContextBuilder.usesProfileContext(task)
        // These legacy lifecycle fixtures do not grade classification. Unknown
        // test metadata permits source-checked optional examples; it must not
        // suppress the fixture's supplied facts or claim automatic accuracy.
        let evidence: PersonalEvidenceRequirement = task.kind == .unknown ? .optional : (personal ? .required : .notRequired)
        let wire = InterviewQuestionRouter.Wire(task: task.kind, personalEvidence: evidence,
            basis: evidence == .optional ? .mixed : (personal ? .candidateRecord : .generalKnowledge), relation: .independent, clarification: "")
        let text = String(decoding: try JSONEncoder().encode(wire), as: UTF8.self)
        return AsyncThrowingStream { continuation in
            continuation.yield(.init(text: text, source: .localQwen, modelName: request.modelName))
            continuation.finish()
        }
    }
}
