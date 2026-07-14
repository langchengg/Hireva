import Foundation
@testable import Hireva

final class HermeticTestASRProvider: ASRProvider, @unchecked Sendable {
    let id: ASRProviderID = .localParakeet
    let displayName = "Hermetic ASR"

    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<TranscriptSegment, Error>.Continuation?

    func isAvailable() async -> Bool { true }

    func startTranscription(config: ASRConfig) async throws -> AsyncThrowingStream<TranscriptSegment, Error> {
        AsyncThrowingStream { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.lock.lock()
                self?.continuation = nil
                self?.lock.unlock()
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
        lock.lock()
        let continuation = self.continuation
        lock.unlock()
        continuation?.yield(segment)
    }

    func stopTranscription() async {
        let continuation = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
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
    static var realAppDatabaseTestsEnabled: Bool {
        ProcessInfo.processInfo.environment["REAL_APP_DB_TESTS"] == "1"
    }

    static func makeTemporaryDatabase(prefix: String = "HirevaTests") throws -> AppDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try AppDatabase(path: directory.appendingPathComponent("test.sqlite"))
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
        permissionService: PermissionService = HermeticPermissionService(),
        candidateProfile: CandidateProfile? = nil,
        opportunityContext: OpportunityContext? = nil,
        domain: InterviewDomainID = .general
    ) throws {
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
        database = try AppDatabase(path: databaseURL)
        asrProvider = HermeticTestASRProvider()
        let resolvedRouter = llmRouter ?? LLMRouter(
            settingsRepository: SettingsRepository(database: database),
            clients: [.deepSeek: HermeticTestLLMClient()]
        )
        appState = AppState(
            database: database,
            llmRouter: resolvedRouter,
            permissionService: permissionService,
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            dialogueDefaults: defaults
        )

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
