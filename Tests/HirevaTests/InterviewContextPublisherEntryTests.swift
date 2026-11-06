import Combine
import Foundation
import os
import Testing
@testable import Hireva

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct InterviewContextPublisherEntryTests {
    @Test(arguments: [false, true])
    func resetFeedbackCannotLetTheOlderSubmissionAcquireTheNewerBuildID(existingWorker: Bool) async throws {
        let fixture = try ContextPublicationFixture()
        try await fixture.run {
            if existingWorker {
                fixture.owner.builderOverride = fixture.previousBuilder
                fixture.capture(fixture.owner.requestRebuild(useLocalQwen: false))
                try await fixture.control.waitUntilEntered("previous")
            }
            var armed = true
            var replacementID: UUID?
            var replacement: Task<Void, Never>?
            fixture.feedback.onClear = { id in
                guard armed, id == ActionID.buildInterviewContext else { return }
                armed = false
                // Capture the actual registration before the nested entry. On
                // the old baseline an idle outer request has no handle yet.
                fixture.captureCurrent()
                fixture.owner.builderOverride = fixture.newerBuilder
                replacement = fixture.owner.requestRebuild(useLocalQwen: false)
                replacementID = fixture.owner.buildID
                fixture.capture(replacement)
            }
            fixture.owner.builderOverride = fixture.outerBuilder
            let olderSubmission = fixture.owner.requestRebuild(useLocalQwen: false)
            fixture.capture(olderSubmission)
            fixture.captureCurrent()
            #expect(!armed)
            let newer = try #require(replacement)
            #expect(olderSubmission == nil,
                "An older submitting stack cannot resume after a newer synchronous entry took authority.")
            #expect(fixture.owner.buildID == replacementID)
            #expect(fixture.owner.worker == newer)
            #expect(!newer.isCancelled)
            let originalReceipts = fixture.receipts.values
            #expect(Set(originalReceipts.map(\.id)).count == originalReceipts.count,
                "Distinct original workers must not acquire the same build identity.")
            fixture.feedback.onClear = nil
            // The old path can prevent B entering, or launch it twice. Never
            // wait for an event that the baseline may make impossible.
            fixture.control.openAll()
            for receipt in fixture.receipts.values { await receipt.task.value }
            #expect(fixture.control.enteredNames == (existingWorker ? ["previous", "newer"] : ["newer"]))
            #expect(fixture.owner.activeCandidateProfileID == fixture.newerProfile.id)
            let storedSelection = try fixture.repository.loadSelection()
            #expect(storedSelection.candidateProfileID == fixture.newerProfile.id)
            #expect(fixture.owner.automaticContextBuildResult?.candidateProfile == fixture.newerProfile)
            #expect(fixture.owner.automaticContextReadiness == .ready)
            #expect(fixture.owner.worker == nil)
            #expect(fixture.owner.pendingTaskCount == 0)
        }
    }

    @Test(arguments: ContextPublicationStop.allCases)
    func readinessPublicationCannotRestoreExtractingAfterItsObserverStopsTheBuild(stop: ContextPublicationStop) async throws {
        let fixture = try ContextPublicationFixture()
        try await fixture.run {
            var armed = false
            var stopped = false
            fixture.feedback.onFeedback = { feedback in
                if feedback.kind == .loading { armed = true }
            }
            let observation = fixture.owner.objectWillChange.sink { _ in
                guard armed else { return }
                armed = false
                stopped = true
                fixture.captureCurrent()
                switch stop {
                case .cancel: fixture.owner.invalidateBuild()
                case .close: fixture.owner.closeAdmission()
                }
            }
            defer { observation.cancel() }
            fixture.owner.builderOverride = fixture.outerBuilder
            let request = fixture.owner.requestRebuild(useLocalQwen: false)
            fixture.capture(request)
            let original = try #require(request)
            await original.value
            #expect(stopped)
            #expect(fixture.control.enteredNames.isEmpty)
            #expect(fixture.owner.automaticContextReadiness == .noDocuments,
                "The old @Published setter must not overwrite the observer's committed stop reset.")
            #expect(fixture.owner.worker == nil)
            #expect(fixture.owner.pendingTaskCount == 0)
            #expect(fixture.feedback.values.filter { $0.kind == .success || $0.kind == .error }.isEmpty)
            let storedSelection = try fixture.repository.loadSelection()
            #expect(storedSelection.candidateProfileID == fixture.originalProfile.id)
        }
    }

    @Test(arguments: ContextPublicationCompletion.allCases)
    func aResultOrFailureSetterCannotUndoTheObserversNewerContext(completion: ContextPublicationCompletion) async throws {
        let fixture = try ContextPublicationFixture()
        try await fixture.run {
            fixture.owner.builderOverride = completion == .result ? fixture.outerBuilder : fixture.failingBuilder
            let request = fixture.owner.requestRebuild(useLocalQwen: false)
            fixture.capture(request)
            let original = try #require(request)
            try await fixture.control.waitUntilEntered(completion == .result ? "outer" : "failure")
            var armed = true
            var replaced = false
            var replacement: Task<Void, Never>?
            let observation = fixture.owner.objectWillChange.sink { _ in
                guard armed else { return }
                armed = false
                replaced = true
                fixture.captureCurrent()
                switch completion {
                case .result:
                    // The real result's first publication changes candidate ID.
                    // Selection inside that setter must remain both UI and DB
                    // authority after the older completion stack resumes.
                    fixture.owner.selectCandidateProfile(fixture.newerProfile.id)
                case .failure:
                    fixture.owner.builderOverride = fixture.newerBuilder
                    replacement = fixture.owner.requestRebuild(useLocalQwen: false)
                    fixture.capture(replacement)
                }
            }
            defer { observation.cancel() }
            fixture.control.openAll()
            await original.value
            if let replacement { await replacement.value }
            #expect(replaced)
            #expect(fixture.owner.activeCandidateProfileID == fixture.newerProfile.id)
            let storedSelection = try fixture.repository.loadSelection()
            #expect(storedSelection.candidateProfileID == fixture.newerProfile.id)
            #expect(fixture.owner.worker == nil)
            #expect(fixture.owner.pendingTaskCount == 0)
            switch completion {
            case .result:
                #expect(fixture.owner.contextConfigurationOrigin == .legacyManualContext)
                #expect(fixture.owner.automaticContextBuildResult == nil)
                #expect(fixture.owner.automaticContextReadiness == .noDocuments)
                #expect(fixture.feedback.values.filter { $0.kind == .success || $0.kind == .error }.isEmpty)
            case .failure:
                #expect(replacement != nil)
                #expect(fixture.owner.automaticContextBuildResult?.candidateProfile == fixture.newerProfile)
                #expect(fixture.owner.automaticContextReadiness == .ready)
                #expect(fixture.feedback.values.filter { $0.kind == .error }.isEmpty,
                    "The old failure cannot emit an error after its setter admitted a newer request.")
            }
        }
    }
}

