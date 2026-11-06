import Foundation
import Combine
import Testing
@testable import Hireva

#if DEBUG
/// Actual controller completion/shutdown with an existing injected deadline.
/// The DEBUG snapshot observes ownership only; finite packets are not model
/// quality evidence and the held clock is not a real 90-second timing test.
@Suite
@MainActor
struct PracticeNormalDeadlineRetirementTests {
    @Test(.timeLimit(.minutes(1)))
    func normalCompletionRetainsTheExactCancelledDeadlineUntilShutdownJoinsExit() async throws {
        let fixture = try PracticeDeadlineRetirementFixture()
        do {
            let controller = fixture.controller
            #expect(!controller.workCleanupSnapshot.retirementAttached)
            controller.start(kind: .generalKnowledge, question: "Explain the admitted transition boundary.",
                language: "en", criteria: ["State a boundary"], maxFollowUps: 0)
            controller.beginAnswer()
            controller.run?.draft = PracticeDeadlineRetirementFixture.answer
            fixture.observeCompletion()
            controller.submit()
            _ = try await TestEventWaitTrace(label: "PracticeNormalDeadline.completed")
                .nextEvent(in: fixture.completed.stream, event: "actual.completed.publication")
            // The callback, root defer and this consumer all use MainActor.
            // No await follows the completed publication before root defer.
            // This observation therefore runs after that synchronous stack.
            #expect(controller.run?.phase == .completed)
            #expect(controller.run?.attempts.first?.feedback?.covered.map(\.quote) == [PracticeDeadlineRetirementFixture.answer])
            #expect(fixture.completionError == nil)
            let snapshot = controller.workCleanupSnapshot
            #expect(!snapshot.evaluationAttached && !snapshot.deadlineAttached)
            #expect(snapshot.retirementAttached,
                "A normally finished evaluation must retain its exact cancelled deadline for actual shutdown join.")
            #expect(await fixture.deadline.durations == [90_000_000_000])
            #expect(await fixture.deadline.hasExited == false)
            _ = try await TestEventWaitTrace(label: "PracticeNormalDeadline.cancelled")
                .nextEvent(in: fixture.deadline.cancelled, event: "exact.deadline.cancel.receipt")
            #expect(await fixture.provider.evaluationPhases == ["primary", "critic"])

            fixture.startShutdown()
            _ = try await TestEventWaitTrace(label: "PracticeNormalDeadline.shutdown")
                .nextEvent(in: fixture.deadline.shutdownEntered, event: "owned.shutdown.started")
            // Release is explicit and finite even for a clock which ignores
            // cancellation. No negative wait, FIFO assumption or sleep is used.
            await fixture.deadline.release()
            await fixture.finishOwnedShutdown()
            let journal = await fixture.deadline.journal
            let exit = try #require(journal.firstIndex(of: "deadline.exited"))
            let returned = try #require(journal.firstIndex(of: "shutdown.returned"))
            #expect(exit < returned, "Shutdown must join the exact retired deadline through exit.")
            #expect(await fixture.deadline.hasExited)
            try await fixture.close()
        } catch {
            try? await fixture.close() // releases the latch before joining
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func shutdownWithoutEvaluationDoesNotCreateADeadlineRetirement() async throws {
        let fixture = try PracticeDeadlineRetirementFixture()
        do {
            #expect(fixture.controller.workCleanupSnapshot == .init(evaluationAttached: false,
                deadlineAttached: false, retirementAttached: false))
            await fixture.controller.shutdown()
            #expect(!fixture.controller.workCleanupSnapshot.retirementAttached)
            #expect(await fixture.deadline.durations.isEmpty)
            #expect(await fixture.provider.evaluationPhases.isEmpty)
            try await fixture.close()
        } catch {
            try? await fixture.close()
            throw error
        }
    }
}

@MainActor
private final class PracticeDeadlineRetirementFixture {
    static let answer = "The rule applies only to admitted transitions."
    let database: AppDatabase
    let deadline: HeldPracticeEvaluationDeadline
    let provider: DeadlineRetirementPacketProvider
    let controller: PracticeController
    let completed = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
    private(set) var completionError: String?
    private var observedCompletion = false
    private var subscription: AnyCancellable?
    private var shutdownTask: Task<Void, Never>?
    private var closed = false

