import Combine
import Foundation
import Testing
import os
@testable import Hireva

/// Characterizes the existing application constructor before a pure assembly
/// move. These cases do not call bootstrap(), native capture or any network.
@MainActor
struct AppCompositionConstructionTests {
    @Test(.timeLimit(.minutes(1)))
    func injectedAuthoritiesAndQuestionServiceUseTheExactProvidedGraph() async throws {
        let database = try AppDatabase(inMemory: true)
        let suite = "com.langcheng.Hireva.tests.composition-overrides." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let permissions = HermeticPermissionService()
        let capture = ScreenCaptureKitSystemAudioCaptureService()
        let granted = ScreenSystemAudioPermissionProbeResult(preflightGranted: true,
            shareableContentProbeSucceeded: true, streamAudioProbeSucceeded: true,
            errorDescription: nil, likelyIdentityMismatch: false)
        let systemPermissions = SystemAudioPermissionController(permissions: permissions,
            initialSnapshot: permissions.snapshot(), initialProbeResult: granted,
            probe: { granted }, stopProbe: {}, diagnosticCaptureService: capture)
        let keychain = KeychainService(store: InMemoryMockKeychainStore())
        let repository = SettingsRepository(database: database)
        let client = CompositionCharacterizationClient()
        let router = LLMRouter(settingsRepository: repository, clients: [.deepSeek: client])
        let retrieval = SimpleContextRetrievalService(documentRepository: DocumentRepository(database: database))
        let routing = HermeticQuestionRoutingProvider()
        defaults.set(InterviewContextMode.phdRobotics.rawValue, forKey: DialogueSettingsStore.contextModeKey)
        defaults.set(InterviewSessionMode.presentation.rawValue, forKey: DialogueSettingsStore.sessionModeKey)
        defaults.set("synthetic-caller-marker", forKey: "compositionCallerMarker")
        let app = AppState(database: database, questionRoutingProvider: routing, llmRouter: router,
            permissionService: permissions, systemAudioPermissions: systemPermissions,
            keychainService: keychain, contextRetrievalService: retrieval,
            systemAudioCaptureService: capture, verificationMocksEnabled: false,
            defaultAppSection: .sessions, dialogueDefaults: defaults)
        do {
            await app.automaticContextBuildTask?.value
            try Task.checkCancellation()
            #expect(app.database === database)
            #expect(app.permissionService === permissions)
            #expect(app.systemAudioCaptureService === capture)
            #expect(app.systemAudioPermissions === systemPermissions)
            #expect(app.keychainService === keychain)
            #expect(app.llmRouter === router)
            #expect((app.contextRetrievalService as? SimpleContextRetrievalService) === retrieval)
            #expect(app.dialogueDefaults === defaults)
            #expect(app.questionRoutingProvider?.id == routing.id)
            #expect(app.interviewContextMode == .phdRobotics)
            #expect(app.interviewSessionMode == .presentation)
            #expect(app.selectedSection == .home, "Section overrides retain their existing verification-mocks boundary.")
            #expect(app.generationCoordinator.dependencies.suggestionGenerationService === app.suggestionGenerationService)
            var configuration = LLMProviderConfiguration.deepSeekDefault(model: "synthetic-composition-model")
            configuration.baseURL = "https://synthetic.invalid"
            configuration.name = "Synthetic composition transport"
            let result = try await app.questionDetectionService.detect(
                transcriptContext: CompositionCharacterizationClient.question,
                sessionID: "synthetic-composition-session", transcriptSegmentID: nil,
                providerConfiguration: configuration)
            #expect(client.chatConfigurations == [configuration],
                "The real constructed question service must call the injected router, not create another client graph.")
            #expect(result.question.questionText == CompositionCharacterizationClient.question)
            #expect(result.question.modelName == configuration.model)
            #expect(result.question.providerName == configuration.name)
            #expect(result.response.content == CompositionCharacterizationClient.response)
            await app.shutdownForTesting()
            #expect(defaults.string(forKey: "compositionCallerMarker") == "synthetic-caller-marker")
            try database.close()
            defaults.removePersistentDomain(forName: suite)
        } catch {
            await app.shutdownForTesting()
            try? database.close()
            defaults.removePersistentDomain(forName: suite)
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func defaultRetrievalAndFeatureSubscriptionsShareTheApplicationFacts() async throws {
        let database = try AppDatabase(inMemory: true)
        let suite = "com.langcheng.Hireva.tests.composition-defaults." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let observations = CompositionCharacterizationObservations()
        let app = AppState(database: database, questionRoutingProvider: HermeticQuestionRoutingProvider(),
            permissionService: HermeticPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()),
            verificationMocksEnabled: false, dialogueDefaults: defaults,
            embeddingProviderResolverOverride: { settings in
                observations.embeddingModels.append(settings.embeddingModelName)
                return nil
            })
        let settingsOwner = app.settingsState
        let historyOwner = app.historyState
        let documentsOwner = app.documentsState
        let liveOwner = app.liveInterview
        let forwarded = app.objectWillChange.sink { observations.applicationNotifications += 1 }
        do {
            await app.automaticContextBuildTask?.value
            try Task.checkCancellation()
            let externalDocuments = DocumentRepository(database: database)
            let savedDocument = try externalDocuments.saveDocument(type: .cv,
                title: "Synthetic composition database note",
                content: "Database transaction atomicity commits every operation together or rolls back every operation together. A controlled synthetic example checks the consistent state after a simulated failure.")
            let beforeDocuments = observations.applicationNotifications
            try documentsOwner.reload()
            #expect(app.documents.contains { $0.id == savedDocument.id })
            #expect(observations.applicationNotifications > beforeDocuments,
                "Compatibility observers retain the exact document owner subscription.")
            let savedSession = try SessionRepository(database: database).createSession(mode: .mock,
                title: "Synthetic composition history")
            let beforeHistory = observations.applicationNotifications
            try historyOwner.refreshSessions()
            #expect(app.sessions.contains { $0.id == savedSession.id })
            #expect(observations.applicationNotifications > beforeHistory)
            var original = app.settings
            original.enableVectorRAG = false
            original.embeddingProviderKind = .disabled
            original.embeddingModelName = "synthetic-frozen-composition-embedding"
            app.settings = original
            let callsBeforeFreeze = observations.embeddingModels.count
            let frozen = app.contextRetrievalService.freezeConfiguration()
            #expect(observations.embeddingModels.count == callsBeforeFreeze + 1)
            #expect(observations.embeddingModels.last == original.embeddingModelName)
            var replacement = original
            replacement.embeddingModelName = "synthetic-replacement-composition-embedding"
            app.settings = replacement
            let callsBeforeRetrieve = observations.embeddingModels.count
            let output = try await frozen.retrieveContextWithTrace(
                question: "Explain database transaction atomicity.", intent: .technical,
                maxCVWords: 100, maxJDWords: 100)
            #expect(output.context.cvChunks.contains { $0.documentID == savedDocument.id })
            #expect(observations.embeddingModels.count == callsBeforeRetrieve,
                "The default assembled Hybrid service must retain the submitted settings/provider pair.")
            #expect(app.settings.embeddingModelName == replacement.embeddingModelName)
            let beforeLive = observations.applicationNotifications
            liveOwner.liveState = .transcribing
            #expect(app.liveState == .transcribing)
            #expect(app.diagnostics.liveState == .transcribing,
                "The committed Live value must still drive the existing diagnostic reaction.")
            #expect(observations.applicationNotifications > beforeLive)
            #expect(app.settingsState === settingsOwner)
            #expect(app.historyState === historyOwner)
            #expect(app.documentsState === documentsOwner)
            #expect(app.liveInterview === liveOwner)
            forwarded.cancel()
            await app.shutdownForTesting()
            try database.close()
            defaults.removePersistentDomain(forName: suite)
        } catch {
            forwarded.cancel()
            await app.shutdownForTesting()
            try? database.close()
            defaults.removePersistentDomain(forName: suite)
            throw error
        }
    }
}