enum ContextPublicationStop: String, CaseIterable, Sendable { case cancel, close }
enum ContextPublicationCompletion: String, CaseIterable, Sendable { case result, failure }

@MainActor
private final class ContextPublicationFixture {
    let database: AppDatabase
    let repository: InterviewContextRepository
    let owner: InterviewContextState
    let originalProfile: CandidateProfile
    let newerProfile: CandidateProfile
    let previousBuilder: ContextPublicationBuilder
    let outerBuilder: ContextPublicationBuilder
    let newerBuilder: ContextPublicationBuilder
    let failingBuilder: ContextPublicationBuilder
    let control = ContextPublicationControl()
    let receipts = ContextPublicationReceipts()
    let feedback = ContextPublicationFeedback()

    init() throws {
        database = try AppDatabase(inMemory: true)
        repository = InterviewContextRepository(database: database)
        let documents = DocumentRepository(database: database)
        let document = try documents.saveDocument(type: .cv,
            title: "Synthetic context publisher document",
            content: "Synthetic only: I validated isolated database transaction boundaries and cancellation with controlled test inputs. No real candidate, private material, microphone or cloud request is involved.")
        let evidence = ProfileEvidence(id: "synthetic-context-publication-evidence",
            statement: "I validated isolated database transaction boundaries and cancellation with controlled test inputs.",
            sourceDocumentID: document.id, sourceChunkID: nil,
            sourceSpan: "I validated isolated database transaction boundaries and cancellation with controlled test inputs.",
            confidence: 1, evidenceType: .project, explicitness: .userConfirmed)
        func profile(_ id: String) -> CandidateProfile {
            .init(id: id, displayName: "Synthetic context publisher profile", sourceDocumentIDs: [document.id],
                education: [], experience: [], projects: [evidence], skills: [], publications: [],
                achievements: [], declaredGaps: [], goals: [], generatedSummary: nil,
                version: 1, updatedAt: Date(timeIntervalSince1970: 1))
        }
        originalProfile = profile("synthetic-context-publication-original")
        newerProfile = profile("synthetic-context-publication-newer")
        let outerProfile = profile("synthetic-context-publication-outer")
        try repository.saveCandidateProfile(originalProfile)
        try repository.saveCandidateProfile(newerProfile)
        try repository.saveSelection(.init(candidateProfileID: originalProfile.id,
            opportunityContextID: nil, domainProfileID: .general))
        func result(_ candidate: CandidateProfile) -> InterviewContextBuildResult {
            var result = AutomaticInterviewContextBuilder.emptyResult
            result.candidateProfile = candidate
            result.readiness = .ready
            result.evidenceSummary = .init(candidateFactCount: 1, opportunityRequirementCount: 0,
                uncertainFactCount: 0, conflictCount: 0, candidateSourceTitles: [document.title], opportunitySourceTitles: [])
            result.classifications = [.init(documentID: document.id, type: .resume, confidence: 1,
                reason: "Synthetic controlled response; not model quality evidence")]
            return result
        }
        previousBuilder = ContextPublicationBuilder(name: "previous", result: result(outerProfile), control: control)
        outerBuilder = ContextPublicationBuilder(name: "outer", result: result(outerProfile), control: control)
        newerBuilder = ContextPublicationBuilder(name: "newer", result: result(newerProfile), control: control)
        failingBuilder = ContextPublicationBuilder(name: "failure", result: result(outerProfile), control: control, fails: true)
        let feedback = self.feedback, builder = outerBuilder
        owner = InterviewContextState(repository: repository, documents: documents,
            documentRecords: { [document] }, makeBuilder: { _ in builder },
            selectionWillChange: {}, domainDidChange: { _ in }, contextDidChange: {}, refreshApplication: {},
            feedback: { feedback.append($0) }, clearFeedback: { feedback.clear($0) }, showError: { _ in })
        try owner.reload(sessionSnapshotID: nil)
    }

