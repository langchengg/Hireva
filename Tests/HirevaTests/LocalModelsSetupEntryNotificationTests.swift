import AVFoundation
import Combine
import Foundation
import os
import Testing
@testable import Hireva

@MainActor
struct LocalModelsSetupEntryNotificationTests {
    enum StreamAction: CaseIterable, Sendable { case download, pull }

    // Existing API only: the production Published error-clear callback closes
    // admission synchronously before the submission has registered its Task.
    @Test(.timeLimit(.minutes(1)), arguments: StreamAction.allCases)
    func errorClearObserverCannotStartDependenciesAfterClosingAdmission(action: StreamAction) async {
        let counts = SetupEntryCounts()
        let owner = makeOwner(counts)
        var didClose = false
        let observation = owner.$lastError.dropFirst().sink { _ in
            MainActor.assumeIsolated {
                guard !didClose else { return }
                didClose = true
                owner.closeAdmission()
            }
        }
        defer { observation.cancel() }
        switch action {
        case .download: owner.downloadTranscriptionModel()
        case .pull: owner.pullQwen(modelName: "synthetic-entry-qwen")
        }
        await owner.waitForPendingOperations()
        #expect(didClose, "The actual synchronous error publication must exercise the admission boundary.")
        #expect(counts.snapshot.downloads == 0,
            "A stream operation called its model dependency after shutdown closed admission.")
        #expect(counts.snapshot.pulls == 0,
            "A Qwen pull was started after the error observer closed admission.")
        #expect(owner.pendingOperationTaskCount == 0)
        observation.cancel()
        #expect(await owner.shutdown())
    }

    // The first real control objectWillChange may come from invalidateRefresh.
    // A later Task must still check its submitted ownership before any model IO.
    @Test(.timeLimit(.minutes(1)))
    func firstControlPublicationCannotRefreshAfterClosingAdmission() async {
        let counts = SetupEntryCounts()
        let owner = makeOwner(counts)
        var didClose = false
        let observation = owner.objectWillChange.sink { _ in
            MainActor.assumeIsolated {
                guard !didClose else { return }
                didClose = true
                owner.closeAdmission()
            }
        }
        defer { observation.cancel() }
        owner.requestRefresh(qwenModel: "synthetic-entry-qwen")
        await owner.waitForPendingOperations()
        #expect(didClose)
        #expect(counts.snapshot.statuses == 0,
            "Readiness invoked modelStatus after a synchronous control observer closed admission.")
        #expect(counts.snapshot.health == 0)
        #expect(counts.snapshot.runtimeChecks == 0)
        #expect(owner.pendingOperationTaskCount == 0)
        observation.cancel()
        #expect(await owner.shutdown())
    }

    private func makeOwner(_ counts: SetupEntryCounts) -> LocalModelsSetupViewModel {
        LocalModelsSetupViewModel(modelManager: SetupEntryManager(counts: counts),
            qwenProvider: SetupEntryQwen(counts: counts), parakeetRuntimeClient: SetupEntryRuntime(counts: counts))
    }
}

private final class SetupEntryCounts: Sendable {
    struct Snapshot: Sendable { var downloads = 0; var pulls = 0; var statuses = 0; var health = 0; var runtimeChecks = 0 }
    private let state = OSAllocatedUnfairLock(initialState: Snapshot())
    var snapshot: Snapshot { state.withLock { $0 } }
    func download() { state.withLock { $0.downloads += 1 } }
    func pull() { state.withLock { $0.pulls += 1 } }
    func status() { state.withLock { $0.statuses += 1 } }
    func health() { state.withLock { $0.health += 1 } }
    func runtime() { state.withLock { $0.runtimeChecks += 1 } }
}

private struct SetupEntryManager: LocalModelManager, Sendable {
    let counts: SetupEntryCounts
    func modelStatus(_ model: LocalModelDescriptor) async -> LocalModelStatus { counts.status(); return .notInstalled }
    func downloadModel(_ model: LocalModelDescriptor) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        counts.download(); return AsyncThrowingStream { $0.finish() }
    }
    func deleteModel(_ model: LocalModelDescriptor) async throws {}
    func verifyModel(_ model: LocalModelDescriptor) async throws -> Bool { false }
    func fileURL(for model: LocalModelDescriptor) -> URL {
        URL(fileURLWithPath: "/synthetic-unopened-entry-model").appendingPathComponent(model.storageRelativePath)
    }
}
private struct SetupEntryQwen: LocalLLMProvider, Sendable {
    let counts: SetupEntryCounts
    let id = "synthetic-entry-qwen"
    let displayName = "Synthetic Entry Qwen"
    func healthCheck(modelName: String) async -> LocalLLMHealth {
        counts.health()
        return .init(ollamaRunning: false, selectedModel: modelName, modelInstalled: false,
            providerSource: .ollamaQwen, lastError: nil)
    }
    func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        counts.pull(); return AsyncThrowingStream { $0.finish() }
    }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        throw CancellationError()
    }
}
private final class SetupEntryRuntime: ParakeetRuntimeClient, Sendable {
    let counts: SetupEntryCounts
    init(counts: SetupEntryCounts) { self.counts = counts }
    func isRuntimeAvailable() async -> Bool { counts.runtime(); return false }
    func startTranscription(modelDirectory: URL, config: ASRConfig) async throws -> AsyncThrowingStream<ParakeetTranscriptEvent, Error> {
        throw CancellationError()
    }
    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {}
    func stop() async {}
}