@MainActor
private final class CompositionCharacterizationObservations {
    var applicationNotifications = 0
    var embeddingModels: [String] = []
}

private final class CompositionCharacterizationClient: LLMClientProtocol {
    let providerKind: LLMProviderKind = .deepSeek
    private let configurations = OSAllocatedUnfairLock(initialState: [LLMProviderConfiguration]())
    var chatConfigurations: [LLMProviderConfiguration] { configurations.withLock { $0 } }
    static let question = "Explain database transaction atomicity?"
    static let response = """
    {"should_trigger":true,"question_complete":true,"question_text":"Explain database transaction atomicity?","intent":"technical","answer_strategy":"technical_explanation","confidence":0.99,"reason":"Synthetic constructor characterization."}
    """
    func chatCompletion(configuration: LLMProviderConfiguration, messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?, options: LLMRequestOptions) async throws -> LLMChatResult {
        try Task.checkCancellation()
        configurations.withLock { $0.append(configuration) }
        return .init(content: Self.response, modelName: configuration.model, providerKind: configuration.kind,
            providerName: configuration.name, baseURL: configuration.baseURL,
            latencyMS: 0, isLocal: true, rawResponse: nil)
    }
    func testConnection(configuration: LLMProviderConfiguration) async throws -> LLMConnectionTestResult {
        throw LLMProviderError.notConfigured("Connection testing is outside this synthetic constructor fixture.")
    }
    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] {
        throw LLMProviderError.notConfigured("Model listing is outside this synthetic constructor fixture.")
    }
}