    func capture(_ task: Task<Void, Never>?) {
        if let task { receipts.append(id: owner.buildID, task: task) }
    }
    func captureCurrent() { capture(owner.worker) }

    func run(_ body: () async throws -> Void) async throws {
        do {
            try await withTaskCancellationHandler { try await body() } onCancel: { [control, receipts] in
                control.openAll()
                receipts.cancelAll()
            }
            try await close()
        } catch {
            try? await close()
            throw error
        }
    }
    private func close() async throws {
        feedback.onClear = nil
        feedback.onFeedback = nil
        captureCurrent()
        owner.closeAdmission()
        control.openAll()
        receipts.cancelAll()
        for receipt in receipts.values { await receipt.task.value }
        await owner.shutdown()
        try database.close()
    }
}

@MainActor
private final class ContextPublicationFeedback {
    private(set) var values: [ActionFeedback] = []
    var onFeedback: ((ActionFeedback) -> Void)?
    var onClear: ((String) -> Void)?
    func append(_ value: ActionFeedback) { values.append(value); onFeedback?(value) }
    func clear(_ id: String) { onClear?(id) }
}

private actor ContextPublicationBuilder: InterviewContextBuilding {
    private let name: String
    private let result: InterviewContextBuildResult
    private let control: ContextPublicationControl
    private let fails: Bool
    init(name: String, result: InterviewContextBuildResult, control: ContextPublicationControl, fails: Bool = false) {
        self.name = name; self.result = result; self.control = control; self.fails = fails
    }
    func buildContext(from documents: [DocumentRecord], previousConfirmedProfile: CandidateProfile?) async throws -> InterviewContextBuildResult {
        await control.wait(name)
        if fails { throw ContextPublicationFailure() }
        return result
    }
}

private struct ContextPublicationFailure: LocalizedError {
    var errorDescription: String? { "Synthetic controlled context build failure." }
}

/// Checked synthetic gate; owning cancellation, fixture errors and success all
/// release every continuation before joining original public Task receipts.
private final class ContextPublicationControl: Sendable {
    private struct State: Sendable {
        var opened = false
        var enteredNames: [String] = []
        var waiting: [CheckedContinuation<Void, Never>] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let entries = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(8))
    private let trace = TestEventWaitTrace(label: "context_publication_entry")
    var enteredNames: [String] { state.withLock { $0.enteredNames } }
    func wait(_ name: String) async {
        await withCheckedContinuation { continuation in
            let resume = state.withLock { value in
                value.enteredNames.append(name)
                if value.opened { return true }
                value.waiting.append(continuation)
                return false
            }
            entries.continuation.yield(name)
            if resume { continuation.resume() }
        }
    }
    func waitUntilEntered(_ name: String) async throws {
        while !enteredNames.contains(name) {
            _ = try await trace.nextEvent(in: entries.stream, event: name)
        }
    }
    func openAll() {
        let waiting = state.withLock { value in
            value.opened = true
            let pending = value.waiting
            value.waiting.removeAll()
            return pending
        }
        waiting.forEach { $0.resume() }
        entries.continuation.finish()
    }
}

private final class ContextPublicationReceipts: Sendable {
    struct Receipt: Sendable { let id: UUID; let task: Task<Void, Never> }
    private let stored = OSAllocatedUnfairLock(initialState: [Receipt]())
    var values: [Receipt] { stored.withLock { $0 } }
    func append(id: UUID, task: Task<Void, Never>) {
        stored.withLock { if !$0.contains(where: { $0.task == task }) { $0.append(.init(id: id, task: task)) } }
    }
    func cancelAll() { values.forEach { $0.task.cancel() } }
}