    init() throws {
        let database = try AppDatabase(inMemory: true)
        self.database = database
        let deadline = HeldPracticeEvaluationDeadline()
        self.deadline = deadline
        let provider = DeadlineRetirementPacketProvider(deadline: deadline)
        self.provider = provider
        controller = PracticeController(dependencies: .init(
            repository: PracticeRepository(database: database), sessions: SessionRepository(database: database),
            questions: SuggestionRepository(database: database), contexts: InterviewContextRepository(database: database),
            persistenceConsent: PersistenceConsent(),
            context: { .init(historyEnabled: false, selection: .init(candidateProfileID: nil,
                opportunityContextID: nil, domainProfileID: .general), temporarySnapshotID: nil) },
            evaluationConfiguration: { (provider, "synthetic-deadline-retirement") },
            selectedASRProvider: { .localParakeet }, isLiveCaptureActive: { false }, prepareForPractice: {},
            requestAudioPermissions: { _ in throw MaterialError.invalid("Native audio is forbidden in this fixture.") },
            makeAudioProvider: { _ in throw MaterialError.invalid("Native audio is forbidden in this fixture.") },
            historyDidChange: { _ in }, delayProvider: deadline))
    }
    func observeCompletion() {
        subscription = controller.runUpdates.sink { [weak self] incoming in
            MainActor.assumeIsolated {
                guard let self, !self.observedCompletion, let incoming,
                      [.completed, .failed].contains(incoming.phase) else { return }
                self.observedCompletion = true
                if incoming.phase == .failed { self.completionError = self.controller.error ?? "Unexpected evaluation failure." }
                self.completed.continuation.yield(())
            }
        }
    }
    func startShutdown() {
        guard shutdownTask == nil else { return }
        let controller = controller, deadline = deadline
        shutdownTask = Task {
            await deadline.markShutdownEntered()
            await controller.shutdown()
            await deadline.markShutdownReturned()
        }
    }
    func finishOwnedShutdown() async { await shutdownTask?.value }
    func close() async throws {
        guard !closed else { return }
        subscription?.cancel(); subscription = nil
        completed.continuation.finish()
        await deadline.release()
        await shutdownTask?.value
        shutdownTask = nil
        await controller.shutdown()
        await deadline.finishSignals()
        try database.close()
        closed = true
    }
}

/// One finite, releasable operation using the actual DelayProvider seam.
/// Cancellation is observed but cannot release the continuation until the
/// owning fixture releases it. This deliberately tests cooperative cleanup.
private actor HeldPracticeEvaluationDeadline: DelayProvider {
    private nonisolated let entered: AsyncStream<Void>
    private let enteredContinuation: AsyncStream<Void>.Continuation
    nonisolated let cancelled: AsyncStream<Void>
    private nonisolated let cancelledContinuation: AsyncStream<Void>.Continuation
    nonisolated let shutdownEntered: AsyncStream<Void>
    private let shutdownEnteredContinuation: AsyncStream<Void>.Continuation
    private var held: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var durations: [UInt64] = []
    private(set) var hasExited = false
    private(set) var journal: [String] = []
    init() {
        let entry = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        entered = entry.stream; enteredContinuation = entry.continuation
        let cancel = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        cancelled = cancel.stream; cancelledContinuation = cancel.continuation
        let shutdown = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        shutdownEntered = shutdown.stream; shutdownEnteredContinuation = shutdown.continuation
    }
    nonisolated func waitForEntry() async {
        for await _ in entered { break }
    }
    func sleep(nanoseconds: UInt64) async throws {
        durations.append(nanoseconds)
        enteredContinuation.yield(()); enteredContinuation.finish()
        let cancellation = cancelledContinuation
        try await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if released { continuation.resume() } else { held = continuation }
            }
            hasExited = true
            journal.append("deadline.exited")
            try Task.checkCancellation()
        } onCancel: {
            cancellation.yield(()); cancellation.finish()
        }
    }
    func release() {
        released = true
        let continuation = held; held = nil
        continuation?.resume()
    }
    func markShutdownEntered() {
        journal.append("shutdown.entered")
        shutdownEnteredContinuation.yield(()); shutdownEnteredContinuation.finish()
    }
    func markShutdownReturned() { journal.append("shutdown.returned") }
    func finishSignals() {
        enteredContinuation.finish(); cancelledContinuation.finish(); shutdownEnteredContinuation.finish()
    }
}

private actor DeadlineRetirementPacketProvider: LocalLLMProvider {
    nonisolated let id = "synthetic-deadline-retirement"
    nonisolated let displayName = "Finite owned-deadline fixture packets"
    private let deadline: HeldPracticeEvaluationDeadline
    private(set) var evaluationPhases: [String] = []
    init(deadline: HeldPracticeEvaluationDeadline) { self.deadline = deadline }
    func healthCheck(modelName: String) async -> LocalLLMHealth {
        .init(ollamaRunning: true, selectedModel: modelName, modelInstalled: true,
            providerSource: .localQwen, lastError: nil)
    }
    nonisolated func pullModel(_ modelName: String) -> AsyncThrowingStream<ModelDownloadProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func generateAnswer(request: LocalLLMRequest) async throws -> AsyncThrowingStream<LLMToken, Error> {
        let system = request.systemPrompt ?? ""
        let output: String
        if system.contains("Evaluate this practice answer") || system.contains("Independently critique the complete original answer") {
            let review = system.contains("Independently critique the complete original answer")
            evaluationPhases.append(review ? "critic" : "primary")
            let packet = PracticeEvaluationPayload(coverage: ["r0": "The rule applies only to admitted transitions."],
                suggestion: "The requested boundary is stated.", followUp: nil,
                reason: "The supplied criterion is covered.",
                reference: "State the admitted transitions and the assumptions under which the rule applies.",
                reviewOutcome: review ? "accepted" : nil)
            output = String(decoding: try JSONEncoder().encode(packet), as: UTF8.self)
        } else {
            await deadline.waitForEntry()
            output = #"{"task":"generalKnowledge","personalEvidence":"notRequired","basis":"generalKnowledge","relation":"independent","clarification":""}"#
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.init(text: output, source: .localQwen, modelName: request.modelName))
            continuation.finish()
        }
    }
}
#endif
