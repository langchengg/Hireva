import Foundation
import os
import Testing
@testable import Hireva

/// Actual Generate Recap entry, SQL repositories and source quote validation.
/// All providers are per-instance fakes; no audio, model, cloud or Keychain I/O.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct RecapEntrySnapshotTests {
    @Test
    func queuedRecapFreezesLocalProviderAndModelBeforeItsRootRuns() async throws {
        let fixture = try await RecapEntryFixture(localOnly: true)
        var roots: [Task<Void, Never>] = []
        do {
            fixture.app.generateRecap(for: fixture.session)
            roots.append(try #require(fixture.app.recapTask))
            // No suspension since submission: the MainActor recap root has not
            // read either provider or model. This keeps the configured policy;
            // the mode setter's explicit cancellation is tested independently.
            fixture.app.localLLMProviderOverride = fixture.replacement
            fixture.app.setSelectedQwenModelName("replacement-recap-model")
            try await fixture.join(try #require(roots.last))

            let original = await fixture.local.requests()
            #expect(original.count == 2, "One route and one validated recap use the submitted local provider.")
            #expect(original.allSatisfy { $0.modelName == fixture.originalModel })
            #expect(await fixture.replacement.requests().isEmpty)
            #expect(fixture.remote.configurations().isEmpty)
            let report = try #require(try fixture.app.recapRepository.recap(sessionID: fixture.session.id))
            #expect(report.modelName == fixture.originalModel)
            #expect(report.markdown.contains(fixture.answer.text))
            try await fixture.close(roots)
        } catch {
            try? await fixture.close(roots)
            throw error
        }
    }

    @Test
    func routingAwaitCannotReplaceTheSubmittedRemoteConfiguration() async throws {
        let fixture = try await RecapEntryFixture(localOnly: false, holdRouting: true)
        var roots: [Task<Void, Never>] = []
        do {
            fixture.app.generateRecap(for: fixture.session)
            roots.append(try #require(fixture.app.recapTask))
            try await fixture.routingGate.waitUntilEntered()
            var replacement = fixture.configuration
            replacement.model = "replacement-remote-recap-model"
            replacement.baseURL = "https://replacement.invalid"
            try fixture.app.settingsRepository.saveProviderConfiguration(replacement)
            fixture.routingGate.releaseAll()
            try await fixture.join(try #require(roots.last))

            #expect(fixture.remote.configurations() == [fixture.configuration])
            let report = try #require(try fixture.app.recapRepository.recap(sessionID: fixture.session.id))
            #expect(report.modelName == fixture.configuration.model)
            #expect(report.providerBaseURL == fixture.configuration.baseURL)
            #expect(report.markdown.contains(fixture.answer.text))
            try await fixture.close(roots)
        } catch {
            try? await fixture.close(roots)
            throw error
        }
    }

    @Test
    func correctedRevisionDiscardsLateOldFeedbackAndUsesItsOwnExactQuotes() async throws {
        let fixture = try await RecapEntryFixture(localOnly: false, holdRouting: true)
        var roots: [Task<Void, Never>] = []
        do {
            fixture.app.generateRecap(for: fixture.session)
            let old = try #require(fixture.app.recapTask)
            roots.append(old)
            try await fixture.routingGate.waitUntilEntered()
            let corrected = "Atomicity rolls back the entire transaction on failure."
            fixture.app.saveTranscriptCorrection(fixture.answer, text: corrected,
                speaker: .candidate, startsQuestion: false, question: "")
            fixture.routingGate.releaseAll()
            try await fixture.join(old)
            #expect(try fixture.app.recapRepository.versions(sessionID: fixture.session.id).isEmpty)
            #expect(fixture.app.selectedSessionRecap == nil)

            fixture.app.generateRecap(for: fixture.session)
            roots.append(try #require(fixture.app.recapTask))
            try await fixture.join(try #require(roots.last))
            let reports = try fixture.app.recapRepository.versions(sessionID: fixture.session.id)
            let current = try #require(reports.first)
            #expect(reports.count == 1)
            #expect(current.contentRevision == 1)
            #expect(current.markdown.contains(corrected))
            #expect(!current.markdown.contains(fixture.answer.text))
            #expect(try fixture.app.transcriptRepository.segments(sessionID: fixture.session.id).last?.text == fixture.answer.text,
                "The original ASR text stays unchanged; the recap uses the revision overlay.")
            try await fixture.close(roots)
        } catch {
            try? await fixture.close(roots)
            throw error
        }
    }
}

@MainActor
final class RecapEntryFixture {
    let database: AppDatabase
    let defaults: UserDefaults
    let suiteName = "com.langcheng.Hireva.tests.recap-entry.\(UUID().uuidString)"
    let originalModel = "original-recap-model"
    let routingGate = RecapEntryGate()
    let remote = RecapEntryRemoteClient()
    let local: RecapEntryLocalProvider
    let replacement: RecapEntryLocalProvider
    let configuration: LLMProviderConfiguration
    let app: AppState
    let session: InterviewSession
    let answer: TranscriptSegment

    init(localOnly: Bool, holdRouting: Bool = false) async throws {
        // Freeze/admission assertions share one independent real SQLite queue;
        // file durability and reopening are tested separately.
        let preparedDatabase = try await TestSupport.makeInMemoryDatabase()
        database = preparedDatabase
        var preparedDefaults: UserDefaults?
        var preparedApp: AppState?
        do {
            defaults = try #require(UserDefaults(suiteName: suiteName))
            preparedDefaults = defaults
            defaults.set((localOnly ? AnswerProviderMode.localQwenPrimary : .deepSeekPrimary).rawValue,
                forKey: HirevaPreferenceKeys.answerProviderMode)
            defaults.set(originalModel, forKey: HirevaPreferenceKeys.selectedQwenModel)
            local = RecapEntryLocalProvider(id: "submitted-recap-provider", gate: routingGate, holdRouting: holdRouting)
            replacement = RecapEntryLocalProvider(id: "replacement-recap-provider", gate: RecapEntryGate(), holdRouting: false)
            let settings = SettingsRepository(database: database)
            var value = AppSettings.default
            value.saveTranscriptsLocally = true
            value.diagnosticTraceMode = .off
            try settings.saveSettings(value)
            try settings.ensureDefaultProviderConfigurations()
            var provider = try #require(settings.providerConfigurations().first { $0.kind == .deepSeek })
            provider.name = "Synthetic recap provider"
            provider.model = "submitted-remote-recap-model"
            provider.baseURL = "https://submitted.invalid"
            provider.apiKeyAccount = nil
            try settings.saveProviderConfiguration(provider)
            try settings.setActiveRecapProvider(id: provider.id)
            configuration = try #require(try settings.providerConfiguration(id: provider.id))
            app = AppState(database: database,
                llmRouter: LLMRouter(settingsRepository: settings, clients: [.deepSeek: remote]),
                keychainService: KeychainService(store: InMemoryMockKeychainStore()), dialogueDefaults: defaults)
            preparedApp = app
            app.localLLMProviderOverride = local
            session = try app.sessionRepository.createSession(mode: .mock, title: "Synthetic recap lifecycle")
            let question = TranscriptSegment(id: "question-" + UUID().uuidString, sessionID: session.id,
                source: .mock, speaker: .interviewer, text: "Explain transaction atomicity.")
            answer = .init(id: "answer-" + UUID().uuidString, sessionID: session.id,
                source: .mock, speaker: .candidate, text: "Atomicity commits all operations together.")
            try app.transcriptRepository.saveSegment(question)
            try app.transcriptRepository.saveSegment(answer)
            app.loadSessionDetails(sessionID: session.id)
        } catch {
            await preparedApp?.shutdownForTesting()
            try? preparedDatabase.close()
            preparedDefaults?.removePersistentDomain(forName: suiteName)
            throw error
        }
    }

    func join(_ task: Task<Void, Never>) async throws {
        let trace = TestEventWaitTrace(label: "recap.owned-root-exit")
        trace.mark("join.requested")
        // Deliberately held provider gates are released by the caller before
        // joining. The suite time limit cancels this exact retained root.
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        trace.mark("join.completed")
        try Task.checkCancellation()
    }

    func close(_ roots: [Task<Void, Never>], trace: TestEventWaitTrace? = nil) async throws {
        // Release every deliberately noncooperative fixture gate BEFORE any
        // cleanup wait. A failed assertion cannot hang the shared test host.
        trace?.mark("fixture.cleanup.release.requested")
        routingGate.releaseAll()
        roots.forEach { $0.cancel() }
        trace?.mark("fixture.cleanup.release.completed")
        for (index, root) in roots.enumerated() {
            trace?.mark("fixture.cleanup.root.\(index).join.requested")
            await root.value
            trace?.mark("fixture.cleanup.root.\(index).join.completed")
        }
        trace?.mark("fixture.shutdown.requested")
        await app.shutdownForTesting()
        trace?.mark("fixture.shutdown.completed")
        try database.close()
        defaults.removePersistentDomain(forName: suiteName)
        trace?.mark("fixture.storage.close.completed")
    }
}

final class RecapEntryGate: Sendable {
    private struct State: Sendable {
        var released = false
        var pending: [CheckedContinuation<Void, Never>] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))

    func hold() async {
        await withCheckedContinuation { continuation in
            let resume = state.withLock { value in
                if value.released { return true }
                value.pending.append(continuation)
                return false
            }
            entered.continuation.yield(())
            if resume { continuation.resume() }
        }
    }

    func waitUntilEntered() async throws {
        _ = try await TestEventWaitTrace(label: "recap.provider-entry")
            .nextEvent(in: entered.stream, event: "actual-provider-entered")
    }

    func releaseAll() {
        let pending = state.withLock { value in
            value.released = true
            let result = value.pending
            value.pending.removeAll()
            return result
        }
        pending.forEach { $0.resume() }
    }
}

actor RecapEntryLocalProvider: LocalLLMProvider {
    nonisolated let id: String
    nonisolated var displayName: String { id }
    let gate: RecapEntryGate
    let holdRouting: Bool
    private var captured: [LocalLLMRequest] = []
    init(id: String, gate: RecapEntryGate, holdRouting: Bool) {
        self.id = id; self.gate = gate; self.holdRouting = holdRouting
    }
    func requests() -> [LocalLLMRequest] { captured }
    func healthCheck(modelName: String) async -> LocalLLMHealth {
        .init(ollamaRunning: true, selectedModel: modelName, modelInstalled: true,
            providerSource: .ollamaQwen, lastError: nil)
    }
    nonisolated func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        try Task.checkCancellation()
        captured.append(request)
        let routing = request.responseSchema != nil
        if routing && holdRouting { await gate.hold() }
        try Task.checkCancellation()
        let text = routing
            ? "{\"task\":\"generalKnowledge\",\"personalEvidence\":\"notRequired\",\"basis\":\"generalKnowledge\",\"relation\":\"independent\",\"clarification\":\"\"}"
            : try recapEntryFeedbackJSON(input: request.prompt)
        return AsyncThrowingStream { continuation in
            continuation.yield(.init(text: text, source: .ollamaQwen, modelName: request.modelName))
            continuation.finish()
        }
    }
}

final class RecapEntryRemoteClient: LLMClientProtocol {
    let providerKind: LLMProviderKind = .deepSeek
    private let captured = OSAllocatedUnfairLock(initialState: [LLMProviderConfiguration]())
    func configurations() -> [LLMProviderConfiguration] { captured.withLock { $0 } }
    func testConnection(configuration: LLMProviderConfiguration) async throws -> LLMConnectionTestResult {
        .init(success: true, message: "Synthetic", latencyMS: 0, models: [])
    }
    func listModels(configuration: LLMProviderConfiguration) async throws -> [LLMModelInfo] { [] }
    func chatCompletion(configuration: LLMProviderConfiguration, messages: [LLMChatMessage],
        responseFormat: LLMResponseFormat?, options: LLMRequestOptions) async throws -> LLMChatResult {
        try Task.checkCancellation()
        captured.withLock { $0.append(configuration) }
        guard let input = messages.last(where: { $0.role == "user" })?.content else {
            throw MaterialError.invalid("Synthetic recap input missing")
        }
        return .init(content: try recapEntryFeedbackJSON(input: input),
            modelName: configuration.model, providerKind: configuration.kind,
            providerName: configuration.name, baseURL: configuration.baseURL,
            latencyMS: 0, isLocal: false, rawResponse: nil)
    }
}

private func recapEntryFeedbackJSON(input: String) throws -> String {
    struct Input: Decodable { var transcript: [TranscriptSegment] }
    let unit = try JSONDecoder().decode(Input.self, from: Data(input.utf8))
    guard let candidate = unit.transcript.first(where: { $0.speaker == .candidate }) else {
        throw MaterialError.invalid("Synthetic recap candidate source missing")
    }
    let feedback = RecapUnitFeedback(observations: [.init(segmentID: candidate.id,
        quote: candidate.text, feedback: "Explain failure rollback as well.")])
    return String(decoding: try JSONEncoder().encode(feedback), as: UTF8.self)
}
