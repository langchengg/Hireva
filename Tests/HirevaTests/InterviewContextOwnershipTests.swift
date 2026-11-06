import Combine
import Foundation
import Testing
@testable import Hireva

@MainActor
struct InterviewContextOwnershipTests {
    @Test(.timeLimit(.minutes(1)))
    func documentsUsesSameOwnerAndCompatibilityPublishesOneFact() async throws {
        try await withFixture { app in
            let owner = app.interviewContextState
            let view = DocumentsApplicationHost(appState: app).content
            #expect(view.context === owner)
            #expect(view.documents === app.documentsState)
            #expect(view.storySettings === app.settingsState)

            var ownerPublications = 0
            var appPublications = 0
            let ownerSubscription = owner.objectWillChange.sink { ownerPublications += 1 }
            let appSubscription = app.objectWillChange.sink { appPublications += 1 }
            // No suspension: these counts describe this actual fact mutation,
            // not unrelated feature initialization or rendered frame latency.
            app.activeCandidateProfileID = "synthetic-context-owner"
            #expect(owner.activeCandidateProfileID == "synthetic-context-owner")
            #expect(ownerPublications == 1)
            #expect(appPublications == 1)
            owner.activeOpportunityContextID = "synthetic-opportunity-owner"
            #expect(app.activeOpportunityContextID == "synthetic-opportunity-owner")
            #expect(ownerPublications == 2)
            #expect(appPublications == 2)
            ownerSubscription.cancel()
            appSubscription.cancel()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelledWorkerRemainsOwnedUntilActualBuilderExit() async throws {
        try await withFixture { app in
            let owner = app.interviewContextState
            let builder = ContextOwnerHeldBuilder()
            owner.builderOverride = builder
            let request = Task { await app.rebuildAutomaticInterviewContext(useLocalQwen: false) }
            do {
                try await builder.waitUntilStarted("context.owner.retirement")
                let worker = try #require(owner.worker)
                let id = owner.buildID
                owner.invalidateBuild()
                #expect(owner.buildID != id)
                #expect(worker.isCancelled)
                #expect(owner.worker == nil)
                #expect(owner.pendingTaskCount == 1)
                let shutdown = Task { await app.shutdownResources() }
                await builder.release()
                await request.value
                #expect(await shutdown.value)
                #expect(owner.pendingTaskCount == 0)
                #expect(!app.isActionLoading(ActionID.buildInterviewContext))
            } catch {
                await builder.release()
                request.cancel()
                await request.value
                throw error
            }
            await builder.release()
            request.cancel()
            await request.value
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func parentCancellationRestoresReadinessAfterReleasedWorkerExit() async throws {
        try await withFixture { app in
            let owner = app.interviewContextState
            let builder = ContextOwnerHeldBuilder()
            owner.builderOverride = builder
            let request = Task { await app.rebuildAutomaticInterviewContext(useLocalQwen: false) }
            do {
                try await builder.waitUntilStarted("context.owner.parent_cancel")
                #expect(owner.automaticContextReadiness == .extracting)
                request.cancel()
                await builder.release()
                await request.value
                #expect(owner.automaticContextReadiness == .noDocuments)
                #expect(!app.isActionLoading(ActionID.buildInterviewContext))
                #expect(owner.pendingTaskCount == 0)
            } catch {
                await builder.release()
                request.cancel()
                await request.value
                throw error
            }
            await builder.release()
            request.cancel()
            await request.value
        }
    }

    private func withFixture(_ body: (AppState) async throws -> Void) async throws {
        let database = try AppDatabase(inMemory: true)
        let app = AppState(database: database, questionRoutingProvider: HermeticQuestionRoutingProvider(),
            permissionService: HermeticPermissionService(),
            keychainService: KeychainService(store: InMemoryMockKeychainStore()), dialogueDefaults: nil)
        do {
            _ = try app.documentRepository.saveDocument(type: .cv,
                title: "Synthetic Context ownership document",
                content: "Synthetic fixture only. I implemented database transaction checks in a rehearsal project. This contains no real candidate material and creates no microphone or cloud request.")
            app.refreshAll()
            try await body(app)
        } catch {
            await app.shutdownForTesting()
            try? database.close()
            throw error
        }
        await app.shutdownForTesting()
        try database.close()
    }
}

private actor ContextOwnerHeldBuilder: InterviewContextBuilding {
    private let started: AsyncStream<Void>
    private let startedContinuation: AsyncStream<Void>.Continuation
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var released = false

    init() {
        let pair = AsyncStream<Void>.makeStream()
        started = pair.stream
        startedContinuation = pair.continuation
    }

    func buildContext(from documents: [DocumentRecord],
        previousConfirmedProfile: CandidateProfile?) async throws -> InterviewContextBuildResult {
        startedContinuation.yield(())
        startedContinuation.finish()
        if !released {
            await withCheckedContinuation { releaseContinuation = $0 }
        }
        return AutomaticInterviewContextBuilder.emptyResult
    }

    func waitUntilStarted(_ label: String) async throws {
        _ = try await TestEventWaitTrace(label: label).nextEvent(in: started, event: "builder.entered")
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
