import Foundation
import Testing
@testable import Hireva

/// Requires HistoryState's transfer API. Intended to fail the transfer candidate
/// before its post-feedback identity guard; not claimed as an executed RED.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct HistoryRecapFeedbackReentryTests {
    enum Action: CaseIterable, Equatable { case cancel, replace }

    @Test(arguments: Action.allCases)
    func synchronousFailureFeedbackCannotPublishAnErrorAfterRevocation(action: Action) async throws {
        let fixture = try await RecapEntryFixture(localOnly: true)
        let gate = RecapEntryGate()
        let failing = RecapControlledFailureProvider(gate: gate)
        let history = fixture.app.historyState
        var roots: [Task<Void, Never>] = []
        var errors: [String] = []
        var failedFeedbackCount = 0
        var replacementRoot: Task<Void, Never>?
        var callbackFailure: Error?
        func cleanup() async throws {
            gate.releaseAll()
            if let replacementRoot { roots.append(replacementRoot) }
            try await fixture.close(roots)
        }
        do {
            let root = try #require(try history.requestRecap(sessionID: fixture.session.id,
                providerConfiguration: fixture.configuration, routingProvider: failing,
                routingModel: fixture.originalModel, localOnly: true, persistenceAllowed: { true },
                onFeedback: { feedback in
                    guard feedback.kind == .error else { return }
                    failedFeedbackCount += 1
                    switch action {
                    case .cancel: history.cancelRecap()
                    case .replace:
                        do {
                            replacementRoot = try history.requestRecap(sessionID: fixture.session.id,
                                providerConfiguration: fixture.configuration, routingProvider: fixture.local,
                                routingModel: fixture.originalModel, localOnly: true, persistenceAllowed: { true },
                                onFeedback: { _ in }, onError: { errors.append($0) }, didPublish: { _ in })
                        } catch { callbackFailure = error }
                    }
                }, onError: { errors.append($0) }, didPublish: { _ in
                    Issue.record("A failed recap must not publish a report")
                }))
            roots.append(root)
            try await gate.waitUntilEntered()
            gate.releaseAll()
            try await fixture.join(root)
            if let replacementRoot { try await fixture.join(replacementRoot) }
            if let callbackFailure { throw callbackFailure }
            #expect(failedFeedbackCount == 1)
            #expect(errors.isEmpty, "The failure callback revoked/replaced the old recap before the error publication boundary.")
            let reports = try fixture.app.recapRepository.versions(sessionID: fixture.session.id)
            #expect(reports.count == (action == .replace ? 1 : 0))
            #expect(history.pendingRecapTaskCount == 0)
            #expect(!history.isGeneratingRecap)
            try await cleanup()
        } catch {
            try? await cleanup()
            throw error
        }
    }
}

private final class RecapControlledFailureProvider: LocalLLMProvider {
    let id = "controlled-recap-failure"
    let displayName = "Controlled synthetic recap failure"
    let gate: RecapEntryGate
    init(gate: RecapEntryGate) { self.gate = gate }
    func healthCheck(modelName: String) async -> LocalLLMHealth {
        .init(ollamaRunning: true, selectedModel: modelName, modelInstalled: true,
            providerSource: .ollamaQwen, lastError: nil)
    }
    func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        if request.responseSchema != nil {
            return try await HermeticQuestionRoutingProvider().generateAnswer(request: request)
        }
        await gate.hold()
        try Task.checkCancellation()
        throw MaterialError.invalid("Controlled synthetic recap failure")
    }
}
